// HotkeyMonitor — global PTT + cancel via a CGEvent tap (§12.4).
//
// Two push-to-talk keys, so a bilingual user never pays for language detection: hold
// Right-Option (keycode 61) or Left-Option (58), and the app pins the language bound to
// whichever key was used. Esc cancels while a dictation is active (consumed so it doesn't
// also hit the target app). Everything else passes through untouched. The tap is re-enabled
// if macOS disables it for latency — user input must never stay blocked because of us (§16.3).
//
// Why the two Option keys and not, say, Right-Control: Apple laptops don't have one. The
// MacBook bottom row is fn / control / option / command / space / command / option / arrows —
// a single Control, on the left. Right-Shift types capitals and Right-Command is half of every
// right-handed ⌘ shortcut, which leaves the Option pair as the only two keys that are both
// present and unclaimed.
//
// Both Option keys raise the same .maskAlternate, so telling them apart needs the
// device-dependent bits (NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK from IOLLEvent.h) rather
// than the general mask — see `isDown`.
//
// Left-Option is the more dangerous binding of the two, because it is the Option people
// actually use: ⌥e for an accent, ⌃⌥⌘Z to undo. Two retractions defend it — see the `cancel`
// paths in PTTArbiter.

import AppKit
import CoreGraphics

/// Which push-to-talk key fired. Each is bound to its own language by the app layer.
public enum PTTKey: String {
    case primary  // Right-Option
    case secondary  // Left-Option
}

/// The push-to-talk arbitration rules, factored out of the event tap so they can be exercised
/// without synthesizing CGEvents (the Swift layer has no XCTest — see `cadence
/// selftest-hotkeys`). Three invariants live here:
///
/// 1. **One dictation at a time.** A second PTT pressed while another is held is ignored, and
///    only the key that started an utterance can end it — otherwise the two languages could
///    interleave mid-utterance, or a stray release could cut a live dictation short.
/// 2. **A chord is not a PTT.** If another real modifier is already down the user is typing a
///    shortcut, not starting to speak.
/// 3. **A hold can be retracted.** Invariant 2 only catches chords whose *other* modifier
///    lands first. Press Option before Control in ⌃⌥⌘Z — which is the natural order for a
///    left hand — and the dictation has already started by the time the chord is
///    recognisable. So anything that proves the user was not speaking retracts it: a foreign
///    modifier arriving mid-hold, or any ordinary key being typed. The latter is what makes
///    ⌥e (é) safe. Retraction happens within milliseconds of the press, before there is any
///    speech to lose, and it must fire exactly once — the eventual key release is then a
///    no-op, since nothing is held any more.
public struct PTTArbiter {
    public enum Decision: Equatable {
        case start(PTTKey)
        case stop(PTTKey)
        case cancel(PTTKey)
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

    /// The user did something that proves this was not speech — a foreign modifier joined the
    /// hold, or they started typing. Retract the dictation if one is in flight.
    public mutating func retract() -> Decision {
        guard let key = held else { return .ignore }
        held = nil
        return .cancel(key)
    }
}

public final class HotkeyMonitor {
    public var onPTTDown: ((PTTKey) -> Void)?
    public var onPTTUp: ((PTTKey) -> Void)?
    /// A hold was retracted before it counted as speech (chord or typing). Distinct from
    /// onPTTUp: there is no utterance to finish, only one to throw away.
    public var onPTTCancel: ((PTTKey) -> Void)?
    public var onCancel: (() -> Void)?
    /// §7 F21: dedicated undo-last-dictation chord (⌃⌥⌘Z), consumed when handled.
    public var onUndo: (() -> Void)?
    /// Governs Esc consumption; read on the tap thread (main run loop).
    public var isActive: () -> Bool = { false }
    /// The second key is opt-out: when this returns false Left-Option is ignored entirely,
    /// so a user who needs it for typing can turn the whole binding off.
    public var secondaryEnabled: () -> Bool = { true }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Owns the "which key is held" state; see PTTArbiter for the rules it enforces.
    private var arbiter = PTTArbiter()

    private static let kRightOption: Int64 = 61
    private static let kLeftOption: Int64 = 58
    private static let kEscape: Int64 = 53
    private static let kZ: Int64 = 6
    /// Device-dependent modifier bits (IOLLEvent.h). The general .maskAlternate cannot tell
    /// the two Option keys apart, and both PTT keys are Option keys.
    private static let deviceLeftAlt: UInt64 = 0x0000_0020
    private static let deviceRightAlt: UInt64 = 0x0000_0040

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
                update(key: .primary, down: isDown(.primary, event.flags), flags: event.flags)
                return Unmanaged.passUnretained(event)
            }
            if keyCode == Self.kLeftOption, secondaryEnabled() {
                update(key: .secondary, down: isDown(.secondary, event.flags), flags: event.flags)
                return Unmanaged.passUnretained(event)
            }
            // Some *other* modifier moved. If a PTT is held, the user is assembling a chord
            // (⌃⌥⌘Z with a left hand presses Option first), so retract the dictation.
            retractIfChording(flags: event.flags)
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown, keyCode == Self.kEscape, isActive() {
            DispatchQueue.main.async { self.onCancel?() }
            return nil // consumed: cancel must not also close the user's dialog/sheet
        }
        // Typing while a PTT is held is not speech — it is ⌥e for an accent, or a shortcut.
        // Retract rather than transcribe silence. Esc above has already been handled.
        if type == .keyDown, arbiter.held != nil {
            fire(arbiter.retract())
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

    /// Is this specific Option key physically down? Both raise .maskAlternate, so the general
    /// mask would report the left key as down while only the right one is held.
    private func isDown(_ key: PTTKey, _ flags: CGEventFlags) -> Bool {
        let bit = key == .primary ? Self.deviceRightAlt : Self.deviceLeftAlt
        return flags.rawValue & bit != 0
    }

    /// Edge-detect one PTT key: translate CGEvent flags into the pure arbiter's terms, then
    /// fan the decision out to the app layer.
    private func update(key: PTTKey, down: Bool, flags: CGEventFlags) {
        // Option is excluded from the "foreign modifier" set because both PTT keys are Option
        // keys — the other one being down is the arbiter's business, not a chord signal.
        let chordMods: CGEventFlags = [.maskCommand, .maskControl, .maskShift]
        let others = !flags.intersection(chordMods).isEmpty
        fire(arbiter.resolve(key: key, down: down, otherModifiers: others))
    }

    /// A non-PTT modifier moved: retract any hold it just turned into a chord.
    private func retractIfChording(flags: CGEventFlags) {
        guard arbiter.held != nil else { return }
        let chordMods: CGEventFlags = [.maskCommand, .maskControl, .maskShift]
        guard !flags.intersection(chordMods).isEmpty else { return }
        fire(arbiter.retract())
    }

    private func fire(_ decision: PTTArbiter.Decision) {
        switch decision {
        case .start(let k): DispatchQueue.main.async { self.onPTTDown?(k) }
        case .stop(let k): DispatchQueue.main.async { self.onPTTUp?(k) }
        case .cancel(let k): DispatchQueue.main.async { self.onPTTCancel?(k) }
        case .ignore: break
        }
    }
}
