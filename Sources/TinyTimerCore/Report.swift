import Foundation

public enum Report {
    public static func day(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }

    /// `listed` followed by the activities of `entries` that are not listed (e.g. deleted from the list),
    /// in order of first appearance. Reports use it so no tracked time is left out.
    public static func activities(listed: [Activity], entries: [Entry]) -> [Activity] {
        var seen = Set(listed)
        var result = listed
        for entry in entries where seen.insert(entry.activity).inserted {
            result.append(entry.activity)
        }
        return result
    }

    /// Per-activity totals clipped to `interval`. Every listed activity is present (0 if unused),
    /// plus every activity that appears in `entries`.
    public static func totals(_ entries: [Entry], in interval: DateInterval, listed: [Activity], now: Date) -> [Activity: TimeInterval] {
        var result = Dictionary(listed.map { ($0, TimeInterval(0)) }, uniquingKeysWith: { a, _ in a })
        for entry in entries {
            result[entry.activity, default: 0] += entry.duration(in: interval, now: now)
        }
        return result
    }

    public struct DailyRow: Equatable {
        public let day: Date
        public let activity: Activity
        public let duration: TimeInterval
    }

    /// One row per local day per activity; entries crossing midnight are split between days.
    /// Within a day, rows follow `listed`, then unlisted activities in order of first appearance.
    public static func dailyRows(_ entries: [Entry], listed: [Activity], now: Date, calendar: Calendar = .current) -> [DailyRow] {
        let order = activities(listed: listed, entries: entries.sorted { $0.start < $1.start })
        var buckets: [Date: [Activity: TimeInterval]] = [:]
        for entry in entries {
            let end = entry.end ?? now
            var dayStart = calendar.startOfDay(for: entry.start)
            while dayStart < end {
                let day = Report.day(containing: dayStart, calendar: calendar)
                let seconds = entry.duration(in: day, now: now)
                if seconds > 0 {
                    buckets[day.start, default: [:]][entry.activity, default: 0] += seconds
                }
                dayStart = day.end
            }
        }
        return buckets.keys.sorted().flatMap { day in
            order.compactMap { activity in
                guard let seconds = buckets[day]?[activity], seconds > 0 else { return nil }
                return DailyRow(day: day, activity: activity, duration: seconds)
            }
        }
    }

    /// The whole export for `format`. Durations are HH:MM:SS, or hours with 2 decimals ("1.50") if `decimalHours`.
    /// `listed` is the user's activity list; activities found only in `entries` are exported too.
    public static func export(_ entries: [Entry], format: ExportFormat, listed: [Activity], decimalHours: Bool = false,
                              interval: DateInterval? = nil, now: Date, calendar: Calendar = .current) -> String {
        let entries = interval.map { clipped(entries, to: $0, now: now) } ?? entries
        return switch format {
        case .days: daysCSV(dailyRows(entries, listed: listed, now: now, calendar: calendar), listed: listed,
                            decimalHours: decimalHours, calendar: calendar)
        case .daysByActivity: csv(dailyRows(entries, listed: listed, now: now, calendar: calendar), decimalHours: decimalHours, calendar: calendar)
        case .entries: entriesCSV(entries, decimalHours: decimalHours, now: now, calendar: calendar)
        }
    }

    /// Keeps only entries overlapping the interval and clips their boundaries to it.
    private static func clipped(_ entries: [Entry], to interval: DateInterval, now: Date) -> [Entry] {
        entries.compactMap { entry in
            let end = min(entry.end ?? now, interval.end)
            let start = max(entry.start, interval.start)
            guard end > start else { return nil }
            return Entry(id: entry.id, activity: entry.activity, start: start,
                         end: entry.end == nil && end == now ? nil : end)
        }
    }

