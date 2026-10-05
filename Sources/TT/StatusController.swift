import AppKit
import Combine
import SwiftUI
import TTCore

/// Menu bar item: hourglass icon + "D 01:42:17" while running, plus the dropdown menu.
@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private let tracker: Tracker
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []
    /// Activity rows of the open menu, refreshed every tick so their totals stay live.
    private var activityItems: [Activity: NSMenuItem] = [:]

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
            .sink { [weak self] now, current in
                self?.updateTitle(now: now, current: current)
                self?.updateActivityItems()
            }
            .store(in: &cancellables)
    }

    private func updateTitle(now: Date, current: Entry?) {
        guard let button = item.button else { return }
        if button.image == nil {
            // Template image follows the menu bar's light/dark appearance.
            let image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "TT")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            // Monospaced digits stop the width from jittering every second.
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        // Kept short so the item is not pushed behind the notch: just the activity's initial ("D 01:42:17").
        button.title = current.map { " \($0.activity.title.prefix(1)) " + Format.hms(now.timeIntervalSince($0.start)) } ?? ""
        button.toolTip = current.map { "TT — \($0.activity.title)" } ?? "TT — Idle"
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let summary = NSHostingView(rootView: MenuSummaryView(tracker: tracker))
        summary.frame.size = summary.fittingSize
        let summaryItem = NSMenuItem()
        summaryItem.view = summary
        menu.addItem(summaryItem)

        activityItems = [:]
        for activity in Activity.allCases {
            let mi = NSMenuItem(title: activity.title, action: #selector(startActivity(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = activity.rawValue
            menu.addItem(mi)
            activityItems[activity] = mi
        }
        updateActivityItems()
        if tracker.current != nil {
            let stopItem = action("Stop", #selector(stop))
            stopItem.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
            menu.addItem(stopItem)
        }
        menu.addItem(.separator())

        menu.addItem(action("Today", #selector(openWindow)))
        menu.addItem(action("Export CSV…", #selector(export)))
        menu.addItem(action("Settings…", #selector(settings), key: ","))
        menu.addItem(.separator())
        menu.addItem(action("Quit TT", #selector(quit), key: "q"))
    }

    /// "● Development      1h 05m": state dot, name and today's total right-aligned under the header's total.
    private func updateActivityItems() {
        guard !activityItems.isEmpty else { return }
        let totals = tracker.totals(on: tracker.now)
        let font = NSFont.menuFont(ofSize: 0)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: Self.totalColumn)]
        for (activity, mi) in activityItems {
            let running = tracker.current?.activity == activity
            let title = NSMutableAttributedString(string: activity.title + "\t", attributes: [.font: font, .paragraphStyle: style])
            title.append(NSAttributedString(string: Format.short(totals[activity] ?? 0), attributes: [
                .font: digits, .paragraphStyle: style, .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            mi.attributedTitle = title
            mi.image = Self.dot(running: running)
        }
    }

    /// Right edge of the totals, measured from the start of an item's title.
    private static let totalColumn: CGFloat = 192

    private static func dot(running: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(.init(paletteColors: [running ? .systemGreen : .secondaryLabelColor]))
        return NSImage(systemSymbolName: running ? "circle.fill" : "circle", accessibilityDescription: running ? "Running" : nil)?
            .withSymbolConfiguration(config)
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

/// Non-interactive header of the menu: today's total. Per-activity totals live in the activity items below.
struct MenuSummaryView: View {
    @ObservedObject var tracker: Tracker

    var body: some View {
        let totals = tracker.totals(on: tracker.now)
        HStack {
            Text("Today")
            Spacer()
            Text(Format.short(totals.values.reduce(0, +)))
        }
        .fontWeight(.semibold)
        .monospacedDigit()
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .frame(width: 250)
    }
}
