// DashboardWindow — the product surface (§ F22). Answers "what is this saving me?" first,
// the way our inspiration (Wispr Flow) does: time saved, words, speaking pace, streak, a
// week of activity, and where you dictate — engine latency demoted to a footer.
//
// Data: the encrypted store (§24) when present, else the ~/.cadence/history.jsonl stand-in.
// Every headline number is computed here from the utterance rows (words from text, day from
// ts, pace from capture duration) — no aggregation lives in the core.
//
// Design: native system materials + SF Pro, one accent (BrandColor green), inset-grouped
// cards like Settings.app, a Health-style activity chart. No emoji, typographic marks only.

import AVFoundation
import AppKit

struct HistoryEntry {
    let id: String
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
    /// hears no words. They're not dictation — excluded from counts and shown muted.
    var isNonSpeech: Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("[") && t.hasSuffix("]")
    }

    var words: Int { isNonSpeech ? 0 : text.split(whereSeparator: \.isWhitespace).count }
}

enum HistoryReader {
    static var store: HistoryStore?

    static func load() -> [HistoryEntry] {
        if let store {
            return store.recent(limit: 1000).map(entry(from:))
        }
        guard let data = try? Data(contentsOf: History.url),
            let content = String(data: data, encoding: .utf8)
        else { return [] }
        return content.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8),
                let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            else { return nil }
            return entry(from: obj)
        }.reversed()
    }

    private static func entry(from obj: [String: Any]) -> HistoryEntry {
        let iso = ISO8601DateFormatter()
        return HistoryEntry(
            id: obj["utterance"] as? String ?? "",
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

// MARK: - Stats

/// Words-per-minute we assume a person types at; time saved is measured against it. 40 wpm is
/// a common average sustained typing speed — deliberately conservative so the number is honest.
private let typingWPM = 40.0

struct Stats {
    var timeSavedMin: Int          // over the selected range
    var timeSavedAllMin: Int       // all-time (hero context line)
    var words: Int                 // over the selected range
    var wordsToday: Int
    var wpm: Int                   // speaking pace over the range (0 = not enough data)
    var streak: Int                // consecutive days ending today/most-recent with a dictation
    var perDay: [(label: String, words: Int, isToday: Bool)]   // last 7 days
    var topApps: [(name: String, words: Int, frac: Double)]    // up to 5, frac of the top

    enum Range { case today, week, all }

    static func compute(_ entries: [HistoryEntry], range: Range) -> Stats {
        let cal = Calendar.current
        let now = Date()
        let real = entries.filter { !$0.isNonSpeech && $0.ts != nil }

        func inRange(_ e: HistoryEntry) -> Bool {
            guard let ts = e.ts else { return false }
            switch range {
            case .today: return cal.isDateInToday(ts)
            case .week: return ts >= now.addingTimeInterval(-7 * 86_400)
            case .all: return true
            }
        }
        let scoped = real.filter(inRange)

        func savedMinutes(_ es: [HistoryEntry]) -> Int {
            let words = es.reduce(0) { $0 + $1.words }
            // Actual dictation time from capture windows where we have them; estimate the rest
            // at a typical 130 wpm speaking pace so a missing metric never zeroes the saving.
            var speakMin = 0.0
            for e in es {
                if let ms = e.captureWindowMs { speakMin += Double(ms) / 60_000 }
                else { speakMin += Double(e.words) / 130 }
            }
            return max(0, Int((Double(words) / typingWPM - speakMin).rounded()))
        }

        let words = scoped.reduce(0) { $0 + $1.words }
        let wordsToday = real.filter { cal.isDateInToday($0.ts!) }.reduce(0) { $0 + $1.words }

        // Pace: words over measured dictation minutes (only rows with a capture window).
        let paced = scoped.filter { $0.captureWindowMs != nil }
        let pacedWords = paced.reduce(0) { $0 + $1.words }
        let pacedMin = paced.reduce(0.0) { $0 + Double($1.captureWindowMs!) / 60_000 }
        let wpm = pacedMin > 0.05 ? Int((Double(pacedWords) / pacedMin).rounded()) : 0

        // Streak: consecutive calendar days with ≥1 dictation, counting back from today.
        let days = Set(real.map { cal.startOfDay(for: $0.ts!) })
        var streak = 0
        var cursor = cal.startOfDay(for: now)
        // Grace: if nothing today yet, start the count from yesterday so an active streak holds.
        if !days.contains(cursor) { cursor = cal.date(byAdding: .day, value: -1, to: cursor)! }
        while days.contains(cursor) {
            streak += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }

        // Last 7 days for the chart.
        let dfDay = DateFormatter()
        dfDay.dateFormat = "EEE"
        var perDay: [(String, Int, Bool)] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            let day = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now))!
            let w = real.filter { cal.isDate($0.ts!, inSameDayAs: day) }.reduce(0) { $0 + $1.words }
            perDay.append((dfDay.string(from: day), w, offset == 0))
        }

        // Top apps over the range, by words.
        var byApp: [String: Int] = [:]
        for e in scoped where !e.app.isEmpty { byApp[e.app, default: 0] += e.words }
        let sorted = byApp.sorted { $0.value > $1.value }.prefix(5)
        let top = sorted.first?.value ?? 1
        let topApps = sorted.map {
            (name: $0.key, words: $0.value, frac: top > 0 ? Double($0.value) / Double(top) : 0)
        }

        return Stats(
            timeSavedMin: savedMinutes(scoped),
            timeSavedAllMin: savedMinutes(real),
            words: words, wordsToday: wordsToday, wpm: wpm, streak: streak,
            perDay: perDay, topApps: Array(topApps))
    }
}

