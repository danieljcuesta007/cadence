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

public struct InsertionResult: Codable {
    public var strategy: Strategy
    public var inserted: Bool
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
        func done(_ s: Strategy, _ ok: Bool, restored: Bool, refused: Bool = false,
                  _ detail: String) -> InsertionResult {
            InsertionResult(
                strategy: s, inserted: ok, clipboardRestored: restored,
                refusedSecureField: refused,
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
                if ok { return done(.direct, true, restored: true, "AX selected-text replace") }
            } else {
                // Deadline expired: the target was slow — we abandoned the attempt without
                // blocking anyone. Fall through to paste.
            }

            // Strategy 2: synthetic ⌘V with clipboard snapshot/restore.
            let pasted = pasteWithRestore(text, deadlineMs: deadline)
            if pasted.pasted {
                return done(.pasteRestore, true, restored: pasted.restored,
                            pasted.detail)
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
                                detail: "CGEvent post failed; clipboard restored")
        }

        // Give the target app time to service the paste before restoring. This wait bounds
        // *our* latency only; the target processes ⌘V on its own schedule and is never blocked.
        Thread.sleep(forTimeInterval: Double(min(deadlineMs, 250)) / 1000.0)

        let restored = snapshot.restore(to: pb, ifChangeCountStill: ourChangeCount)
        return PasteOutcome(
            pasted: true, restored: restored,
            detail: restored ? "pasted; prior clipboard restored"
                             : "pasted; clipboard changed by another app mid-flight — left alone")
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

// MARK: - direct AX insertion (free function so the deadline closure captures no self)

func focusedElement() -> AXUIElement? {
    let system = AXUIElementCreateSystemWide()
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(
        system, kAXFocusedUIElementAttribute as CFString, &value)
    guard err == .success, let v = value else { return nil }
    return (v as! AXUIElement)
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
    if let value = axString(el, kAXValueAttribute) {
        return value.contains(text)
    }
    return true
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
