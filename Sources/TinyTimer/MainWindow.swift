import SwiftUI
import TinyTimerCore

enum MainTab: Hashable {
    case history, statistics, timeline
}

/// Selected day, period and tab of the window, plus the History tab's selection, editor sheet and pending delete.
/// (A model rather than @State: SwiftUI's @State macro plugin isn't shipped with Command Line Tools.)
final class DaySelection: ObservableObject {
    @Published var day = Date()
    @Published var tab = MainTab.history
    /// Span of Statistics and Timeline; History always shows one day.
    @Published var period = Period.day
    @Published var selectedEntry: Int64?
    @Published var editor: EntryEditor?
    @Published var pendingDelete: Entry?
    let drag = TimelineDrag()

    var activePeriod: Period { tab == .history ? .day : period }
    var interval: DateInterval { activePeriod.interval(containing: day) }
}

/// "Statistics" window: History, Statistics and Timeline tabs for a chosen day, week or month.
struct MainView: View {
    @ObservedObject var tracker: Tracker
    @ObservedObject var selection: DaySelection
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                if selection.tab != .history {
                    Picker("Period", selection: $selection.period) {
                        ForEach(Period.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                }
                DayPicker(day: $selection.day, period: selection.activePeriod)
            }
            .padding(.vertical, 10)
            TabView(selection: $selection.tab) {
                HistoryView(tracker: tracker, selection: selection)
                    .tabItem { Text("History") }
                    .tag(MainTab.history)
                StatisticsView(tracker: tracker, preferences: preferences, interval: selection.interval)
                    .tabItem { Text("Statistics") }
                    .tag(MainTab.statistics)
                TimelineView(tracker: tracker, preferences: preferences, drag: selection.drag, interval: selection.interval,
                             period: selection.activePeriod)
                    .tabItem { Text("Timeline") }
                    .tag(MainTab.timeline)
            }
            .padding([.horizontal, .bottom], 12)
        }
        .frame(minWidth: 460, minHeight: 360)
        .monospacedDigit()
    }
}

private struct DayPicker: View {
    @Binding var day: Date
    let period: Period

    /// The shown period contains now: there is nothing later to go to.
    private var isCurrent: Bool { period.interval(containing: day).contains(Date()) }

    var body: some View {
        HStack(spacing: 12) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Text(title).font(.headline).frame(minWidth: 160)
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .disabled(isCurrent)
            Button("Today") { day = Date() }
                .disabled(isCurrent)
        }
        .buttonStyle(.borderless)
    }

    private var title: String {
        let calendar = Calendar.current
        let interval = period.interval(containing: day)
        switch period {
        case .day:
            if calendar.isDateInToday(day) { return "Today" }
            if calendar.isDateInYesterday(day) { return "Yesterday" }
            return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        case .week:
            if isCurrent { return "This week" }
            let last = interval.end.addingTimeInterval(-1)
            return "\(interval.start.formatted(.dateTime.day().month(.abbreviated))) – \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
        case .month:
            return day.formatted(.dateTime.month(.wide).year())
        }
    }

    private func shift(_ count: Int) {
        day = period.shifted(day, by: count)
    }
}

private struct HistoryView: View {
    @ObservedObject var tracker: Tracker
    @ObservedObject var selection: DaySelection

    var body: some View {
        let day = selection.day
        let interval = Report.day(containing: day)
        let entries = tracker.entries(on: day)
        VStack(spacing: 8) {
            if entries.isEmpty {
                Text("No entries").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries, selection: $selection.selectedEntry) { entry in
                    HStack {
                        Text("\(Format.clock(entry.start)) — \(entry.end.map(Format.clock) ?? "now")")
                            .frame(width: 120, alignment: .leading)
                        Text(entry.activity.title)
                            .fontWeight(entry.isRunning ? .semibold : .regular)
                        Spacer()
                        Text(Format.short(entry.duration(in: interval, now: tracker.now)))
                            .foregroundStyle(.secondary)
                    }
                }
                // Double-click is the primary action.
                .contextMenu(forSelectionType: Int64.self) { ids in
                    if let entry = entries.first(where: { ids.contains($0.id) }) {
                        Button("Edit…") { selection.editor = EntryEditor(entry: entry) }
                        Button("Delete…") { selection.pendingDelete = entry }
                    }
                } primaryAction: { ids in
                    if let entry = entries.first(where: { ids.contains($0.id) }) {
                        selection.editor = EntryEditor(entry: entry)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Add…") {
                    selection.editor = EntryEditor(newOn: day, before: entries.first,
                                                   defaultActivity: tracker.activities.first ?? .development)
                }
            }
            .padding([.horizontal, .bottom], 8)
        }
        .sheet(item: $selection.editor) { editor in
            EntryEditorView(model: editor, tracker: tracker)
        }
        .confirmationDialog("Delete this entry?", isPresented: Binding(
            get: { selection.pendingDelete != nil },
            set: { if !$0 { selection.pendingDelete = nil } }
        ), presenting: selection.pendingDelete) { entry in
            Button("Delete", role: .destructive) { tracker.delete(entry) }
        } message: { entry in
            Text("\(entry.activity.title), \(Format.clock(entry.start)) — \(entry.end.map(Format.clock) ?? "now")")
        }
    }
}

