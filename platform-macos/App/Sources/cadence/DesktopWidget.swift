// A local, optional desktop tile. Ships inside Cadence; no server or extra app.
import AppKit
import SwiftUI

struct DesktopStats: Equatable {
    var words = 0
    var minutesSaved = 0
    var current = false
    var wordsWeek = 0
    var minutesWeek = 0
    var streak = 0
    var pace = 0
    var allWords = 0
    var days: [Int] = []
    var lastDictation: Date?

    static func read(_ data: Data?, now: Date = Date()) -> DesktopStats {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["schema"] as? Int == 1,
              let stamp = json["generated_at"] as? String,
              let date = ISO8601DateFormatter().date(from: stamp),
              Calendar.current.isDate(date, inSameDayAs: now), date <= now.addingTimeInterval(60),
              let today = json["today"] as? [String: Any],
              let words = today["words"] as? Int,
              let minutes = today["time_saved_min"] as? Int,
              words >= 0, minutes >= 0 else { return DesktopStats() }
        guard let week = json["week"] as? [String: Any],
              let all = json["all"] as? [String: Any],
              let wordsWeek = week["words"] as? Int,
              let minutesWeek = week["time_saved_min"] as? Int,
              let pace = week["wpm"] as? Int,
              let streak = json["streak_days"] as? Int,
              let allWords = all["words"] as? Int,
              let perDay = json["per_day"] as? [[String: Any]],
              [wordsWeek, minutesWeek, pace, streak, allWords].allSatisfy({ $0 >= 0 }) else { return DesktopStats() }
        let days = perDay.suffix(7).compactMap { $0["words"] as? Int }
        guard days.allSatisfy({ $0 >= 0 }) else { return DesktopStats() }
        return DesktopStats(words: words, minutesSaved: minutes, current: true,
                            wordsWeek: wordsWeek, minutesWeek: minutesWeek, streak: streak,
                            pace: pace, allWords: allWords, days: days,
                            lastDictation: (json["last_dictation_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
    }
}

private final class DesktopHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation, origin = window.frame.origin
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                         until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            let position = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: origin.x + position.x - mouse.x,
                                          y: origin.y + position.y - mouse.y))
        }
    }
}

