import Foundation

/// A tracked activity, identified by its name. The list of activities lives in the `activities` table;
/// an entry keeps its activity name even after that activity is deleted from the list.
public struct Activity: Hashable, Identifiable, Sendable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public var id: String { name }
    public var title: String { name }

    public static let development = Activity("Development")
    public static let investigation = Activity("Investigation")
    public static let meeting = Activity("Meeting")

    /// Seeded into a new database.
    public static let defaults: [Activity] = [.development, .investigation, .meeting]

    /// The name to store for a new activity: trimmed, not empty, not a case-insensitive duplicate of `existing`.
    public static func validatedName(_ raw: String, existing: [Activity]) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            throw StoreError.invalid("Enter a name.")
        }
        if existing.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw StoreError.invalid("\u{201C}\(name)\u{201D} is already in the list.")
        }
        return name
    }
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
