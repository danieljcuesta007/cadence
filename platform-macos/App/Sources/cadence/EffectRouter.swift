// EffectRouter — the shell-side interpreter of core effects (ADR-0001/0005).
//
// route() is called on the core's orchestrator thread. UI work trampolines to `uiQueue`
// (main in app mode, nil = inline in selftest mode); insertion runs on its own serial
// queue, off any UI thread, per §16.3.

import AppKit
import CadenceCapture
import CadenceInsertion
import CadenceOverlay
import Foundation

final class EffectRouter {
    // Wired by the composition root; all optional so selftest can run headless.
    var overlay: OverlayHUD?
    var statusUpdate: ((String) -> Void)?
    var capture: AudioCapture?
    var engine: (() -> CoreEngine?) = { nil }
    /// nil = allowed; otherwise the refusal reason. Selftest installs a frontmost-app
    /// guard here; live dictation intentionally has none — the focused field IS the target.
    var insertionGuard: (() -> String?)?
    var uiQueue: DispatchQueue?
    var earconsEnabled = true
    /// Selftest hook: fires on fade-to-idle with the last inserted text (nil = none).
    var onIdle: ((String?) -> Void)?
    /// Encrypted store (§24); nil (keychain/open failure) keeps the JSONL stand-in.
    var historyStore: HistoryStore?

    private let insertionEngine = InsertionEngine()
    private let insertionQueue = DispatchQueue(label: "cadence.insertion", qos: .userInteractive)
    private var lastInsertedText: String?
    private var captureStartedAt: Date?

    /// Per-utterance timings, merged into the history record at persist time so the
    /// dashboard reads real numbers per dictation. Touched from uiQueue, insertionQueue,
    /// and the core thread — lock-guarded.
    private let metricsLock = NSLock()
    private var utteranceMetrics: [String: Any] = [:]

    // §26/F21 undo state: written on insertionQueue, armed on the core thread, fired on
    // main (hotkey/menu) — lock-guarded.
    struct UndoRecord {
        let app: String
        let text: String
        let at: Date
        var armed: Bool
    }
    private let undoLock = NSLock()
    private var undoRecord: UndoRecord?

