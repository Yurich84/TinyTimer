import AppKit
import Combine
import SwiftUI
import TinyTimerCore

/// Menu bar item: hourglass icon + "D 42:17" / "D 1:42:17" while running. Left click stops the running activity or
/// starts the default one; right click (or ⌃-click) opens the dropdown menu.
@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private let tracker: Tracker
    private let preferences: Preferences
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []
    /// Activity rows of the open menu, refreshed every tick so their totals stay live.
    private var activityRows: [Activity: ActivityRowView] = [:]

    var onOpenWindow: () -> Void = {}
    var onExport: () -> Void = {}
    var onSettings: () -> Void = {}

    init(tracker: Tracker, preferences: Preferences) {
        self.tracker = tracker
        self.preferences = preferences
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        // No permanent item.menu: it would open on every click. The menu is attached only for a right click.
        item.button?.target = self
        item.button?.action = #selector(buttonClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        tracker.$now.combineLatest(tracker.$current, preferences.$defaultActivity, preferences.$timerMode)
            .sink { [weak self] now, current, defaultActivity, timerMode in
                self?.updateTitle(now: now, current: current, defaultActivity: defaultActivity, timerMode: timerMode)
                self?.updateActivityRows()
            }
            .store(in: &cancellables)
    }

    @objc private func buttonClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if tracker.current != nil {
            tracker.stop()
        } else {
            tracker.start(preferences.defaultActivity)
        }
    }

    /// Attaches the menu only for this click, so menuNeedsUpdate still builds it; menuDidClose detaches it.
    private func showMenu() {
        item.menu = menu
        item.button?.performClick(nil)
    }

    private func updateTitle(now: Date, current: Entry?, defaultActivity: Activity, timerMode: TimerMode) {
        guard let button = item.button else { return }
        if button.image == nil {
            // Template image follows the menu bar's light/dark appearance.
            let image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "TinyTimer")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            // Monospaced digits stop the width from jittering every second.
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        // Kept short so the item is not pushed behind the notch: just the activity's initial ("D 42:17").
        button.title = current.map { " \($0.activity.title.prefix(1)) " + Format.timer(elapsed(of: $0, now: now, mode: timerMode)) } ?? ""
        button.toolTip = current.map { "TinyTimer — \($0.activity.title) · click: stop, right-click: menu" }
            ?? "TinyTimer — Idle · click: start \(defaultActivity.title), right-click: menu"
    }

    private func elapsed(of entry: Entry, now: Date, mode: TimerMode) -> TimeInterval {
        switch mode {
        case .session: now.timeIntervalSince(entry.start)
        // One SQLite query per tick; the store already includes the running entry.
        case .dayTotal: tracker.totals(on: now, now: now)[entry.activity] ?? 0
        }
    }

    // MARK: - NSMenuDelegate

    func menuDidClose(_ menu: NSMenu) {
        item.menu = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let summary = NSHostingView(rootView: MenuSummaryView(tracker: tracker))
        summary.frame.size = summary.fittingSize
        // Stretch to the menu's width so the total sits at the right edge with the shortcuts.
        summary.autoresizingMask = [.width]
        let summaryItem = NSMenuItem()
        summaryItem.view = summary
        menu.addItem(summaryItem)

        activityRows = [:]
        for activity in Activity.allCases {
            let mi = NSMenuItem(title: activity.title, action: #selector(startActivity(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = activity.rawValue
            let row = ActivityRowView(title: activity.title)
            mi.view = row
            menu.addItem(mi)
            activityRows[activity] = row
        }
        updateActivityRows()
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
        menu.addItem(action("Quit TinyTimer", #selector(quit), key: "q"))
    }

    private func updateActivityRows() {
        guard !activityRows.isEmpty else { return }
        let totals = tracker.totals(on: tracker.now)
        for (activity, row) in activityRows {
            row.total = Format.short(totals[activity] ?? 0)
            row.running = tracker.current?.activity == activity
        }
    }

    /// Gap between the right edge of the shortcuts (⌘ Q) and the menu's right edge; totals end there too.
    static let trailingInset: CGFloat = 16

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
        .padding(.leading, 14)
        .padding(.trailing, StatusController.trailingInset)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .frame(minWidth: ActivityRowView.minWidth)
    }
}

/// "● Development      1h 05m" menu row. A custom view because a native item can't put text at the
/// menu's right edge: its tab stops are relative to the title and the item reserves a shortcut column.
/// Clicking it fires the enclosing item's action.
final class ActivityRowView: NSView {
    static let minWidth: CGFloat = 200

    private let title: String
    var total = "" { didSet { if total != oldValue { needsDisplay = true } } }
    var running = false { didSet { if running != oldValue { needsDisplay = true } } }

    init(title: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minWidth, height: 24))
        // Stretches to the menu's width, so the total lines up with the shortcuts.
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
        }
        let text: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        let secondary: NSColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        let font = NSFont.menuFont(ofSize: 0)

        let dotSize: CGFloat = 10
        let dotRect = NSRect(x: 11, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize)
        if running {
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        } else {
            secondary.setStroke()
            let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        }

        let name = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: text])
        name.draw(at: NSPoint(x: 34, y: (bounds.height - name.size().height) / 2))

        let value = NSAttributedString(string: total, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular),
            .foregroundColor: secondary,
        ])
        let size = value.size()
        value.draw(at: NSPoint(x: bounds.maxX - StatusController.trailingInset - size.width, y: (bounds.height - size.height) / 2))
    }

    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, let menu = item.menu else { return }
        menu.cancelTracking()
        if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
    }
}
