import Foundation
import SQLite3
import TinyTimerCore

/// Logic checks runnable without XCTest (Command Line Tools ship no test frameworks):
/// `swift run TinyTimer --selftest`
enum SelfTest {
    private static var failures = 0

    static func run() -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
        }

        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tinytimer-selftest-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        do {
            let store = try Store(path: path)

            // Switching closes the previous entry.
            try store.start(.development, at: at(5, 9))
            try store.start(.meeting, at: at(5, 11, 17))
            try store.start(.development, at: at(5, 12, 3))
            try store.stop(at: at(5, 13))
            let all = try store.allEntries()
            check(all.count == 3, "3 entries")
            check(all.filter(\.isRunning).isEmpty, "no open entries after stop")
            check(all[0].end == at(5, 11, 17), "switch closes previous at switch time")
            check(try store.openEntry() == nil, "openEntry nil after stop")

            // Totals for the day.
            let day5 = Report.day(containing: at(5, 12), calendar: cal)
            check(try store.activities() == Activity.defaults, "new store is seeded with the defaults")
            let listed = Activity.defaults
            let totals = Report.totals(try store.entries(overlapping: day5), in: day5, listed: listed, now: at(5, 20))
            let developmentTotal: TimeInterval = 2 * 3600 + 17 * 60 + 57 * 60
            check(totals[.development] == developmentTotal, "development total")
            check(totals[.meeting] == 46 * 60, "meeting total")
            check(totals[.investigation] == 0, "investigation zero")

            // Running entry crossing midnight is split between days.
            try store.start(.investigation, at: at(5, 23))
            check(try store.openEntry()?.activity == .investigation, "openEntry running")
            let now = at(6, 1, 30)
            let day6 = Report.day(containing: now, calendar: cal)
            let day6Totals = Report.totals(try store.entries(overlapping: day6), in: day6, listed: listed, now: now)
            check(day6Totals[.investigation] == 90 * 60, "midnight clip, next day")
            let rows = Report.dailyRows(try store.allEntries(), listed: listed, now: now, calendar: cal)
            check(rows.count == 4, "daily rows count (dev, inv, meet on 5th; inv on 6th)")

            let csv = Report.csv(rows, calendar: cal)
            let expected = """
                date,activity,duration
                2026-10-05,Development,03:14:00
                2026-10-05,Investigation,01:00:00
                2026-10-05,Meeting,00:46:00
                2026-10-06,Investigation,01:30:00

                """
            check(csv == expected, "csv output:\n\(csv)")

            // Export formats over the same entries; the running one ends at `now`.
            let entries = try store.allEntries()
            check(Report.export(entries, format: .daysByActivity, listed: listed, now: now, calendar: cal) == expected, "export by activity equals csv")
            let days = Report.export(entries, format: .days, listed: listed, now: now, calendar: cal)
            check(days == """
                date,Development,Investigation,Meeting,total
                2026-10-05,03:14:00,01:00:00,00:46:00,05:00:00
                2026-10-06,00:00:00,01:30:00,00:00:00,01:30:00

                """, "export one row per day:\n\(days)")
            let daysDecimal = Report.export(entries, format: .days, listed: listed, decimalHours: true, now: now, calendar: cal)
            check(daysDecimal == """
                date,Development,Investigation,Meeting,total
                2026-10-05,3.23,1.00,0.77,5.00
                2026-10-06,0.00,1.50,0.00,1.50

                """, "export one row per day, decimal hours:\n\(daysDecimal)")
            let perEntry = Report.export(entries, format: .entries, listed: listed, now: now, calendar: cal)
            check(perEntry == """
                date,activity,start,end,duration
                2026-10-05,Development,09:00:00,11:17:00,02:17:00
                2026-10-05,Meeting,11:17:00,12:03:00,00:46:00
                2026-10-05,Development,12:03:00,13:00:00,00:57:00
                2026-10-05,Investigation,23:00:00,,02:30:00

                """, "export one row per entry, running end empty:\n\(perEntry)")
            let overnight = [Entry(id: 1, activity: .meeting, start: at(8, 23, 30), end: at(9, 0, 15))]
            let overnightCSV = Report.entriesCSV(overnight, decimalHours: true, now: now, calendar: cal)
            check(overnightCSV == "date,activity,start,end,duration\n2026-10-08,Meeting,23:30:00,00:15:00,0.75\n",
                  "entry crossing midnight is one row dated by start:\n\(overnightCSV)")
            check(Report.export([], format: .days, listed: listed, now: now, calendar: cal) == "date,Development,Investigation,Meeting,total\n", "empty export has header only")
            check(Format.hours(5400) == "1.50", "decimal hours")
            check(Format.hours(0) == "0.00", "decimal hours zero")

            check(Format.short(3 * 3600 + 42 * 60 + 5) == "3h 42m", "short h m")
            check(Format.short(46 * 60) == "46m", "short m")
            check(Format.hms(6137) == "01:42:17", "hms")
            check(Format.timer(0) == "00:00", "timer zero")
            check(Format.timer(59) == "00:59", "timer seconds")
            check(Format.timer(42 * 60 + 17) == "42:17", "timer no hours")
            check(Format.timer(3723) == "1:02:03", "timer hours without leading zero")
            check(Format.timer(10 * 3600) == "10:00:00", "timer two-digit hours")
            check(StatusController.idleTitle(dayTotal: 0) == " 00:00", "idle title zero")
            check(StatusController.idleTitle(dayTotal: 42 * 60 + 17) == " 42:17", "idle title no hours")
            check(StatusController.idleTitle(dayTotal: 6137) == " 1:42:17", "idle title hours")
            check(StatusController.runningTitle(initial: "D", elapsed: 6137) == " D 1:42:17", "running title")

            // Preferences: default value, persistence, fallback for an unknown stored value.
            let suite = "tinytimer-selftest-\(UUID())"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let defaults = UserDefaults(suiteName: suite)!
            check(Preferences(defaults: defaults).defaultActivity(in: listed) == .development, "default activity is the first listed")
            Preferences(defaults: defaults).defaultActivityName = Activity.meeting.name
            check(Preferences(defaults: defaults).defaultActivity(in: listed) == .meeting, "default activity persists")
            check(Preferences(defaults: defaults).defaultActivity(in: [.investigation, .development]) == .investigation,
                  "deleted default activity falls back to the first listed")
            defaults.set("Gardening", forKey: Preferences.Key.defaultActivity)
            check(Preferences(defaults: defaults).defaultActivity(in: listed) == .development, "unknown activity falls back")
            check(Preferences(defaults: defaults).defaultActivity(in: [Activity("Gardening"), .meeting]) == Activity("Gardening"),
                  "custom default activity resolves")
            check(Preferences(defaults: defaults).timerMode == .session, "timer mode is session")
            Preferences(defaults: defaults).timerMode = .dayTotal
            check(Preferences(defaults: defaults).timerMode == .dayTotal, "timer mode persists")
            defaults.set("Forever", forKey: Preferences.Key.timerMode)
            check(Preferences(defaults: defaults).timerMode == .session, "unknown timer mode falls back")
            check(Preferences(defaults: defaults).exportFormat == .days, "export format is one row per day")
            Preferences(defaults: defaults).exportFormat = .entries
            check(Preferences(defaults: defaults).exportFormat == .entries, "export format persists")
            defaults.set("Weekly", forKey: Preferences.Key.exportFormat)
            check(Preferences(defaults: defaults).exportFormat == .days, "unknown export format falls back")
            check(Preferences(defaults: defaults).exportDecimalHours == false, "decimal hours off by default")
            Preferences(defaults: defaults).exportDecimalHours = true
            check(Preferences(defaults: defaults).exportDecimalHours, "decimal hours persists")

            // Manual edits, on a fresh store: insert, update, delete and their validation.
            let editPath = path + "-edit"
            defer { try? FileManager.default.removeItem(atPath: editPath) }
            let edits = try Store(path: editPath)
            let a = try edits.insert(activity: .development, start: at(7, 9), end: at(7, 10))
            let b = try edits.insert(activity: .meeting, start: at(7, 10), end: at(7, 11))
            check(a.id != b.id, "insert returns a new id")
            check(try edits.allEntries() == [a, b], "inserted entries read back; touching ends allowed")
            check(rejects { try edits.insert(activity: .meeting, start: at(7, 9, 30), end: at(7, 10, 30)) }, "insert overlap rejected")
            check(rejects { try edits.insert(activity: .meeting, start: at(7, 8), end: at(7, 12)) }, "insert covering others rejected")
            check(rejects { try edits.insert(activity: .meeting, start: at(7, 13), end: at(7, 12)) }, "end before start rejected")
            try edits.update(id: a.id, activity: .investigation, start: at(7, 9), end: at(7, 10))
            check(try edits.allEntries().first?.activity == .investigation, "update changes activity in place")
            try edits.update(id: a.id, activity: .investigation, start: at(7, 8, 30), end: at(7, 9, 45))
            check(try edits.allEntries().first == Entry(id: a.id, activity: .investigation, start: at(7, 8, 30), end: at(7, 9, 45)), "update changes times")
            check(rejects { try edits.update(id: a.id, activity: .investigation, start: at(7, 8, 30), end: at(7, 10, 1)) }, "update overlap rejected")
            check(rejects { try edits.update(id: 999, activity: .meeting, start: at(8, 9), end: at(8, 10)) }, "update unknown id rejected")

            // Open entries: one at most, and it reaches into the future.
            try edits.start(.development, at: at(7, 12))
            let open = try edits.openEntry()!
            check(rejects { try edits.insert(activity: .meeting, start: at(7, 14), end: at(7, 15)) }, "insert after open start overlaps it")
            check(rejects { try edits.insert(activity: .meeting, start: at(7, 11, 30), end: nil) }, "second open entry rejected by insert")
            check(rejects { try edits.update(id: b.id, activity: .meeting, start: at(7, 10), end: nil) }, "second open entry rejected by update")
            try edits.update(id: open.id, activity: .meeting, start: at(7, 11, 15), end: nil)
            check(try edits.openEntry() == Entry(id: open.id, activity: .meeting, start: at(7, 11, 15), end: nil), "open entry start and activity edited")
            try edits.update(id: open.id, activity: .meeting, start: at(7, 11, 15), end: at(7, 12))
            check(try edits.openEntry() == nil, "setting an end closes the open entry")
            check(rejects { try edits.update(id: open.id, activity: .meeting, start: at(7, 11, 15), end: nil) }, "stopped entry can't be reopened")
            check(rejects { try edits.insert(activity: .development, start: at(7, 11, 30), end: nil) }, "open insert overlapping a finished entry rejected")
            try edits.insert(activity: .development, start: at(7, 13), end: nil)
            check(try edits.openEntry()?.start == at(7, 13), "open entry inserted when nothing runs")

            try edits.delete(id: b.id)
            check(try edits.allEntries().map(\.id).contains(b.id) == false, "delete removes the entry")
            check(rejects { try edits.delete(id: b.id) }, "delete unknown id rejected")
            check(StoreError.invalid("End must not be earlier than start.").localizedDescription == "End must not be earlier than start.",
                  "error message reaches localizedDescription")

            try activityChecks(path: path, at: at, cal: cal)
        } catch {
            check(false, "threw \(error)")
        }

        print(failures == 0 ? "selftest: OK" : "selftest: \(failures) failure(s)")
        return failures == 0
    }

    /// Activity list: seeding, add, delete, move, validation, and entries of deleted activities.
    private static func activityChecks(path: String, at: (Int, Int, Int) -> Date, cal: Calendar) throws {
        // A database from before the activity list: entries only, including a name that is not a default.
        let legacyPath = path + "-legacy"
        defer { try? FileManager.default.removeItem(atPath: legacyPath) }
        var db: OpaquePointer?
        sqlite3_open(legacyPath, &db)
        sqlite3_exec(db, """
            CREATE TABLE entries (id INTEGER PRIMARY KEY AUTOINCREMENT, activity TEXT NOT NULL, start REAL NOT NULL, end REAL);
            INSERT INTO entries (activity, start, end) VALUES
                ('Gardening', \(at(4, 9, 0).timeIntervalSince1970), \(at(4, 10, 0).timeIntervalSince1970)),
                ('Development', \(at(4, 10, 0).timeIntervalSince1970), \(at(4, 11, 0).timeIntervalSince1970)),
                ('meeting', \(at(4, 11, 0).timeIntervalSince1970), \(at(4, 11, 30).timeIntervalSince1970));
            """, nil, nil, nil)
        sqlite3_close(db)

        let gardening = Activity("Gardening")
        var store = try Store(path: legacyPath)
        check(try store.activities() == Activity.defaults + [gardening],
              "seeded once with defaults plus names from entries, case-insensitive duplicates merged")
        check(try store.allEntries().count == 3, "all legacy entries load, whatever their activity")

        // Add: trimmed; empty and case-insensitive duplicates rejected.
        let reading = try store.addActivity(named: "  Reading \n")
        check(reading == Activity("Reading"), "added name is trimmed")
        check(try store.activities().last == reading, "added activity goes last")
        check(rejects { try store.addActivity(named: "   ") }, "empty name rejected")
        check(rejects { try store.addActivity(named: "reading") }, "duplicate name rejected regardless of case")
        check(rejects { try store.addActivity(named: " DEVELOPMENT") }, "duplicate default rejected regardless of case")
        check((try? Activity.validatedName("Garden, pond", existing: [gardening])) == "Garden, pond", "validation accepts a new name")

        // Move.
        try store.moveActivity(reading, by: -10)
        check(try store.activities().first == reading, "move up clamps to the top")
        try store.moveActivity(reading, by: 1)
        check(try store.activities().map(\.name) == ["Development", "Reading", "Investigation", "Meeting", "Gardening"], "move down by one")

        // Delete keeps history; deleted defaults are not re-seeded on the next open.
        try store.deleteActivity(.development)
        try store.deleteActivity(gardening)
        check(rejects { try store.deleteActivity(gardening) }, "deleting a missing activity rejected")
        store = try Store(path: legacyPath)
        let listed = try store.activities()
        check(listed == [reading, .investigation, .meeting], "deleted activities stay deleted after reopening")
        let entries = try store.allEntries()
        check(entries.map(\.activity) == [gardening, .development, Activity("meeting")], "entries of deleted activities still load")
        let day4 = Report.day(containing: at(4, 12, 0), calendar: cal)
        let totals = Report.totals(entries, in: day4, listed: listed, now: at(4, 20, 0))
        check(totals[gardening] == 3600 && totals[.development] == 3600, "deleted activities counted in totals")
        check(totals.values.reduce(0, +) == 2.5 * 3600, "day total includes deleted activities")
        check(Report.activities(listed: listed, entries: entries) == listed + [gardening, .development, Activity("meeting")],
              "report activities: listed first, then unlisted in order of first use")
        let days = Report.export(entries, format: .days, listed: listed, now: at(4, 20, 0), calendar: cal)
        check(days == """
            date,Reading,Investigation,Meeting,Gardening,Development,meeting,total
            2026-10-04,00:00:00,00:00:00,00:00:00,01:00:00,01:00:00,00:30:00,02:30:00

            """, "export keeps columns of deleted activities:\n\(days)")

        // The last activity can't be deleted.
        try store.deleteActivity(reading)
        try store.deleteActivity(.investigation)
        check(rejects { try store.deleteActivity(.meeting) }, "last activity can't be deleted")
        check(try store.activities() == [.meeting], "one activity left")
    }

    /// True if `body` throws a validation error (not an SQLite one).
    private static func rejects(_ body: () throws -> Any) -> Bool {
        do {
            _ = try body()
            return false
        } catch StoreError.invalid {
            return true
        } catch {
            return false
        }
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        if (try? condition()) != true {
            failures += 1
            print("FAIL: \(message)")
        }
    }
}
