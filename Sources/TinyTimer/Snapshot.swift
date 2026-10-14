import AppKit
import SwiftUI
import TinyTimerCore

/// Renders the SwiftUI screens with sample data into PNGs (no screen-recording permission needed):
/// `TinyTimer --snapshot <dir>`
@MainActor
enum Snapshot {
    static func run(into dir: URL) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tinytimer-snapshot-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try Store(path: path.path)
        // A custom activity, and a deleted one (Investigation) whose entries must still show up.
        let review = try store.addActivity(named: "Code review")
        // Sample day ending with a running entry, laid out backwards from now.
        let plan: [(Activity, Int)] = [(.development, 137), (.meeting, 46), (.development, 77),
                                       (.investigation, 50), (review, 32), (.development, 65)]
        var t = Date().addingTimeInterval(-TimeInterval(plan.reduce(0) { $0 + $1.1 } * 60))
        for (activity, minutes) in plan {
            try store.start(activity, at: t)
            t = t.addingTimeInterval(TimeInterval(minutes * 60))
        }
        try store.deleteActivity(.investigation)
        // Earlier days, for the week and month views: a morning and an afternoon block each.
        let calendar = Calendar.current
        for (back, blocks) in [(2, [(Activity.development, 9.0, 12.5), (.meeting, 13.0, 14.0), (review, 14.0, 17.5)]),
                               (3, [(.development, 8.5, 12.0), (.meeting, 12.0, 13.0), (.development, 14.0, 18.0)]),
                               (5, [(.meeting, 10.0, 11.0), (.development, 11.0, 16.0)])] {
            let midnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -back, to: Date())!)
            for (activity, from, to) in blocks {
                try store.insert(activity: activity, start: midnight.addingTimeInterval(from * 3600),
                                 end: midnight.addingTimeInterval(to * 3600))
            }
        }
        let tracker = Tracker(store: store, dataURL: path)
        // Throwaway suite so the snapshot neither reads nor writes the user's settings.
        let suite = "tinytimer-snapshot-\(UUID())"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: UserDefaults(suiteName: suite)!)

        try render(MenuSummaryView(tracker: tracker), to: dir.appendingPathComponent("menu.png"))
        try render(QuickSwitchView(model: QuickSwitchModel(), activities: tracker.activities, current: .development) { _ in },
                   to: dir.appendingPathComponent("quickswitch.png"))
        try render(MainView(tracker: tracker, selection: DaySelection(), preferences: preferences).frame(width: 520, height: 420),
                   to: dir.appendingPathComponent("main.png"))
        // Editor sheet content: a finished entry, and the running one with an inline error.
        let entries = try store.allEntries()
        try render(EntryEditorView(model: EntryEditor(entry: entries[1]), tracker: tracker),
                   to: dir.appendingPathComponent("editor.png"))
        // An entry of the deleted Investigation: still shown and selected in the picker.
        try render(EntryEditorView(model: EntryEditor(entry: entries[3]), tracker: tracker),
                   to: dir.appendingPathComponent("editor-deleted-activity.png"))
        let running = EntryEditor(entry: entries[entries.count - 1])
        do {   // A real overlap error, for the wrapping of its full text.
            try store.insert(activity: .meeting, start: entries[0].start, end: entries[1].end)
        } catch {
            running.error = error.localizedDescription
        }
        try render(EntryEditorView(model: running, tracker: tracker),
                   to: dir.appendingPathComponent("editor-running.png"))
        try render(StatisticsView(tracker: tracker, preferences: preferences, interval: Report.day(containing: Date())).frame(width: 480, height: 220),
                   to: dir.appendingPathComponent("stats.png"))
        for period in Period.allCases {
            let interval = period.interval(containing: Date())
            try render(TimelineView(tracker: tracker, preferences: preferences, drag: TimelineDrag(), interval: interval, period: period)
                .frame(width: 520, height: 360), to: dir.appendingPathComponent("timeline-\(period.rawValue).png"))
            try render(StatisticsView(tracker: tracker, preferences: preferences, interval: interval)
                .frame(width: 480, height: 220), to: dir.appendingPathComponent("stats-\(period.rawValue).png"))
        }
        try render(SettingsView(dataURL: path, model: SettingsModel(), preferences: preferences, tracker: tracker),
                   to: dir.appendingPathComponent("settings.png"))
        // A case-insensitive duplicate in the field: Add disabled, reason shown.
        let duplicate = SettingsModel()
        duplicate.newActivityName = "meeting "
        try render(SettingsView(dataURL: path, model: duplicate, preferences: preferences, tracker: tracker),
                   to: dir.appendingPathComponent("settings-duplicate.png"))
    }

    private static func render<V: View>(_ view: V, to url: URL) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.backgroundColor = .windowBackgroundColor
        window.appearance = NSAppearance(named: .aqua)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
