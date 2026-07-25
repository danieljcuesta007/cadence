// InsertionEngine — Phase-0 spike of blueprint §7 F20 / §12.3 / §16.3.
//
// Contract (AC-20, non-negotiable gate #2):
//   • NEVER freeze the target app: every AX call is bounded by AXUIElementSetMessagingTimeout
//     and each strategy runs off the calling thread with a hard deadline (default 250 ms).
//   • NEVER corrupt the clipboard: if paste is used, prior contents are snapshotted and
//     restored — unless a third party changed the pasteboard mid-flight, in which case we
//     leave their change alone (their data > our restore).
//   • NEVER type into secure fields: secure text fields / secure event input ⇒ refuse.
//   • The words are never lost: the terminal fallback leaves the text on the clipboard and
//     reports `inserted: false` so the caller can notify the user (§29).

import AppKit
import ApplicationServices
import Carbon.HIToolbox

public enum Strategy: String, Codable {
    case direct           // AX selected-text replacement at the caret
    case pasteRestore     // synthetic ⌘V with clipboard snapshot+restore
    case clipboardNotify  // words parked on the clipboard + notify (never lost)
}

/// Post-insert verification outcome (AC-20: "inserted" must not be a blind claim).
public enum Verification: String, Codable {
    case verified      // focused element's value readback contains the inserted text
    case unverifiable  // element's value not readable (AX-opaque: web views, canvases…)
    case contradicted  // value readable and the text is NOT there — the paste was swallowed
}

public struct InsertionResult: Codable {
    public var strategy: Strategy
    public var inserted: Bool
    public var verification: Verification
    public var clipboardRestored: Bool
    public var refusedSecureField: Bool
    public var elapsedMs: Int
    public var detail: String
}

public struct CapabilityReport: Codable {
    public var axTrusted: Bool
    public var secureEventInput: Bool
    public var frontmostApp: String
    public var focusedRole: String?
    public var focusedSubrole: String?
    public var selectedTextSettable: Bool
    public var valueReadable: Bool
}

/// Deadline-bounded execution: runs `work` on a background queue; if it exceeds `deadlineMs`
/// the caller moves on (the worker thread is abandoned — its AX calls are themselves bounded
/// by the messaging timeout, so it cannot hang forever, and it can never block the target app).
public func withDeadline<T>(_ deadlineMs: Int, _ work: @escaping () -> T) -> T? {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    DispatchQueue.global(qos: .userInteractive).async {
        box.value = work()
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + .milliseconds(deadlineMs)) == .timedOut {
        return nil
    }
    return box.value
}

final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

public final class InsertionEngine {
    let timeoutMs: Int
    /// AX messaging timeout (seconds): bounds every individual AX IPC round-trip.
    let axTimeout: Float

    public init(timeoutMs: Int = 250) {
        self.timeoutMs = timeoutMs
        self.axTimeout = Float(timeoutMs) / 1000.0
    }

    // MARK: capability detection

