// HistoryStore — Swift face of the encrypted store (§24) plus its keychain key.
//
// Key custody: a 32-byte random key lives in the login keychain (generic password,
// service "dev.cadence.app", account "store-key"), created on first launch. The core only
// ever sees the raw bytes at open; SQLCipher encrypts everything at rest at
// ~/.cadence/store.db. Blueprint "local data at rest": DB encrypted, key in OS keychain.
//
// AC-22 (no words ever lost): if the store cannot open or a persist fails, callers fall
// back to the append-only JSONL exactly as before — the store is an upgrade, never a gate.

import CCadenceFFI
import Foundation
import Security

enum StoreKey {
    static let service = "dev.cadence.app"
    static let account = "store-key"

    /// Fetch the store key, creating and persisting it on first use. Nil only if the
    /// keychain refuses both read and write (locked/denied) — callers then skip the store.
    static func resolve() -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecSuccess, let data = out as? Data, data.count == 32 {
            return data
        }
        guard status == errSecItemNotFound else {
            LogFile.append("store key: keychain read failed (\(status))")
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            LogFile.append("store key: SecRandomCopyBytes failed")
            return nil
        }
        let key = Data(bytes)
        query.removeValue(forKey: kSecReturnData as String)
        query[kSecValueData as String] = key
        // This Mac only: history is local-first (§10); no iCloud keychain sync for the key.
        query[kSecAttrSynchronizable as String] = false
        let add = SecItemAdd(query as CFDictionary, nil)
        guard add == errSecSuccess else {
            LogFile.append("store key: keychain write failed (\(add))")
            return nil
        }
        LogFile.append("store key: created in login keychain")
        return key
    }
}

final class HistoryStore {
    static let dbURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cadence/store.db")

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "cadence.store", qos: .utility)

    /// Nil when the key or the open fails — callers keep the JSONL path.
    init?() {
        guard let key = StoreKey.resolve() else { return nil }
        let opened: OpaquePointer? = key.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return cadence_store_open(Self.dbURL.path, base, raw.count)
        }
        guard let opened else {
            let msg = cadence_last_error().map { String(cString: $0) } ?? "unknown"
            LogFile.append("store open failed — staying on JSONL: \(msg)")
            return nil
        }
        handle = opened
        importLegacyJSONLIfPresent()
    }

    deinit {
        cadence_store_free(handle)
    }

    /// Persist the enriched history record; falls back to JSONL on any failure (AC-22).
    /// Async on the store queue — never blocks the effect router.
    func persist(record: [String: Any], text: String?, metrics: [String: Any]) {
        var rec = record
        rec["text"] = text
        rec["ts"] = ISO8601DateFormatter().string(from: Date())
        rec.merge(metrics) { current, _ in current }
        queue.async { [weak self] in
            guard let self, let handle = self.handle,
                let data = try? JSONSerialization.data(withJSONObject: rec),
                let json = String(data: data, encoding: .utf8),
                cadence_store_persist_json(handle, json)
            else {
                let msg = cadence_last_error().map { String(cString: $0) } ?? "encode failed"
                LogFile.append("store persist failed — JSONL fallback: \(msg)")
                History.append(record: record, text: text, metrics: metrics)
                return
            }
        }
    }

    /// Newest-first history for the dashboard. Synchronous (dashboard opens on demand).
    func recent(limit: Int) -> [[String: Any]] {
        guard let handle else { return [] }
        return queue.sync {
            guard let c = cadence_store_recent_json(handle, limit) else { return [] }
            defer { cadence_string_free(c) }
            let json = String(cString: c)
            guard let data = json.data(using: .utf8),
                let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            else { return [] }
            return arr
        }
    }

    /// One-time migration: fold the JSONL stand-in into the store, then rename it aside so
    /// the import never runs twice (and the plaintext stops accumulating). The file is
    /// renamed, not deleted — it is the user's dictation history (do-not-destroy).
    private func importLegacyJSONLIfPresent() {
        let jsonl = History.url
        guard FileManager.default.fileExists(atPath: jsonl.path), let handle else { return }
        let imported = cadence_store_import_jsonl(handle, jsonl.path)
        if imported >= 0 {
            let aside = jsonl.appendingPathExtension("imported")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: jsonl, to: aside)
            LogFile.append("store: imported \(imported) JSONL records; JSONL moved aside")
        } else {
            let msg = cadence_last_error().map { String(cString: $0) } ?? "unknown"
            LogFile.append("store: JSONL import failed (keeping JSONL): \(msg)")
        }
    }
}
