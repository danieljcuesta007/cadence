// AppMain — composition root for `cadence run` (menu-bar agent) and the WAV selftest.

import AppKit
import CadenceCapture
import CadenceHotkeys
import CadenceInsertion
import CadenceOverlay
import Foundation
import IOKit.hid
import ServiceManagement

// MARK: - Menu-bar agent

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let config: Config
    var statusItem: NSStatusItem!
    let stateMenuItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    let router = EffectRouter()
    let overlay = OverlayHUD()
    let capture = AudioCapture()
    let hotkeys = HotkeyMonitor()
    var engine: CoreEngine?
    var pttDownAt: Date?
    var historyStore: HistoryStore?
    /// PTT-down reads this cache, never the DB (§28: the hot path stays hot).
    var disabledApps: Set<String> = []
    let disableItem = NSMenuItem(title: "Disable in This App", action: nil, keyEquivalent: "")
    /// Frontmost app captured when the menu opens (stable while it's held open).
    var menuFrontApp: String?
    /// A PTT-down swallowed by a per-app rule must also swallow its up.
    var pttSwallowed = false
    /// §24 retained audio: cached opt-in flag (capture start reads this, never the DB).
    var retainAudio = false
    let retainAudioItem = NSMenuItem(
        title: "Keep Audio Recordings", action: nil, keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Start at Login", action: nil, keyEquivalent: "")
    let builtInMicItem = NSMenuItem(
        title: "Use Built-in Microphone", action: nil, keyEquivalent: "")
    let voiceIsolationItem = NSMenuItem(
        title: "Voice Isolation (Experimental)", action: nil, keyEquivalent: "")
    let retentionItem = NSMenuItem(title: "Keep History", action: nil, keyEquivalent: "")
    /// §24 retention choices surfaced in the menu (days; 0 = forever).
    static let retentionChoices: [(String, Int64)] = [
        ("Forever", 0), ("90 Days", 90), ("30 Days", 30), ("7 Days", 7),
    ]
    var dictionaryWindow: DictionaryWindowController?
    let languageItem = NSMenuItem(title: "Dictation Language", action: nil, keyEquivalent: "")
    /// Language menu: label → code passed to the core ("auto" detects per utterance).
    static let languageChoices: [(String, String)] = [
        ("Automatic", "auto"), ("English", "en"), ("Spanish", "es"),
    ]
    /// Cached so menuNeedsUpdate can tick the current choice without hitting the DB.
    var dictationLanguage = "auto"
    // Held during an utterance: App Nap must never throttle a decode mid-dictation
    // (§28 latency budgets; suspected cause of a one-off 30 s Metal stall in testing).
    var activity: NSObjectProtocol?

    init(config: Config) {
        self.config = config
    }

    /// AppleScript/⌘Q quits bypass our menu action — free the engine here too, or ggml's
    /// Metal atexit teardown aborts (see quit()).
    func applicationWillTerminate(_ notification: Notification) {
        engine = nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        renderState("idle")
        let menu = NSMenu()
        stateMenuItem.isEnabled = false
        menu.addItem(stateMenuItem)
        menu.addItem(
            NSMenuItem(
                title: "Hold Right-Option to dictate · Esc cancels · ⌃⌥⌘Z undoes",
                action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let dashItem = NSMenuItem(
            title: "History & Metrics…", action: #selector(showDashboard), keyEquivalent: "d")
        dashItem.target = self
        menu.addItem(dashItem)
        let undoItem = NSMenuItem(
            title: "Undo Last Dictation", action: #selector(undoLast), keyEquivalent: "z")
        undoItem.keyEquivalentModifierMask = [.control, .option, .command]
        undoItem.target = self
        menu.addItem(undoItem)
        menu.addItem(.separator())
        // Per-app rule (§7 per-app overrides, first slice): toggle dictation for whatever
        // app is frontmost when the menu opens (we're an LSUIElement — opening the menu
        // does not steal frontmost). Title/state refresh in menuNeedsUpdate.
        disableItem.action = #selector(toggleDisableFrontApp)
        disableItem.target = self
        menu.addItem(disableItem)
        // §24 retained audio, opt-in (default off): keep each dictation's audio as an
        // encrypted blob alongside its transcript. Disabled entirely when the store is
        // unavailable — audio never goes to the JSONL fallback.
        retainAudioItem.action = #selector(toggleRetainAudio)
        retainAudioItem.target = self
        menu.addItem(retainAudioItem)
        // §24 retention window as a submenu (Forever/90/30/7) — the interim Settings UI.
        let retentionMenu = NSMenu()
        for (label, days) in Self.retentionChoices {
            let item = NSMenuItem(
                title: label, action: #selector(pickRetention(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(days)
            retentionMenu.addItem(item)
        }
        retentionItem.submenu = retentionMenu
        menu.addItem(retentionItem)
        // Bluetooth mics mean HFP telephony audio (ASR-hostile, music-degrading): the
        // built-in mic is preferred by default; this is the escape hatch.
        builtInMicItem.action = #selector(toggleBuiltInMic)
        builtInMicItem.target = self
        menu.addItem(builtInMicItem)
        // Apple AEC + noise suppression on capture (café/office ambience otherwise leaks
        // into transcripts). Fallback logic in AudioCapture keeps it from ever blocking.
        voiceIsolationItem.action = #selector(toggleVoiceIsolation)
        voiceIsolationItem.target = self
        menu.addItem(voiceIsolationItem)
        // Dictation language (auto-detect by default; Spanish needs the multilingual model).
        let languageMenu = NSMenu()
        for (label, code) in Self.languageChoices {
            let item = NSMenuItem(
                title: label, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
        // Personal dictionary: proper nouns / jargon the user wants spelled their way.
        let dictItem = NSMenuItem(
            title: "Personal Dictionary…", action: #selector(showDictionary), keyEquivalent: "")
        dictItem.target = self
        menu.addItem(dictItem)
        // Daily-driver basics: the app should survive a reboot without being remembered.
        loginItem.action = #selector(toggleStartAtLogin)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Quit Cadence", action: #selector(quit), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu

        router.overlay = overlay
        router.capture = capture
        router.uiQueue = .main
        // Encrypted store (§24): key from the login keychain, DB at ~/.cadence/store.db.
        // Nil (keychain refused / bad open) keeps the JSONL stand-in — never a gate.
        let store = HistoryStore()
        historyStore = store
        router.historyStore = store
        HistoryReader.store = store
        disabledApps = store?.disabledApps() ?? []
        retainAudio = store?.retainAudioEnabled ?? false
        dictationLanguage = store?.dictationLanguage ?? "auto"
        router.retainAudioEnabled = { [weak self] in self?.retainAudio ?? false }
        capture.preferBuiltInMic = store?.preferBuiltInMic ?? true
        capture.voiceIsolation = store?.voiceIsolation ?? true
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
            // Per-app rule: dictation is off here — say so briefly, touch nothing else.
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            if self.disabledApps.contains(front) {
                self.pttSwallowed = true
                self.overlay.show(state: "disabled", chip: nil)
                self.overlay.scheduleFade(after: 0.9)
                return
            }
            self.pttDownAt = Date()
            if self.activity == nil {
                self.activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .latencyCritical], reason: "dictation")
            }
            self.engine?.triggerDown(verbatim: self.config.verbatim)
        }
        hotkeys.onPTTUp = { [weak self] in
            guard let self else { return }
            // Symmetry with the gate above: a swallowed down means nothing to stop.
            if self.pttSwallowed {
                self.pttSwallowed = false
                return
            }
            self.engine?.triggerUp()
        }
        hotkeys.onCancel = { [weak self] in self?.engine?.cancel() }
        hotkeys.onUndo = { [weak self] in self?.router.undoLastInsertion() }
        startHotkeysOrOnboard()

        capture.onChunk = { [weak self] samples, level in
            self?.engine?.pushAudio(samples, level: level)
            self?.router.retainChunk(samples)
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
            // Pay tap-install/converter/prepare costs now, not on the first key-down (§28).
            self.capture.prewarm()
            DispatchQueue.global(qos: .userInitiated).async {
                let t0 = Date()
                let engine = CoreEngine(backend: makeBackend(self.config)) { [weak self] json in
                    self?.router.route(json)
                }
                guard let engine else { exit(1) }
                DispatchQueue.main.async {
                    self.engine = engine
                    // Apply the saved language now that the engine exists (env default is
                    // "auto"; this makes a persisted English/Spanish choice stick across launches).
                    engine.setLanguage(self.dictationLanguage)
                    // Restore the personal dictionary so custom spellings survive a relaunch.
                    let vocab = Vocabulary.prompt(from: self.historyStore?.customVocabulary ?? "")
                    if !vocab.isEmpty { engine.setVocabulary(vocab) }
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    self.router.log(
                        "core ready in \(ms) ms (core v\(CoreEngine.coreVersion)) — "
                            + "hold Right-Option to dictate")
                    self.renderState("idle")
                }
            }
        }
    }

    /// First launch of the .app has no Accessibility grant (new TCC identity): trigger the
    /// system prompt (which also adds Cadence to the Settings list), then poll until the
    /// grant lands and the tap can start — never crash, never require a relaunch (§10.1).
    /// A keyDown event tap can ALSO require Input Monitoring (separate TCC service) on
    /// modern macOS: if AX reports trusted but the tap still fails, request that too and
    /// log the distinction — otherwise the two failure modes are indistinguishable live.
    private var requestedInputMonitoring = false
    private var lastAXTrusted: Bool?

    private func startHotkeysOrOnboard() {
        if hotkeys.start() { return }
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        router.log(
            "waiting for Accessibility — System Settings → Privacy & Security → "
                + "Accessibility → enable Cadence")
        stateMenuItem.title = "Grant Accessibility to enable dictation"
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if self.hotkeys.start() {
                timer.invalidate()
                self.router.log("permissions granted — hotkeys live")
                self.renderState("idle")
                return
            }
            let trusted = AXIsProcessTrusted()
            if trusted != self.lastAXTrusted {
                self.lastAXTrusted = trusted
                self.router.log(
                    "event tap unavailable (AXIsProcessTrusted=\(trusted)) — "
                        + (trusted
                            ? "Accessibility OK, likely Input Monitoring"
                            : "Accessibility not granted to THIS binary"))
            }
            if trusted, !self.requestedInputMonitoring {
                self.requestedInputMonitoring = true
                self.router.log("requesting Input Monitoring (kIOHIDRequestTypeListenEvent)")
                _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                self.stateMenuItem.title = "Grant Input Monitoring to enable dictation"
            }
        }
    }

    func renderState(_ state: String) {
        // SF Symbols, template-rendered: adapts to menu-bar light/dark, no emoji.
        let symbols = [
            "idle": "mic", "listening": "mic.fill", "thinking": "ellipsis",
            "inserting": "arrow.down.to.line", "done": "checkmark", "cancelled": "mic",
            "error": "exclamationmark.triangle", "disabled": "pause",
        ]
        let name = symbols[state] ?? "mic"
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: state) {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = state.prefix(1).uppercased()
        }
        stateMenuItem.title = engine == nil ? "Loading model…" : state.capitalized
    }

    private var dashboard: DashboardWindowController?

    // MARK: menu

    /// Refresh the per-app toggle for whatever is frontmost as the menu opens. We're an
    /// LSUIElement, so opening our menu leaves the user's app frontmost.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName
        menuFrontApp = front
        if let front, historyStore != nil {
            let off = disabledApps.contains(front)
            disableItem.title = off ? "Enable in \(front)" : "Disable in \(front)"
            disableItem.state = off ? .on : .off
            disableItem.isEnabled = true
        } else {
            disableItem.title = "Disable in This App"
            disableItem.isEnabled = false
        }
        retainAudioItem.state = retainAudio ? .on : .off
        retainAudioItem.isEnabled = historyStore != nil
        retentionItem.isEnabled = historyStore != nil
        let current = historyStore?.retentionDays ?? 0
        for item in retentionItem.submenu?.items ?? [] {
            item.state = Int64(item.tag) == current ? .on : .off
        }
        // SMAppService only manages a real .app bundle; dev `cadence run` can't register.
        loginItem.isEnabled = Bundle.main.bundlePath.hasSuffix(".app")
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        builtInMicItem.state = capture.preferBuiltInMic ? .on : .off
        voiceIsolationItem.state = capture.voiceIsolation ? .on : .off
        for item in languageItem.submenu?.items ?? [] {
            item.state = (item.representedObject as? String) == dictationLanguage ? .on : .off
        }
    }

    @objc func pickLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        dictationLanguage = code
        historyStore?.setDictationLanguage(code)
        engine?.setLanguage(code)  // instant — no model reload
        let label = Self.languageChoices.first { $0.1 == code }?.0 ?? code
        router.log("dictation language → \(label) (\(code))")
    }

    @objc func showDictionary() {
        let current = historyStore?.customVocabulary ?? ""
        let controller = DictionaryWindowController(initial: current) { [weak self] text in
            guard let self else { return }
            self.historyStore?.setCustomVocabulary(text)
            let prompt = Vocabulary.prompt(from: text)
            self.engine?.setVocabulary(prompt)  // instant — no model reload
            let count = text.split(whereSeparator: \.isNewline).filter {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }.count
            self.router.log("personal dictionary saved (\(count) terms)")
        }
        dictionaryWindow = controller
        controller.showWindow(nil)
    }

    @objc func toggleBuiltInMic() {
        let on = !capture.preferBuiltInMic
        capture.setPreferBuiltInMic(on)
        historyStore?.setPreferBuiltInMic(on)
        router.log("built-in mic preference → \(on ? "on" : "off (system default input)")")
    }

    @objc func toggleVoiceIsolation() {
        let on = !capture.voiceIsolation
        capture.setVoiceIsolation(on)
        historyStore?.setVoiceIsolation(on)
        router.log("voice isolation → \(on ? "on" : "off")")
    }

    @objc func pickRetention(_ sender: NSMenuItem) {
        guard let store = historyStore else { return }
        store.setRetentionDays(Int64(sender.tag))
        router.log("history retention → \(sender.tag == 0 ? "forever" : "\(sender.tag) days")")
    }

    @objc func toggleStartAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                router.log("start at login → off")
            } else {
                try SMAppService.mainApp.register()
                router.log("start at login → on")
            }
        } catch {
            router.log("start-at-login toggle failed: \(error)")
        }
    }

    @objc func toggleRetainAudio() {
        guard let store = historyStore else { return }
        retainAudio.toggle()
        store.setRetainAudio(retainAudio)
        router.log("retained audio → \(retainAudio ? "on" : "off")")
    }

    @objc func toggleDisableFrontApp() {
        guard let app = menuFrontApp, let store = historyStore else { return }
        let nowDisabled = !disabledApps.contains(app)
        store.setApp(app, disabled: nowDisabled)
        disabledApps = store.disabledApps()
        router.log("per-app rule: \(app) → \(nowDisabled ? "disabled" : "enabled")")
    }

    @objc func undoLast() {
        router.undoLastInsertion()
    }

    // Clicking Cadence in the Dock/Finder (or `open`-ing it while it's already running)
    // routes here instead of launching a second copy. We're an accessory app with no
    // window of its own, so without this the click appears to "do nothing" — surface the
    // dashboard, which is the thing a user is looking for when they click the app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showDashboard()
        return true
    }

    @objc func showDashboard() {
        if dashboard == nil { dashboard = DashboardWindowController() }
        // Accessory apps don't come forward on their own; activate so the window is
        // actually visible and focused rather than opening behind everything.
        NSApp.activate(ignoringOtherApps: true)
        dashboard?.showWindow(nil)
        dashboard?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func quit() {
        hotkeys.stop()
        capture.stop()
        // Free the engine BEFORE terminate: ggml's Metal teardown asserts in atexit
        // (__cxa_finalize) when the device is still alive — every quit wrote a SIGABRT
        // .ips to DiagnosticReports. cadence_engine_free joins the core threads and
        // drops whisper cleanly first.
        engine = nil
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
