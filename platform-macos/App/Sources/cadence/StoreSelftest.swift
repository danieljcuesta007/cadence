// selftest-store — pins StorePlan, the decision that keeps a lost keychain key from either
// minting a key over a store or leaving dictation on JSONL forever (11 Oct 2026).

import Foundation

func runStoreSelftest() -> Int32 {
    var failed = 0
    func check(_ name: String, _ got: StorePlan, _ want: StorePlan) {
        let ok = got == want
        if !ok { failed += 1 }
        print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : ": got \(got), want \(want)")")
    }
    let a = Data(repeating: 1, count: 32), b = Data(repeating: 2, count: 32)

    let wrong: StorePlan.OpenFailure? = .wrongKey, other: StorePlan.OpenFailure? = .other
    func only(_ good: Data) -> (Data) -> StorePlan.OpenFailure? { { $0 == good ? nil : wrong } }

    check("keychain_key_opens", StorePlan.decide(keys: [a, b], keychainKnown: true, dbExists: true, opens: only(a)), .use(a))
    check("file_copy_rescues_lost_keychain_key",
          StorePlan.decide(keys: [a, b], keychainKnown: true, dbExists: true, opens: only(b)), .use(b))
    check("no_key_opens_existing_store_resets_it",
          StorePlan.decide(keys: [a], keychainKnown: true, dbExists: true) { _ in wrong }, .reset(a))
    check("busy_or_broken_store_is_never_reset",
          StorePlan.decide(keys: [a], keychainKnown: true, dbExists: true) { _ in other }, .wait)
    check("one_non_key_failure_blocks_reset",
          StorePlan.decide(keys: [a, b], keychainKnown: true, dbExists: true) { $0 == a ? wrong : other }, .wait)
    check("no_store_yet_creates_with_first_key",
          StorePlan.decide(keys: [a], keychainKnown: true, dbExists: false) { _ in other }, .use(a))
    check("locked_keychain_never_resets",
          StorePlan.decide(keys: [b], keychainKnown: false, dbExists: true) { _ in wrong }, .wait)
    check("locked_keychain_file_copy_still_opens",
          StorePlan.decide(keys: [b], keychainKnown: false, dbExists: true, opens: only(b)), .use(b))
    check("no_keys_at_all_waits",
          StorePlan.decide(keys: [], keychainKnown: false, dbExists: true) { _ in nil }, .wait)
    return failed == 0 ? 0 : 1
}
