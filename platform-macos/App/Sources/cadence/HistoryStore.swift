// HistoryStore — Swift face of the encrypted store (§24) plus its keychain key.
//
// Key custody: a 32-byte random key in the login keychain (generic password, service
// "dev.cadence.app", account "store-key") AND a 0600 copy at ~/.cadence/store.key, created on
// first launch. The file copy is tried first and the keychain only when it fails, so a normal
// launch never raises a keychain prompt. The core only ever sees the raw bytes at open;
// SQLCipher encrypts ~/.cadence/store.db. If no copy opens the store, it is renamed aside (never deleted) and a
// fresh one starts. Disk-level protection is FileVault's job.
//
// AC-22 (no words ever lost): if the store cannot open or a persist fails, callers fall
// back to the append-only JSONL exactly as before — the store is an upgrade, never a gate.

import CCadenceFFI
import Foundation
import Security

enum StoreKey {
    static let service = "dev.cadence.app"
    static let account = "store-key"
    /// Second copy of the key, beside the store (0600). The login keychain can be replaced out
    /// from under us (it was, 11 Oct 2026, and a year of history became unreadable), so the
    /// keychain is no longer the only copy. FileVault still encrypts the disk underneath.
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cadence/store.key")

    /// One read of the keychain copy. `key` is set only for a 32-byte key.
    struct KeychainRead: Equatable {
        var key: Data?
        var status: OSStatus
        var known: Bool { status == errSecSuccess || status == errSecItemNotFound }
    }

    struct Found {
        var keys: [Data]          // every distinct key we hold, keychain first
        var keychainKnown: Bool   // false = keychain locked/denied; true also when never asked,
                                  // because the file copy already settles it
        var keychain: KeychainRead? // nil = never asked: the file copy opened the store
        var file: Data?           // the file copy as read, so remember() needn't read it again
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func readKeychain() -> KeychainRead {
        var query = baseQuery
        query[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status != errSecSuccess && status != errSecItemNotFound {
            LogFile.append("store key: keychain read failed (\(status))")
        }
        let data = status == errSecSuccess ? out as? Data : nil
        return KeychainRead(key: data?.count == 32 ? data : nil, status: status)
    }

    static func readFile() -> Data? {
        guard let file = try? Data(contentsOf: fileURL), file.count == 32 else { return nil }
        return file
    }

    /// The file copy goes first: when it opens the store, the keychain is never touched, so a
    /// normal launch shows no keychain prompt at all. Otherwise the keychain is read exactly
    /// once. Each read of an item whose access list doesn't name this build is its own
    /// "Cadence wants to use your keychain" prompt, and two reads per launch was two prompts
    /// on every launch (12 Oct 2026).
    static func find(file: Data?, dbExists: Bool, opens: (Data) -> Bool,
                     keychain: () -> KeychainRead) -> Found {
        if let f = file, !dbExists || opens(f) {
            return Found(keys: [f], keychainKnown: true, keychain: nil, file: f)
        }
        let kc = keychain()
        var keys: [Data] = []
        if let k = kc.key { keys.append(k) }
        if let f = file, !keys.contains(f) { keys.append(f) }
        return Found(keys: keys, keychainKnown: kc.known, keychain: kc, file: file)
    }

    enum KeychainWrite: Equatable { case none, update, add }

    /// What `remember` does to the keychain copy, from the one read `find` already made.
    /// Never asked this launch → leave it alone (asking would be the prompt we avoid).
    static func keychainWrite(_ read: KeychainRead?, key: Data) -> KeychainWrite {
        guard let read else { return .none }
        switch read.status {
        case errSecSuccess: return read.key == key ? .none : .update
        case errSecItemNotFound: return .add
        default: return .none // locked or denied: it'd fail anyway
        }
    }

    /// Write `data` readable by this user only: created 0600 (never briefly 0644), then
    /// renamed into place so a reader never sees a half-written key.
    @discardableResult
    static func writePrivate(_ data: Data, to url: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        if rename(tmp.path, url.path) != 0 { try? fm.removeItem(at: tmp); return false }
        return true
    }

    static func create() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            LogFile.append("store key: SecRandomCopyBytes failed")
            return nil
        }
        LogFile.append("store key: created")
        return Data(bytes)
    }

    /// Make both copies hold `key` (the one that opened the store). Best-effort per copy.
    /// Reuses `find`'s keychain read rather than reading again (a second read = a second prompt).
    static func remember(_ key: Data, keychain read: KeychainRead?, file: Data?) {
        switch keychainWrite(read, key: key) {
        case .none: break
        case .update:
            let status = SecItemUpdate(baseQuery as CFDictionary,
                                       [kSecValueData as String: key] as CFDictionary)
            if status != errSecSuccess { LogFile.append("store key: keychain update failed (\(status))") }
        case .add:
            var add = baseQuery
            add[kSecValueData as String] = key
            // This Mac only: history is local-first (§10); no iCloud keychain sync for the key.
            add[kSecAttrSynchronizable as String] = false
            let status = SecItemAdd(add as CFDictionary, nil)
            if status != errSecSuccess { LogFile.append("store key: keychain write failed (\(status))") }
        }
        if file != key {
            if writePrivate(key, to: fileURL) {
                LogFile.append("store key: file copy saved")
            } else {
                LogFile.append("store key: file copy failed")
            }
        }
    }
}

