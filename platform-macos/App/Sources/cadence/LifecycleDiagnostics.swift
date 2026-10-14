// Content-free, durable lifecycle records. No store key, transcript, or audio is read.
import Foundation
import Darwin

struct LifecycleSession: Codable {
    var id: String
    var pid: Int32
    var bootID: String
    var version: String
    var startedAt: Date
    var heartbeatAt: Date
    var stoppedAt: Date?
    var stopReason: String?
    var hotkeysReady: Bool?
    var engineReady: Bool?
}

struct LifecycleRecord: Codable {
    var schema = 1
    var current: LifecycleSession
    var previous: LifecycleSession?
}

enum LifecycleRead {
    case absent, unreadable, record(LifecycleRecord)
}

enum LifecycleDiagnostics {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cadence/logs/lifecycle.json")

    static func bootID() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
            return "unknown"
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: bytes)
    }

    static func read(_ url: URL = url) -> LifecycleRead {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(LifecycleRecord.self, from: data),
              record.schema == 1 else { return .unreadable }
        return .record(record)
    }

    static func write(_ record: LifecycleRecord, to url: URL = url) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func outcome(_ session: LifecycleSession, bootID: String) -> String {
        if let reason = session.stopReason, session.stoppedAt != nil { return reason }
        if session.bootID != "unknown", bootID != "unknown", session.bootID != bootID {
            return "no shutdown record; Mac restarted since this session"
        }
        return "no shutdown record; cause unknown (crash, force quit, or external termination possible)"
    }
}

/// Main-thread-owned. Timers deliberately record liveness without claiming that a late
/// heartbeat proves a hang: sleep and a busy main queue can both delay it.
final class LifecycleMonitor {
    private var record: LifecycleRecord?
    private var timer: Timer?
    private var failed = false
    private let url: URL
    private let log: (String) -> Void
    private let flush: () -> Void

    init(url: URL = LifecycleDiagnostics.url, log: @escaping (String) -> Void,
         flush: @escaping () -> Void) {
        self.url = url
        self.log = log
        self.flush = flush
    }

    func start(now: Date = Date(), pid: Int32 = ProcessInfo.processInfo.processIdentifier,
               bootID: String = LifecycleDiagnostics.bootID(), version: String,
               scheduleHeartbeat: Bool = true) {
        let previous: LifecycleSession?
        switch LifecycleDiagnostics.read(url) {
        case .record(let old):
            previous = old.current
            log("lifecycle previous pid=\(old.current.pid): \(LifecycleDiagnostics.outcome(old.current, bootID: bootID))")
        case .absent:
            previous = nil
            log("lifecycle previous: unavailable (first run with lifecycle logging)")
        case .unreadable:
            // Preserve malformed or newer-format evidence rather than overwriting it.
            failed = true
            log("lifecycle record unreadable or unsupported; preserved, recording disabled")
            flush()
            return
        }
        let session = LifecycleSession(id: UUID().uuidString, pid: pid, bootID: bootID,
            version: version, startedAt: now, heartbeatAt: now)
        record = LifecycleRecord(current: session, previous: previous)
        persist()
        log("lifecycle started id=\(session.id) pid=\(pid) version=\(version)")
        flush()
        if scheduleHeartbeat {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.heartbeat()
            }
        }
    }

    func heartbeat(now: Date = Date()) {
        guard record?.current.stoppedAt == nil else { return }
        record?.current.heartbeatAt = now
        persist()
    }

    func ready(hotkeys: Bool? = nil, engine: Bool? = nil) {
        if let hotkeys { record?.current.hotkeysReady = hotkeys }
        if let engine { record?.current.engineReady = engine }
        persist()
    }

    func stop(reason: String, now: Date = Date()) {
        timer?.invalidate()
        timer = nil
        guard record != nil, record?.current.stoppedAt == nil else { return }
        record?.current.stoppedAt = now
        record?.current.stopReason = reason
        persist()
        log("lifecycle stopped pid=\(record!.current.pid) reason=\(reason)")
        flush() // Shutdown must not drop queued log lines on process exit.
    }

    private func persist() {
        guard !failed, let record else { return }
        do { try LifecycleDiagnostics.write(record, to: url) }
        catch {
            failed = true
            log("lifecycle recording failed; dictation remains available")
        }
    }
}
