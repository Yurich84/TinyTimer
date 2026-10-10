import Foundation

public enum Report {
    public static func day(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }

    /// Per-activity totals clipped to `interval`. Every activity is present (0 if unused).
    public static func totals(_ entries: [Entry], in interval: DateInterval, now: Date) -> [Activity: TimeInterval] {
        var result = Dictionary(uniqueKeysWithValues: Activity.allCases.map { ($0, TimeInterval(0)) })
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
    public static func dailyRows(_ entries: [Entry], now: Date, calendar: Calendar = .current) -> [DailyRow] {
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
            Activity.allCases.compactMap { activity in
                guard let seconds = buckets[day]?[activity], seconds > 0 else { return nil }
                return DailyRow(day: day, activity: activity, duration: seconds)
            }
        }
    }

    /// The whole export for `format`. Durations are HH:MM:SS, or hours with 2 decimals ("1.50") if `decimalHours`.
    public static func export(_ entries: [Entry], format: ExportFormat, decimalHours: Bool = false,
                              now: Date, calendar: Calendar = .current) -> String {
        switch format {
        case .days: daysCSV(dailyRows(entries, now: now, calendar: calendar), decimalHours: decimalHours, calendar: calendar)
        case .daysByActivity: csv(dailyRows(entries, now: now, calendar: calendar), decimalHours: decimalHours, calendar: calendar)
        case .entries: entriesCSV(entries, decimalHours: decimalHours, now: now, calendar: calendar)
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

    /// CSV with header `date,<activity>…,total`: one row per day, one column per activity (0 if unused).
    public static func daysCSV(_ rows: [DailyRow], decimalHours: Bool = false, calendar: Calendar = .current) -> String {
        let df = formatter("yyyy-MM-dd", calendar)
        var lines = [(["date"] + Activity.allCases.map { escape($0.title) } + ["total"]).joined(separator: ",")]
        // `rows` is sorted by day, so equal days are adjacent.
        for (day, dayRows) in rows.chunked(by: \.day) {
            let cells = Activity.allCases.map { activity in
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
