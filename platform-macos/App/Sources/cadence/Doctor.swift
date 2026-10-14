import AppKit
import AVFoundation
import Foundation
import ServiceManagement

/// Read-only diagnostics: no permission prompts, store access, clipboard, or transcript logs.
func runDoctor() -> Int32 {
    let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "dev.cadence.app" }
    let bundled = Bundle.main.bundlePath.hasSuffix(".app")
    var report: [String: Any] = [
        "schema": 1,
        "running": !apps.isEmpty,
        "runningPIDs": apps.map { Int($0.processIdentifier) },
        "diagnosticDirectory": LifecycleDiagnostics.url.deletingLastPathComponent().path,
        "permissionCheckScope": "this diagnostic executable; run from the installed Cadence.app",
        "accessibilityGranted": AXIsProcessTrusted(),
        "modelAvailable": bundledModel().map { FileManager.default.fileExists(atPath: $0) } ?? false,
    ]
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: report["microphone"] = "authorized"
    case .denied: report["microphone"] = "denied"
    case .restricted: report["microphone"] = "restricted"
    default: report["microphone"] = "not determined"
    }
    if bundled {
        switch SMAppService.mainApp.status {
        case .enabled: report["startAtLogin"] = "enabled"
        case .requiresApproval: report["startAtLogin"] = "requires approval"
        case .notFound: report["startAtLogin"] = "not found"
        default: report["startAtLogin"] = "not registered"
        }
    } else {
        report["startAtLogin"] = "unknown (run inside installed bundle)"
    }
    var ready = false
    let formatter = ISO8601DateFormatter()
    func sessionReport(_ session: LifecycleSession) -> [String: Any] {
        var result: [String: Any] = [
            "pid": Int(session.pid), "version": session.version,
            "startedAt": formatter.string(from: session.startedAt),
            "lastHeartbeatAt": formatter.string(from: session.heartbeatAt),
        ]
        if let stop = session.stoppedAt { result["stoppedAt"] = formatter.string(from: stop) }
        if let reason = session.stopReason { result["stopReason"] = reason }
        return result
    }
    switch LifecycleDiagnostics.read() {
    case .absent: report["lifecycle"] = "unavailable (no lifecycle record yet)"
    case .unreadable: report["lifecycle"] = "unreadable or unsupported; original file preserved"
    case .record(let record):
        var current = sessionReport(record.current)
        let alive = apps.contains { $0.processIdentifier == record.current.pid }
            && record.current.bootID == LifecycleDiagnostics.bootID()
            && record.current.stoppedAt == nil
        if alive {
            current["status"] = "running"
            current["heartbeatAgeSeconds"] = max(0, Int(Date().timeIntervalSince(record.current.heartbeatAt)))
            current["heartbeatNote"] = "updated every 60 seconds; sleep can delay it"
            current["hotkeysReady"] = record.current.hotkeysReady ?? false
            current["engineReady"] = record.current.engineReady ?? false
            ready = record.current.hotkeysReady == true && record.current.engineReady == true
        } else {
            current["status"] = LifecycleDiagnostics.outcome(record.current, bootID: LifecycleDiagnostics.bootID())
        }
        report["lastSession"] = current
        if let previous = record.previous {
            var prior = sessionReport(previous)
            prior["status"] = LifecycleDiagnostics.outcome(previous, bootID: record.current.bootID)
            report["previousSession"] = prior
        }
    }
    // Report metadata only, never crash contents (which can include private process data).
    let crashDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports")
    if let files = try? FileManager.default.contentsOfDirectory(at: crashDir,
        includingPropertiesForKeys: [.contentModificationDateKey]) {
        let dates = files.filter {
            $0.lastPathComponent.lowercased().hasPrefix("cadence-") && $0.pathExtension == "ips"
        }.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        report["crashReportCount"] = dates.count
        if let latest = dates.max() { report["latestCrashReportAt"] = formatter.string(from: latest) }
    } else {
        report["crashReports"] = "unavailable (directory missing or access denied)"
    }
    var actions: [String] = []
    if apps.isEmpty { actions.append("Open Cadence.app to start dictation. Start at Login runs at login, not after an arbitrary exit.") }
    if report["accessibilityGranted"] as? Bool != true {
        actions.append("Enable the installed Cadence in System Settings > Privacy & Security > Accessibility.")
    }
    if report["microphone"] as? String != "authorized" {
        actions.append("Open Cadence and grant Microphone access in System Settings > Privacy & Security.")
    }
    if report["modelAvailable"] as? Bool != true {
        actions.append("Reinstall a complete Cadence.app containing its bundled model.")
    }
    if report["startAtLogin"] as? String != "enabled" {
        actions.append("Check Cadence > Start at Login and System Settings > General > Login Items.")
    }
    if !apps.isEmpty && !ready {
        actions.append("Read cadence.log locally for startup or hotkey errors; lifecycle readiness is unavailable or incomplete.")
    }
    report["suggestedActions"] = actions
    report["note"] = "No crash report does not prove a clean exit. SIGKILL, crashes, and power loss cannot reliably record a shutdown reason."
    guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return 2 }
    print(text)
    return !apps.isEmpty && ready && actions.isEmpty ? 0 : 1
}
