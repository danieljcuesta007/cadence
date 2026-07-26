// Pure-logic checks for the two-key push-to-talk binding (§12.4) and the language pairing
// shown in the menu. The Swift layer has no XCTest (Command Line Tools only), so the pattern
// here is the same one `insertctl selftest` and `cadence selftest-stats` use: exercise the
// pure types directly and print a JSON verdict.
//
//   cadence selftest-hotkeys
//
// What is worth pinning: the arbitration rules are invisible in normal use and fail silently.
// A regression would not crash — it would let two languages interleave in one utterance, let
// ⌃⌥⌘Z quietly open a dictation while undoing one, or leave a stray empty utterance behind
// every time the user types an accented character with ⌥.

import CadenceHotkeys
import Foundation

private struct HotkeyCheck: Encodable {
    let name: String
    let pass: Bool
    let detail: String?
}

func runHotkeySelftest() -> Int32 {
    var checks: [HotkeyCheck] = []
    func check(_ name: String, _ pass: Bool, _ detail: String? = nil) {
        checks.append(HotkeyCheck(name: name, pass: pass, detail: pass ? nil : detail))
    }

    // 1. The ordinary round trip on each key.
    for key in [PTTKey.primary, PTTKey.secondary] {
        var a = PTTArbiter()
        let down = a.resolve(key: key, down: true, otherModifiers: false)
        let up = a.resolve(key: key, down: false, otherModifiers: false)
        check(
            "\(key.rawValue)_round_trip", down == .start(key) && up == .stop(key),
            "got \(down) then \(up)")
        check("\(key.rawValue)_releases_hold", a.held == nil, "held is \(String(describing: a.held))")
    }

    // 2. One dictation at a time: the second key pressed mid-utterance is ignored, and the
    //    utterance still belongs to the key that started it.
    do {
        var a = PTTArbiter()
        _ = a.resolve(key: .primary, down: true, otherModifiers: false)
        let intruder = a.resolve(key: .secondary, down: true, otherModifiers: false)
        check("second_key_ignored_while_held", intruder == .ignore, "got \(intruder)")
        check("hold_still_primary", a.held == .primary, "held is \(String(describing: a.held))")
    }

    // 3. Only the owning key can end the utterance — releasing the other one is a no-op, not
    //    a stop. This is what keeps a stray modifier from cutting a dictation short.
    do {
        var a = PTTArbiter()
        _ = a.resolve(key: .primary, down: true, otherModifiers: false)
        let wrong = a.resolve(key: .secondary, down: false, otherModifiers: false)
        check("foreign_release_is_noop", wrong == .ignore, "got \(wrong)")
        check("still_held_after_foreign_release", a.held == .primary, "held is \(String(describing: a.held))")
        let right = a.resolve(key: .primary, down: false, otherModifiers: false)
        check("owner_release_stops", right == .stop(.primary), "got \(right)")
    }

    // 4. A chord is not a PTT, when the other modifier lands first.
    for key in [PTTKey.primary, PTTKey.secondary] {
        var a = PTTArbiter()
        let d = a.resolve(key: key, down: true, otherModifiers: true)
        check("\(key.rawValue)_chord_not_ptt", d == .ignore, "got \(d)")
        check("\(key.rawValue)_chord_leaves_idle", a.held == nil, "held is \(String(describing: a.held))")
    }

    // 4b. …and when it lands second, the hold is retracted. This is the ⌃⌥⌘Z case that
    //     actually happens: a left hand presses Option before Control, so the dictation has
    //     already started by the time the chord is recognisable.
    do {
        var a = PTTArbiter()
        _ = a.resolve(key: .secondary, down: true, otherModifiers: false)
        let r = a.retract()
        check("late_chord_retracts", r == .cancel(.secondary), "got \(r)")
        check("retract_clears_hold", a.held == nil, "held is \(String(describing: a.held))")
        // The key release still arrives afterwards; it must not double-fire as a stop.
        let up = a.resolve(key: .secondary, down: false, otherModifiers: false)
        check("release_after_retract_is_noop", up == .ignore, "got \(up)")
    }

    // 4c. Retracting when nothing is held is a no-op — typing with no PTT down must not
    //     manufacture a cancel for an utterance that never existed.
    do {
        var a = PTTArbiter()
        let r = a.retract()
        check("retract_while_idle_is_noop", r == .ignore, "got \(r)")
    }

    // 4d. Typing retracts too: ⌥e for an accent starts a hold on the Option press, and the
    //     'e' is what proves it was never speech. Without this, every accented character
    //     would leave a stray empty utterance behind.
    do {
        var a = PTTArbiter()
        _ = a.resolve(key: .secondary, down: true, otherModifiers: false)
        check("typing_retracts_hold", a.retract() == .cancel(.secondary))
        check("typing_leaves_idle", a.held == nil, "held is \(String(describing: a.held))")
    }

    // 5. A release arriving with other modifiers still down must NOT be swallowed: the user
    //    can press a modifier mid-dictation, and losing the release would strand the app in
    //    the capturing state forever. Chord rejection applies to starts only.
    do {
        var a = PTTArbiter()
        _ = a.resolve(key: .primary, down: true, otherModifiers: false)
        let up = a.resolve(key: .primary, down: false, otherModifiers: true)
        check("release_survives_other_modifiers", up == .stop(.primary), "got \(up)")
    }

    // 6. The menu hint names the live pairing, and drops the second key when it is unbound so
    //    the line never advertises a key that does nothing.
    do {
        let both = AppDelegate.hintTitle(primary: "en", secondary: "es")
        check("hint_names_both_keys",
              both.contains("Right-Option (English)") && both.contains("Left-Option (Spanish)"),
              both)
        let off = AppDelegate.hintTitle(primary: "en", secondary: "off")
        check("hint_hides_unbound_key", !off.contains("Left-Option"), off)
        check("hint_keeps_cancel_and_undo", off.contains("Esc cancels") && off.contains("⌃⌥⌘Z"), off)
        let auto = AppDelegate.hintTitle(primary: "auto", secondary: "off")
        check("hint_labels_auto", auto.contains("Automatic"), auto)
    }

    let pass = checks.allSatisfy { $0.pass }
    struct Report: Encodable {
        let checks: [HotkeyCheck]
        let pass: Bool
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(Report(checks: checks, pass: pass)),
        let s = String(data: data, encoding: .utf8)
    {
        print(s)
    }
    return pass ? 0 : 1
}
