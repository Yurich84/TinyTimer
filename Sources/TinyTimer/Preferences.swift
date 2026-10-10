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

    /// Started by a left click on the status item while idle.
    @Published var defaultActivity: Activity {
        didSet { defaults.set(defaultActivity.rawValue, forKey: Key.defaultActivity) }
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
        defaultActivity = defaults.string(forKey: Key.defaultActivity).flatMap(Activity.init(rawValue:)) ?? .development
        timerMode = defaults.string(forKey: Key.timerMode).flatMap(TimerMode.init(rawValue:)) ?? .session
        exportFormat = defaults.string(forKey: Key.exportFormat).flatMap(ExportFormat.init(rawValue:)) ?? .days
        exportDecimalHours = defaults.bool(forKey: Key.exportDecimalHours)
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
