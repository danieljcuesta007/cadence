// selftest-store — pins StorePlan, the decision that keeps a lost keychain key from either
// minting a key over a store or leaving dictation on JSONL forever (11 Oct 2026).

import Foundation
import Security

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

    // One prompt at most: every keychain read can be a "Cadence wants to use your keychain"
    // prompt, and reading it twice per launch was two prompts every launch (12 Oct 2026).
    func expect<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        let ok = got == want
        if !ok { failed += 1 }
        print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : ": got \(got), want \(want)")")
    }
    func probe(file: Data?, dbExists: Bool, opens: (Data) -> Bool,
               keychain: StoreKey.KeychainRead) -> (StoreKey.Found, Int) {
        var reads = 0
        let found = StoreKey.find(file: file, dbExists: dbExists, opens: opens) { reads += 1; return keychain }
        return (found, reads)
    }
    let kcA = StoreKey.KeychainRead(key: a, status: errSecSuccess)
    var (f, reads) = probe(file: b, dbExists: true, opens: { $0 == b }, keychain: kcA)
    expect("file_copy_opens_store_without_asking_keychain", reads, 0)
    expect("file_copy_opens_store_keys", f.keys, [b])
    (f, reads) = probe(file: b, dbExists: false, opens: { _ in false }, keychain: kcA)
    expect("no_store_yet_file_copy_needs_no_keychain", reads, 0)
    expect("no_store_yet_uses_file_copy", f.keys, [b])
    (f, reads) = probe(file: b, dbExists: true, opens: { $0 == a }, keychain: kcA)
    expect("file_copy_fails_keychain_read_once", reads, 1)
    expect("file_copy_fails_keychain_key_first", f.keys, [a, b])
    (f, reads) = probe(file: nil, dbExists: true, opens: { _ in true }, keychain: kcA)
    expect("no_file_copy_keychain_read_once", reads, 1)
    let denied = StoreKey.KeychainRead(key: nil, status: errSecAuthFailed)
    (f, reads) = probe(file: nil, dbExists: true, opens: { _ in true }, keychain: denied)
    expect("denied_keychain_is_unknown", f.keychainKnown, false)

    expect("unasked_keychain_is_left_alone", StoreKey.keychainWrite(nil, key: a), .none)
    expect("keychain_already_holds_key", StoreKey.keychainWrite(kcA, key: a), .none)
    expect("keychain_holds_other_key_is_updated", StoreKey.keychainWrite(kcA, key: b), .update)
    expect("keychain_missing_key_is_added",
           StoreKey.keychainWrite(.init(key: nil, status: errSecItemNotFound), key: a), .add)
    expect("denied_keychain_is_not_written", StoreKey.keychainWrite(denied, key: a), .none)
    return failed == 0 ? 0 : 1
}
