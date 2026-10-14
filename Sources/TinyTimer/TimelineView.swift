import AppKit
import SwiftUI
import TinyTimerCore

/// State of a drag on the timeline. A model rather than @State, like `DaySelection`.
/// The store is written once, when the drag ends: every write re-queries all views and would reset a drag in progress.
final class TimelineDrag: ObservableObject {
    /// The edge being dragged, and the time it would get.
    @Published var active: Timeline.Handle?
    @Published var date = Date()
    /// Id of the edge under the pointer.
    @Published var hovered: String?
}

/// One bar per day, from midnight to midnight, with the day's entries as colored segments.
/// Drag an edge of a segment to change the entry; touching entries move together.
/// Day: one bar. Week: seven bars. Month: every day of the month, scrolling vertically.
struct TimelineView: View {
    @ObservedObject var tracker: Tracker
    @ObservedObject var preferences: Preferences
    @ObservedObject var drag: TimelineDrag
    let interval: DateInterval
    let period: Period

    private static let labelWidth: CGFloat = 52
    private static let totalWidth: CGFloat = 52

    var body: some View {
        let entries = tracker.entries(in: interval)
        let order = Report.activities(listed: tracker.activities, entries: entries)
        VStack(alignment: .leading, spacing: 8) {
            legend(order)
            HourAxis(leading: period == .day ? 0 : Self.labelWidth + 8, trailing: Self.totalWidth + 8)
            rows(entries)
        }
        .padding(12)
    }

    private func legend(_ activities: [Activity]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(activities) { activity in
                HStack(spacing: 5) {
                    Circle().fill(preferences.color(for: activity)).frame(width: 9, height: 9)
                    Text(activity.title).font(.caption).lineLimit(1)
                }
            }
        }
    }

    private func rows(_ entries: [Entry]) -> some View {
        let today = Calendar.current.startOfDay(for: Date())
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: period == .day ? 0 : 6) {
                    ForEach(Report.days(in: interval), id: \.start) { day in
                        DayRow(tracker: tracker, preferences: preferences, drag: drag, day: day, entries: entries,
                               height: barHeight, showLabel: period != .day,
                               labelWidth: Self.labelWidth, totalWidth: Self.totalWidth)
                            .id(day.start)
                    }
                }
                .padding(.vertical, 4)
            }
            .onAppear {
                if period == .month, interval.contains(today) { proxy.scrollTo(today, anchor: .center) }
            }
        }
    }

    private var barHeight: CGFloat {
        switch period {
        case .day: 56
        case .week: 32
        case .month: 22
        }
    }
}

/// Hour labels above the bars.
private struct HourAxis: View {
    let leading: CGFloat
    let trailing: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: leading)
            GeometryReader { geo in
                ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                    Text(String(format: "%02d", hour))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .position(x: geo.size.width * CGFloat(hour) / 24, y: 6)
                }
            }
            .frame(height: 12)
            Spacer().frame(width: trailing)
        }
    }
}

private struct DayRow: View {
    @ObservedObject var tracker: Tracker
    @ObservedObject var preferences: Preferences
    @ObservedObject var drag: TimelineDrag
    let day: DateInterval
    let entries: [Entry]
    let height: CGFloat
    let showLabel: Bool
    let labelWidth: CGFloat
    let totalWidth: CGFloat

    var body: some View {
        let segments = Timeline.segments(entries, in: day, now: tracker.now)
        let total = segments.reduce(0) { $0 + $1.duration }
        let isToday = Calendar.current.isDateInToday(day.start)
        return HStack(spacing: 8) {
            if showLabel {
                Text(day.start.formatted(.dateTime.weekday(.abbreviated).day()))
                    .font(.caption)
                    .fontWeight(isToday ? .bold : .regular)
                    .frame(width: labelWidth, alignment: .leading)
            }
            DayBar(tracker: tracker, preferences: preferences, drag: drag, day: day, segments: segments, height: height)
            Text(Format.short(total))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: totalWidth, alignment: .trailing)
        }
    }
}

