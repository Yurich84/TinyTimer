import AppKit
import ServiceManagement
import SwiftUI
import TinyTimerCore

final class SettingsModel: ObservableObject {
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var error: String?
}

struct SettingsView: View {
    let dataURL: URL
    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Picker("Default activity", selection: $preferences.defaultActivity) {
                ForEach(Activity.allCases) { Text($0.title).tag($0) }
            }
            Picker("Timer shows", selection: $preferences.timerMode) {
                ForEach(TimerMode.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            LabeledContent("Quick switch") {
                Text("⌥⌘T")
            }
            LabeledContent("Data") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([dataURL])
                }
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            model.error = nil
        } catch {
            model.error = error.localizedDescription
        }
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
