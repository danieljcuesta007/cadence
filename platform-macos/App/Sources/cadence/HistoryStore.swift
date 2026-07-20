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
        applyRetention()
    }

    /// §24 retention: `retention_days` setting (unset/0 = keep forever). Runs at launch.
    /// Expired audio blobs are purged unconditionally — their `purge_after` deadline was
    /// stamped at write time, independent of the transcript window.
    private func applyRetention() {
        guard let handle else { return }
        if let c = cadence_store_setting_get(handle, "retention_days") {
            defer { cadence_string_free(c) }
            if let days = Int64(String(cString: c)), days > 0 {
                let purged = cadence_store_purge_utterances(handle, days)
                if purged > 0 {
                    LogFile.append("store: retention purged \(purged) utterances (> \(days) days)")
                }
            }
        }
        let audioPurged = cadence_store_audio_purge_expired(handle)
        if audioPurged > 0 {
            LogFile.append("store: purged \(audioPurged) expired audio blobs")
        }
    }

    deinit {
        cadence_store_free(handle)
    }

    /// Persist the enriched history record; falls back to JSONL on any failure (AC-22).
    /// Async on the store queue — never blocks the effect router. `audio` is the utterance's
    /// 16 kHz mono capture, retained as an encrypted WAV blob only when the user opted in
    /// (§24; the router passes nil otherwise). Audio is best-effort: a blob failure costs
    /// the audio, never the words.
    func persist(
        record: [String: Any], text: String?, metrics: [String: Any], audio: [Int16]? = nil
    ) {
        var rec = record
        rec["text"] = text
        rec["ts"] = ISO8601DateFormatter().string(from: Date())
        rec.merge(metrics) { current, _ in current }
        queue.async { [weak self] in
            guard let self, let handle = self.handle else {
                History.append(record: record, text: text, metrics: metrics)
                return
            }
            // Blob first so the record can carry the link. Redacted utterances never
            // retain audio — the raw capture would keep what redaction removed.
            if let audio, !audio.isEmpty, (rec["redacted"] as? Bool) != true {
                let blobId = "audio-" + UUID().uuidString
                let wav = WavWriter.data(from: audio)
                let ok = wav.withUnsafeBytes { raw -> Bool in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                        return false
                    }
                    return cadence_store_audio_put(
                        handle, blobId, base, raw.count, self.audioPurgeDeadlineMs())
                }
                if ok {
                    rec["audio_blob_id"] = blobId
                } else {
                    let msg = cadence_last_error().map { String(cString: $0) } ?? "unknown"
                    LogFile.append("audio blob put failed (keeping transcript): \(msg)")
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: rec),
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

    // MARK: retention window (§24; menu-surfaced until a full Settings UI exists)

    /// `retention_days` setting; 0/unset = keep forever. The purge itself runs at launch
    /// (`applyRetention`) and immediately on shortening the window.
    var retentionDays: Int64 {
        guard let handle, let c = cadence_store_setting_get(handle, "retention_days")
        else { return 0 }
        defer { cadence_string_free(c) }
        return Int64(String(cString: c)) ?? 0
    }

    func setRetentionDays(_ days: Int64) {
        guard let handle else { return }
        if !cadence_store_setting_set(handle, "retention_days", String(days)) {
            let msg = cadence_last_error().map { String(cString: $0) } ?? "unknown"
            LogFile.append("retention_days save failed: \(msg)")
            return
        }
        if days > 0 {
            let purged = cadence_store_purge_utterances(handle, days)
            if purged > 0 {
                LogFile.append("store: retention now \(days)d — purged \(purged) utterances")
            }
        }
    }

    // MARK: input device preference

    /// Prefer the built-in mic over Bluetooth headsets (default ON — HFP telephony audio
    /// wrecks ASR quality and the user's music). Stored as "off" only when disabled.
    var preferBuiltInMic: Bool {
        guard let handle, let c = cadence_store_setting_get(handle, "prefer_builtin_mic")
        else { return true }
        defer { cadence_string_free(c) }
        return String(cString: c) != "off"
    }

    func setPreferBuiltInMic(_ on: Bool) {
        guard let handle else { return }
        if !cadence_store_setting_set(handle, "prefer_builtin_mic", on ? "on" : "off") {
            let msg = cadence_last_error().map { String(cString: $0) } ?? "unknown"
            LogFile.append("prefer_builtin_mic save failed: \(msg)")
        }
    }

    /// Apple voice processing (noise suppression) on capture; default OFF — experimental
    /// (AUVoiceIO teardown deadlocked the app live 2026-07-19; opt-in until trustworthy).
    var voiceIsolation: Bool {
        guard let handle, let c = cadence_store_setting_get(handle, "voice_isolation")
        else { return false }
        defer { cadence_string_free(c) }
        return String(cString: c) == "on"
    }

    func setVoiceIsolation(_ on: Bool) {
        guard let handle else { return }
        if !cadence_store_setting_set(handle, "voice_isolation", on ? "on" : "off") {
            let msg = cadence_last_error().map { String(cString: $0) } ?? "unknown"
            LogFile.append("voice_isolation save failed: \(msg)")
        }
    }

    // MARK: retained audio (§24, opt-in; off by default)

    private static let retainAudioKey = "retain_audio"

    var retainAudioEnabled: Bool {
        guard let handle, let c = cadence_store_setting_get(handle, Self.retainAudioKey)
        else { return false }
        defer { cadence_string_free(c) }
        return String(cString: c) == "on"
    }

    func setRetainAudio(_ on: Bool) {
        guard let handle else { return }
        if !cadence_store_setting_set(handle, Self.retainAudioKey, on ? "on" : "off") {
            let msg = cadence_last_error().map { String(cString: $0) } ?? "unknown"
            LogFile.append("retain_audio save failed: \(msg)")
        }
    }

    /// Absolute purge deadline for a blob written now. `audio_retention_days` wins when
    /// set (0 = keep until the utterance goes); otherwise the transcript's
    /// `retention_days` window applies; 0 = no per-blob deadline.
    private func audioPurgeDeadlineMs() -> Int64 {
        for key in ["audio_retention_days", "retention_days"] {
            guard let handle, let c = cadence_store_setting_get(handle, key) else { continue }
            defer { cadence_string_free(c) }
            guard let days = Int64(String(cString: c)) else { continue }
            return days > 0
                ? Int64(Date().timeIntervalSince1970 * 1000) + days * 86_400_000 : 0
        }
        return 0
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

    // MARK: per-app rules (first slice: a disabled-apps list in the settings KV)

    private static let disabledKey = "disabled_apps"

    /// Apps (by localized name) where dictation is switched off. Read once at launch and
    /// after each toggle — PTT-down checks the cached set, never the DB.
    func disabledApps() -> Set<String> {
        guard let handle, let c = cadence_store_setting_get(handle, Self.disabledKey)
        else { return [] }
        defer { cadence_string_free(c) }
        guard let data = String(cString: c).data(using: .utf8),
            let arr = (try? JSONSerialization.jsonObject(with: data)) as? [String]
        else { return [] }
        return Set(arr)
    }

    func setApp(_ app: String, disabled: Bool) {
        guard let handle else { return }
        var apps = disabledApps()
        if disabled { apps.insert(app) } else { apps.remove(app) }
        guard let data = try? JSONSerialization.data(withJSONObject: Array(apps).sorted()),
            let json = String(data: data, encoding: .utf8)
        else { return }
        if !cadence_store_setting_set(handle, Self.disabledKey, json) {
            let msg = cadence_last_error().map { String(cString: $0) } ?? "unknown"
            LogFile.append("app rule save failed: \(msg)")
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