// MARK: - Window

final class DashboardWindowController: NSWindowController {
    private var entries: [HistoryEntry] = []
    private var filtered: [HistoryEntry] = []
    private var range: Stats.Range = .week
    private var query = ""
    private var selectedTs: Date?
    private var reloadTimer: Timer?
    private var player: AVAudioPlayer?

    private let doc = NSStackView()
    private let searchField = NSSearchField()
    private var rowViews: [HistoryRowView] = []

    // Detail dock (pinned bottom).
    private let detailText = NSTextField(wrappingLabelWithString: "")
    private let detailMeta = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let playButton = NSButton()
    private let reinsertButton = NSButton()
    private let deleteButton = NSButton()

    /// Injected by the composition root: re-inserts text into the app that was frontmost before
    /// the dashboard came forward (focus handling lives there, not here). Nil = no re-insert.
    var onReinsert: ((String) -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Cadence"
        window.minSize = NSSize(width: 620, height: 520)
        self.init(window: window)
        buildChrome()
        reload()
        window.center()
    }

    override func showWindow(_ sender: Any?) {
        reload()
        reloadTimer?.invalidate()
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.reload()
        }
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: chrome (built once)

    private func buildChrome() {
        guard let content = window?.contentView else { return }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        doc.orientation = .vertical
        doc.alignment = .leading
        doc.spacing = 22
        doc.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 24, right: 24)
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc

        // Detail dock — always visible under the scroll.
        let dock = buildDetailDock()