private final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DesktopButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct DesktopAction: NSViewRepresentable {
    let title: String
    var symbol: String? = nil
    var transparent = false
    let action: () -> Void
    final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> DesktopButton {
        let button = DesktopButton(title: title, target: context.coordinator, action: #selector(Coordinator.invoke))
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.contentTintColor = .white
        button.setAccessibilityLabel(title)
        return button
    }
    func updateNSView(_ button: DesktopButton, context: Context) {
        context.coordinator.action = action
        button.title = transparent ? "" : title
        button.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
        button.imagePosition = symbol == nil ? .noImage : .imageOnly
        button.toolTip = title
    }
}

struct DesktopTile: View {
    let stats: DesktopStats
    let open: () -> Void
    let hide: () -> Void
    private let cobalt = Color(red: 36/255, green: 67/255, blue: 196/255)
    private let pink = Color(red: 242/255, green: 162/255, blue: 191/255)

    private func number(_ n: Int) -> String { stats.current ? n.formatted() : "—" }
    private func metric(_ label: String, _ value: Int, _ unit: String, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(stats.current && compact ? value.formatted(.number.notation(.compactName)) : number(value)).font(.system(size: 20, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text(unit).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                HStack(spacing: 1.5) {
                    ForEach(0..<5, id: \.self) { i in
                        Capsule().fill(i == 2 ? pink : cobalt)
                            .frame(width: 2.5, height: [5.9, 10.2, 13.1, 10.2, 5.9][i])
                    }
                }
                .frame(width: 22, height: 22)
                .overlay { DesktopAction(title: "Open Cadence", transparent: true, action: open) }
                .accessibilityLabel("Open Cadence")
                Text("Cadence").font(.system(size: 15, weight: .bold, design: .rounded))
                Text("DC Labs").font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.white.opacity(0.15), in: Capsule())
                Spacer(minLength: 0)
                if let last = stats.lastDictation {
                    Text(last, style: .relative).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                        .help("Time since last dictation")
                }
                DesktopAction(title: "Hide desktop widget", symbol: "xmark.circle", action: hide)
                    .frame(width: 15, height: 18)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Today").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    Text(number(stats.words)).font(.system(size: 32, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.5).lineLimit(1)
                    Text(stats.current ? "words · \(stats.minutesSaved) min saved" : "Dictate to update")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text("This week").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    Text(number(stats.wordsWeek)).font(.system(size: 32, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.5).lineLimit(1)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(Array(stats.days.enumerated()), id: \.offset) { i, words in
                            Capsule().fill(i == stats.days.count - 1 ? pink : .white.opacity(0.35))
                                .frame(width: 5, height: max(2, 14 * CGFloat(words) / CGFloat(max(stats.days.max() ?? 1, 1))))
                        }
                        Text("words").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
                    }.frame(height: 14)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 0) {
                metric("Streak", stats.streak, "days").frame(maxWidth: .infinity, alignment: .leading)
                metric("Pace", stats.pace, "wpm").frame(maxWidth: .infinity, alignment: .leading)
                metric("Saved", stats.minutesWeek, "min wk").frame(maxWidth: .infinity, alignment: .leading)
                metric("All time", stats.allWords, "words", compact: true).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16).frame(width: 350, height: 170)
        .foregroundStyle(.white)
        .background {
            ZStack(alignment: .trailing) {
                Color(red: 11/255, green: 11/255, blue: 12/255)
                HStack(spacing: 4) {
                    ForEach(0..<5, id: \.self) { i in
                        Capsule().fill(i == 2 ? pink.opacity(0.15) : cobalt.opacity(0.12))
                            .frame(width: 7, height: [42.0, 68, 100, 68, 42][i])
                    }
                }.padding(.trailing, 22)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.25), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}

final class DesktopWidgetController: NSObject, NSWindowDelegate {
    private let defaults: UserDefaults
    private var panel: DesktopPanel?
    private var timer: Timer?
    private var lastStats: DesktopStats?
    var onOpen: (() -> Void)?
    var enabled: Bool { defaults.bool(forKey: "desktopWidgetEnabled") }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(fitScreen),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }

    @objc private func fitScreen() {
        guard let panel else { return }
        panel.setFrameOrigin(Self.visibleOrigin(panel.frame.origin, size: panel.frame.size,
                                               screens: NSScreen.screens.map(\.visibleFrame)))
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "desktopWidgetEnabled")
        if enabled { show() } else {
            timer?.invalidate(); timer = nil
            panel?.orderOut(nil)
        }
    }

    func restore() { if enabled { show() } }

    private func show() {
        if panel == nil {
            let size = NSSize(width: 350, height: 170)
            let p = DesktopPanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isReleasedWhenClosed = false
            p.isOpaque = false; p.backgroundColor = .clear
            p.hasShadow = true; p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            p.setAccessibilityLabel("Cadence desktop widget")
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
            let origin = NSPoint(x: defaults.object(forKey: "desktopWidgetX") as? Double ?? screen.minX + 24,
                                 y: defaults.object(forKey: "desktopWidgetY") as? Double ?? screen.maxY - size.height - 24)
            p.setFrameOrigin(Self.visibleOrigin(origin, size: size, screens: NSScreen.screens.map(\.visibleFrame)))
            p.delegate = self
            panel = p
        }
        refresh(force: true)
        panel?.orderFrontRegardless()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        }
    }

    // Keep the tile reachable when an external display is removed.
    static func visibleOrigin(_ origin: NSPoint, size: NSSize, screens: [NSRect]) -> NSPoint {
        guard let screen = screens.first(where: { $0.contains(origin) }) ?? screens.first else { return origin }
        return NSPoint(x: max(screen.minX, min(origin.x, screen.maxX - size.width)),
                       y: max(screen.minY, min(origin.y, screen.maxY - size.height)))
    }

    private func refresh(force: Bool = false) {
        let stats = DesktopStats.read(try? Data(contentsOf: StatsExport.url))
        guard force || stats != lastStats else { return }
        lastStats = stats
        panel?.contentView = DesktopHostingView(rootView: DesktopTile(stats: stats,
            open: { [weak self] in self?.onOpen?() },
            hide: { [weak self] in self?.setEnabled(false) }))
    }

    func windowDidMove(_ notification: Notification) {
        guard let origin = panel?.frame.origin else { return }
        defaults.set(origin.x, forKey: "desktopWidgetX")
        defaults.set(origin.y, forKey: "desktopWidgetY")
    }
}
