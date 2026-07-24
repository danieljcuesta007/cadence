// DashboardWindow — history + metrics for the user (§ product surface, F22).
//
// Reads the encrypted store (§24) when present, else the ~/.cadence/history.jsonl stand-in.
// Layout: a fixed-height KPI band up top (headline numbers), a search field, a history table,
// and a detail pane that shows the full transcript + metadata for the selected row and plays
// back the retained recording (§24 audio blobs) when one exists.
//
// Design: native system materials and text tokens only (label/secondaryLabel), stat tiles for
// the headline numbers, table for history — light/dark follow the system appearance. No
// color-coded series, no emoji (typographic marks only).

import AVFoundation
import AppKit

struct HistoryEntry {
    let ts: Date?
    let text: String
    let inserted: Bool
    let app: String
    let strategy: String
    let language: String?
    let location: String?
    let audioBlobId: String?
    let captureStartMs: Int?
    let captureWindowMs: Int?
    let insertionMs: Int?

    /// Whisper emits bracketed non-speech markers ([BLANK_AUDIO], [MUSIC], [SILENCE]…) when it
    /// hears no words. They're not dictation — excluded from word counts and shown muted.
    var isNonSpeech: Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("[") && t.hasSuffix("]")
    }

    var words: Int {
        isNonSpeech ? 0 : text.split(whereSeparator: \.isWhitespace).count
    }
}

enum HistoryReader {
    /// Wired by the composition root; when present the dashboard reads the encrypted
    /// store (§24), else the JSONL stand-in.
    static var store: HistoryStore?

    static func load() -> [HistoryEntry] {
        if let store {
            return store.recent(limit: 500).map(entry(from:))
        }
        guard let data = try? Data(contentsOf: History.url),
            let content = String(data: data, encoding: .utf8)
        else { return [] }
        return content.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8),
                let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            else { return nil }
            return entry(from: obj)
        }.reversed()  // newest first (store rows already arrive newest-first)
    }

    private static func entry(from obj: [String: Any]) -> HistoryEntry {
        let iso = ISO8601DateFormatter()
        return HistoryEntry(
            ts: (obj["ts"] as? String).flatMap { iso.date(from: $0) },
            text: obj["text"] as? String ?? "",
            inserted: obj["inserted"] as? Bool ?? false,
            app: obj["app"] as? String ?? "",
            strategy: obj["strategy"] as? String ?? "",
            language: obj["language"] as? String,
            location: obj["location"] as? String,
            audioBlobId: obj["audio_blob_id"] as? String,
            captureStartMs: (obj["capture_start_ms"] as? NSNumber)?.intValue,
            captureWindowMs: (obj["capture_window_ms"] as? NSNumber)?.intValue,
            insertionMs: (obj["insertion_ms"] as? NSNumber)?.intValue)
    }
}