        content.addSubview(scroll)
        content.addSubview(dock)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: dock.topAnchor),
            dock.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dock.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dock.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // Fill the width; only scroll vertically (width pinned to the clip view; height
            // grows with content because the bottom is intentionally left unconstrained).
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    private func buildDetailDock() -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let top = NSBox()
        top.boxType = .separator
        top.translatesAutoresizingMaskIntoConstraints = false

        detailText.font = .systemFont(ofSize: 13)
        detailText.textColor = .labelColor
        detailText.maximumNumberOfLines = 2
        detailText.stringValue = "Select a dictation to see the full transcript."
        detailMeta.font = .systemFont(ofSize: 11)
        detailMeta.textColor = .secondaryLabelColor
        detailMeta.lineBreakMode = .byTruncatingTail

        styleButton(copyButton, "Copy", primary: false, action: #selector(copySelected))
        styleButton(reinsertButton, "Re-insert", primary: false, action: #selector(reinsertSelected))
        styleButton(playButton, "Play Recording", primary: true, action: #selector(playSelected))
        styleButton(deleteButton, "Delete", primary: false, action: #selector(deleteSelected))
        deleteButton.contentTintColor = .systemRed
        copyButton.isEnabled = false
        reinsertButton.isEnabled = false
        playButton.isEnabled = false
        deleteButton.isEnabled = false

        let exportButton = NSButton()
        styleButton(exportButton, "Export All…", primary: false, action: #selector(exportAll))

        let actions = NSStackView(views: [
            copyButton, reinsertButton, playButton, NSView(), deleteButton, exportButton,
        ])
        actions.orientation = .horizontal
        actions.spacing = 8

        let stack = NSStackView(views: [detailText, detailMeta, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(top)
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: box.topAnchor),
            top.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),
            actions.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        return box
    }

    private func styleButton(_ b: NSButton, _ title: String, primary: Bool, action: Selector) {
        b.title = title
        b.bezelStyle = .rounded
        b.target = self
        b.action = action
        if primary {
            b.bezelColor = BrandColor.green
            b.contentTintColor = .white
        }
    }

    // MARK: reload → rebuild the document stack

    private func reload() {
        entries = HistoryReader.load()
        applyFilter()

        doc.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let stats = Stats.compute(entries, range: range)

        doc.addArrangedSubview(makeHeader())
        doc.addArrangedSubview(makeHero(stats))
        doc.addArrangedSubview(makeHighlights(stats))
        doc.addArrangedSubview(makeSection("Activity this week", makeChart(stats)))
        if !stats.topApps.isEmpty {
            doc.addArrangedSubview(makeSection("Where you dictate", makeApps(stats)))
        }
        doc.addArrangedSubview(makeHistorySection())
        // Full-width children.
        for v in doc.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -48).isActive = true
        }
        updateDetail()
    }

    private func applyFilter() {
        if query.isEmpty {
            filtered = entries
        } else {
            let q = query.lowercased()
            filtered = entries.filter {
                $0.text.lowercased().contains(q) || $0.app.lowercased().contains(q)
            }
        }
    }

    // MARK: header + segmented range

    private func makeHeader() -> NSView {
        let title = NSTextField(labelWithString: "Your dictation")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d"
        let sub = NSTextField(labelWithString: "\(df.string(from: Date())) · everything stays on this Mac")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .tertiaryLabelColor
        let left = NSStackView(views: [title, sub])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 2

        let seg = NSSegmentedControl(
            labels: ["Today", "This Week", "All Time"], trackingMode: .selectOne,
            target: self, action: #selector(rangeChanged(_:)))
        seg.selectedSegment = [.today: 0, .week: 1, .all: 2][range] ?? 1
        seg.segmentStyle = .rounded

        let row = NSStackView(views: [left, NSView(), seg])
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }

    @objc private func rangeChanged(_ sender: NSSegmentedControl) {
        range = [0: .today, 1: .week, 2: .all][sender.selectedSegment] ?? .week
        reload()
    }

    // MARK: hero — time saved

    private func makeHero(_ s: Stats) -> NSView {
        let card = roundedCard(fill: BrandColor.greenWash, border: BrandColor.greenSoft)

        let label = tag("TIME SAVED", color: BrandColor.greenStrong)
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = BrandColor.green.cgColor
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        let labelRow = NSStackView(views: [dot, label])
        labelRow.orientation = .horizontal
        labelRow.spacing = 6
        labelRow.alignment = .centerY

        let (h, m) = (s.timeSavedMin / 60, s.timeSavedMin % 60)
        let big = bigNumber(h > 0 ? "\(h)" : "\(m)", unit: h > 0 ? "hr" : "min")
        let left = NSStackView(views: [labelRow, big])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 8

        let (ah, am) = (s.timeSavedAllMin / 60, s.timeSavedAllMin % 60)
        let allStr = ah > 0 ? "\(ah) hr \(am) min" : "\(am) min"
        let ctx = NSTextField(wrappingLabelWithString: "")
        ctx.attributedStringValue = context(
            "Versus typing at 40 wpm.\n", bold: allStr, tail: " saved all time.")
        ctx.font = .systemFont(ofSize: 12)
        ctx.textColor = .secondaryLabelColor
        ctx.alignment = .right
        ctx.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [left, NSView(), ctx])
        row.orientation = .horizontal
        row.alignment = .centerY
        embed(row, in: card, inset: 20)
        return card
    }

    // MARK: three highlight cards

    private func makeHighlights(_ s: Stats) -> NSView {
        let cards = [
            statCard("WORDS DICTATED", "\(s.words.formatted())", nil,
                note: s.wordsToday > 0 ? "+\(s.wordsToday) today" : "in range", noteBold: true),
            statCard("SPEAKING PACE", s.wpm > 0 ? "\(s.wpm)" : "—", s.wpm > 0 ? "wpm" : nil,
                note: s.wpm > 0 ? String(format: "%.1f× faster than typing", Double(s.wpm) / typingWPM) : "no timing yet",
                noteBold: false),
            statCard("DAY STREAK", "\(s.streak)", s.streak == 1 ? "day" : "days",
                note: s.streak > 0 ? "keep it going" : "start today", noteBold: false),
        ]
        let row = NSStackView(views: cards)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 12
        return row
    }

    private func statCard(_ label: String, _ value: String, _ unit: String?, note: String, noteBold: Bool) -> NSView {
        let card = roundedCard(fill: .controlBackgroundColor, border: .separatorColor)
        let l = tag(label, color: .tertiaryLabelColor)
        let v = bigNumber(value, unit: unit, size: 30)
        let n = NSTextField(labelWithString: note)
        n.font = .systemFont(ofSize: 11)
        n.textColor = noteBold ? BrandColor.greenStrong : .tertiaryLabelColor
        if noteBold { n.font = .systemFont(ofSize: 11, weight: .semibold) }
        let stack = NSStackView(views: [l, v, n])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        embed(stack, in: card, inset: 16)
        return card
    }

    // MARK: activity chart

    private func makeChart(_ s: Stats) -> NSView {
        let maxW = max(1, s.perDay.map(\.words).max() ?? 1)
        let cols = s.perDay.map { day -> NSView in
            let frac = CGFloat(day.words) / CGFloat(maxW)
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.backgroundColor = (day.isToday ? BrandColor.green : BrandColor.greenSoft).cgColor
            bar.layer?.cornerRadius = 5
            bar.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 26).isActive = true
            bar.heightAnchor.constraint(equalToConstant: max(4, frac * 96)).isActive = true

            let cap = NSTextField(labelWithString: day.words > 0 ? "\(day.words)" : "")
            cap.font = .systemFont(ofSize: 10, weight: .semibold)
            cap.textColor = .secondaryLabelColor
            let name = NSTextField(labelWithString: day.label)
            name.font = .systemFont(ofSize: 11, weight: day.isToday ? .bold : .medium)
            name.textColor = day.isToday ? BrandColor.greenStrong : .tertiaryLabelColor

            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
            let col = NSStackView(views: [cap, spacer, bar, name])
            col.orientation = .vertical
            col.alignment = .centerX
            col.spacing = 6
            col.setHuggingPriority(.defaultLow, for: .horizontal)
            return col
        }
        let chart = NSStackView(views: cols)
        chart.orientation = .horizontal
        chart.distribution = .fillEqually
        chart.alignment = .bottom
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 132).isActive = true

        let card = roundedCard(fill: .controlBackgroundColor, border: .separatorColor)
        embed(chart, in: card, inset: 18)
        return card
    }

    // MARK: top apps

    private func makeApps(_ s: Stats) -> NSView {
        let total = max(1, s.topApps.reduce(0) { $0 + $1.words })
        let rows = s.topApps.map { app -> NSView in
            let name = NSTextField(labelWithString: app.name)
            name.font = .systemFont(ofSize: 13, weight: .medium)
            name.translatesAutoresizingMaskIntoConstraints = false
            name.widthAnchor.constraint(equalToConstant: 92).isActive = true

            let track = NSView()
            track.wantsLayer = true
            track.layer?.backgroundColor = NSColor.separatorColor.cgColor
            track.layer?.cornerRadius = 4
            track.translatesAutoresizingMaskIntoConstraints = false
            track.heightAnchor.constraint(equalToConstant: 8).isActive = true

            let fill = NSView()
            fill.wantsLayer = true
            fill.layer?.backgroundColor = BrandColor.green.cgColor
            fill.layer?.cornerRadius = 4
            fill.translatesAutoresizingMaskIntoConstraints = false
            track.addSubview(fill)
            NSLayoutConstraint.activate([
                fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
                fill.topAnchor.constraint(equalTo: track.topAnchor),
                fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
                fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: max(0.03, CGFloat(app.frac))),
            ])

            let pct = NSTextField(labelWithString: "\(Int((Double(app.words) / Double(total) * 100).rounded()))%")
            pct.font = .systemFont(ofSize: 12)
            pct.textColor = .tertiaryLabelColor
            pct.alignment = .right
            pct.translatesAutoresizingMaskIntoConstraints = false
            pct.widthAnchor.constraint(equalToConstant: 42).isActive = true

            let row = NSStackView(views: [name, track, pct])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            return row
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        for r in rows { r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        let card = roundedCard(fill: .controlBackgroundColor, border: .separatorColor)
        embed(stack, in: card, inset: 18)
        return card
    }

    // MARK: history

    private func makeHistorySection() -> NSView {
        let header = NSTextField(labelWithString: "Recent dictations")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .secondaryLabelColor

        searchField.placeholderString = "Search transcripts or apps"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = false
        (searchField.cell as? NSSearchFieldCell)?.sendsActionOnEndEditing = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let card = roundedCard(fill: .controlBackgroundColor, border: .separatorColor)
        rowViews = []
        let shown = Array(filtered.prefix(60))
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        if shown.isEmpty {
            let empty = NSTextField(labelWithString: query.isEmpty ? "No dictations yet." : "No matches.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .tertiaryLabelColor
            list.addArrangedSubview(empty)
        }
        for (i, e) in shown.enumerated() {
            let rv = HistoryRowView(entry: e) { [weak self] in self?.select(e) }
            rv.isSelected = (e.ts != nil && e.ts == selectedTs)
            rowViews.append(rv)
            list.addArrangedSubview(rv)
            rv.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            if i < shown.count - 1 {
                let sep = NSBox()
                sep.boxType = .separator
                list.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
        }
        embed(list, in: card, inset: 8)

        let section = NSStackView(views: [header, searchField, card])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        searchField.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        card.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    @objc private func searchChanged() {
        query = searchField.stringValue
        applyFilter()
        reload()
    }

    private func select(_ e: HistoryEntry) {
        selectedTs = e.ts
        for rv in rowViews { rv.isSelected = (rv.entry.ts != nil && rv.entry.ts == selectedTs) }
        updateDetail()
    }

    // MARK: detail dock

    private func selectedEntry() -> HistoryEntry? {
        guard let ts = selectedTs else { return nil }
        return entries.first { $0.ts == ts }
    }

    private func updateDetail() {
        player?.stop(); player = nil
        guard let e = selectedEntry() else {
            detailText.stringValue = "Select a dictation to see the full transcript."
            detailText.textColor = .secondaryLabelColor
            detailMeta.stringValue = ""
            copyButton.isEnabled = false
            reinsertButton.isEnabled = false
            playButton.isEnabled = false
            deleteButton.isEnabled = false
            playButton.title = "Play Recording"
            return
        }
        detailText.stringValue = e.isNonSpeech ? "No speech detected" : e.text
        detailText.textColor = e.isNonSpeech ? .secondaryLabelColor : .labelColor

        var bits: [String] = []
        if let ts = e.ts { bits.append(Self.detailTimeFmt.string(from: ts)) }
        if !e.app.isEmpty { bits.append(e.app) }
        bits.append(Self.languageName(e.language))
        bits.append((e.location ?? "local") == "cloud" ? "cloud" : "on-device")
        if let w = e.captureWindowMs { bits.append(String(format: "%.1fs audio", Double(w) / 1000)) }
        if e.inserted, let i = e.insertionMs {
            bits.append("inserted via \(e.strategy == "paste_restore" ? "paste" : e.strategy) · \(i) ms")
        } else if !e.inserted {
            bits.append("not inserted")
        }
        detailMeta.stringValue = bits.joined(separator: "  ·  ")

        let hasText = !e.text.isEmpty && !e.isNonSpeech
        copyButton.isEnabled = hasText
        reinsertButton.isEnabled = hasText && onReinsert != nil
        deleteButton.isEnabled = !e.id.isEmpty && HistoryReader.store != nil
        let hasAudio = e.audioBlobId != nil && HistoryReader.store != nil
        playButton.isEnabled = hasAudio
        playButton.title = hasAudio ? "Play Recording" : "No Recording"
    }

    @objc private func copySelected() {
        guard let e = selectedEntry() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(e.text, forType: .string)
    }

    @objc private func reinsertSelected() {
        guard let e = selectedEntry(), !e.text.isEmpty, !e.isNonSpeech else { return }
        onReinsert?(e.text)
    }

    @objc private func deleteSelected() {
        guard let e = selectedEntry(), !e.id.isEmpty, let store = HistoryReader.store else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this dictation?"
        alert.informativeText = "“\(e.text.prefix(80))”\n\nThis also removes its recording, if any. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.deleteUtterance(id: e.id)
        selectedTs = nil
        reload()
    }

    @objc private func playSelected() {
        guard let e = selectedEntry(), let id = e.audioBlobId,
            let store = HistoryReader.store, let data = store.audioBlob(id: id)
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
                return "\(ts)\t\(e.app.isEmpty ? "—" : e.app)\t\(e.text)"
            }
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: small builders

    private func roundedCard(fill: NSColor, border: NSColor) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = fill.cgColor
        v.layer?.borderColor = border.cgColor
        v.layer?.borderWidth = 1
        v.layer?.cornerRadius = 14
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    private func embed(_ child: NSView, in card: NSView, inset: CGFloat) {
        child.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
        ])
    }

    private func tag(_ text: String, color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 11, weight: .semibold)
        f.textColor = color
        return f
    }

    private func bigNumber(_ value: String, unit: String?, size: CGFloat = 52) -> NSView {
        let v = NSTextField(labelWithString: value)
        v.font = .systemFont(ofSize: size, weight: .bold)
        v.textColor = .labelColor
        let views: [NSView]
        if let unit {
            let u = NSTextField(labelWithString: unit)
            u.font = .systemFont(ofSize: size * 0.46, weight: .semibold)
            u.textColor = .secondaryLabelColor
            views = [v, u]
        } else {
            views = [v]
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .lastBaseline
        row.spacing = 4
        return row
    }

    private func context(_ head: String, bold: String, tail: String) -> NSAttributedString {
        let s = NSMutableAttributedString(
            string: head,
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)])
        s.append(NSAttributedString(
            string: bold,
            attributes: [.foregroundColor: BrandColor.greenStrong, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)]))
        s.append(NSAttributedString(
            string: tail,
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]))
        return s
    }

    private func makeSection(_ title: String, _ body: NSView) -> NSView {
        let h = NSTextField(labelWithString: title)
        h.font = .systemFont(ofSize: 13, weight: .semibold)
        h.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [h, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

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
}

// MARK: - History row

final class HistoryRowView: NSView {
    let entry: HistoryEntry
    private let onClick: () -> Void
    private let bg = CALayer()

    var isSelected = false { didSet { updateBG() } }
    private var hovering = false { didSet { updateBG() } }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, HH:mm"; return f
    }()

    init(entry: HistoryEntry, onClick: @escaping () -> Void) {
        self.entry = entry
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        bg.cornerRadius = 7
        layer?.addSublayer(bg)
        build()
        heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let time = NSTextField(labelWithString: entry.ts.map { Self.timeFmt.string(from: $0) } ?? "—")
        time.font = .systemFont(ofSize: 12)
        time.textColor = .tertiaryLabelColor
        time.translatesAutoresizingMaskIntoConstraints = false
        time.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let audio = NSTextField(labelWithString: entry.audioBlobId != nil ? "♪" : "")
        audio.font = .systemFont(ofSize: 12)
        audio.textColor = BrandColor.green
        audio.translatesAutoresizingMaskIntoConstraints = false
        audio.widthAnchor.constraint(equalToConstant: 12).isActive = true

        let txt = NSTextField(labelWithString: entry.isNonSpeech ? "No speech detected" : entry.text)
        txt.font = .systemFont(ofSize: 13)
        txt.textColor = entry.isNonSpeech ? .tertiaryLabelColor : .labelColor
        txt.lineBreakMode = .byTruncatingTail
        txt.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pill = PillView(
            text: (entry.language ?? "").uppercased().isEmpty ? "" : (entry.language ?? "").uppercased(),
            language: entry.language)

        let app = NSTextField(labelWithString: entry.app.isEmpty ? "" : entry.app)
        app.font = .systemFont(ofSize: 12)
        app.textColor = .tertiaryLabelColor
        app.alignment = .right
        app.translatesAutoresizingMaskIntoConstraints = false
        app.widthAnchor.constraint(equalToConstant: 78).isActive = true

        let row = NSStackView(views: [time, audio, txt, pill, app])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    override func layout() {
        super.layout()
        bg.frame = bounds.insetBy(dx: 2, dy: 1)
    }

    private func updateBG() {
        bg.backgroundColor = isSelected
            ? BrandColor.green.withAlphaComponent(0.16).cgColor
            : (hovering ? NSColor.separatorColor.withAlphaComponent(0.4).cgColor : NSColor.clear.cgColor)
    }

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick() }
}

/// Small language chip. Non-English wears the brand tint; English stays neutral.
final class PillView: NSView {
    init(text: String, language: String?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        guard !text.isEmpty else {
            widthAnchor.constraint(equalToConstant: 0).isActive = true
            return
        }
        wantsLayer = true
        let isEN = language == "en"
        layer?.cornerRadius = 8
        layer?.backgroundColor = (isEN ? NSColor.separatorColor.withAlphaComponent(0.5)
            : BrandColor.greenWash).cgColor
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = isEN ? .secondaryLabelColor : BrandColor.greenStrong
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            l.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            l.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            l.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
