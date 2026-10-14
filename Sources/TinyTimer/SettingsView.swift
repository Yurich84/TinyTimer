import AppKit
import ServiceManagement
import SwiftUI
import TinyTimerCore

final class SettingsModel: ObservableObject {
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var error: String?
    /// Text field of the Activities section.
    @Published var newActivityName = ""
    /// Last failed add, delete or move in the Activities section.
    @Published var activityError: String?
    /// Activity waiting for the delete confirmation.
    @Published var pendingDelete: Activity?
}

struct SettingsView: View {
    let dataURL: URL
    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var tracker: Tracker

    var body: some View {
        Form {
            Section {
                Picker("Default activity", selection: Binding(
                    get: { preferences.defaultActivity(in: tracker.activities) ?? .development },
                    set: { preferences.defaultActivityName = $0.name }
                )) {
                    ForEach(tracker.activities) { Text($0.title).tag($0) }
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
            activitiesSection
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize()
        .confirmationDialog("Delete this activity?", isPresented: Binding(
            get: { model.pendingDelete != nil },
            set: { if !$0 { model.pendingDelete = nil } }
        ), presenting: model.pendingDelete) { activity in
            Button("Delete", role: .destructive) { delete(activity) }
        } message: { activity in
            Text("\(activity.title) is removed from the list. Its entries stay in History, Statistics and exports.")
        }
    }

    private var activitiesSection: some View {
        let activities = tracker.activities
        return Section {
            ForEach(Array(activities.enumerated()), id: \.element) { index, activity in
                HStack {
                    ColorPicker("Color of \(activity.title)", selection: Binding(
                        get: { preferences.color(for: activity) },
                        set: { preferences.setColor($0, for: activity) }
                    ), supportsOpacity: false)
                        .labelsHidden()
                    Text(activity.title)
                    Spacer()
                    Group {
                        Button { move(activity, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                            .help("Move up")
                        Button { move(activity, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == activities.count - 1)
                            .help("Move down")
                        Button { model.pendingDelete = activity } label: { Image(systemName: "trash") }
                            .disabled(activities.count == 1)
                            .help(activities.count == 1 ? "The last activity can't be deleted" : "Delete")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("New activity", text: $model.newActivityName, prompt: Text("New activity name"))
                    .labelsHidden()
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(nameProblem != nil)
            }
            // An empty field only disables Add; a duplicate also says why.
            if let problem = nameProblem, !model.newActivityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if let error = model.activityError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Activities")
        } footer: {
            Text("The color shows the activity in Statistics and Timeline. Keys 1–9 in the quick switch pick the first nine. Deleting an activity keeps its entries.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Why the typed name can't be added, or nil if it can.
    private var nameProblem: String? {
        do {
            _ = try Activity.validatedName(model.newActivityName, existing: tracker.activities)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func add() {
        guard nameProblem == nil else { return }
        perform { try tracker.addActivity(named: model.newActivityName) }
        if model.activityError == nil { model.newActivityName = "" }
    }

    private func delete(_ activity: Activity) {
        perform { try tracker.deleteActivity(activity) }
    }

    private func move(_ activity: Activity, by offset: Int) {
        perform { try tracker.moveActivity(activity, by: offset) }
    }

    private func perform(_ body: () throws -> Void) {
        do {
            try body()
            model.activityError = nil
        } catch {
            model.activityError = error.localizedDescription
        }
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
