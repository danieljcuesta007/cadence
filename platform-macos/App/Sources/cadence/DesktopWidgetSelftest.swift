import AppKit
import Foundation
import SwiftUI

func runDesktopWidgetSelftest(outDir: String? = nil) -> Int32 {
    var failures = 0
    var count = 0
    func check(_ good: Bool, _ label: String) {
        count += 1
        if !good { failures += 1; print("FAIL: \(label)") }
    }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func payload(_ date: Date, schema: Int = 1, words: Int = 123, minutes: Int = 4) -> Data {
        try! JSONSerialization.data(withJSONObject: ["schema": schema,
            "generated_at": ISO8601DateFormatter().string(from: date),
            "today": ["words": words, "time_saved_min": minutes],
            "week": ["words": 766, "time_saved_min": 14, "wpm": 156],
            "all": ["words": 7000], "streak_days": 3,
            "per_day": [["words": 0], ["words": 532], ["words": 234]]])
    }
    let stats = DesktopStats.read(payload(now), now: now)
    check(stats.words == 123 && stats.minutesSaved == 4 && stats.current, "today aggregate stats")
    check(stats.wordsWeek == 766 && stats.minutesWeek == 14 && stats.pace == 156, "week aggregate stats")
    check(stats.streak == 3 && stats.allWords == 7000 && stats.days == [0, 532, 234], "streak, all-time and chart data")
    check(!DesktopStats.read(nil, now: now).current, "missing stats")
    check(!DesktopStats.read(Data("broken".utf8), now: now).current, "corrupt stats")
    check(!DesktopStats.read(payload(now, schema: 2), now: now).current, "unknown schema")
    check(!DesktopStats.read(payload(now.addingTimeInterval(-86400)), now: now).current, "yesterday is not today")
    check(!DesktopStats.read(payload(now.addingTimeInterval(300)), now: now).current, "future timestamp")
    check(!DesktopStats.read(payload(now, words: -1), now: now).current, "negative words")
    check(!DesktopStats.read(payload(now, minutes: -1), now: now).current, "negative savings")
    check(DesktopStats.read(payload(now, words: 0, minutes: 0), now: now).current, "valid empty history")
    let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
    check(DesktopWidgetController.visibleOrigin(NSPoint(x: 900, y: 700), size: NSSize(width: 350, height: 170), screens: [screen]) == NSPoint(x: 650, y: 630), "clamp to visible screen")
    check(DesktopWidgetController.visibleOrigin(NSPoint(x: 2000, y: 900), size: NSSize(width: 350, height: 170), screens: [screen]) == NSPoint(x: 650, y: 630), "removed display recovery")
    let name = "dev.cadence.widget-selftest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let widget = DesktopWidgetController(defaults: defaults)
    check(!widget.enabled, "opt-in by default")
    defaults.set(true, forKey: "desktopWidgetEnabled")
    check(DesktopWidgetController(defaults: defaults).enabled, "choice survives controller recreation")
    widget.setEnabled(false)
    check(!DesktopWidgetController(defaults: defaults).enabled, "hide persists")
    if let outDir {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        for (name, sample) in [("ready", stats), ("empty", DesktopStats())] {
            let host = NSHostingView(rootView: DesktopTile(stats: sample, open: {}, hide: {}))
            host.frame = NSRect(x: 0, y: 0, width: 350, height: 170)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("widget-\(name).png"))
            }
        }
    }
    print("Desktop widget: \(count - failures)/\(count) checks passed")
    return failures == 0 ? 0 : 1
}
