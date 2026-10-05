import Foundation

public enum Activity: String, CaseIterable, Identifiable, Sendable {
    case development = "Development"
    case investigation = "Investigation"
    case meeting = "Meeting"

    public var id: String { rawValue }
    public var title: String { rawValue }
}

public struct Entry: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let activity: Activity
    public let start: Date
    public var end: Date?

    public init(id: Int64, activity: Activity, start: Date, end: Date?) {
        self.id = id
        self.activity = activity
        self.start = start
        self.end = end
    }

    public var isRunning: Bool { end == nil }

    /// Duration of the part of this entry that falls inside `interval`.
    public func duration(in interval: DateInterval, now: Date) -> TimeInterval {
        let from = max(start, interval.start)
        let to = min(end ?? now, interval.end)
        return max(0, to.timeIntervalSince(from))
    }
}