    public func capabilities() -> CapabilityReport {
        let trusted = AXIsProcessTrusted()
        let secure = IsSecureEventInputEnabled()
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        var report = CapabilityReport(
            axTrusted: trusted, secureEventInput: secure, frontmostApp: front,
            focusedRole: nil, focusedSubrole: nil,
            selectedTextSettable: false, valueReadable: false)
        guard trusted, let el = focusedElement() else { return report }
        report.focusedRole = axString(el, kAXRoleAttribute)
        report.focusedSubrole = axString(el, kAXSubroleAttribute)
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable)
        report.selectedTextSettable = settable.boolValue
        report.valueReadable = axString(el, kAXValueAttribute) != nil
        return report
    }

    // MARK: the cascade

    public func insert(_ text: String) -> InsertionResult {
        let start = Date()
        func done(_ s: Strategy, _ ok: Bool, verify: Verification = .unverifiable,
                  restored: Bool, refused: Bool = false,
                  _ detail: String) -> InsertionResult {
            InsertionResult(
                strategy: s, inserted: ok, verification: verify,
                clipboardRestored: restored, refusedSecureField: refused,
                elapsedMs: Int(Date().timeIntervalSince(start) * 1000), detail: detail)
        }

        // Gate: never insert into secure fields / while secure event input is active (§20).
        if IsSecureEventInputEnabled() {
            return done(.clipboardNotify, false, restored: true, refused: true,
                        "secure event input active — refusing to type; nothing touched")
        }
        if AXIsProcessTrusted(), let el = focusedElement(),
           axString(el, kAXSubroleAttribute) == "AXSecureTextField" {
            return done(.clipboardNotify, false, restored: true, refused: true,
                        "focused element is a secure text field — refusing")
        }

        // Strategy 1: direct AX insertion at the caret, off-thread, deadline-bounded.
        if AXIsProcessTrusted() {
            let deadline = timeoutMs
            let axTimeout = self.axTimeout
            if let ok = withDeadline(deadline, { directInsert(text, axTimeout: axTimeout) }) {
                // directInsert already readback-verifies when the value is readable.
                if ok {
                    return done(.direct, true, verify: .verified, restored: true,
                                "AX selected-text replace")
                }
            } else {
                // Deadline expired: the target was slow — we abandoned the attempt without
                // blocking anyone. Fall through to paste.
            }

            // Strategy 2: synthetic ⌘V with clipboard snapshot/restore.
            let pasted = pasteWithRestore(text, deadlineMs: deadline)
            if pasted.pasted {
                switch pasted.verification {
                case .contradicted:
                    // AC-20 blind-paste gap (found live in Pages page-layout): the target
                    // readably does NOT contain the text — the paste was swallowed. The
                    // words are already parked on the clipboard (restore was skipped);
                    // report not-inserted so the caller notifies instead of celebrating.
                    return done(.clipboardNotify, false, verify: .contradicted,
                                restored: false,
                                "paste swallowed by target (readback missing) — text left on clipboard")
                case .verified, .unverifiable:
                    return done(.pasteRestore, true, verify: pasted.verification,
                                restored: pasted.restored, pasted.detail)
                }
            }
        }

        // Terminal fallback: park the words on the clipboard, tell the user (§29).
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return done(.clipboardNotify, false, restored: false,
                    AXIsProcessTrusted()
                        ? "all strategies failed — text left on clipboard"
                        : "accessibility not granted — text left on clipboard")
    }

    // MARK: strategy 2 impl

    struct PasteOutcome {
        var pasted: Bool
        var restored: Bool
        var verification: Verification
        var detail: String
    }

    func pasteWithRestore(_ text: String, deadlineMs: Int) -> PasteOutcome {
        let pb = NSPasteboard.general
        let snapshot = ClipboardSnapshot.capture(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChangeCount = pb.changeCount

        guard postCmdV() else {
            // Could not synthesize the keystroke: undo our clipboard write immediately.
            let restored = snapshot.restore(to: pb, ifChangeCountStill: ourChangeCount)
            return PasteOutcome(pasted: false, restored: restored,
                                verification: .unverifiable,
                                detail: "CGEvent post failed; clipboard restored")
        }

        // Give the target app time to service the paste before restoring. This wait bounds
        // *our* latency only; the target processes ⌘V on its own schedule and is never blocked.
        Thread.sleep(forTimeInterval: Double(min(deadlineMs, 250)) / 1000.0)

        // AC-20 post-insert verification, BEFORE the clipboard restore so a swallowed paste
        // can keep the words parked (never lost). Readback is best-effort: only a readable
        // focused value can confirm or deny; opaque targets stay "unverifiable" and are
        // trusted as before (VS Code, web views and Spotlight land pastes AX-opaquely).
        let verification = verifyLanded(text)
        if verification == .contradicted {
            // Leave OUR text on the clipboard (do not restore): the user was just told
            // nothing was inserted — the words must be one ⌘V away (§29).
            return PasteOutcome(pasted: true, restored: false, verification: .contradicted,
                                detail: "readback contradicts paste")
        }

        let restored = snapshot.restore(to: pb, ifChangeCountStill: ourChangeCount)
        return PasteOutcome(
            pasted: true, restored: restored, verification: verification,
            detail: restored ? "pasted; prior clipboard restored"
                             : "pasted; clipboard changed by another app mid-flight — left alone")
    }

    /// Best-effort readback of the focused element after a paste. `verified` only when the
    /// value is readable AND contains the text; `contradicted` only when readable and the
    /// text is absent (checked via a tail sample — values can be huge). Everything else is
    /// `unverifiable` — never treated as failure.
    ///
    /// A first-read "contradicted" gets ONE re-read after a render window: terminal TUIs
    /// process a paste through the pty and redraw asynchronously, so the immediate
    /// readback sees the pre-paste screen. Live false-negatives (3× on 2026-07-19,
    /// dictating into a Claude Code terminal): text visibly landed, yet history said
    /// inserted=false and the user's clipboard was left stomped. A genuine swallow
    /// (the Pages page-layout case) is still absent on the re-read.
    func verifyLanded(_ text: String) -> Verification {
        let first = readbackVerdict(text)
        guard first == .contradicted else { return first }
        Thread.sleep(forTimeInterval: 0.18)
        return readbackVerdict(text)
    }

    private func readbackVerdict(_ text: String) -> Verification {
        let probe = foldForReadback(String(text.suffix(64)))
        guard !probe.isEmpty,
            let outcome = withDeadline(timeoutMs, { () -> Verification in
                guard let el = focusedElement() else { return .unverifiable }
                AXUIElementSetMessagingTimeout(el, self.axTimeout)
                guard let value = axString(el, kAXValueAttribute), !value.isEmpty else {
                    return .unverifiable
                }
                return foldForReadback(value).contains(probe) ? .verified : .contradicted
            })
        else { return .unverifiable }
        return outcome
    }

    func postCmdV() -> Bool {
        guard let src = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V),
                                 keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V),
                               keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

