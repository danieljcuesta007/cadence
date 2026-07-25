// StatsSelftest — headless assertions over the dashboard's arithmetic (`cadence selftest-stats`).
//
// Every headline number the dashboard shows is computed here in Swift from utterance rows, and
// this machine has no XCTest (Command Line Tools only), so without this the maths behind "time
// saved", the streak and the pace would ship unpinned — the numbers a user is most likely to
// call wrong, and the least likely to notice being wrong slowly.
//
// Same shape as `insertctl selftest`: named checks, JSON out, non-zero exit on failure, no
// windows, no store, no permissions.

import Foundation

private struct StatsCheck: Codable {
    var name: String
    var pass: Bool
    var detail: String?
}

/// Build a history row with just the fields the stats read.
private func entry(
    minutesAgo: Double, words: Int, app: String = "Notes", captureMs: Int? = nil
) -> HistoryEntry {
    let text = Array(repeating: "word", count: words).joined(separator: " ")
    return HistoryEntry(
        id: UUID().uuidString,
        ts: Date().addingTimeInterval(-minutesAgo * 60),
        text: words == 0 ? "" : text,
        inserted: true, app: app, strategy: "paste_restore",
        language: "en", location: "local", audioBlobId: nil,
        captureStartMs: 40, captureWindowMs: captureMs, insertionMs: 60,
        transcriptInstant: nil, transcriptFinal: nil)
}

func runStatsSelftest() -> Int32 {
    var checks: [StatsCheck] = []
    func check(_ name: String, _ pass: Bool, _ detail: String? = nil) {
        checks.append(StatsCheck(name: name, pass: pass, detail: pass ? nil : detail))
    }

    // 1. Time saved = typing time at 40 wpm minus the measured time spent speaking.
    //    80 words would take 2 min to type; spoken in 30 s ⇒ 1.5 min saved, rounds to 2.
    do {
        let s = Stats.compute([entry(minutesAgo: 5, words: 80, captureMs: 30_000)], range: .all)
        check("time_saved_uses_measured_speaking_time", s.timeSavedMin == 2,
              "expected 2, got \(s.timeSavedMin)")
        check("words_counted", s.words == 80, "expected 80, got \(s.words)")
    }

    // 2. Time saved never goes negative: a slow dictation must read 0, not a debt.
    do {
        let s = Stats.compute([entry(minutesAgo: 5, words: 5, captureMs: 120_000)], range: .all)
        check("time_saved_never_negative", s.timeSavedMin == 0, "got \(s.timeSavedMin)")
    }

    // 3. Non-speech markers ([BLANK_AUDIO] and friends) are excluded from every total.
    do {
        var blank = entry(minutesAgo: 5, words: 0)
        blank = HistoryEntry(
            id: blank.id, ts: blank.ts, text: "[BLANK_AUDIO]", inserted: blank.inserted,
            app: blank.app, strategy: blank.strategy, language: blank.language,
            location: blank.location, audioBlobId: nil, captureStartMs: nil,
            captureWindowMs: 5_000, insertionMs: nil,
            transcriptInstant: nil, transcriptFinal: nil)
        let s = Stats.compute([blank, entry(minutesAgo: 5, words: 40, captureMs: 30_000)], range: .all)
        check("non_speech_excluded_from_words", s.words == 40, "got \(s.words)")
        check("non_speech_excluded_from_apps",
              s.topApps.first?.words == 40, "got \(String(describing: s.topApps.first))")
    }

    // 4. Pace uses only rows with a measured capture window, so an unmeasured row cannot
    //    silently deflate wpm. 60 words in 30 s = 120 wpm.
    do {
        let s = Stats.compute(
            [entry(minutesAgo: 5, words: 60, captureMs: 30_000),
             entry(minutesAgo: 6, words: 999)],
            range: .all)
        check("wpm_ignores_rows_without_capture_window", s.wpm == 120, "got \(s.wpm)")
    }

    // 5. Too little data to be honest about pace ⇒ 0, not a wild number.
    do {
        let s = Stats.compute([entry(minutesAgo: 5, words: 3, captureMs: 100)], range: .all)
        check("wpm_zero_when_not_enough_measured_time", s.wpm == 0, "got \(s.wpm)")
    }

    // 6. Streak counts consecutive days back from today, and stops at the gap.
    do {
        let day = 24.0 * 60
        let s = Stats.compute(
            [entry(minutesAgo: 10, words: 10),            // today
             entry(minutesAgo: day + 10, words: 10),      // yesterday
             entry(minutesAgo: 2 * day + 10, words: 10),  // 2 days ago
             entry(minutesAgo: 5 * day + 10, words: 10)], // 5 days ago — past the gap
            range: .all)
        check("streak_counts_to_the_gap", s.streak == 3, "expected 3, got \(s.streak)")
    }

    // 7. Nothing today yet must not break an active streak (the grace day).
    do {
        let day = 24.0 * 60
        let s = Stats.compute(
            [entry(minutesAgo: day + 10, words: 10), entry(minutesAgo: 2 * day + 10, words: 10)],
            range: .all)
        check("streak_survives_a_day_not_yet_dictated", s.streak == 2, "got \(s.streak)")
    }

    // 8. Ranges actually scope: today excludes older rows, all-time keeps them.
    do {
        let rows = [entry(minutesAgo: 10, words: 10), entry(minutesAgo: 40 * 24 * 60, words: 100)]
        let today = Stats.compute(rows, range: .today)
        let all = Stats.compute(rows, range: .all)
        check("range_today_scopes_words", today.words == 10, "got \(today.words)")
        check("range_all_keeps_history", all.words == 110, "got \(all.words)")
        check("words_today_independent_of_range", all.wordsToday == 10, "got \(all.wordsToday)")
    }

    // 9. The 7-day chart is always 7 buckets ending today, however sparse the history.
    do {
        let s = Stats.compute([entry(minutesAgo: 10, words: 10)], range: .week)
        check("chart_has_seven_days", s.perDay.count == 7, "got \(s.perDay.count)")
        check("chart_last_bucket_is_today", s.perDay.last?.isToday == true)
        check("chart_today_has_the_words", s.perDay.last?.words == 10,
              "got \(String(describing: s.perDay.last?.words))")
    }

    // 10. Top apps rank by words and are scaled against the leader (the bar widths).
    do {
        let s = Stats.compute(
            [entry(minutesAgo: 5, words: 100, app: "Notes"),
             entry(minutesAgo: 6, words: 50, app: "Terminal"),
             entry(minutesAgo: 7, words: 25, app: "Mail")],
            range: .all)
        check("top_apps_ranked", s.topApps.map(\.name) == ["Notes", "Terminal", "Mail"],
              "got \(s.topApps.map(\.name))")
        check("top_apps_fraction_of_leader",
              s.topApps.first?.frac == 1.0 && s.topApps[1].frac == 0.5,
              "got \(s.topApps.map(\.frac))")
    }

    // 11. No history at all must produce zeros, not a crash or a divide-by-zero.
    do {
        let s = Stats.compute([], range: .all)
        check("empty_history_is_all_zeros",
              s.words == 0 && s.wpm == 0 && s.streak == 0 && s.timeSavedMin == 0
                  && s.topApps.isEmpty && s.perDay.count == 7)
    }

    struct Report: Codable { var checks: [StatsCheck]; var pass: Bool }
    let allPass = checks.allSatisfy { $0.pass }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(Report(checks: checks, pass: allPass)),
        let s = String(data: data, encoding: .utf8) {
        print(s)
    }
    return allPass ? 0 : 1
}
