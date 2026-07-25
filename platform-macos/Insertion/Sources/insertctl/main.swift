// insertctl — Phase-0 insertion spike CLI (§32).
//
//   insertctl check                 permission + capability report (JSON)
//   insertctl insert "text"         run the cascade against the focused element
//   insertctl insert "text" --delay 3   sleep first so you can focus a target field
//   insertctl selftest-clipboard    prove snapshot/restore never corrupts the clipboard

import AppKit
import CadenceInsertion
import Foundation

func printJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    FileHandle.standardError.write(Data("""
    usage: insertctl <check|insert|selftest-clipboard> [text] [--delay seconds] [--timeout ms]
    """.utf8))
    exit(2)
}

var timeoutMs = 250
if let i = args.firstIndex(of: "--timeout"), i + 1 < args.count, let t = Int(args[i + 1]) {
    timeoutMs = t
}

let engine = InsertionEngine(timeoutMs: timeoutMs)

switch command {
case "check":
    printJSON(engine.capabilities())

case "insert":
    guard args.count >= 2 else {
        FileHandle.standardError.write(Data("insertctl insert \"text\" [--delay seconds]\n".utf8))
        exit(2)
    }
    let text = args[1]
    if let i = args.firstIndex(of: "--delay"), i + 1 < args.count, let d = Double(args[i + 1]) {
        FileHandle.standardError.write(Data("focus your target field… inserting in \(d)s\n".utf8))
        Thread.sleep(forTimeInterval: d)
    }
    let result = engine.insert(text)
    printJSON(result)
    exit(result.inserted ? 0 : 1)

case "find-click":
    // insertctl find-click "secure" — find + click a matching element in the frontmost app.
    guard args.count >= 2 else {
        FileHandle.standardError.write(Data("insertctl find-click <query> [--delay s]\n".utf8))
        exit(2)
    }
    if let i = args.firstIndex(of: "--delay"), i + 1 < args.count, let d = Double(args[i + 1]) {
        Thread.sleep(forTimeInterval: d)
    }
    let result = findAndClick(args[1])
    printJSON(result)
    exit(result.clicked ? 0 : 1)

case "frontmost":
    print(NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown")

case "read":
    // Dump the focused element (role/subrole/value/selection) — matrix verification readback.
    if let i = args.firstIndex(of: "--delay"), i + 1 < args.count, let d = Double(args[i + 1]) {
        Thread.sleep(forTimeInterval: d)
    }
    printJSON(readFocused())

case "key":
    // insertctl key cmd-n | return | esc | cmd-space | cmd-a ...   (CGEvents; AX perm only)
    guard args.count >= 2 else {
        FileHandle.standardError.write(Data("insertctl key <combo> [--delay s]\n".utf8))
        exit(2)
    }
    if let i = args.firstIndex(of: "--delay"), i + 1 < args.count, let d = Double(args[i + 1]) {
        Thread.sleep(forTimeInterval: d)
    }
    let combo = args[1].lowercased().split(separator: "-").map(String.init)
    var flags: CGEventFlags = []
    let keyName: String = combo.last ?? ""
    for part in combo.dropLast() {
        switch part {
        case "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt", "alt": flags.insert(.maskAlternate)
        case "ctrl": flags.insert(.maskControl)
        default:
            FileHandle.standardError.write(Data("unknown modifier: \(part)\n".utf8))
            exit(2)
        }
    }
    let keyMap: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "tab": 48, "space": 49, "delete": 51, "esc": 53,
        "down": 125, "up": 126, "left": 123, "right": 124,
    ]
    guard let code = keyMap[keyName] else {
        FileHandle.standardError.write(Data("unknown key: \(keyName)\n".utf8))
        exit(2)
    }
    exit(postKey(code, flags: flags) ? 0 : 1)

case "selftest":
    // Runs every headless invariant: deadline abandonment (the no-freeze mechanism) and the
    // clipboard snapshot/restore contract, on a private pasteboard (user clipboard untouched).
    struct Check: Codable { var name: String; var pass: Bool }
    var checks: [Check] = []

    // 1. Deadline abandons slow work without waiting (§16.3).
    let t0 = Date()
    let slow: Int? = withDeadline(100) {
        Thread.sleep(forTimeInterval: 5.0)
        return 42
    }
    let elapsed = Date().timeIntervalSince(t0)
    checks.append(Check(name: "deadline_abandons_slow_work",
                        pass: slow == nil && elapsed < 1.0))

    // 2. Deadline returns fast work.
    checks.append(Check(name: "deadline_returns_fast_work",
                        pass: withDeadline(250) { 7 } == 7))

    // 3. Empty-clipboard snapshot restores to empty.
    do {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.cadence.test.\(UUID())"))
        pb.clearContents()
        let snap = ClipboardSnapshot.capture(pb)
        pb.clearContents()
        pb.setString("junk", forType: .string)
        let ok = snap.restore(to: pb, ifChangeCountStill: pb.changeCount)
            && pb.string(forType: .string) == nil
        checks.append(Check(name: "empty_snapshot_restores_empty", pass: ok))
    }

    // 4. Multi-type roundtrip is byte-exact.
    do {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.cadence.test.\(UUID())"))
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setData(Data([1, 2, 3]), forType: .init("com.cadence.blob"))
        pb.writeObjects([item])
        let snap = ClipboardSnapshot.capture(pb)
        pb.clearContents()
        pb.setString("transient", forType: .string)
        let ok = snap.restore(to: pb, ifChangeCountStill: pb.changeCount)
            && pb.string(forType: .string) == "hello"
            && pb.data(forType: .init("com.cadence.blob")) == Data([1, 2, 3])
        checks.append(Check(name: "multi_type_roundtrip", pass: ok))
    }

    // 5. Third-party write is never clobbered by restore.
    do {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.cadence.test.\(UUID())"))
        pb.clearContents()
        pb.setString("original", forType: .string)
        let snap = ClipboardSnapshot.capture(pb)
        pb.clearContents()
        pb.setString("ours", forType: .string)
        let ourCount = pb.changeCount
        pb.clearContents()
        pb.setString("third-party", forType: .string)
        let refused = !snap.restore(to: pb, ifChangeCountStill: ourCount)
        let ok = refused && pb.string(forType: .string) == "third-party"
        checks.append(Check(name: "third_party_write_never_clobbered", pass: ok))
    }

    // 6-9. Readback folding (AC-20). These pin the live failure that made 14 of 40 real
    // insertions report `contradicted` while the text had landed: the target re-flows what it
    // was given, and an exact substring probe cannot survive that.
    do {
        // Measured shape of the live case: Terminal exposes the visible screen only, wrapped at
        // ~93 columns, each continuation line carrying the TUI's "│ " gutter.
        let dictated = "Let's patch this up and then call the project good, because it is close."
        let probe = String(dictated.suffix(64))
        let wrapped = "│ Let's patch this up and then call the project good, because\n│ it is close.\n"
        checks.append(Check(name: "exact_probe_fails_on_wrapped_readback",
                            pass: !wrapped.contains(probe)))
        checks.append(Check(name: "folded_probe_survives_wrapped_readback",
                            pass: foldForReadback(wrapped).contains(foldForReadback(probe))))

        // Smart substitutions on entry (this machine has smart quotes on).
        let curly = "│ Let's patch this up and then call the project good, because it is close."
            .replacingOccurrences(of: "'", with: "\u{2019}")
        checks.append(Check(name: "folded_probe_survives_smart_quotes",
                            pass: foldForReadback(curly).contains(foldForReadback(probe))))

        // The verdict this check exists for (Pages page-layout): text genuinely nowhere.
        let swallowed = "│ > \n│ (no input)\n"
        checks.append(Check(name: "genuine_swallow_still_contradicted",
                            pass: !foldForReadback(swallowed).contains(foldForReadback(probe))))
    }

    struct SelfTestReport: Codable { var checks: [Check]; var pass: Bool }
    let allPass = checks.allSatisfy { $0.pass }
    printJSON(SelfTestReport(checks: checks, pass: allPass))
    exit(allPass ? 0 : 1)

case "selftest-clipboard":
    // Invariant under test (AC-20): a full snapshot → overwrite → restore cycle leaves the
    // clipboard byte-identical, including multi-type items; and a third-party write mid-cycle
    // is never clobbered.
    let pb = NSPasteboard.general
    let original = ClipboardSnapshot.capture(pb)

    // Seed a known multi-type payload.
    pb.clearContents()
    let seeded = NSPasteboardItem()
    seeded.setString("cadence-selftest-original", forType: .string)
    seeded.setData(Data([0xDE, 0xAD, 0xBE, 0xEF]), forType: .init("com.cadence.selftest"))
    pb.writeObjects([seeded])

    let snap = ClipboardSnapshot.capture(pb)
    pb.clearContents()
    pb.setString("cadence-transient-payload", forType: .string)
    let ours = pb.changeCount
    let restoredOK = snap.restore(to: pb, ifChangeCountStill: ours)

    let str = pb.string(forType: .string)
    let blob = pb.data(forType: .init("com.cadence.selftest"))
    let roundtrip = restoredOK && str == "cadence-selftest-original"
        && blob == Data([0xDE, 0xAD, 0xBE, 0xEF])

    // Third-party interference: restore must refuse when changeCount moved on.
    pb.clearContents()
    pb.setString("third-party-data", forType: .string)
    let refused = !snap.restore(to: pb, ifChangeCountStill: ours) // stale count ⇒ refuse
    let intact = pb.string(forType: .string) == "third-party-data"

    // Put the user's real clipboard back.
    _ = original.restore(to: pb, ifChangeCountStill: pb.changeCount)

    struct SelfTest: Codable {
        var multiTypeRoundtripRestored: Bool
        var thirdPartyWriteNeverClobbered: Bool
        var pass: Bool
    }
    let pass = roundtrip && refused && intact
    printJSON(SelfTest(
        multiTypeRoundtripRestored: roundtrip,
        thirdPartyWriteNeverClobbered: refused && intact,
        pass: pass))
    exit(pass ? 0 : 1)

default:
    FileHandle.standardError.write(Data("unknown command: \(command)\n".utf8))
    exit(2)
}
