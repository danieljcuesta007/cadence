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

/// One day rebuilt from the log for history whose store key was lost (tools/recover_from_log.py
/// writes ~/.cadence/recovered.json). Counts and speaking time are exact; words are estimated
/// at the dashboard's 130 wpm speaking pace, and stats.json says so under "recovered".
struct RecoveredDay {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cadence/recovered.json")
    static let speakingWPM = 130.0

    var date: String          // yyyy-MM-dd, local
    var dictations: Int
    var speechSec: Double
    var estimatedWords: Int { Int((speechSec / 60 * Self.speakingWPM).rounded()) }

    static func load() -> [RecoveredDay] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let days = obj["days"] as? [[String: Any]] else { return [] }
        return days.compactMap { d in
            guard let date = d["date"] as? String, let n = d["dictations"] as? Int,
                  let sec = (d["speech_sec"] as? NSNumber)?.doubleValue else { return nil }
            return RecoveredDay(date: date, dictations: n, speechSec: sec)
        }
    }
}

enum StatsExport {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cadence/stats.json")

    /// Bumped when a field changes meaning; readers should check it.
    static let schema = 1

    /// The JSON body, built from history rows. Pure, so `selftest-stats` can pin it.
    static func payload(_ entries: [HistoryEntry], now: Date = Date(),
                        recovered: [RecoveredDay] = []) -> [String: Any] {
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

        // Fold recovered days in (estimated words, exact counts), so totals don't read as zero
        // after a lost key. Every touched figure is listed under "recovered" for labelling.
        var out: [String: Any] = [:]
        var allB = block(.all), weekB = block(.week), todayB = block(.today)
        var perDayOut = perDay, yearOut = year
        var streak = all.streak, wordsToday = all.wordsToday
        if !recovered.isEmpty {
            let todayKey = dayFmt.string(from: today)
            let weekFloor = dayFmt.string(from: now.addingTimeInterval(-7 * 86_400))
            func add(_ b: inout [String: Any], _ days: [RecoveredDay]) {
                let w = days.reduce(0) { $0 + $1.estimatedWords }
                let speakMin = days.reduce(0.0) { $0 + $1.speechSec } / 60
                b["words"] = (b["words"] as? Int ?? 0) + w
                b["time_saved_min"] = (b["time_saved_min"] as? Int ?? 0)
                    + max(0, Int((Double(w) / 40 - speakMin).rounded()))
            }
            add(&allB, recovered)
            add(&weekB, recovered.filter { $0.date > weekFloor })   // 7 calendar days incl. today
            add(&todayB, recovered.filter { $0.date == todayKey })
            wordsToday += recovered.filter { $0.date == todayKey }.reduce(0) { $0 + $1.estimatedWords }
            let rw = Dictionary(recovered.map { ($0.date, $0.estimatedWords) }, uniquingKeysWith: +)
            perDayOut = perDay.map { d in
                var d = d
                d["words"] = (d["words"] as? Int ?? 0) + (rw[d["date"] as? String ?? ""] ?? 0)
                return d
            }
            var merged = byDay
            let yearFloor = dayFmt.string(from: yearStart)
            for (k, v) in rw where k >= yearFloor { merged[k, default: 0] += v }
            yearOut = merged.filter { $0.value > 0 }.sorted { $0.key < $1.key }
                .map { ["date": $0.key, "words": $0.value] }
            // Same streak rule as Stats.compute, over both sources.
            var days = Set(real.map { dayFmt.string(from: $0.ts!) })
            days.formUnion(recovered.filter { $0.dictations > 0 }.map(\.date))
            streak = 0
            var cursor = today
            if !days.contains(dayFmt.string(from: cursor)) { cursor = cal.date(byAdding: .day, value: -1, to: cursor)! }
            while days.contains(dayFmt.string(from: cursor)) {
                streak += 1
                cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
            }
            let dates = recovered.map(\.date).sorted()
            out["recovered"] = [
                "dictations": recovered.reduce(0) { $0 + $1.dictations },
                "speech_min": Int((recovered.reduce(0.0) { $0 + $1.speechSec } / 60).rounded()),
                "words_estimated": recovered.reduce(0) { $0 + $1.estimatedWords },
                "words_per_min_assumed": Int(RecoveredDay.speakingWPM),
                "from": dates.first as Any, "to": dates.last as Any,
                "note": "Rebuilt from the log after the store key was lost: counts exact, words estimated.",
            ]
        }

        return out.merging([
            "schema": schema,
            "generated_at": iso.string(from: now),
            "last_dictation_at": real.compactMap(\.ts).max().map { iso.string(from: $0) } as Any,
            "dictations": real.count + recovered.reduce(0) { $0 + $1.dictations },
            "streak_days": streak,
            "words_today": wordsToday,
            "typing_wpm_assumed": 40,
            "today": todayB,
            "week": weekB,
            "all": allB,
            "per_day": perDayOut,
            "year": yearOut,
        ]) { a, _ in a }
    }

    /// Recompute from history and replace the file atomically.
    static func write() {
        let body = payload(HistoryReader.load(), recovered: RecoveredDay.load())
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