/// What to do with the keys we hold. Pure, so `selftest-store` can pin every branch.
enum StorePlan: Equatable {
    case use(Data)    // this key opened the store (or there is no store yet: create with it)
    case reset(Data)  // a store exists and no key opens it: move it aside, start fresh with this
    case wait         // keychain locked/denied, or the store failed for a reason other than
                      // the key (busy, disk, migration): its key may be fine, touch nothing

    enum OpenFailure { case wrongKey, other }

    /// `opens` returns nil on success, else why that key failed.
    static func decide(keys: [Data], keychainKnown: Bool, dbExists: Bool,
                       opens: (Data) -> OpenFailure?) -> StorePlan {
        var allWrongKey = true
        for k in keys {
            guard let failure = opens(k) else { return .use(k) }
            if failure != .wrongKey { allWrongKey = false }
        }
        guard keychainKnown, let k = keys.first else { return .wait }
        if !dbExists { return .use(k) }
        return allWrongKey ? .reset(k) : .wait
    }
}

final class HistoryStore {
    static let dbURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cadence/store.db")

    private var handle: OpaquePointer?

    private static func open(_ key: Data) -> OpaquePointer? {
        key.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return cadence_store_open(dbURL.path, base, raw.count)
        }
    }

    /// Rename store.db (and any WAL/SHM beside it) to store.locked-<stamp>.db*.
    private static func moveAside() -> URL? {
        let fm = FileManager.default
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let aside = dbURL.deletingLastPathComponent()
            .appendingPathComponent("store.locked-\(f.string(from: Date())).db")
        // All or nothing: a fresh store.db must never sit beside the old store's WAL.
        var moved: [(URL, URL)] = []
        do {
            for ext in ["", "-wal", "-shm"] {
                let from = URL(fileURLWithPath: dbURL.path + ext)
                let to = URL(fileURLWithPath: aside.path + ext)
                if ext.isEmpty || fm.fileExists(atPath: from.path) {
                    try fm.moveItem(at: from, to: to)
                    moved.append((from, to))
                }
            }
            return aside
        } catch {
            for (from, to) in moved.reversed() { try? fm.moveItem(at: to, to: from) }
            LogFile.append("store: could not move the locked store aside: \(error.localizedDescription)")
            return nil
        }
    }
    private let queue = DispatchQueue(label: "cadence.store", qos: .utility)

    /// Nil when no key opens the store — callers keep the JSONL path.
    init?() {
        let dbExists = FileManager.default.fileExists(atPath: Self.dbURL.path)
        var opened: (Data, OpaquePointer)?
        let attempt: (Data) -> StorePlan.OpenFailure? = { k in
            if let (held, _) = opened, held == k { return nil } // already open: no second handle
            guard let h = Self.open(k) else {
                let msg = cadence_last_error().map { String(cString: $0) } ?? ""
                return msg.contains("wrong key or not a cadence store") ? .wrongKey : .other
            }
            opened = (k, h)
            return nil
        }
        let found = StoreKey.find(file: StoreKey.readFile(), dbExists: dbExists,
                                  opens: { attempt($0) == nil }, keychain: StoreKey.readKeychain)
        var keys = found.keys
        if keys.isEmpty {
            // Keychain locked/denied and no file copy: wait, never mint a key over a store.
            guard found.keychainKnown, let fresh = StoreKey.create() else { return nil }
            keys = [fresh]
        }
        let plan = StorePlan.decide(keys: keys, keychainKnown: found.keychainKnown,
                                    dbExists: dbExists, opens: attempt)
        switch plan {
        case .wait:
            return nil
        case .use(let k):
            if opened == nil { opened = Self.open(k).map { (k, $0) } }
        case .reset(let k):
            // No key we hold opens it: the key is gone. Keep the old file (renamed, never
            // deleted, in case its key turns up) and start a fresh store, instead of
            // silently living on JSONL forever.
            let msg = cadence_last_error().map { String(cString: $0) } ?? "unknown"
            if let aside = Self.moveAside() {
                // Every key we held goes with it, so remember() below can't erase the one
                // that might still open it.
                StoreKey.writePrivate(keys.reduce(Data(), +),
                                      to: aside.deletingPathExtension().appendingPathExtension("keys"))
                LogFile.append("store: no key opens store.db (\(msg)); kept it as \(aside.lastPathComponent), starting a fresh store")
                opened = Self.open(k).map { (k, $0) }
            }
        }
        guard let (key, db) = opened else {
            let msg = cadence_last_error().map { String(cString: $0) } ?? "unknown"
            LogFile.append("store open failed — staying on JSONL: \(msg)")
            return nil
        }
        StoreKey.remember(key, keychain: found.keychain, file: found.file)
        handle = db
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

    /// The user's Start at Login choice; nil until recorded. Kept here so a launch can
    /// restore the system registration if it is ever lost (see LoginItem.swift).
    var startAtLogin: Bool? {
        guard let handle, let c = cadence_store_setting_get(handle, "start_at_login")
        else { return nil }
        defer { cadence_string_free(c) }
        return String(cString: c) == "on"
    }

    func setStartAtLogin(_ on: Bool) {
        guard let handle else { return }
        if !cadence_store_setting_set(handle, "start_at_login", on ? "on" : "off") {
            let msg = cadence_last_error().map { String(cString: $0) } ?? "unknown"
            LogFile.append("start_at_login save failed: \(msg)")
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

    // MARK: dictation language (auto-detect by default; multilingual model required for ES)

    /// What Right-Option dictates in: "auto" (detect per utterance), "en", or "es".
    /// Unset ⇒ "en", not "auto": detection costs ~160 ms per utterance and buys nothing when
    /// the user can just hold the other key for their second language (§30).
    var dictationLanguage: String {
        guard let handle, let c = cadence_store_setting_get(handle, "dictation_language")
        else { return "en" }
        defer { cadence_string_free(c) }
        let v = String(cString: c)
        return v.isEmpty ? "en" : v
    }

    func setDictationLanguage(_ lang: String) {
        guard let handle else { return }
        if !cadence_store_setting_set(handle, "dictation_language", lang) {
            let msg = cadence_last_error().map { String(cString: $0) } ?? "unknown"
            LogFile.append("dictation_language save failed: \(msg)")
        }
    }

    /// What Left-Option dictates in — same codes plus "off" to unbind the key entirely.
    /// Unset ⇒ "es", which is the pairing that makes the two-key design worth having.
    var secondaryLanguage: String {
        guard let handle, let c = cadence_store_setting_get(handle, "secondary_language")
        else { return "es" }
        defer { cadence_string_free(c) }
        let v = String(cString: c)
        return v.isEmpty ? "es" : v
    }

    func setSecondaryLanguage(_ lang: String) {
        guard let handle else { return }
        if !cadence_store_setting_set(handle, "secondary_language", lang) {
            let msg = cadence_last_error().map { String(cString: $0) } ?? "unknown"
            LogFile.append("secondary_language save failed: \(msg)")
        }
    }

    // MARK: appearance (System / Light / Dark)

    /// The app's appearance pick. Unset or unknown ⇒ .system (follow macOS).
    var appearance: Appearance {
        guard let handle, let c = cadence_store_setting_get(handle, "appearance")
        else { return .system }
        defer { cadence_string_free(c) }
        return Appearance(rawValue: String(cString: c)) ?? .system
    }

    func setAppearance(_ choice: Appearance) {
        guard let handle else { return }
        if !cadence_store_setting_set(handle, "appearance", choice.rawValue) {
            let msg = cadence_last_error().map { String(cString: $0) } ?? "unknown"
            LogFile.append("appearance save failed: \(msg)")
        }
    }

    // MARK: personal dictionary (§; biases whisper toward the user's terms)

    /// Custom terms, one per line, the user wants spelled correctly (proper nouns, jargon,
    /// names). Stored verbatim; the engine gets them joined into one prompt phrase.
    var customVocabulary: String {
        guard let handle, let c = cadence_store_setting_get(handle, "custom_vocabulary")
        else { return "" }
        defer { cadence_string_free(c) }
        return String(cString: c)
    }

    func setCustomVocabulary(_ text: String) {
        guard let handle else { return }
        if !cadence_store_setting_set(handle, "custom_vocabulary", text) {
            let msg = cadence_last_error().map { String(cString: $0) } ?? "unknown"
            LogFile.append("custom_vocabulary save failed: \(msg)")
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

    /// Delete a single dictation (and its audio) by utterance id — the dashboard's per-row
    /// delete. Returns true if a row was removed.
    @discardableResult
    func deleteUtterance(id: String) -> Bool {
        guard let handle else { return false }
        return queue.sync { cadence_store_delete_utterance(handle, id) }
    }

    /// Fetch a retained audio blob (the encrypted WAV) by id, for dashboard playback. Nil when
    /// absent (never retained, purged, or store unavailable).
    func audioBlob(id: String) -> Data? {
        guard let handle else { return nil }
        return queue.sync {
            var len: Int = 0
            guard let ptr = cadence_store_audio_get(handle, id, &len), len > 0 else { return nil }
            defer { cadence_bytes_free(ptr, len) }
            return Data(bytes: ptr, count: len)
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
