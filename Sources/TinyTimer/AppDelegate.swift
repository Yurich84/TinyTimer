import AppKit
import Carbon
import SwiftUI
import TinyTimerCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// After a sleep shorter than this, the interrupted activity resumes on wake.
    private static let resumeAfterSleepLimit: TimeInterval = 15 * 60

    private var tracker: Tracker!
    private var status: StatusController!
    private var quickSwitch: QuickSwitchController!
    private var hotKey: HotKey?
    private var mainWindow: NSWindow?
    private let daySelection = DaySelection()
    private let preferences = Preferences()
    private var settingsWindow: NSWindow?
    private var sleptActivity: (activity: Activity, at: Date)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let url = try Store.defaultURL()
            tracker = Tracker(store: try Store(path: url.path), dataURL: url)
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }

        quickSwitch = QuickSwitchController(tracker: tracker)
        status = StatusController(tracker: tracker, preferences: preferences)
        status.onOpenWindow = { [weak self] in self?.showMainWindow() }
        status.onExport = { [weak self] in self?.exportCSV() }
        status.onSettings = { [weak self] in self?.showSettings() }

        hotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: cmdKey | optionKey) { [weak self] in
            self?.quickSwitch.toggle()
        }
        if hotKey?.isRegistered == false {
            NSLog("TinyTimer: ⌥⌘T is taken by another app; quick switch is available from the menu only")
        }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        tracker?.stop()
    }

    // MARK: - Sleep

    /// Close the running entry so an overnight lid-close doesn't count as work.
    @objc private func willSleep() {
        guard let current = tracker.current else { return }
        sleptActivity = (current.activity, Date())
        tracker.stop()
    }

    @objc private func didWake() {
        defer { sleptActivity = nil }
        guard let slept = sleptActivity, tracker.current == nil,
              Date().timeIntervalSince(slept.at) < Self.resumeAfterSleepLimit else { return }
        tracker.start(slept.activity)
    }

    // MARK: - Windows

    private func showMainWindow() {
        daySelection.day = Date()
        if mainWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: MainView(tracker: tracker, selection: daySelection, preferences: preferences)))
            window.title = "TinyTimer"
            window.setContentSize(NSSize(width: 520, height: 420))
            window.styleMask.insert(.resizable)
            window.isReleasedWhenClosed = false
            window.center()
            mainWindow = window
        }
        present(mainWindow!)
    }

    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(dataURL: tracker.dataURL, model: SettingsModel(), preferences: preferences, tracker: tracker)))
            window.title = "TinyTimer Settings"
            window.styleMask.remove([.resizable, .miniaturizable])
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        present(settingsWindow!)
    }

    /// Accessory apps must activate first, otherwise windows open behind other apps.
    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let options = ExportOptionsView(panel: panel, preferences: preferences)
        panel.accessoryView = options
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let csv = Report.export(try tracker.store.allEntries(), format: preferences.exportFormat, listed: tracker.activities,
                                    decimalHours: preferences.exportDecimalHours, now: Date())
            try csv.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Save panel accessory: format pop-up and decimal hours checkbox. Choices go straight to `Preferences`.
@MainActor
private final class ExportOptionsView: NSView {
    private weak var panel: NSSavePanel?
    private let preferences: Preferences
    private let formatPopUp = NSPopUpButton()
    private let decimalCheckbox = NSButton(checkboxWithTitle: "Durations as decimal hours", target: nil, action: nil)

    init(panel: NSSavePanel, preferences: Preferences) {
        self.panel = panel
        self.preferences = preferences
        super.init(frame: .zero)
        formatPopUp.addItems(withTitles: ExportFormat.allCases.map(\.title))
        formatPopUp.selectItem(at: ExportFormat.allCases.firstIndex(of: preferences.exportFormat) ?? 0)
        formatPopUp.target = self
        formatPopUp.action = #selector(formatChanged)
        decimalCheckbox.state = preferences.exportDecimalHours ? .on : .off
        decimalCheckbox.target = self
        decimalCheckbox.action = #selector(decimalChanged)

        let formatRow = NSStackView(views: [NSTextField(labelWithString: "Format:"), formatPopUp])
        let stack = NSStackView(views: [formatRow, decimalCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        frame.size = stack.fittingSize
        updateFileName()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func formatChanged() {
        preferences.exportFormat = ExportFormat.allCases[formatPopUp.indexOfSelectedItem]
        updateFileName()
    }

    @objc private func decimalChanged() {
        preferences.exportDecimalHours = decimalCheckbox.state == .on
    }

    /// Default name plus the format suffix: "tinytimer-2026-10-10-entries.csv". Replaces a name typed by the user.
    private func updateFileName() {
        panel?.nameFieldStringValue = "tinytimer-\(Date().formatted(.iso8601.year().month().day()))\(preferences.exportFormat.fileSuffix).csv"
    }
}