    /// CSV with header `date,activity,duration`.
    public static func csv(_ rows: [DailyRow], decimalHours: Bool = false, calendar: Calendar = .current) -> String {
        let df = formatter("yyyy-MM-dd", calendar)
        var lines = ["date,activity,duration"]
        for row in rows {
            lines.append([df.string(from: row.day), escape(row.activity.title), duration(row.duration, decimalHours)].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// CSV with header `date,<activity>…,total`: one row per day, one column per listed activity (0 if unused),
    /// then one column per unlisted activity that appears in `rows`.
    public static func daysCSV(_ rows: [DailyRow], listed: [Activity], decimalHours: Bool = false, calendar: Calendar = .current) -> String {
        let df = formatter("yyyy-MM-dd", calendar)
        var columns = listed
        for row in rows where !columns.contains(row.activity) { columns.append(row.activity) }
        var lines = [(["date"] + columns.map { escape($0.title) } + ["total"]).joined(separator: ",")]
        // `rows` is sorted by day, so equal days are adjacent.
        for (day, dayRows) in rows.chunked(by: \.day) {
            let cells = columns.map { activity in
                duration(dayRows.first { $0.activity == activity }?.duration ?? 0, decimalHours)
            }
            let total = dayRows.reduce(0) { $0 + $1.duration }
            lines.append(([df.string(from: day)] + cells + [duration(total, decimalHours)]).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// CSV with header `date,activity,start,end,duration`: one row per entry, sorted by start, dated by its start day.
    /// An entry crossing midnight stays one row. A running entry has an empty `end` and its duration up to `now`.
    public static func entriesCSV(_ entries: [Entry], decimalHours: Bool = false, now: Date, calendar: Calendar = .current) -> String {
        let df = formatter("yyyy-MM-dd", calendar)
        let tf = formatter("HH:mm:ss", calendar)
        var lines = ["date,activity,start,end,duration"]
        for entry in entries.sorted(by: { $0.start < $1.start }) {
            let end = entry.end ?? now
            lines.append([df.string(from: entry.start), escape(entry.activity.title), tf.string(from: entry.start),
                          entry.end.map(tf.string(from:)) ?? "", duration(max(0, end.timeIntervalSince(entry.start)), decimalHours)]
                .joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func duration(_ seconds: TimeInterval, _ decimalHours: Bool) -> String {
        decimalHours ? Format.hours(seconds) : Format.hms(seconds)
    }

    private static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let df = DateFormatter()
        df.calendar = calendar
        df.timeZone = calendar.timeZone
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = format
        return df
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    /// `date,<activity>…,total`
    case days
    /// `date,activity,duration`
    case daysByActivity
    /// `date,activity,start,end,duration`
    case entries

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .days: "One row per day"
        case .daysByActivity: "One row per day per activity"
        case .entries: "One row per entry"
        }
    }

    /// Appended to the default file name: "tinytimer-2026-10-10-entries.csv".
    public var fileSuffix: String {
        switch self {
        case .days: ""
        case .daysByActivity: "-by-activity"
        case .entries: "-entries"
        }
    }
}

private extension Array {
    /// Runs of adjacent elements with equal `key`, in order.
    func chunked<Key: Equatable>(by key: (Element) -> Key) -> [(Key, [Element])] {
        var result: [(Key, [Element])] = []
        for element in self {
            let k = key(element)
            if let last = result.last, last.0 == k {
                result[result.count - 1].1.append(element)
            } else {
                result.append((k, [element]))
            }
        }
        return result
    }
}

public enum Format {
    /// 01:42:17
    public static func hms(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    /// Decimal hours with 2 decimals and a "." separator: "1.50". For spreadsheets and timesheets.
    public static func hours(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", seconds / 3600)
    }

    /// Status bar timer: "42:17" under an hour, "1:02:03" from one hour on.
    public static func timer(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        let h = s / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, s % 3600 / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// "3h 42m", "46m", "0m"
    public static func short(_ seconds: TimeInterval) -> String {
        let m = Int(seconds.rounded(.down)) / 60
        let h = m / 60
        return h > 0 ? String(format: "%dh %02dm", h, m % 60) : "\(m)m"
    }

    /// "09:00"
    public static func clock(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH:mm"
        return df.string(from: date)
    }
}
