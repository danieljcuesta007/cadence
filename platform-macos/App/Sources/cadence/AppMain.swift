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
    /// The keybinding hint, rebuilt on menu open so it always names the live language pairing.
    let hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let languageItem = NSMenuItem(title: "Right-Option Speaks", action: nil, keyEquivalent: "")
    let secondaryLanguageItem = NSMenuItem(
        title: "Left-Option Speaks", action: nil, keyEquivalent: "")
    /// Language menu: label → code passed to the core ("auto" detects per utterance).
    static let languageChoices: [(String, String)] = [
        ("Automatic", "auto"), ("English", "en"), ("Spanish", "es"),
    ]
    /// The second key adds "Off" — it can be unbound if the user needs Left-Option for typing.
    static let secondaryLanguageChoices: [(String, String)] = [("Off", "off")] + languageChoices
    /// Cached so menuNeedsUpdate can tick the current choice without hitting the DB.
    /// Both default to a *pinned* language rather than "auto" on purpose: detection costs
    /// ~160 ms per utterance in both languages and, for Spanish, 8 points of WER (21.5 % auto
    /// vs 13.6 % pinned, §30). Two keys mean the user never trades speed for bilingualism.
    var dictationLanguage = "en"
    var secondaryLanguage = "es"
    /// What the engine currently has applied, so switching keys only crosses the FFI when the
    /// language actually changes.
    var appliedLanguage: String?
    // Held during an utterance: App Nap must never throttle a decode mid-dictation
    // (§28 latency budgets; suspected cause of a one-off 30 s Metal stall in testing).
    var activity: NSObjectProtocol?
    /// The last app that was frontmost before Cadence's own window came forward — the target
    /// for the dashboard's Re-insert (we activate it, then paste). Updated on every app switch,
    /// ignoring Cadence itself, so opening the dashboard doesn't overwrite it.
    var lastActiveApp: NSRunningApplication?

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

        // Remember the app the user was in before Cadence, so the dashboard's Re-insert has a
        // real target. Ignore Cadence itself — activating our own window must not clobber it.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.processIdentifier != NSRunningApplication.current.processIdentifier
            else { return }
            self?.lastActiveApp = app
        }
        let menu = NSMenu()
        stateMenuItem.isEnabled = false
        menu.addItem(stateMenuItem)
        menu.addItem(hintItem)
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
        // Dictation language, one binding per push-to-talk key. Pinning both beats
        // auto-detection on speed and (for Spanish) accuracy, so bilingual dictation costs
        // a different finger rather than a menu trip or 160 ms of detection.
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
        let secondaryMenu = NSMenu()
        for (label, code) in Self.secondaryLanguageChoices {
            let item = NSMenuItem(
                title: label, action: #selector(pickSecondaryLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            secondaryMenu.addItem(item)
            if code == "off" { secondaryMenu.addItem(.separator()) }
        }
        secondaryLanguageItem.submenu = secondaryMenu
        menu.addItem(secondaryLanguageItem)
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
        dictationLanguage = store?.dictationLanguage ?? "en"
        secondaryLanguage = store?.secondaryLanguage ?? "es"
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
        hotkeys.secondaryEnabled = { [weak self] in (self?.secondaryLanguage ?? "off") != "off" }
        hotkeys.onPTTDown = { [weak self] key in
            guard let self else { return }
            // Per-app rule: dictation is off here — say so briefly, touch nothing else.
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            if self.disabledApps.contains(front) {
                self.pttSwallowed = true
                self.overlay.show(state: "disabled", chip: nil)
                self.overlay.scheduleFade(after: 0.9)
                return
            }
            // Pin the language this key speaks before capture starts. setLanguage is a cell
            // the worker reads before each decode, so it lands ahead of both passes.
            let lang = self.language(for: key)
            self.applyLanguage(lang)
            // Which key, and what it pinned. Without this line a "Spanish came out English"
            // report is unfalsifiable from the log — the two candidate causes (wrong key
            // pressed vs. right key resolving to the wrong language) look identical.
            self.router.log("ptt down: \(key == .primary ? "Right-Option" : "Left-Option") → \(lang)")
            self.pttDownAt = Date()
            if self.activity == nil {
                self.activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .latencyCritical], reason: "dictation")
            }
            self.engine?.triggerDown(verbatim: self.config.verbatim)
        }
        hotkeys.onPTTUp = { [weak self] _ in
            guard let self else { return }
            // Symmetry with the gate above: a swallowed down means nothing to stop.
            if self.pttSwallowed {
                self.pttSwallowed = false
                return
            }
            self.engine?.triggerUp()
        }
        // A hold retracted as a chord or as typing: throw the utterance away silently. No
        // overlay flash — the user pressed ⌥e or ⌃⌥⌘Z and never meant to dictate, so telling
        // them a dictation was cancelled would be noise about something they never started.
        // Clearing pttSwallowed matters: a retracted hold never delivers its onPTTUp (the
        // arbiter has already let go), so a swallowed flag left set would eat the *next*
        // dictation's release. The activity assertion is freed by the usual route — cancel
        // drives the router back to "idle", which ends it.
        hotkeys.onPTTCancel = { [weak self] _ in
            guard let self else { return }
            self.pttSwallowed = false
            self.engine?.cancel()
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
                    // Apply the primary key's language now that the engine exists (the env
                    // default is "auto"), so a dictation that starts before any key-driven
                    // switch is already pinned. Each PTT re-pins to its own key's language.
                    self.applyLanguage(self.dictationLanguage)
                    // Restore the personal dictionary so custom spellings survive a relaunch.
                    let vocab = Vocabulary.prompt(from: self.historyStore?.customVocabulary ?? "")
                    if !vocab.isEmpty { engine.setVocabulary(vocab) }
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    let keys =
                        self.secondaryLanguage == "off"
                        ? "Right-Option=\(self.dictationLanguage)"
                        : "Right-Option=\(self.dictationLanguage) Left-Option=\(self.secondaryLanguage)"
                    let model = (self.config.model as NSString).lastPathComponent
                    self.router.log(
                        "core ready in \(ms) ms (core v\(CoreEngine.coreVersion)) — "
                            + "model=\(model) \(keys)")
                    // An .en model accepts a language argument and ignores it, so a Spanish
                    // binding on an English-only build fails silently and looks like a bad
                    // model rather than a bad package. Say so once, at launch.
                    if isEnglishOnly(self.config.model) {
                        let pinned = [self.dictationLanguage, self.secondaryLanguage]
                            .filter { $0 != "en" && $0 != "off" }
                        if !pinned.isEmpty {
                            self.router.log(
                                "WARNING: \(model) is English-only — \(pinned.joined(separator: "/")) "
                                    + "dictation cannot work. Repackage with "
                                    + "CADENCE_BUNDLE_MODEL=models/artifacts/ggml-small.bin")
                        }
                    }
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
        for item in secondaryLanguageItem.submenu?.items ?? [] {
            item.state = (item.representedObject as? String) == secondaryLanguage ? .on : .off
        }
        hintItem.title = Self.hintTitle(primary: dictationLanguage, secondary: secondaryLanguage)
    }

    /// "Hold Right-Option (English) · Left-Option (Spanish) · Esc cancels" — the second key
    /// is dropped from the hint when it is unbound, so the line never advertises a dead key.
    static func hintTitle(primary: String, secondary: String) -> String {
        func name(_ code: String) -> String {
            secondaryLanguageChoices.first { $0.1 == code }?.0 ?? code
        }
        var parts = ["Hold Right-Option (\(name(primary)))"]
        if secondary != "off" { parts.append("Left-Option (\(name(secondary)))") }
        parts.append("Esc cancels")
        parts.append("⌃⌥⌘Z undoes")
        return parts.joined(separator: " · ")
    }

    /// Which language a given push-to-talk key dictates in.
    func language(for key: PTTKey) -> String {
        key == .primary ? dictationLanguage : secondaryLanguage
    }

    /// Cross the FFI only when the language actually changes — holding the same key
    /// repeatedly should cost nothing.
    func applyLanguage(_ code: String) {
        guard code != appliedLanguage else { return }
        engine?.setLanguage(code)  // instant — no model reload
        appliedLanguage = code
    }

    @objc func pickLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        dictationLanguage = code
        historyStore?.setDictationLanguage(code)
        applyLanguage(code)
        let label = Self.languageChoices.first { $0.1 == code }?.0 ?? code
        router.log("Right-Option speaks → \(label) (\(code))")
    }

    @objc func pickSecondaryLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        secondaryLanguage = code
        historyStore?.setSecondaryLanguage(code)
        let label = Self.secondaryLanguageChoices.first { $0.1 == code }?.0 ?? code
        router.log("Left-Option speaks → \(label) (\(code))")
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

    /// Add one term to the personal dictionary (the dashboard's Add to Dictionary, driven by a
    /// selection in a past transcript — the moment you notice a misspelling is the moment to fix
    /// it). Returns false when the term was already there. Case-insensitive: whisper's prompt bias
    /// doesn't care, and a second "Addisuna" would just dilute the prompt.
    private func addToDictionary(_ term: String) -> Bool {
        guard let store = historyStore else { return false }
        let existing = store.customVocabulary.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !existing.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else {
            router.log("personal dictionary: “\(term)” already present")
            return false
        }
        let updated = (existing + [term]).joined(separator: "\n")
        store.setCustomVocabulary(updated)
        engine?.setVocabulary(Vocabulary.prompt(from: updated))  // instant — no model reload
        dictionaryWindow?.absorb(term: term)
        router.log("personal dictionary: added “\(term)” (\(existing.count + 1) terms)")
        return true
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
        if dashboard == nil {
            let d = DashboardWindowController()
            d.onReinsert = { [weak self] text in self?.reinsertFromDashboard(text) }
            if historyStore != nil {
                d.onAddToDictionary = { [weak self] term in self?.addToDictionary(term) ?? false }
            }
            dashboard = d
        }
        // Accessory apps don't come forward on their own; activate so the window is
        // actually visible and focused rather than opening behind everything.
        NSApp.activate(ignoringOtherApps: true)
        dashboard?.showWindow(nil)
        dashboard?.window?.makeKeyAndOrderFront(nil)
    }

    /// Re-insert a past dictation: return focus to the app the user came from, then paste there.
    /// Without a known target (or if it's Cadence) we can't safely place text, so we fall back
    /// to leaving it on the clipboard and telling the user.
    private func reinsertFromDashboard(_ text: String) {
        guard let target = lastActiveApp,
            target.processIdentifier != NSRunningApplication.current.processIdentifier
        else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            router.log("re-insert: no prior app — left text on clipboard")
            return
        }
        dashboard?.window?.orderOut(nil)
        target.activate(options: [])
        // Wait for the switch to actually land instead of guessing at it. A fixed delay is
        // wrong in both directions: too short and we paste into Cadence's own window (or a
        // half-focused target that drops the ⌘V), too long and Re-insert feels broken. Poll
        // frontmostApplication and go the moment the target owns focus.
        waitForFrontmost(target, deadline: Date().addingTimeInterval(1.5)) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.router.log(
                    "re-insert: \(target.localizedName ?? "target") never came forward "
                        + "— left text on clipboard")
                return
            }
            self.router.reinsert(text) { ok in
                if !ok {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
    }

    /// Call back once `app` is frontmost (true) or `deadline` passes without it (false). Polled
    /// on main at display cadence — activation is not observable synchronously, and the
    /// activation notification can arrive before the app is actually able to take keystrokes.
    private func waitForFrontmost(
        _ app: NSRunningApplication, deadline: Date, then done: @escaping (Bool) -> Void
    ) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier == app.processIdentifier {
            // One frame of settle: focus has moved to the app, but its key window may still be
            // finishing first responder handoff.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done(true) }
            return
        }
        guard Date() < deadline else {
            done(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            self?.waitForFrontmost(app, deadline: deadline, then: done)
        }
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
