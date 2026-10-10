import Foundation
import TinyTimerCore

/// User preferences stored in UserDefaults. Each setting is a @Published property that writes itself back on change.
final class Preferences: ObservableObject {
    enum Key {
        static let defaultActivity = "defaultActivity"
        static let timerMode = "timerMode"
        static let exportFormat = "exportFormat"
        static let exportDecimalHours = "exportDecimalHours"
    }

    private let defaults: UserDefaults

    /// Name of the activity started by a left click on the status item while idle; nil until chosen.
    /// Resolve it with `defaultActivity(in:)`: the activity may have been deleted since.
    @Published var defaultActivityName: String? {
        didSet { defaults.set(defaultActivityName, forKey: Key.defaultActivity) }
    }

    /// What the status bar timer counts.
    @Published var timerMode: TimerMode {
        didSet { defaults.set(timerMode.rawValue, forKey: Key.timerMode) }
    }

    /// Last format chosen in the export panel.
    @Published var exportFormat: ExportFormat {
        didSet { defaults.set(exportFormat.rawValue, forKey: Key.exportFormat) }
    }

    /// Export durations as decimal hours ("1.50") instead of HH:MM:SS.
    @Published var exportDecimalHours: Bool {
        didSet { defaults.set(exportDecimalHours, forKey: Key.exportDecimalHours) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Unknown or missing values fall back to the default.
        defaultActivityName = defaults.string(forKey: Key.defaultActivity)
        timerMode = defaults.string(forKey: Key.timerMode).flatMap(TimerMode.init(rawValue:)) ?? .session
        exportFormat = defaults.string(forKey: Key.exportFormat).flatMap(ExportFormat.init(rawValue:)) ?? .days
        exportDecimalHours = defaults.bool(forKey: Key.exportDecimalHours)
    }

    /// The chosen default activity if it is still in `activities`, otherwise the first listed one.
    func defaultActivity(in activities: [Activity]) -> Activity? {
        activities.first { $0.name == defaultActivityName } ?? activities.first
    }
}

enum TimerMode: String, CaseIterable, Identifiable {
    /// Time since the running entry started.
    case session
    /// Today's total for the running activity, the running entry included.
    case dayTotal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: "Since switch"
        case .dayTotal: "Today's total"
        }
    }
}
