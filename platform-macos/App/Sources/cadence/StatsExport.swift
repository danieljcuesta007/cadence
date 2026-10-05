// StatsExport — the dashboard's headline numbers, written to ~/.cadence/stats.json so other
// local tools (a personal command-center page, a script) can show "what is Cadence saving me"
// without the store key.
//
// Totals only, by design: no transcript text, no audio, no per-utterance rows. The encrypted
// store stays the only place dictations live; this file is safe to read from a plain web server.
// Same arithmetic as the dashboard (Stats.compute), so the two can never disagree.
//
// Rewritten after every persisted dictation, after a delete, and at launch. Best-effort: a
// failed write is logged and never touches dictation.

import Foundation

enum StatsExport {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cadence/stats.json")

    /// Bumped when a field changes meaning; readers should check it.
    static let schema = 1

    /// The JSON body, built from history rows. Pure, so `selftest-stats` can pin it.
    static func payload(_ entries: [HistoryEntry], now: Date = Date()) -> [String: Any] {
        let cal = Calendar.current
        let iso = ISO8601DateFormatter()
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"

        func block(_ range: Stats.Range) -> [String: Any] {
            let s = Stats.compute(entries, range: range)
            return [
                "time_saved_min": s.timeSavedMin,
                "words": s.words,
                "wpm": s.wpm,
                "top_apps": s.topApps.map { ["name": $0.name, "words": $0.words] },
            ]
        }

        let all = Stats.compute(entries, range: .all)
        let today = cal.startOfDay(for: now)
        let perDay: [[String: Any]] = all.perDay.enumerated().map { i, d in
            let date = cal.date(byAdding: .day, value: i - 6, to: today)!
            return ["date": dayFmt.string(from: date), "label": d.label, "words": d.words]
        }
        let real = entries.filter { !$0.isNonSpeech && $0.ts != nil }

        // Words per day over the last year (days with words only), for the Command Center's
        // contribution skyline. A sum per calendar day, so still totals only.
        let yearStart = cal.date(byAdding: .day, value: -370, to: today)!
        var byDay: [String: Int] = [:]
        for e in real where e.ts! >= yearStart { byDay[dayFmt.string(from: e.ts!), default: 0] += e.words }
        let year: [[String: Any]] = byDay.filter { $0.value > 0 }.sorted { $0.key < $1.key }
            .map { ["date": $0.key, "words": $0.value] }

        return [
            "schema": schema,
            "generated_at": iso.string(from: now),
            "last_dictation_at": real.compactMap(\.ts).max().map { iso.string(from: $0) } as Any,
            "dictations": real.count,
            "streak_days": all.streak,
            "words_today": all.wordsToday,
            "typing_wpm_assumed": 40,
            "today": block(.today),
            "week": block(.week),
            "all": block(.all),
            "per_day": perDay,
            "year": year,
        ]
    }

    /// Recompute from history and replace the file atomically.
    static func write() {
        let body = payload(HistoryReader.load())
        do {
            let data = try JSONSerialization.data(
                withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            LogFile.append("stats export failed: \(error.localizedDescription)")
        }
    }
}
