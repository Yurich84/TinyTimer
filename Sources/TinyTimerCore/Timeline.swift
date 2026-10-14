import Foundation

/// The span the statistics and timeline views cover.
public enum Period: String, CaseIterable, Identifiable, Sendable {
    case day, week, month

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }

    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    /// The local day, calendar week (per the calendar's first weekday) or calendar month containing `date`.
    public func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: component, for: date) ?? Report.day(containing: date, calendar: calendar)
    }

    /// `date` moved by `count` periods.
    public func shifted(_ date: Date, by count: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: component, value: count, to: date) ?? date
    }
}

extension Report {
    /// Every local day of `interval`, in order.
    public static func days(in interval: DateInterval, calendar: Calendar = .current) -> [DateInterval] {
        var result: [DateInterval] = []
        var start = interval.start
        while start < interval.end {
            let day = Report.day(containing: start, calendar: calendar)
            result.append(day)
            start = day.end
        }
        return result
    }
}

/// Layout and edit rules of the timeline: one bar per day, intervals as segments,
/// edges between segments (or between a segment and free time) as draggable handles.
public enum Timeline {
    /// An edit never makes an entry shorter than this.
    public static let minLength: TimeInterval = 60

    /// The part of an entry inside one day. A running entry ends at `now`.
    public struct Segment: Identifiable, Equatable, Sendable {
        public let entry: Entry
        public let start: Date
        public let end: Date

        public init(entry: Entry, start: Date, end: Date) {
            self.entry = entry
            self.start = start
            self.end = end
        }

        public var id: Int64 { entry.id }
        public var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// A draggable edge. `left` ends and `right` starts at `position`; both are set when the entries touch,
    /// and then they move together. `range` is where the edge may be dropped.
    public struct Handle: Identifiable, Equatable, Sendable {
        public let left: Entry?
        public let right: Entry?
        public let position: Date
        public let range: ClosedRange<Date>

        public init(left: Entry?, right: Entry?, position: Date, range: ClosedRange<Date>) {
            self.left = left
            self.right = right
            self.position = position
            self.range = range
        }

        public var id: String { "\(left.map { "\($0.id)" } ?? "-")|\(right.map { "\($0.id)" } ?? "-")" }

        /// The time to store for a drag that ended at `date`: cut to the minute, kept inside `range`.
        /// Within the minute of `position` the edge stays exactly where it is, so a click changes nothing.
        public func target(for date: Date) -> Date {
            let floored = Self.minute(date)
            if floored == Self.minute(position) { return position }
            return min(max(floored, range.lowerBound), range.upperBound)
        }

        private static func minute(_ date: Date) -> Date {
            Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
        }
    }

    /// Segments of `entries` inside `day`, ordered by start. Entries outside the day are dropped.
    public static func segments(_ entries: [Entry], in day: DateInterval, now: Date) -> [Segment] {
        entries.sorted { $0.start < $1.start }.compactMap { entry in
            let start = max(entry.start, day.start)
            let end = min(entry.end ?? now, day.end)
            return end > start ? Segment(entry: entry, start: start, end: end) : nil
        }
    }

    /// Draggable edges of `segments` (from `segments(_:in:now:)`). Edges cut by midnight and the end of
    /// the running entry have none. Nothing may be dropped in the future or past the end of the day.
    public static func handles(_ segments: [Segment], in day: DateInterval, now: Date) -> [Handle] {
        let limit = min(day.end, now)
        var result: [Handle] = []
        for (index, segment) in segments.enumerated() {
            let previous = index > 0 ? segments[index - 1] : nil
            let next = index + 1 < segments.count ? segments[index + 1] : nil
            let entry = segment.entry

            // Start edge; a touching predecessor owns it as a joint edge.
            if entry.start >= day.start, previous?.entry.end != entry.start {
                let lower = previous?.end ?? day.start
                let upper = segment.end - minLength
                if lower <= upper {
                    result.append(Handle(left: nil, right: entry, position: entry.start, range: lower...upper))
                }
            }

            // End edge.
            guard let end = entry.end, end <= day.end else { continue }
            let lower = segment.start + minLength
            if let next, next.entry.start == end {
                let upper = min(next.end - minLength, limit)
                if lower <= upper {
                    result.append(Handle(left: entry, right: next.entry, position: end, range: lower...upper))
                }
            } else {
                let upper = min(next?.start ?? day.end, limit)
                if lower <= upper {
                    result.append(Handle(left: entry, right: nil, position: end, range: lower...upper))
                }
            }
        }
        return result
    }

    /// `segments` as they look while `handle` is dragged to `date`.
    public static func preview(_ segments: [Segment], moving handle: Handle, to date: Date) -> [Segment] {
        segments.map { segment in
            if segment.entry.id == handle.left?.id {
                return Segment(entry: segment.entry, start: segment.start, end: date)
            }
            if segment.entry.id == handle.right?.id {
                return Segment(entry: segment.entry, start: date, end: segment.end)
            }
            return segment
        }
    }
}
