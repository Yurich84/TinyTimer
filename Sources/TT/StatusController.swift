import AppKit
import Combine
import SwiftUI
import TTCore

/// Menu bar item: "⌚ 01:42:17  Development ▾" plus the dropdown menu.
@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private let tracker: Tracker
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    var onOpenWindow: () -> Void = {}
    var onExport: () -> Void = {}
    var onSettings: () -> Void = {}

    init(tracker: Tracker) {
        self.tracker = tracker
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        tracker.$now.combineLatest(tracker.$current)
            .sink { [weak self] now, current in self?.updateTitle(now: now, current: current) }
            .store(in: &cancellables)
    }

    private func updateTitle(now: Date, current: Entry?) {
        let text: String
        if let current {
            text = "⌚ \(Format.hms(now.timeIntervalSince(current.start)))  \(current.activity.title) ▾"
        } else {
            text = "⌚ Idle ▾"
        }
        // Plain title keeps the menu bar's adaptive color; monospaced digits stop jitter.
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        item.button?.title = text
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let summary = NSHostingView(rootView: MenuSummaryView(tracker: tracker))
        summary.frame.size = summary.fittingSize
        let summaryItem = NSMenuItem()
        summaryItem.view = summary
        menu.addItem(summaryItem)
        menu.addItem(.separator())

        for activity in Activity.allCases {
            let mi = NSMenuItem(title: "▶ \(activity.title)", action: #selector(startActivity(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = activity.rawValue
            mi.state = tracker.current?.activity == activity ? .on : .off
            menu.addItem(mi)
        }
        if tracker.current != nil {
            menu.addItem(action("■ Stop", #selector(stop)))
        }
        menu.addItem(.separator())

        menu.addItem(action("Today", #selector(openWindow)))
        menu.addItem(action("Export CSV…", #selector(export)))
        menu.addItem(action("Settings…", #selector(settings), key: ","))
        menu.addItem(.separator())
        menu.addItem(action("Quit TT", #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        mi.target = self
        return mi
    }

    @objc private func startActivity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let activity = Activity(rawValue: raw) else { return }
        tracker.start(activity)
    }

    @objc private func stop() { tracker.stop() }
    @objc private func openWindow() { onOpenWindow() }
    @objc private func export() { onExport() }
    @objc private func settings() { onSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Non-interactive header of the menu: today's total and per-activity totals.
struct MenuSummaryView: View {
    @ObservedObject var tracker: Tracker

    var body: some View {
        let totals = tracker.totals(on: tracker.now)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Today").fontWeight(.semibold)
                Spacer()
                Text(Format.short(totals.values.reduce(0, +))).fontWeight(.semibold)
            }
            .padding(.bottom, 4)
            ForEach(Activity.allCases) { activity in
                HStack {
                    Text(tracker.current?.activity == activity ? "●" : "○")
                        .foregroundStyle(tracker.current?.activity == activity ? Color.green : Color.secondary)
                    Text(activity.title)
                    Spacer()
                    Text(Format.short(totals[activity] ?? 0)).foregroundStyle(.secondary)
                }
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 250)
    }
}
