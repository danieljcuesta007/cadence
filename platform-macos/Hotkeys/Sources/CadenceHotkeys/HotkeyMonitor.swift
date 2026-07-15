// HotkeyMonitor — global PTT + cancel via a CGEvent tap (§12.4).
//
// Default binding per §12.4: hold Right-Option (keycode 61) = push-to-talk; Esc cancels
// while a dictation is active (consumed so it doesn't also hit the target app). Everything
// else passes through untouched. The tap is re-enabled if macOS disables it for latency —
// user input must never stay blocked because of us (§16.3).

import AppKit
import CoreGraphics

public final class HotkeyMonitor {
    public var onPTTDown: (() -> Void)?
    public var onPTTUp: (() -> Void)?
    public var onCancel: (() -> Void)?
    /// Governs Esc consumption; read on the tap thread (main run loop).
    public var isActive: () -> Bool = { false }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pttHeld = false

    private static let kRightOption: Int64 = 61
    private static let kEscape: Int64 = 53

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
        if type == .flagsChanged, keyCode == Self.kRightOption {
            let down = event.flags.contains(.maskAlternate)
            if down != pttHeld {
                pttHeld = down
                let fire = down ? onPTTDown : onPTTUp
                DispatchQueue.main.async { fire?() }
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown, keyCode == Self.kEscape, isActive() {
            DispatchQueue.main.async { self.onCancel?() }
            return nil // consumed: cancel must not also close the user's dialog/sheet
        }
        return Unmanaged.passUnretained(event)
    }
}
