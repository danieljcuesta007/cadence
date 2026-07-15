// AppMain — composition root for `cadence run` (menu-bar agent) and the WAV selftest.

import AppKit
import CadenceCapture
import CadenceHotkeys
import CadenceInsertion
import CadenceOverlay
import Foundation

// MARK: - Menu-bar agent

final class AppDelegate: NSObject, NSApplicationDelegate {
    let config: Config
    var statusItem: NSStatusItem!
    let stateMenuItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    let router = EffectRouter()
    let overlay = OverlayHUD()
    let capture = AudioCapture()
    let hotkeys = HotkeyMonitor()
    var engine: CoreEngine?
    var pttDownAt: Date?
    // Held during an utterance: App Nap must never throttle a decode mid-dictation
    // (§28 latency budgets; suspected cause of a one-off 30 s Metal stall in testing).
    var activity: NSObjectProtocol?

    init(config: Config) {
        self.config = config
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙"
        let menu = NSMenu()
        stateMenuItem.isEnabled = false
        menu.addItem(stateMenuItem)
        menu.addItem(
            NSMenuItem(
                title: "Hold Right-Option to dictate · Esc cancels", action: nil,
                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Quit Cadence", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        router.overlay = overlay
        router.capture = capture
        router.uiQueue = .main
        router.engine = { [weak self] in self?.engine }
        router.statusUpdate = { [weak self] state in
            guard let self else { return }
            self.renderState(state)
            if state == "idle", let a = self.activity {
                ProcessInfo.processInfo.endActivity(a)
                self.activity = nil
            }
        }

        // Hotkeys before anything heavy: if Accessibility is missing there's no product.
        hotkeys.isActive = { [weak self] in (self?.router.activeState ?? "idle") != "idle" }
        hotkeys.onPTTDown = { [weak self] in
            guard let self else { return }
            self.pttDownAt = Date()
            if self.activity == nil {
                self.activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .latencyCritical], reason: "dictation")
            }
            self.engine?.triggerDown(verbatim: self.config.verbatim)
        }
        hotkeys.onPTTUp = { [weak self] in self?.engine?.triggerUp() }
        hotkeys.onCancel = { [weak self] in self?.engine?.cancel() }
        guard hotkeys.start() else {
            fatalError(
                "CGEvent tap failed — grant Accessibility to this binary/terminal and rerun")
        }

        capture.onChunk = { [weak self] samples, level in
            self?.engine?.pushAudio(samples, level: level)
        }

        // Mic permission just-in-time would be at first PTT; the spine asks at launch so a
        // dictation never silently records nothing. Model load happens off-main (cold
        // whisper load is ~0.5 s and must not block the run loop).
        AudioCapture.requestMicAccess { granted in
            guard granted else {
                self.router.log(
                    "mic access denied — System Settings → Privacy & Security → Microphone")
                exit(1)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let t0 = Date()
                let engine = CoreEngine(backend: makeBackend(self.config)) { [weak self] json in
                    self?.router.route(json)
                }
                guard let engine else { exit(1) }
                DispatchQueue.main.async {
                    self.engine = engine
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    self.router.log(
                        "core ready in \(ms) ms (core v\(CoreEngine.coreVersion)) — "
                            + "hold Right-Option to dictate")
                    self.renderState("idle")
                }
            }
        }
    }

    func renderState(_ state: String) {
        let glyphs = [
            "idle": "🎙", "listening": "🔴", "thinking": "✦", "inserting": "↳",
            "done": "✓", "cancelled": "🎙", "error": "⚠︎", "disabled": "⏸",
        ]
        statusItem.button?.title = glyphs[state] ?? "🎙"
        stateMenuItem.title = engine == nil ? "Loading model…" : state.capitalized
    }

    @objc func quit() {
        hotkeys.stop()
        capture.stop()
        NSApp.terminate(nil)
    }
}

func runApp(_ config: Config) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // menu-bar agent: no Dock icon, steals no focus
    let delegate = AppDelegate(config: config)
    app.delegate = delegate
    app.run()
}

// MARK: - WAV-injection selftest

func runSelftest(_ config: Config) -> Int32 {
    guard let wavPath = config.wav else {
        FileHandle.standardError.write(Data("selftest-wav requires a wav path\n".utf8))
        return 2
    }
    let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical], reason: "spine selftest")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    let samples: [Int16]
    do { samples = try WavLoader.load16kMono(wavPath) } catch {
        FileHandle.standardError.write(Data("wav load failed: \(error)\n".utf8))
        return 2
    }

    let router = EffectRouter()
    router.uiQueue = nil // headless: execute inline on the core thread
    router.earconsEnabled = false
    // Phase-0 lesson, now structural: a selftest NEVER inserts without a frontmost guard.
    // Default target is TextEdit; there is deliberately no way to turn the guard off.
    let expect = config.expectApp ?? "TextEdit"
    router.insertionGuard = {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        return front == expect ? nil : "frontmost is \(front), expected \(expect)"
    }

    let done = DispatchSemaphore(value: 0)
    var insertedText: String?
    router.onIdle = { text in
        insertedText = text
        done.signal()
    }

    let t0 = Date()
    var engineRef: CoreEngine?
    let engine = CoreEngine(backend: makeBackend(config)) { json in
        router.route(json)
    }
    guard let engine else { return 1 }
    engineRef = engine
    router.engine = { engineRef }
    let loadMs = Int(Date().timeIntervalSince(t0) * 1000)

    let t1 = Date()
    engine.triggerDown(verbatim: config.verbatim)
    var i = 0
    while i < samples.count {
        let end = min(i + 1600, samples.count) // mic-sized ~100 ms chunks
        engine.pushAudio(Array(samples[i..<end]), level: 0.5)
        i = end
    }
    engine.triggerUp()

    guard done.wait(timeout: .now() + 30) == .success else {
        FileHandle.standardError.write(Data("selftest TIMEOUT\n".utf8))
        return 1
    }
    let pipelineMs = Int(Date().timeIntervalSince(t1) * 1000)

    let report: [String: Any] = [
        "wav": wavPath,
        "samples": samples.count,
        "model_load_ms": loadMs,
        "pipeline_ms": pipelineMs,
        "inserted_text": insertedText ?? NSNull(),
        "pass": insertedText != nil,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: report),
        let s = String(data: data, encoding: .utf8)
    {
        print(s)
    }
    return insertedText != nil ? 0 : 1
}
