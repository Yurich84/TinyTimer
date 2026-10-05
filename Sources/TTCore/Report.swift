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

    /// CSV with header `date,activity,duration`; duration is HH:MM:SS.
    public static func csv(_ rows: [DailyRow], calendar: Calendar = .current) -> String {
        let df = DateFormatter()
        df.calendar = calendar
        df.timeZone = calendar.timeZone
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        var lines = ["date,activity,duration"]
        for row in rows {
            lines.append([df.string(from: row.day), escape(row.activity.title), Format.hms(row.duration)].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

public enum Format {
    /// 01:42:17
    public static func hms(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
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