// MARK: - focused-element inspection (used by `insertctl read` and the matrix harness)

public struct FocusReport: Codable {
    public var app: String
    public var focusError: String?
    public var role: String?
    public var subrole: String?
    public var value: String?
    public var selectedText: String?
    public var roleDescription: String?
    public var attributeNames: [String]?
}

public func readFocused() -> FocusReport {
    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
    var report = FocusReport(
        app: front, focusError: nil, role: nil, subrole: nil, value: nil, selectedText: nil)
    switch focusedElementDetailed() {
    case .failure(let detail):
        report.focusError = detail
    case .success(let el):
        AXUIElementSetMessagingTimeout(el, 0.25)
        report.role = axString(el, kAXRoleAttribute)
        report.subrole = axString(el, kAXSubroleAttribute)
        report.value = axString(el, kAXValueAttribute)
        report.selectedText = axString(el, kAXSelectedTextAttribute)
        report.roleDescription = axString(el, kAXRoleDescriptionAttribute)
        var names: CFArray?
        if AXUIElementCopyAttributeNames(el, &names) == .success,
           let list = names as? [String] {
            report.attributeNames = list
        }
    }
    return report
}

/// Post a modifier+key chord as CGEvents (accessibility permission only — no Apple Events).
public func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
    guard let src = CGEventSource(stateID: .combinedSessionState),
          let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
    else { return false }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
}

// MARK: - AX tree search + synthetic click (matrix harness: focus a field deterministically)

public struct FindClickResult: Codable {
    public var found: Bool
    public var clicked: Bool
    public var role: String?
    public var subrole: String?
    public var roleDescription: String?
}

func axFrame(_ el: AXUIElement) -> CGRect? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, "AXFrame" as CFString, &value) == .success,
          let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue((v as! AXValue), .cgRect, &rect) else { return nil }
    return rect
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success,
          let arr = value as? [AXUIElement] else { return [] }
    return arr
}

func findElement(_ el: AXUIElement, matching query: String, depth: Int) -> AXUIElement? {
    if depth > 30 { return nil }
    AXUIElementSetMessagingTimeout(el, 0.25)
    let role = axString(el, kAXRoleAttribute) ?? ""
    let subrole = axString(el, kAXSubroleAttribute) ?? ""
    let desc = axString(el, kAXRoleDescriptionAttribute) ?? ""
    let placeholder = axString(el, "AXPlaceholderValue") ?? ""
    let q = query.lowercased()
    if role.lowercased().contains(q) || subrole.lowercased().contains(q)
        || desc.lowercased().contains(q) || placeholder.lowercased().contains(q) {
        return el
    }
    for child in axChildren(el) {
        if let hit = findElement(child, matching: query, depth: depth + 1) {
            return hit
        }
    }
    return nil
}

/// Search the frontmost app's AX tree for an element matching `query` (role/subrole/role
/// description/placeholder substring) and click its center. Used by the matrix harness to
/// focus web-content fields that never receive keyboard focus on page load.
public func findAndClick(_ query: String) -> FindClickResult {
    var result = FindClickResult(
        found: false, clicked: false, role: nil, subrole: nil, roleDescription: nil)
    guard let app = NSWorkspace.shared.frontmostApplication else { return result }
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    guard let hit = findElement(appEl, matching: query, depth: 0) else { return result }
    result.found = true
    result.role = axString(hit, kAXRoleAttribute)
    result.subrole = axString(hit, kAXSubroleAttribute)
    result.roleDescription = axString(hit, kAXRoleDescriptionAttribute)
    guard let frame = axFrame(hit), frame.width > 0 else { return result }
    let point = CGPoint(x: frame.midX, y: frame.midY)
    guard let src = CGEventSource(stateID: .combinedSessionState),
          let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                             mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                           mouseCursorPosition: point, mouseButton: .left)
    else { return result }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    result.clicked = true
    return result
}

