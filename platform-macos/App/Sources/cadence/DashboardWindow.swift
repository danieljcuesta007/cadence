// DashboardWindow — history + metrics for the user (§ product surface, first slice).
//
// Reads ~/.cadence/history.jsonl (enriched with per-utterance timings by EffectRouter).
// Design: native system materials and text tokens only (label/secondaryLabel), stat tiles
// for the headline numbers, table for history — light/dark follow the system appearance.
// No color-coded series, no emoji (typographic marks only).

import AppKit

struct HistoryEntry {
    let ts: Date?
    let text: String
    let inserted: Bool
    let app: String
    let strategy: String
    let captureStartMs: Int?
    let captureWindowMs: Int?
    let insertionMs: Int?

    var words: Int { text.split(whereSeparator: \.isWhitespace).count }
}

enum HistoryReader {
    static func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: History.url),
            let content = String(data: data, encoding: .utf8)
        else { return [] }
        let iso = ISO8601DateFormatter()
        return content.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8),
                let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            else { return nil }
            return HistoryEntry(
                ts: (obj["ts"] as? String).flatMap { iso.date(from: $0) },
                text: obj["text"] as? String ?? "",
                inserted: obj["inserted"] as? Bool ?? false,
                app: obj["app"] as? String ?? "",
                strategy: obj["strategy"] as? String ?? "",
                captureStartMs: (obj["capture_start_ms"] as? NSNumber)?.intValue,
                captureWindowMs: (obj["capture_window_ms"] as? NSNumber)?.intValue,
                insertionMs: (obj["insertion_ms"] as? NSNumber)?.intValue)
        }.reversed()  // newest first
    }
}

final class DashboardWindowController: NSWindowController, NSTableViewDataSource,
    NSTableViewDelegate
{
    private var entries: [HistoryEntry] = []
    private let table = NSTableView()
    private var tiles: [(title: NSTextField, value: NSTextField)] = []
    private var reloadTimer: Timer?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Cadence"
        window.minSize = NSSize(width: 560, height: 320)
        self.init(window: window)
        buildUI()
        reload()
        window.center()
    }

    override func showWindow(_ sender: Any?) {
        reload()
        // Live while visible: a dictation done with the dashboard open shows up promptly.
        reloadTimer?.invalidate()
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
            [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.reload()
        }
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // KPI row: four stat tiles. Values wear primary ink, titles secondary — text
        // tokens only, identity never carried by color.
        let tileStack = NSStackView()
        tileStack.orientation = .horizontal
        tileStack.distribution = .fillEqually
        tileStack.spacing = 12
        for _ in 0..<4 {
            let value = NSTextField(labelWithString: "—")
            value.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
            value.textColor = .labelColor
            let title = NSTextField(labelWithString: "")
            title.font = .systemFont(ofSize: 11, weight: .medium)
            title.textColor = .secondaryLabelColor
            let box = NSStackView(views: [value, title])
            box.orientation = .vertical
            box.alignment = .leading
            box.spacing = 2
            let card = NSBox()
            card.boxType = .custom
            card.cornerRadius = 8
            card.borderColor = .separatorColor
            card.borderWidth = 1
            card.fillColor = .controlBackgroundColor
            card.contentViewMargins = NSSize(width: 14, height: 10)
            card.contentView = box
            tileStack.addArrangedSubview(card)
            tiles.append((title, value))
        }

        // History table.
        let cols: [(String, String, CGFloat)] = [
            ("time", "Time", 130), ("text", "Text", 260), ("app", "App", 90),
            ("capture", "Capture", 70), ("start", "Start", 60), ("insert", "Insert", 80),
        ]
        for (id, label, w) in cols {
            let c = NSTableColumn(identifier: .init(id))
            c.title = label
            c.width = w
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.rowHeight = 22

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let root = NSStackView(views: [tileStack, scroll])
        root.orientation = .vertical
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
    }

    private func reload() {
        entries = HistoryReader.load()
        let inserted = entries.filter(\.inserted)
        let words = inserted.reduce(0) { $0 + $1.words }
        let starts = entries.compactMap(\.captureStartMs)
        let inserts = entries.compactMap(\.insertionMs)
        func avg(_ xs: [Int]) -> String {
            xs.isEmpty ? "—" : "\(xs.reduce(0, +) / xs.count) ms"
        }
        let data: [(String, String)] = [
            ("\(entries.count)", "Dictations"),
            ("\(words)", "Words inserted"),
            (avg(starts), "Avg capture start"),
            (avg(inserts), "Avg insertion"),
        ]
        for (tile, d) in zip(tiles, data) {
            tile.value.stringValue = d.0
            tile.title.stringValue = d.1
        }
        table.reloadData()
    }

    // MARK: - table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm:ss"
        return f
    }()

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard row < entries.count, let col = tableColumn else { return nil }
        let e = entries[row]
        let text: String
        var secondary = false
        switch col.identifier.rawValue {
        case "time":
            text = e.ts.map { Self.timeFmt.string(from: $0) } ?? "—"
            secondary = true
        case "text":
            text = e.text
        case "app":
            text = e.app.isEmpty ? "—" : e.app
            secondary = true
        case "capture":
            text = e.captureWindowMs.map { String(format: "%.1f s", Double($0) / 1000) } ?? "—"
            secondary = true
        case "start":
            text = e.captureStartMs.map { "\($0) ms" } ?? "—"
            secondary = true
        case "insert":
            let strat = e.strategy.isEmpty ? "" : (e.strategy == "paste_restore"
                ? "paste" : e.strategy)
            let ms = e.insertionMs.map { " \($0) ms" } ?? ""
            text = e.inserted ? "\(strat)\(ms)" : "not inserted"
            secondary = true
        default:
            text = ""
        }
        let cellId = NSUserInterfaceItemIdentifier("cell-\(col.identifier.rawValue)")
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = cellId
            field.lineBreakMode = .byTruncatingTail
            field.font = .systemFont(ofSize: 12)
        }
        field.stringValue = text
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }
}
