import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: Error, CustomStringConvertible {
    case sqlite(String)
    public var description: String {
        switch self { case .sqlite(let msg): return "SQLite: \(msg)" }
    }
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

    /// Default location: ~/Library/Application Support/TT/tt.sqlite
    public static func defaultURL() throws -> URL {
        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("TT", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tt.sqlite")
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
