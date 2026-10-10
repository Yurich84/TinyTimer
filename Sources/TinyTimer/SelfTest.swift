import Foundation
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
            let totals = Report.totals(try store.entries(overlapping: day5), in: day5, now: at(5, 20))
            check(totals[.development] == 2 * 3600 + 17 * 60 + 57 * 60, "development total")
            check(totals[.meeting] == 46 * 60, "meeting total")
            check(totals[.investigation] == 0, "investigation zero")

            // Running entry crossing midnight is split between days.
            try store.start(.investigation, at: at(5, 23))
            check(try store.openEntry()?.activity == .investigation, "openEntry running")
            let now = at(6, 1, 30)
            let day6 = Report.day(containing: now, calendar: cal)
            let day6Totals = Report.totals(try store.entries(overlapping: day6), in: day6, now: now)
            check(day6Totals[.investigation] == 90 * 60, "midnight clip, next day")
            let rows = Report.dailyRows(try store.allEntries(), now: now, calendar: cal)
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

            check(Format.short(3 * 3600 + 42 * 60 + 5) == "3h 42m", "short h m")
            check(Format.short(46 * 60) == "46m", "short m")
            check(Format.hms(6137) == "01:42:17", "hms")
        } catch {
            check(false, "threw \(error)")
        }

        print(failures == 0 ? "selftest: OK" : "selftest: \(failures) failure(s)")
        return failures == 0
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        if (try? condition()) != true {
            failures += 1
            print("FAIL: \(message)")
        }
    }
}