/// Draft for the editor sheet: an existing entry (`entry != nil`) or a new one.
final class EntryEditor: ObservableObject, Identifiable {
    let entry: Entry?
    @Published var activity: Activity
    @Published var start: Date
    /// nil only while editing the running entry.
    @Published var end: Date?
    @Published var error: String?
    /// Exact time of "Stop now"; kept to the second like an untouched field.
    private var stoppedAt: Date?
    /// The activity the editor opened with; may have been deleted from the list since.
    private let initialActivity: Activity

    init(entry: Entry) {
        self.entry = entry
        activity = entry.activity
        initialActivity = entry.activity
        start = entry.start
        end = entry.end
    }

    /// A new 30-minute entry on `day`, ending where the day's first entry (`next`) starts,
    /// e.g. for a morning before the timer was started. Without room for it: 09:00–09:30.
    /// Takes the activity of `next`, or `defaultActivity` on an empty day.
    init(newOn day: Date, before next: Entry?, defaultActivity: Activity, calendar: Calendar = .current) {
        entry = nil
        let activity = next?.activity ?? defaultActivity
        self.activity = activity
        initialActivity = activity
        let length: TimeInterval = 30 * 60
        let dayStart = calendar.startOfDay(for: day)
        var end = calendar.date(byAdding: .minute, value: 9 * 60 + 30, to: dayStart)!
        if let next, next.start >= dayStart.addingTimeInterval(length) {
            end = Self.minute(next.start)
        }
        self.end = end
        start = end.addingTimeInterval(-length)
    }

    /// Values to store. The pickers show minutes, so a field the user changed is cut to the minute;
    /// an untouched field keeps its exact seconds and can't start overlapping its neighbour.
    var values: (start: Date, end: Date?) {
        func pick(_ value: Date, _ original: Date?) -> Date { value == original ? value : Self.minute(value) }
        return (pick(start, entry?.start), end.map { pick($0, entry?.end ?? stoppedAt) })
    }

    /// Picker items: the list, plus the initial activity if it was deleted, so editing keeps it selectable.
    func choices(listed: [Activity]) -> [Activity] {
        listed.contains(initialActivity) ? listed : listed + [initialActivity]
    }

    func stopNow() {
        stoppedAt = Date()
        end = stoppedAt
    }

    static func minute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }
}

struct EntryEditorView: View {
    @ObservedObject var model: EntryEditor
    @ObservedObject var tracker: Tracker
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Activity", selection: $model.activity) {
                    ForEach(model.choices(listed: tracker.activities)) { Text($0.title).tag($0) }
                }
                DatePicker("Start", selection: $model.start, displayedComponents: [.date, .hourAndMinute])
                if let end = model.end {
                    DatePicker("End", selection: Binding(get: { end }, set: { model.end = $0 }),
                               displayedComponents: [.date, .hourAndMinute])
                } else {
                    LabeledContent("End") {
                        HStack {
                            Text("Running").foregroundStyle(.secondary)
                            Button("Stop now") { model.stopNow() }
                        }
                    }
                }
                LabeledContent("Duration") {
                    Text(Format.short((model.end ?? tracker.now).timeIntervalSince(model.start)))
                }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.entry == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 380)
        .fixedSize()
        .monospacedDigit()
    }

    private func save() {
        let (start, end) = model.values
        do {
            // The store has no clock; future times would make the status-bar timer run negative.
            if start > Date() || (end ?? .distantPast) > Date() {
                throw StoreError.invalid("Times must not be in the future.")
            }
            if let entry = model.entry {
                try tracker.update(entry.id, activity: model.activity, start: start, end: end)
            } else {
                try tracker.insert(activity: model.activity, start: start, end: end)
            }
            dismiss()
        } catch {
            model.error = error.localizedDescription
        }
    }
}

struct StatisticsView: View {
    @ObservedObject var tracker: Tracker
    @ObservedObject var preferences: Preferences
    let interval: DateInterval

    var body: some View {
        let entries = tracker.entries(in: interval)
        let totals = Report.totals(entries, in: interval, listed: tracker.activities, now: tracker.now)
        let total = totals.values.reduce(0, +)
        let maxValue = max(totals.values.max() ?? 0, 1)
        // Listed activities, then deleted ones that still have time in this period.
        let rows = Report.activities(listed: tracker.activities, entries: entries)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rows) { activity in
                let value = totals[activity] ?? 0
                HStack(spacing: 12) {
                    Text(activity.title).frame(width: 100, alignment: .leading)
                    Text(Format.short(value)).frame(width: 64, alignment: .trailing)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(preferences.color(for: activity))
                            .frame(width: max(value > 0 ? 2 : 0, geo.size.width * value / maxValue))
                    }
                    .frame(height: 12)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Text("Total").fontWeight(.semibold).frame(width: 100, alignment: .leading)
                Text(Format.short(total)).fontWeight(.semibold).frame(width: 64, alignment: .trailing)
                Spacer()
            }
            Spacer()
        }
        .padding(16)
    }
}
