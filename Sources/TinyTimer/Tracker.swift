import AppKit
import Combine
import TinyTimerCore

/// App state: the running entry plus a 1s clock that drives every live label.
@MainActor
final class Tracker: ObservableObject {
    let store: Store
    let dataURL: URL

    @Published private(set) var current: Entry?
    @Published private(set) var now = Date()
    /// Bumped on every write so views re-query the store.
    @Published private(set) var revision = 0

    private var timer: Timer?

    init(store: Store, dataURL: URL) {
        self.store = store
        self.dataURL = dataURL
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

    func entries(on day: Date) -> [Entry] {
        (try? store.entries(overlapping: Report.day(containing: day))) ?? []
    }

    func totals(on day: Date) -> [Activity: TimeInterval] {
        Report.totals(entries(on: day), in: Report.day(containing: day), now: now)
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
