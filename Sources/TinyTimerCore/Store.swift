import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: Error, CustomStringConvertible, LocalizedError {
    case sqlite(String)
    /// A rejected edit; the message is shown to the user as is.
    case invalid(String)
    public var description: String {
        switch self {
        case .sqlite(let msg): return "SQLite: \(msg)"
        case .invalid(let msg): return msg
        }
    }
    public var errorDescription: String? { description }
}

/// Time entries and the activity list persisted in SQLite. Times are stored as UTC epoch seconds.
/// Entries store the activity by name, so deleting an activity from the list keeps its history.
public final class Store {
    private var db: OpaquePointer?

    public init(path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        try exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS entries (
                id       INTEGER PRIMARY KEY AUTOINCREMENT,
                activity TEXT NOT NULL,
                start    REAL NOT NULL,
                end      REAL
            );
            CREATE INDEX IF NOT EXISTS entries_start ON entries(start);
            """)
        try createActivities()
    }

    /// Creates and seeds the `activities` table once: the defaults plus every activity already used by entries.
    /// Never re-seeds an existing table, even an empty one, so deleted defaults stay deleted.
    private func createActivities() throws {
        try transaction {
            let exists = try strings("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'activities'")
            guard exists.isEmpty else { return }
            try exec("""
                CREATE TABLE activities (
                    id       INTEGER PRIMARY KEY,
                    name     TEXT NOT NULL UNIQUE COLLATE NOCASE,
                    position INTEGER NOT NULL
                );
                """)
            let used = try strings("SELECT activity FROM entries GROUP BY activity ORDER BY MIN(start)")
            let names = Activity.defaults.map(\.name) + used.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            for (position, name) in names.enumerated() {
                // OR IGNORE: names differing only in case share one row.
                try run("INSERT OR IGNORE INTO activities (name, position) VALUES (?, ?)") { stmt in
                    sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(stmt, 2, Int64(position))
                }
            }
        }
    }

    deinit { sqlite3_close(db) }

    /// Default location: ~/Library/Application Support/TinyTimer/tinytimer.sqlite
    public static func defaultURL() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("TinyTimer", isDirectory: true)
        let url = dir.appendingPathComponent("tinytimer.sqlite")
        try migrateFromTT(support: support, to: url)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return url
    }

    /// The app used to be called TT and kept its data in Application Support/TT/tt.sqlite.
    /// Moves that database (with its -wal/-shm files) once, before anything opens it.
    private static func migrateFromTT(support: URL, to url: URL) throws {
        let fm = FileManager.default
        let oldDir = support.appendingPathComponent("TT", isDirectory: true)
        let old = oldDir.appendingPathComponent("tt.sqlite")
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: url.path) else { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["-wal", "-shm", ""] {   // main file last: its presence marks a finished move
            let src = URL(fileURLWithPath: old.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.moveItem(at: src, to: URL(fileURLWithPath: url.path + suffix))
        }
        try? fm.removeItem(at: oldDir)   // only succeeds if nothing else is left there
    }

    // MARK: - Commands

    /// Closes the running entry (if any) and starts a new one, atomically.
    @discardableResult
    public func start(_ activity: Activity, at date: Date = Date()) throws -> Entry {
        try exec("BEGIN IMMEDIATE")
        do {
            try closeOpen(at: date)
            try run("INSERT INTO entries (activity, start) VALUES (?, ?)") { stmt in
                sqlite3_bind_text(stmt, 1, activity.name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 2, date.timeIntervalSince1970)
            }
            let id = sqlite3_last_insert_rowid(db)
            try exec("COMMIT")
            return Entry(id: id, activity: activity, start: date, end: nil)
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func stop(at date: Date = Date()) throws {
        try closeOpen(at: date)
    }

    private func closeOpen(at date: Date) throws {
        try run("UPDATE entries SET end = max(start, ?) WHERE end IS NULL") { stmt in
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        }
    }

    // MARK: - Editing
    //
    // Rules for manual edits: end >= start; only one entry may be open (end == nil);
    // intervals may touch but not overlap, otherwise totals would count the same time twice.
    // An open entry counts as reaching into the future.

    /// Adds a finished (or, if nothing is running, an open) entry.
    @discardableResult
    public func insert(activity: Activity, start: Date, end: Date?) throws -> Entry {
        try transaction {
            try validate(id: nil, start: start, end: end)
            try run("INSERT INTO entries (activity, start, end) VALUES (?, ?, ?)") { stmt in
                bind(stmt, activity: activity, start: start, end: end)
            }
            return Entry(id: sqlite3_last_insert_rowid(db), activity: activity, start: start, end: end)
        }
    }

    public func update(id: Int64, activity: Activity, start: Date, end: Date?) throws {
        try transaction {
            try updateEntry(id: id, activity: activity, start: start, end: end)
        }
    }

    /// Moves the edge between two entries, or the edge of one entry, to `date` in one transaction.
    /// `left` loses or gains its end, `right` its start. If both are given, they must still touch.
    public func moveBoundary(left: Entry?, right: Entry?, to date: Date) throws {
        try transaction {
            let current = try [left, right].map { entry -> Entry? in
                guard let entry else { return nil }
                guard let fresh = try entries(id: entry.id) else { throw StoreError.invalid("The entry no longer exists.") }
                return fresh
            }
            let (l, r) = (current[0], current[1])
            if let l, let r, l.end != r.start { throw StoreError.invalid("The entries have changed. Try again.") }
            let from = l?.end ?? r?.start ?? date
            // The entry that gives up time goes first, so the other one can grow into it.
            var steps: [() throws -> Void] = []
            if let l { steps.append { try self.updateEntry(id: l.id, activity: l.activity, start: l.start, end: date) } }
            if let r { steps.append { try self.updateEntry(id: r.id, activity: r.activity, start: date, end: r.end) } }
            for step in date < from ? steps : steps.reversed() { try step() }
        }
    }

    /// `update` without its own transaction.
    private func updateEntry(id: Int64, activity: Activity, start: Date, end: Date?) throws {
        // A stale editor must not reopen an entry that was stopped meanwhile.
        if end == nil, try openEntry()?.id != id {
            throw StoreError.invalid("This entry is no longer running.")
        }
        try validate(id: id, start: start, end: end)
        try run("UPDATE entries SET activity = ?, start = ?, end = ? WHERE id = ?") { stmt in
            bind(stmt, activity: activity, start: start, end: end)
            sqlite3_bind_int64(stmt, 4, id)
        }
        if sqlite3_changes(db) == 0 { throw StoreError.invalid("The entry no longer exists.") }
    }

    public func delete(id: Int64) throws {
        try run("DELETE FROM entries WHERE id = ?") { stmt in
            sqlite3_bind_int64(stmt, 1, id)
        }
        if sqlite3_changes(db) == 0 { throw StoreError.invalid("The entry no longer exists.") }
    }

    /// Checks the edit rules against every entry except `id`.
    private func validate(id: Int64?, start: Date, end: Date?) throws {
        if let end, end < start {
            throw StoreError.invalid("End must not be earlier than start.")
        }
        if end == nil, let open = try openEntry(), open.id != id {
            throw StoreError.invalid("Another entry is running. Only one entry can be open.")
        }
        // Strict comparisons: back-to-back entries (A.end == B.start) are fine.
        let others = try query("""
            SELECT id, activity, start, end FROM entries
            WHERE id != ? AND start < ? AND (end IS NULL OR end > ?)
            ORDER BY start
            """) { stmt in
            sqlite3_bind_int64(stmt, 1, id ?? -1)
            sqlite3_bind_double(stmt, 2, end?.timeIntervalSince1970 ?? .infinity)
            sqlite3_bind_double(stmt, 3, start.timeIntervalSince1970)
        }
        if let other = others.first {
            throw StoreError.invalid("Overlaps \(other.activity.title) \(Self.time(other.start))–\(other.end.map(Self.time) ?? "now").")
        }
    }

    /// "Oct 5 09:12:37": seconds included so a clash shorter than a minute still makes sense.
    private static func time(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMM d HH:mm:ss"
        return df.string(from: date)
    }

    private func bind(_ stmt: OpaquePointer?, activity: Activity, start: Date, end: Date?) {
        sqlite3_bind_text(stmt, 1, activity.name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, start.timeIntervalSince1970)
        if let end {
            sqlite3_bind_double(stmt, 3, end.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
    }

    // MARK: - Activities

    /// The activity list in display order.
    public func activities() throws -> [Activity] {
        try strings("SELECT name FROM activities ORDER BY position, id").map(Activity.init)
    }

    /// Appends an activity. The name is trimmed; empty names and case-insensitive duplicates are rejected.
    @discardableResult
    public func addActivity(named raw: String) throws -> Activity {
        try transaction {
            let name = try Activity.validatedName(raw, existing: activities())
            try run("INSERT INTO activities (name, position) VALUES (?, (SELECT COALESCE(MAX(position), -1) + 1 FROM activities))") { stmt in
                sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            }
            return Activity(name)
        }
    }

    /// Removes an activity from the list. Its entries are kept. The last activity can't be deleted.
    public func deleteActivity(_ activity: Activity) throws {
        try transaction {
            let list = try activities()
            guard list.contains(activity) else { throw StoreError.invalid("\(activity.title) is no longer in the list.") }
            guard list.count > 1 else { throw StoreError.invalid("Keep at least one activity.") }
            try run("DELETE FROM activities WHERE name = ?") { stmt in
                sqlite3_bind_text(stmt, 1, activity.name, -1, SQLITE_TRANSIENT)
            }
        }
    }

    /// Moves an activity `offset` places up (negative) or down (positive) in the list, clamped to its ends.
    public func moveActivity(_ activity: Activity, by offset: Int) throws {
        try transaction {
            var list = try activities()
            guard let index = list.firstIndex(of: activity) else { throw StoreError.invalid("\(activity.title) is no longer in the list.") }
            let target = min(max(index + offset, 0), list.count - 1)
            list.insert(list.remove(at: index), at: target)
            for (position, item) in list.enumerated() {
                try run("UPDATE activities SET position = ? WHERE name = ?") { stmt in
                    sqlite3_bind_int64(stmt, 1, Int64(position))
                    sqlite3_bind_text(stmt, 2, item.name, -1, SQLITE_TRANSIENT)
                }
            }
        }
    }

    // MARK: - Queries

    public func openEntry() throws -> Entry? {
        try query("SELECT id, activity, start, end FROM entries WHERE end IS NULL ORDER BY start DESC LIMIT 1").first
    }

    /// Entries overlapping `interval`, ordered by start.
    public func entries(overlapping interval: DateInterval) throws -> [Entry] {
        try query("""
            SELECT id, activity, start, end FROM entries
            WHERE start < ? AND (end IS NULL OR end > ?)
            ORDER BY start
            """) { stmt in
            sqlite3_bind_double(stmt, 1, interval.end.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, interval.start.timeIntervalSince1970)
        }
    }

    private func entries(id: Int64) throws -> Entry? {
        try query("SELECT id, activity, start, end FROM entries WHERE id = ?") { stmt in
            sqlite3_bind_int64(stmt, 1, id)
        }.first
    }

    public func allEntries() throws -> [Entry] {
        try query("SELECT id, activity, start, end FROM entries ORDER BY start")
    }

    // MARK: - SQLite helpers

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func exec(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func run(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// First column of every row, as text.
    private func strings(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }) throws -> [String] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var result: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "")
        }
        return result
    }

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }) throws -> [Entry] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var result: [Entry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            // Any activity name is kept, listed or not: entries are never dropped.
            let activity = Activity(sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "")
            let end: Date? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            result.append(Entry(
                id: sqlite3_column_int64(stmt, 0),
                activity: activity,
                start: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                end: end
            ))
        }
        return result
    }
}
