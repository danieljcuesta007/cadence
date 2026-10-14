import Foundation

func runLifecycleSelftest() -> Int32 {
    var checks: [[String: Any]] = []
    func check(_ name: String, _ pass: Bool) { checks.append(["name": name, "pass": pass]) }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("lifecycle.json")
    var logs: [String] = []
    var flushes = 0
    let first = LifecycleMonitor(url: url, log: { logs.append($0) }, flush: { flushes += 1 })
    let start = Date(timeIntervalSince1970: 100)
    first.start(now: start, pid: 42, bootID: "boot-a", version: "test", scheduleHeartbeat: false)
    if case .record(let record) = LifecycleDiagnostics.read(url) {
        check("startup_is_durable", record.current.pid == 42 && record.current.startedAt == start)
        check("first_launch_has_no_invented_history", record.previous == nil)
        check("unclean_exit_is_not_claimed_as_crash", LifecycleDiagnostics.outcome(record.current, bootID: "boot-a").contains("cause unknown"))
        check("reboot_is_distinguished", LifecycleDiagnostics.outcome(record.current, bootID: "boot-b").contains("Mac restarted"))
        check("unknown_boot_is_not_claimed_as_reboot", !LifecycleDiagnostics.outcome(record.current, bootID: "unknown").contains("Mac restarted"))
    } else { check("startup_is_durable", false) }
    first.heartbeat(now: Date(timeIntervalSince1970: 160))
    first.ready(hotkeys: true, engine: true)
    if case .record(let record) = LifecycleDiagnostics.read(url) {
        check("heartbeat_and_readiness_persist", record.current.heartbeatAt.timeIntervalSince1970 == 160 && record.current.hotkeysReady == true && record.current.engineReady == true)
    } else { check("heartbeat_and_readiness_persist", false) }
    let second = LifecycleMonitor(url: url, log: { logs.append($0) }, flush: { flushes += 1 })
    second.start(now: Date(timeIntervalSince1970: 200), pid: 43, bootID: "boot-a", version: "test", scheduleHeartbeat: false)
    if case .record(let record) = LifecycleDiagnostics.read(url) {
        check("next_launch_preserves_unexplained_exit", record.previous?.pid == 42 && record.previous?.stopReason == nil)
    } else { check("next_launch_preserves_unexplained_exit", false) }
    second.stop(reason: "menu_quit", now: Date(timeIntervalSince1970: 210))
    second.stop(reason: "wrong_second_reason")
    second.heartbeat(now: Date(timeIntervalSince1970: 300))
    if case .record(let record) = LifecycleDiagnostics.read(url) {
        check("clean_exit_persists_reason", LifecycleDiagnostics.outcome(record.current, bootID: "boot-b") == "menu_quit")
        check("stop_is_idempotent", record.current.stoppedAt?.timeIntervalSince1970 == 210 && record.current.stopReason == "menu_quit")
        check("heartbeat_cannot_revive_stopped_session", record.current.heartbeatAt.timeIntervalSince1970 == 200)
    } else { check("clean_exit_persists_reason", false) }
    check("shutdown_flushes_log", flushes == 3 && logs.last?.contains("reason=menu_quit") == true)
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    check("record_permissions_are_private", (attrs?[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    do {
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: url)
        let beforeBroken = logs.count
        var brokenFlushes = 0
        let broken = LifecycleMonitor(url: url, log: { logs.append($0) }, flush: { brokenFlushes += 1 })
        broken.start(version: "test", scheduleHeartbeat: false)
        broken.heartbeat()
        broken.stop(reason: "menu_quit")
        let brokenLogs = Array(logs.dropFirst(beforeBroken))
        check("malformed_record_preserved", try Data(contentsOf: url) == corrupt)
        check("malformed_record_reported", brokenLogs.contains { $0.contains("record unreadable") })
        check("malformed_record_keeps_shutdown_event", brokenLogs.contains { $0.contains("lifecycle stopped") && $0.contains("reason=menu_quit") })
        check("malformed_record_keeps_shutdown_flush", brokenFlushes == 2)
        let blocked = url.appendingPathComponent("impossible.json")
        let failure = LifecycleMonitor(url: blocked, log: { logs.append($0) }, flush: {})
        failure.start(version: "test", scheduleHeartbeat: false)
        check("write_failure_degrades_without_crash", logs.contains { $0.contains("recording failed") })
    } catch { check("malformed_record_preserved", false) }
    let pass = checks.allSatisfy { $0["pass"] as? Bool == true }
    if let data = try? JSONSerialization.data(withJSONObject: ["pass": pass, "checks": checks], options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text) }
    return pass ? 0 : 1
}
