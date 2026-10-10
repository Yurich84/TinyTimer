import SwiftUI
import TinyTimerCore

/// Selected day of the window. (A model rather than @State: SwiftUI's @State macro
/// plugin isn't shipped with Command Line Tools.)
final class DaySelection: ObservableObject {
    @Published var day = Date()
}

/// "Today" window: History and Statistics tabs for a chosen day.
struct MainView: View {
    @ObservedObject var tracker: Tracker
    @ObservedObject var selection: DaySelection

    private var day: Date { selection.day }

    var body: some View {
        VStack(spacing: 0) {
            DayPicker(day: $selection.day)
                .padding(.vertical, 10)
            TabView {
                HistoryView(tracker: tracker, day: day)
                    .tabItem { Text("History") }
                StatisticsView(tracker: tracker, day: day)
                    .tabItem { Text("Statistics") }
            }
            .padding([.horizontal, .bottom], 12)
        }
        .frame(minWidth: 460, minHeight: 360)
        .monospacedDigit()
    }
}

private struct DayPicker: View {
    @Binding var day: Date

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        HStack(spacing: 12) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Text(title).font(.headline).frame(minWidth: 160)
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .disabled(isToday)
            Button("Today") { day = Date() }
                .disabled(isToday)
        }
        .buttonStyle(.borderless)
    }

    private var title: String {
        if isToday { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
    }

    private func shift(_ days: Int) {
        day = Calendar.current.date(byAdding: .day, value: days, to: day) ?? day
    }
}

private struct HistoryView: View {
    @ObservedObject var tracker: Tracker
    let day: Date

    var body: some View {
        let interval = Report.day(containing: day)
        let entries = tracker.entries(on: day)
        Group {
            if entries.isEmpty {
                Text("No entries").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
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
            }
        }
    }
}

struct StatisticsView: View {
    @ObservedObject var tracker: Tracker
    let day: Date

    var body: some View {
        let totals = tracker.totals(on: day)
        let total = totals.values.reduce(0, +)
        let maxValue = max(totals.values.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Activity.allCases) { activity in
                let value = totals[activity] ?? 0
                HStack(spacing: 12) {
                    Text(activity.title).frame(width: 100, alignment: .leading)
                    Text(Format.short(value)).frame(width: 64, alignment: .trailing)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor)
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
