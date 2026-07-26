// HotkeyMonitor — global PTT + cancel via a CGEvent tap (§12.4).
//
// Two push-to-talk keys, so a bilingual user never pays for language detection: hold
// Right-Option (keycode 61) or Right-Control (62), and the app pins the language bound to
// whichever key was used. Right-Control is the pick for the second key because it is the
// least-claimed modifier on a Mac keyboard — Right-Shift types capitals and Right-Command
// is half of every right-handed ⌘ shortcut. Esc cancels while a dictation is active
// (consumed so it doesn't also hit the target app). Everything else passes through
// untouched. The tap is re-enabled if macOS disables it for latency — user input must never
// stay blocked because of us (§16.3).

import AppKit
import CoreGraphics

/// Which push-to-talk key fired. Each is bound to its own language by the app layer.
public enum PTTKey: String {
    case primary  // Right-Option
    case secondary  // Right-Control
}

/// The push-to-talk arbitration rules, factored out of the event tap so they can be exercised
/// without synthesizing CGEvents (the Swift layer has no XCTest — see `cadence
/// selftest-hotkeys`). Two invariants live here:
///
/// 1. **One dictation at a time.** A second PTT pressed while another is held is ignored, and
///    only the key that started an utterance can end it — otherwise the two languages could
///    interleave mid-utterance, or a stray release could cut a live dictation short.
/// 2. **A chord is not a PTT.** If another real modifier is already down the user is typing a
///    shortcut, not starting to speak. Without this, ⌃⌥⌘Z (undo-last-dictation) pressed with
///    the right hand would start a dictation on its way to undoing one.
public struct PTTArbiter {
    public enum Decision: Equatable {
        case start(PTTKey)
        case stop(PTTKey)
        case ignore
    }

    public private(set) var held: PTTKey?

    public init() {}

    public mutating func resolve(key: PTTKey, down: Bool, otherModifiers: Bool) -> Decision {
        if down {
            guard held == nil, !otherModifiers else { return .ignore }
            held = key
            return .start(key)
        }
        guard held == key else { return .ignore }
        held = nil
        return .stop(key)
    }
}

public final class HotkeyMonitor {
    public var onPTTDown: ((PTTKey) -> Void)?
    public var onPTTUp: ((PTTKey) -> Void)?
    public var onCancel: (() -> Void)?
    /// §7 F21: dedicated undo-last-dictation chord (⌃⌥⌘Z), consumed when handled.
    public var onUndo: (() -> Void)?
    /// Governs Esc consumption; read on the tap thread (main run loop).
    public var isActive: () -> Bool = { false }
    /// The second key is opt-out: when this returns false Right-Control is ignored entirely,
    /// so a user who has it bound elsewhere can turn the whole binding off.
    public var secondaryEnabled: () -> Bool = { true }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Owns the "which key is held" state; see PTTArbiter for the rules it enforces.
    private var arbiter = PTTArbiter()

    private static let kRightOption: Int64 = 61
    private static let kRightControl: Int64 = 62
    private static let kEscape: Int64 = 53
    private static let kZ: Int64 = 6

    public init() {}

    /// Returns false when the event tap can't be created (Accessibility not granted).
    public func start() -> Bool {
        let mask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(mask), callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged {
            if keyCode == Self.kRightOption {
                update(
                    key: .primary, down: event.flags.contains(.maskAlternate),
                    flags: event.flags, own: .maskAlternate)
                return Unmanaged.passUnretained(event)
            }
            if keyCode == Self.kRightControl, secondaryEnabled() {
                update(
                    key: .secondary, down: event.flags.contains(.maskControl),
                    flags: event.flags, own: .maskControl)
                return Unmanaged.passUnretained(event)
            }
        }
        if type == .keyDown, keyCode == Self.kEscape, isActive() {
            DispatchQueue.main.async { self.onCancel?() }
            return nil // consumed: cancel must not also close the user's dialog/sheet
        }
        if type == .keyDown, keyCode == Self.kZ, onUndo != nil {
            let mods: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
            if event.flags.isSuperset(of: mods) {
                DispatchQueue.main.async { self.onUndo?() }
                return nil // consumed: the chord is ours alone
            }
        }
        return Unmanaged.passUnretained(event)
    }

    /// Edge-detect one PTT key: translate CGEvent flags into the pure arbiter's terms, then
    /// fan the decision out to the app layer.
    private func update(key: PTTKey, down: Bool, flags: CGEventFlags, own: CGEventFlags) {
        let chordMods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let others = !flags.intersection(chordMods).subtracting(own).isEmpty
        switch arbiter.resolve(key: key, down: down, otherModifiers: others) {
        case .start(let k): DispatchQueue.main.async { self.onPTTDown?(k) }
        case .stop(let k): DispatchQueue.main.async { self.onPTTUp?(k) }
        case .ignore: break
        }
    }
}
