import AppKit
import SwiftUI
import TinyTimerCore

/// Borderless panels can't become key by default — needed for keyboard input.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class QuickSwitchModel: ObservableObject {
    @Published var selection = 0
}

/// ⌥⌘T popup: "What are you doing?" with ↑↓ / Enter / Esc.
@MainActor
final class QuickSwitchController {
    private let tracker: Tracker
    private let model = QuickSwitchModel()
    private var panel: KeyPanel?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// The list as it was when the panel opened; keys and rows refer to it.
    private var activities: [Activity] = []

    init(tracker: Tracker) {
        self.tracker = tracker
    }

    func toggle() {
        panel == nil ? show() : close()
    }

    private func show() {
        activities = tracker.activities
        guard !activities.isEmpty else { return }
        model.selection = tracker.current.flatMap { activities.firstIndex(of: $0.activity) } ?? 0

        let view = QuickSwitchView(model: model, activities: activities, current: tracker.current?.activity) { [weak self] activity in
            self?.choose(activity)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize

        let panel = KeyPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        position(panel)

        // Non-activating panel becomes key without stealing activation from the frontmost app
        // (Spotlight-style), so focus returns there on close.
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    /// Centered horizontally, upper third of the screen with the mouse.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return panel.center() }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.66 - size.height / 2))
    }

    private func handle(_ event: NSEvent) -> Bool {
        let count = activities.count
        switch Int(event.keyCode) {
        case 126: // ↑
            model.selection = (model.selection - 1 + count) % count
        case 125: // ↓
            model.selection = (model.selection + 1) % count
        case 36, 76: // Return, keypad Enter
            choose(activities[model.selection])
        case 53: // Esc
            close()
        default:
            // 1…9 picks one of the first nine directly.
            if let n = Int(event.charactersIgnoringModifiers ?? ""), (1...min(count, 9)).contains(n) {
                choose(activities[n - 1])
            } else {
                return false
            }
        }
        return true
    }

    private func choose(_ activity: Activity) {
        tracker.start(activity)
        close()
    }

    private func close() {
        guard let panel else { return }
        self.panel = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil
        resignObserver = nil
        panel.orderOut(nil)
    }
}

struct QuickSwitchView: View {
    @ObservedObject var model: QuickSwitchModel
    let activities: [Activity]
    let current: Activity?
    let onChoose: (Activity) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What are you doing?")
                .font(.headline)
            VStack(spacing: 2) {
                ForEach(Array(activities.enumerated()), id: \.element) { index, activity in
                    HStack {
                        Text(activity.title)
                        Spacer()
                        if activity == current {
                            Image(systemName: "record.circle").foregroundStyle(.green)
                        }
                        if index < 9 {
                            Text("\(index + 1)").foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(index == model.selection ? Color.accentColor.opacity(0.25) : .clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onChoose(activity) }
                    .onHover { if $0 { model.selection = index } }
                }
            }
            Text("↑↓ select   Enter start   Esc close")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
}
