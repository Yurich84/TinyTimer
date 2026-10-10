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

/// Time entries persisted in SQLite. Times are stored as UTC epoch seconds.
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
                sqlite3_bind_text(stmt, 1, activity.rawValue, -1, SQLITE_TRANSIENT)
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
        sqlite3_bind_text(stmt, 1, activity.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, start.timeIntervalSince1970)
        if let end {
            sqlite3_bind_double(stmt, 3, end.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 3)
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

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }) throws -> [Entry] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var result: [Entry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            // Rows with an unknown activity (e.g. renamed later) are skipped.
            guard let raw = sqlite3_column_text(stmt, 1),
                  let activity = Activity(rawValue: String(cString: raw)) else { continue }
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