    /// F21: revert the last dictation. Insertions land as a single undoable unit (one paste
    /// / one AX set), so a ⌘Z aimed at the same app reverts exactly that unit. Guards: must
    /// be armed (core confirmed the utterance completed), same app still frontmost, fresh
    /// (≤ 2 min), and no dictation mid-flight. Main thread (hotkey/menu).
    func undoLastInsertion() {
        undoLock.lock()
        let rec = undoRecord
        undoLock.unlock()
        guard activeState == "idle", let rec, rec.armed else {
            log("undo: nothing armed")
            return
        }
        guard Date().timeIntervalSince(rec.at) <= 120 else {
            log("undo: record stale (>2 min) — refusing")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        guard front == rec.app else {
            log("undo: frontmost is \(front), inserted into \(rec.app) — refusing")
            overlay?.show(state: "switch to \(rec.app) to undo", chip: nil)
            overlay?.scheduleFade(after: 1.2)
            return
        }
        guard postKey(CGKeyCode(6 /* kVK_ANSI_Z */), flags: .maskCommand) else {
            log("undo: CGEvent post failed")
            return
        }
        undoLock.lock()
        undoRecord = nil
        undoLock.unlock()
        log("undo: sent ⌘Z to \(front) (\(rec.text.count) chars)")
        overlay?.show(state: "undone", chip: nil)
        overlay?.scheduleFade(after: 0.9)
    }

    private func setMetric(_ key: String, _ value: Any) {
        metricsLock.lock()
        utteranceMetrics[key] = value
        metricsLock.unlock()
    }

    private func takeMetrics() -> [String: Any] {
        metricsLock.lock()
        defer {
            utteranceMetrics = [:]
            metricsLock.unlock()
        }
        return utteranceMetrics
    }

    // Read by the hotkey monitor (main thread) to decide Esc consumption.
    private(set) var activeState = "idle"

    private func onUI(_ block: @escaping () -> Void) {
        if let q = uiQueue { q.async(execute: block) } else { block() }
    }

    static let debug = ProcessInfo.processInfo.environment["CADENCE_DEBUG"] != nil

    func route(_ json: String) {
        if Self.debug { log("effect: \(json)") }
        guard let data = json.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let type = obj["type"] as? String
        else {
            log("unroutable effect: \(json)")
            return
        }
        switch type {
        case "start_capture":
            onUI { self.startCapture() }
        case "stop_capture":
            onUI { self.stopCapture() }
        case "discard_capture":
            onUI { self.capture?.stop() }
        case "play_sound":
            if earconsEnabled { Earcons.play(obj["sound"] as? String ?? "") }
        case "show_overlay":
            let state = obj["state"] as? String ?? "idle"
            let chip = obj["location_chip"] as? String
            onUI {
                self.activeState = state
                self.statusUpdate?(state)
                // Idle is a return-to-rest transition (cancel, re-enable, error recovery),
                // not a pill to display — showing it left a permanent "idle local" pill.
                if state == "idle" {
                    self.overlay?.scheduleFade(after: 0)
                } else {
                    self.overlay?.show(state: state, chip: chip)
                }
            }
        case "update_waveform":
            let level = (obj["level"] as? NSNumber)?.floatValue ?? 0
            onUI { self.overlay?.setLevel(level) }
        case "show_partial":
            let text = obj["text"] as? String ?? ""
            onUI { self.overlay?.setPartial(text) }
        case "run_insertion":
            insertionQueue.async { self.runInsertion(obj) }
        case "notify_text_on_clipboard":
            let text = obj["text"] as? String ?? ""
            onUI {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.log("words preserved on clipboard (\(text.count) chars)")
            }
        case "persist_utterance":
            if let store = historyStore {
                store.persist(record: obj, text: lastInsertedText, metrics: takeMetrics())
            } else {
                History.append(record: obj, text: lastInsertedText, metrics: takeMetrics())
            }
        case "arm_undo":
            undoLock.lock()
            undoRecord?.armed = true
            undoLock.unlock()
        case "schedule_fade_to_idle":
            onUI {
                self.activeState = "idle"
                self.overlay?.scheduleFade()
                self.statusUpdate?("idle")
                self.onIdle?(self.lastInsertedText)
            }
        default:
            log("unknown effect type: \(type)")
        }
    }

    private func startCapture() {
        guard let capture else {
            // Selftest mode: audio is injected directly; nothing to start.
            return
        }
        let t0 = Date()
        do {
            try capture.start()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            captureStartedAt = t0
            setMetric("capture_start_ms", ms)
            log("capture started in \(ms) ms") // §28: perceived start ≤ 50 ms — measured here
        } catch {
            log("capture start failed: \(error) — cancelling utterance")
            engine()?.cancel()
        }
    }

    private func stopCapture() {
        if let capture {
            capture.stop()
            if let t0 = captureStartedAt {
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                setMetric("capture_window_ms", ms)
                log("capture window \(ms) ms")
            }
        }
        // Confirm even in selftest (no real capture): the core holds the ASR drain for this.
        engine()?.captureStopped()
    }

    private func runInsertion(_ obj: [String: Any]) {
        let utterance = obj["utterance"] as? String ?? ""
        let text = obj["text"] as? String ?? ""
        if let reason = insertionGuard?() {
            log("insertion refused by guard: \(reason)")
            engine()?.insertionFailed(utterance: utterance)
            return
        }
        lastInsertedText = text
        let result = insertionEngine.insert(text)
        let strategy: String
        switch result.strategy {
        case .direct: strategy = "direct"
        case .pasteRestore: strategy = "paste_restore"
        case .clipboardNotify: strategy = "clipboard_notify"
        }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        setMetric("insertion_ms", result.elapsedMs)
        setMetric("strategy", strategy)
        setMetric("app", app)
        setMetric("verification", result.verification.rawValue)
        if result.inserted {
            // §26 undo state: what went where. arm_undo (post-insert) makes it fireable.
            undoLock.lock()
            undoRecord = UndoRecord(app: app, text: text, at: Date(), armed: false)
            undoLock.unlock()
        }
        log(
            "insertion: \(strategy) inserted=\(result.inserted) "
                + "verify=\(result.verification.rawValue) "
                + "clipboardRestored=\(result.clipboardRestored) \(result.elapsedMs) ms")
        engine()?.insertionResult(
            utterance: utterance, strategy: strategy, inserted: result.inserted,
            clipboardRestored: result.clipboardRestored)
    }

    func log(_ msg: String) {
        FileHandle.standardError.write(Data("[cadence] \(msg)\n".utf8))
        LogFile.append(msg)
    }
}

/// Persistent diagnostics at ~/.cadence/logs/cadence.log — the .app is launched by
/// launchd/Finder, so stderr goes nowhere; without this the capture-latency and insertion
/// lines are unobservable outside a terminal run. Trimmed at open so it can't grow unbounded.
enum LogFile {
    private static let queue = DispatchQueue(label: "cadence.logfile", qos: .utility)
    private static let handle: FileHandle? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cadence/logs")
        let url = dir.appendingPathComponent("cadence.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size > 2_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func append(_ msg: String) {
        queue.async {
            handle?.write(Data("\(stamp.string(from: Date())) \(msg)\n".utf8))
        }
    }
}

/// Stand-in for core/store (§24): append-only JSONL so no utterance is ever unrecoverable
/// (AC-22 baseline until the encrypted SQLite store lands).
enum History {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cadence/history.jsonl")

    static func append(record: [String: Any], text: String?, metrics: [String: Any] = [:]) {
        var rec = record
        rec["text"] = text
        rec["ts"] = ISO8601DateFormatter().string(from: Date())
        rec.merge(metrics) { current, _ in current }
        guard let data = try? JSONSerialization.data(withJSONObject: rec),
            var line = String(data: data, encoding: .utf8)
        else { return }
        line += "\n"
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

enum Earcons {
    /// Distinct, subtle system sounds (§12.6) until we ship our own assets.
    static func play(_ sound: String) {
        let name: String
        switch sound {
        case "capture_start": name = "Tink"
        case "capture_cancel": name = "Bottle"
        case "insertion_done": name = "Pop"
        case "didnt_catch_that": name = "Basso"
        case "error": name = "Basso"
        default: return
        }
        NSSound(named: name)?.play()
    }
}
