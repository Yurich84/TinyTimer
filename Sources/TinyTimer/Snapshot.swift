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
        // Sample day ending with a running entry, laid out backwards from now.
        let plan: [(Activity, Int)] = [(.development, 137), (.meeting, 46), (.development, 77),
                                       (.investigation, 50), (.meeting, 32), (.development, 65)]
        var t = Date().addingTimeInterval(-TimeInterval(plan.reduce(0) { $0 + $1.1 } * 60))
        for (activity, minutes) in plan {
            try store.start(activity, at: t)
            t = t.addingTimeInterval(TimeInterval(minutes * 60))
        }
        let tracker = Tracker(store: store, dataURL: path)

        try render(MenuSummaryView(tracker: tracker), to: dir.appendingPathComponent("menu.png"))
        try render(QuickSwitchView(model: QuickSwitchModel(), current: .development) { _ in },
                   to: dir.appendingPathComponent("quickswitch.png"))
        try render(MainView(tracker: tracker, selection: DaySelection()).frame(width: 520, height: 420),
                   to: dir.appendingPathComponent("main.png"))
        try render(StatisticsView(tracker: tracker, day: Date()).frame(width: 480, height: 220),
                   to: dir.appendingPathComponent("stats.png"))
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