final class DashboardWindowController: NSWindowController, NSTableViewDataSource,
    NSTableViewDelegate, NSSearchFieldDelegate
{
    private var entries: [HistoryEntry] = []       // full set, newest-first
    private var filtered: [HistoryEntry] = []       // after the search filter
    private let table = NSTableView()
    private let searchField = NSSearchField()
    private var tiles: [(title: NSTextField, value: NSTextField)] = []
    private var reloadTimer: Timer?
    private var query = ""

    // Detail pane.
    private let detailText = NSTextField(wrappingLabelWithString: "")
    private let detailMeta = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let playButton = NSButton()
    private var player: AVAudioPlayer?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Cadence"
        window.minSize = NSSize(width: 640, height: 400)
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

        // KPI row: four stat tiles. Values wear primary ink, titles secondary — text tokens
        // only, identity never carried by color. A fixed height keeps the 24pt digits from
        // being vertically clipped when the window is short (the old bug).
        let tileStack = NSStackView()
        tileStack.orientation = .horizontal
        tileStack.distribution = .fillEqually
        tileStack.spacing = 12
        for _ in 0..<4 {
            let value = NSTextField(labelWithString: "—")
            value.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
            value.textColor = .labelColor
            value.lineBreakMode = .byClipping
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
        tileStack.setContentHuggingPriority(.required, for: .vertical)

        // Search.
        searchField.placeholderString = "Search transcripts or apps"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false

        // History table.
        let cols: [(String, String, CGFloat)] = [
            ("time", "Time", 130), ("text", "Text", 300), ("app", "App", 90),
            ("lang", "Lang", 48), ("capture", "Length", 64), ("insert", "Insertion", 90),
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
        table.target = self
        table.doubleAction = #selector(playSelectedAudio)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        // Detail pane: full (untruncated) transcript, metadata line, and per-row actions.
        detailText.font = .systemFont(ofSize: 13)
        detailText.textColor = .labelColor
        detailText.stringValue = "Select a dictation to see the full transcript."
        detailText.maximumNumberOfLines = 6
        detailMeta.font = .systemFont(ofSize: 11)
        detailMeta.textColor = .secondaryLabelColor
        detailMeta.stringValue = ""

        copyButton.title = "Copy"
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copySelected)
        copyButton.isEnabled = false

        playButton.title = "Play Recording"
        playButton.bezelStyle = .rounded
        playButton.target = self
        playButton.action = #selector(playSelectedAudio)
        playButton.isEnabled = false

        let exportButton = NSButton()
        exportButton.title = "Export All…"
        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(exportAll)

        let buttonRow = NSStackView(views: [copyButton, playButton, NSView(), exportButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let detailBox = NSBox()
        detailBox.boxType = .custom
        detailBox.cornerRadius = 8
        detailBox.borderColor = .separatorColor
        detailBox.borderWidth = 1
        detailBox.fillColor = .controlBackgroundColor
        detailBox.contentViewMargins = NSSize(width: 14, height: 12)
        let detailStack = NSStackView(views: [detailText, detailMeta, buttonRow])
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 8
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailBox.contentView = detailStack
        NSLayoutConstraint.activate([
            detailStack.leadingAnchor.constraint(equalTo: detailBox.leadingAnchor, constant: 14),
            detailStack.trailingAnchor.constraint(equalTo: detailBox.trailingAnchor, constant: -14),
            detailStack.topAnchor.constraint(equalTo: detailBox.topAnchor, constant: 12),
            buttonRow.leadingAnchor.constraint(equalTo: detailStack.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: detailStack.trailingAnchor),
        ])

        let root = NSStackView(views: [tileStack, searchField, scroll, detailBox])
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
            // Fixed KPI band: the tiles never get squeezed into the digits (the clip bug).
            tileStack.heightAnchor.constraint(equalToConstant: 56),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    private func reload() {
        let selectedTs = table.selectedRow >= 0 && table.selectedRow < filtered.count
            ? filtered[table.selectedRow].ts : nil
        entries = HistoryReader.load()
        applyFilter(preservingTs: selectedTs)

        // Headline numbers over the whole set (not just the filtered view).
        let realDictations = entries.filter { !$0.isNonSpeech }
        let inserted = entries.filter(\.inserted)
        let words = inserted.reduce(0) { $0 + $1.words }
        let starts = entries.compactMap(\.captureStartMs)
        let inserts = entries.compactMap(\.insertionMs)
        func avg(_ xs: [Int]) -> String {
            xs.isEmpty ? "—" : "\(xs.reduce(0, +) / xs.count) ms"
        }
        let data: [(String, String)] = [
            ("\(realDictations.count)", "Dictations"),
            ("\(words)", "Words inserted"),
            (avg(starts), "Avg capture start"),
            (avg(inserts), "Avg insertion"),
        ]
        for (tile, d) in zip(tiles, data) {
            tile.value.stringValue = d.0
            tile.title.stringValue = d.1
        }
    }

    private func applyFilter(preservingTs: Date?) {
        if query.isEmpty {
            filtered = entries
        } else {
            let q = query.lowercased()
            filtered = entries.filter {
                $0.text.lowercased().contains(q) || $0.app.lowercased().contains(q)
            }
        }
        table.reloadData()
        // Keep the selection on the same utterance across live reloads / filtering.
        if let ts = preservingTs, let idx = filtered.firstIndex(where: { $0.ts == ts }) {
            table.selectRowIndexes([idx], byExtendingSelection: false)
        } else {
            updateDetail(for: table.selectedRow)
        }
    }

    // MARK: - search

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        query = searchField.stringValue
        applyFilter(preservingTs: nil)
    }

    // MARK: - detail pane

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail(for: table.selectedRow)
    }

    private func updateDetail(for row: Int) {
        player?.stop()
        player = nil
        guard row >= 0, row < filtered.count else {
            detailText.stringValue = "Select a dictation to see the full transcript."
            detailMeta.stringValue = ""
            copyButton.isEnabled = false
            playButton.isEnabled = false
            return
        }
        let e = filtered[row]
        detailText.stringValue = e.text.isEmpty ? "—" : e.text
        detailText.textColor = e.isNonSpeech ? .secondaryLabelColor : .labelColor

        var bits: [String] = []
        if let ts = e.ts { bits.append(Self.detailTimeFmt.string(from: ts)) }
        if !e.app.isEmpty { bits.append(e.app) }
        bits.append(Self.languageName(e.language))
        bits.append((e.location ?? "local") == "cloud" ? "cloud" : "on-device")
        if let w = e.captureWindowMs { bits.append(String(format: "%.1fs audio", Double(w) / 1000)) }
        if let s = e.captureStartMs { bits.append("start \(s) ms") }
        if e.inserted, let i = e.insertionMs {
            let strat = e.strategy == "paste_restore" ? "paste" : e.strategy
            bits.append("inserted via \(strat) in \(i) ms")
        } else if !e.inserted {
            bits.append("not inserted")
        }
        detailMeta.stringValue = bits.joined(separator: "  ·  ")

        copyButton.isEnabled = !e.text.isEmpty && !e.isNonSpeech
        let hasAudio = (e.audioBlobId != nil) && (HistoryReader.store != nil)
        playButton.isEnabled = hasAudio
        playButton.title = hasAudio ? "Play Recording" : "No Recording"
    }

    @objc private func copySelected() {
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(filtered[row].text, forType: .string)
    }

    @objc private func playSelectedAudio() {
        let row = table.selectedRow
        guard row >= 0, row < filtered.count,
            let id = filtered[row].audioBlobId, let store = HistoryReader.store,
            let data = store.audioBlob(id: id)
        else { return }
        do {
            let p = try AVAudioPlayer(data: data)
            player = p
            p.play()
        } catch {
            LogFile.append("dashboard audio playback failed: \(error)")
        }
    }

    @objc private func exportAll() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "cadence-history.txt"
        panel.allowedContentTypes = [.plainText]
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            let lines = self.entries.map { e -> String in
                let ts = e.ts.map { Self.detailTimeFmt.string(from: $0) } ?? "—"
                let app = e.app.isEmpty ? "—" : e.app
                return "\(ts)\t\(app)\t\(e.text)"
            }
            let doc = lines.joined(separator: "\n") + "\n"
            do {
                try doc.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                LogFile.append("history export failed: \(error)")
            }
        }
    }

    // MARK: - table

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm:ss"
        return f
    }()

    private static let detailTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy 'at' HH:mm:ss"
        return f
    }()

    private static func languageName(_ code: String?) -> String {
        switch code {
        case "en": return "English"
        case "es": return "Spanish"
        case nil, "": return "auto"
        case let other?: return other
        }
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard row < filtered.count, let col = tableColumn else { return nil }
        let e = filtered[row]
        let text: String
        var secondary = false
        switch col.identifier.rawValue {
        case "time":
            text = e.ts.map { Self.timeFmt.string(from: $0) } ?? "—"
            secondary = true
        case "text":
            // A small speaker mark flags rows with a retained recording (§24).
            let mark = (e.audioBlobId != nil) ? "♪ " : ""
            text = mark + e.text
            secondary = e.isNonSpeech
        case "app":
            text = e.app.isEmpty ? "—" : e.app
            secondary = true
        case "lang":
            let c = (e.language?.isEmpty == false) ? e.language! : "—"
            text = c == "—" ? "—" : c.uppercased()
            secondary = true
        case "capture":
            text = e.captureWindowMs.map { String(format: "%.1f s", Double($0) / 1000) } ?? "—"
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