// MARK: - direct AX insertion (free function so the deadline closure captures no self)

enum FocusLookup {
    case success(AXUIElement)
    case failure(String)
}

/// Focused element via the frontmost app's AX tree (more reliable than the system-wide
/// element from a background/agent process), falling back to the system-wide query.
func focusedElementDetailed() -> FocusLookup {
    if let app = NSWorkspace.shared.frontmostApplication {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appEl, kAXFocusedUIElementAttribute as CFString, &value)
        if err == .success, let v = value {
            return .success(v as! AXUIElement)
        }
        // Fall through to system-wide, but remember why.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var sysValue: CFTypeRef?
        let sysErr = AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &sysValue)
        if sysErr == .success, let v = sysValue {
            return .success(v as! AXUIElement)
        }
        return .failure("app query: AXError \(err.rawValue); system query: AXError \(sysErr.rawValue)")
    }
    return .failure("no frontmost application")
}

func focusedElement() -> AXUIElement? {
    if case .success(let el) = focusedElementDetailed() { return el }
    return nil
}

func axString(_ el: AXUIElement, _ attr: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else {
        return nil
    }
    return value as? String
}

func directInsert(_ text: String, axTimeout: Float) -> Bool {
    guard let el = focusedElement() else { return false }
    // Bound every AX round-trip to this element: the no-freeze mechanism (§16.3).
    AXUIElementSetMessagingTimeout(el, axTimeout)

    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable)
            == .success, settable.boolValue else { return false }

    // Setting AXSelectedText replaces the current selection — or inserts at the caret when
    // the selection is empty. This is the direct, clipboard-free path.
    let err = AXUIElementSetAttributeValue(
        el, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
    guard err == .success else { return false }

    // Best-effort verification: if the element's value is readable, the text must be in it.
    // Folded, because a false negative here is expensive: `insert` falls through to the paste
    // strategy and the text lands twice.
    if let value = axString(el, kAXValueAttribute) {
        return foldForReadback(value).contains(foldForReadback(text))
    }
    return true
}

/// Reduce text to what a target cannot silently change while displaying it: letters and digits,
/// lowercased. Readback comparison has to survive the target's own rendering, and exact
/// substring matching does not:
///
/// - **Soft wrap.** A terminal or TUI re-flows a pasted line at its window width, so the AX value
///   carries hard newlines (and box gutters like `│ `) mid-string. Measured live: Terminal
///   exposes only the visible screen, wrapped at ~93 columns, so a contiguous 64-char probe
///   survives roughly one time in four. This produced 14 false `contradicted` verdicts in 40
///   live insertions (2026-07-16…25) — text that landed perfectly was reported as swallowed,
///   the user's clipboard was left stomped, and undo was never armed.
/// - **Substitutions.** Smart quotes/dashes turn `don't` into `don’t` on entry in several apps.
///
/// A genuine swallow — the Pages page-layout case this verification exists for — has the text
/// absent under any folding, so the check still catches what it was built to catch.
public func foldForReadback(_ s: String) -> String {
    s.lowercased().filter { $0.isLetter || $0.isNumber }
}

// MARK: - clipboard snapshot/restore

public struct ClipboardSnapshot {
    var items: [[NSPasteboard.PasteboardType: Data]]

    public static func capture(_ pb: NSPasteboard) -> ClipboardSnapshot {
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type] = data
                }
            }
            if !entry.isEmpty { items.append(entry) }
        }
        return ClipboardSnapshot(items: items)
    }

    /// Restore the snapshot. If the pasteboard's changeCount no longer matches `expected`,
    /// another app wrote to it after us — leave their contents alone and report false.
    @discardableResult
    public func restore(to pb: NSPasteboard, ifChangeCountStill expected: Int) -> Bool {
        guard pb.changeCount == expected else { return false }
        pb.clearContents()
        guard !items.isEmpty else { return true } // clipboard was empty before: now empty again
        let restored: [NSPasteboardItem] = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(restored)
        return true
    }
}
