import AppKit
import Combine
import TinyTimerCore

/// App state: the running entry plus a 1s clock that drives every live label.
@MainActor
final class Tracker: ObservableObject {
    let store: Store
    let dataURL: URL

    @Published private(set) var current: Entry?
    /// The user's activity list, in display order. Never empty.
    @Published private(set) var activities: [Activity]
    @Published private(set) var now = Date()
    /// Bumped on every write so views re-query the store.
    @Published private(set) var revision = 0

    private var timer: Timer?

    init(store: Store, dataURL: URL) {
        self.store = store
        self.dataURL = dataURL
        activities = Self.load(store)
        // An entry left open by a crash keeps running.
        current = try? store.openEntry()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        // .common so the title keeps ticking while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func start(_ activity: Activity) {
        guard current?.activity != activity else { return }
        do {
            current = try store.start(activity)
            touch()
        } catch {
            report(error)
        }
    }

    func stop() {
        guard current != nil else { return }
        do {
            try store.stop()
            current = nil
            touch()
        } catch {
            report(error)
        }
    }

    // MARK: - Manual edits
    // Insert and update throw so the editor sheet can show the error inline.

    func insert(activity: Activity, start: Date, end: Date?) throws {
        try store.insert(activity: activity, start: start, end: end)
        reload()
    }

    func update(_ id: Int64, activity: Activity, start: Date, end: Date?) throws {
        try store.update(id: id, activity: activity, start: start, end: end)
        reload()
    }

    func delete(_ entry: Entry) {
        do {
            try store.delete(id: entry.id)
            reload()
        } catch {
            report(error)
        }
    }

    // MARK: - Activity list
    // Throw so Settings can show the error inline. Entries of a deleted activity are kept.

    func addActivity(named name: String) throws {
        try store.addActivity(named: name)
        reloadActivities()
    }

    func deleteActivity(_ activity: Activity) throws {
        try store.deleteActivity(activity)
        reloadActivities()
    }

    func moveActivity(_ activity: Activity, by offset: Int) throws {
        try store.moveActivity(activity, by: offset)
        reloadActivities()
    }

    private func reloadActivities() {
        activities = Self.load(store)
        touch()
    }

    /// The defaults if the list can't be read, so menus and pickers always have something to show.
    private static func load(_ store: Store) -> [Activity] {
        let list = (try? store.activities()) ?? []
        return list.isEmpty ? Activity.defaults : list
    }

    /// An edit may have changed, closed or removed the running entry.
    private func reload() {
        current = try? store.openEntry()
        touch()
    }

    func entries(on day: Date) -> [Entry] {
        (try? store.entries(overlapping: Report.day(containing: day))) ?? []
    }

    /// `now` overrides the clock: @Published sinks run before `self.now` takes the new value.
    func totals(on day: Date, now: Date? = nil) -> [Activity: TimeInterval] {
        Report.totals(entries(on: day), in: Report.day(containing: day), listed: activities, now: now ?? self.now)
    }

    var elapsed: TimeInterval {
        current.map { now.timeIntervalSince($0.start) } ?? 0
    }

    private func touch() {
        now = Date()
        revision += 1
    }

    private func report(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        NSAlert(error: error).runModal()
    }
}