private struct DayBar: View {
    @ObservedObject var tracker: Tracker
    @ObservedObject var preferences: Preferences
    @ObservedObject var drag: TimelineDrag
    let day: DateInterval
    let segments: [Timeline.Segment]
    let height: CGFloat

    private static let space = "timeline-bar"
    private static let handleWidth: CGFloat = 10

    var body: some View {
        let handles = Timeline.handles(segments, in: day, now: tracker.now)
        let dragged = handles.first { $0.id == drag.active?.id }
        let shown = dragged.map { Timeline.preview(segments, moving: $0, to: drag.date) } ?? segments
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                track(width: geo.size.width)
                ForEach(shown) { segment in
                    segmentView(segment, width: geo.size.width)
                }
                ForEach(handles) { handle in
                    handleView(handle, width: geo.size.width)
                }
                if let dragged {
                    badge(dragged, width: geo.size.width)
                }
            }
            .coordinateSpace(name: Self.space)
        }
        .frame(height: height)
    }

    private func x(_ date: Date, _ width: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(day.start) / day.duration) * width
    }

    private func track(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12))
            ForEach([1, 2, 3], id: \.self) { quarter in
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1)
                    .offset(x: width * CGFloat(quarter) / 4)
            }
        }
        .frame(width: width, height: height)
    }

    private func segmentView(_ segment: Timeline.Segment, width: CGFloat) -> some View {
        let from = x(segment.start, width)
        let to = x(segment.end, width)
        let entry = segment.entry
        let help = "\(entry.activity.title) \(Format.clock(segment.start))–\(Format.clock(segment.end)) (\(Format.short(segment.duration)))"
        return RoundedRectangle(cornerRadius: 2)
            .fill(preferences.color(for: entry.activity))
            .frame(width: max(1, to - from), height: height)
            .offset(x: from)
            .help(help)
    }

    private func handleView(_ handle: Timeline.Handle, width: CGFloat) -> some View {
        let isActive = drag.active?.id == handle.id
        let position = isActive ? drag.date : handle.position
        let highlighted = isActive || drag.hovered == handle.id
        return Rectangle()
            .fill(Color.clear)
            .frame(width: Self.handleWidth, height: height)
            .contentShape(Rectangle())
            .overlay(
                Capsule().fill(Color.white).frame(width: 3).shadow(radius: 1).opacity(highlighted ? 1 : 0)
            )
            .offset(x: x(position, width) - Self.handleWidth / 2)
            .onHover { inside in
                drag.hovered = inside ? handle.id : (drag.hovered == handle.id ? nil : drag.hovered)
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        if drag.active?.id != handle.id { drag.active = handle }
                        drag.date = target(handle, value, width)
                    }
                    .onEnded { value in
                        let date = target(handle, value, width)
                        drag.active = nil
                        if date != handle.position {
                            tracker.moveBoundary(left: handle.left, right: handle.right, to: date)
                        }
                    }
            )
    }

    /// Where the edge would land: its own position plus the horizontal travel, never the click point itself.
    private func target(_ handle: Timeline.Handle, _ value: DragGesture.Value, _ width: CGFloat) -> Date {
        let travel = Double((value.location.x - value.startLocation.x) / max(width, 1)) * day.duration
        return handle.target(for: handle.position.addingTimeInterval(travel))
    }

    /// The time of the edge while it is dragged.
    private func badge(_ handle: Timeline.Handle, width: CGFloat) -> some View {
        Text(Format.clock(drag.date))
            .font(.caption2)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.75)))
            .foregroundStyle(Color.white)
            .fixedSize()
            .offset(x: min(max(x(drag.date, width) - 16, 0), max(width - 36, 0)), y: -2)
            .allowsHitTesting(false)
    }
}
