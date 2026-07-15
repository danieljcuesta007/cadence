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
