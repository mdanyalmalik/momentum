import Charts
import MomentumCore
import SwiftUI

/// Look back: how much went into each thing, week by week or month by month. Completed sessions plus
/// time in appointments (minus any part already tracked as a session); skips and swaps are never counted against you.
struct StatsView: View {
    @Environment(AppModel.self) private var model
    @State private var range: Range = .weeks4
    @State private var filter: Filter = .all

    enum Range: String, CaseIterable, Identifiable {
        case weeks4 = "4 weeks", months3 = "3 months", months6 = "6 months", year = "Year"
        var id: String { rawValue }
        var days: Int { switch self { case .weeks4: 28; case .months3: 91; case .months6: 182; case .year: 365 } }
        var byMonth: Bool { self == .months6 || self == .year }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Everything", mainWork = "Projects", anchor = "Habits", hobby = "Hobbies", errand = "Errands",
             appointments = "Appointments"
        var id: String { rawValue }
        var group: Group? {
            switch self {
            case .all: nil
            case .mainWork: .kind(.mainWork); case .anchor: .kind(.anchor); case .hobby: .kind(.hobby); case .errand: .kind(.errand)
            case .appointments: .appointments
            }
        }
    }

    /// What a stretch of time belongs to: an activity kind, or appointments.
    enum Group: Hashable {
        case kind(BucketKind)
        case appointments

        static let all: [Group] = BucketKind.allCases.map { .kind($0) } + [.appointments]
        var title: String { if case .kind(let k) = self { k.title } else { "Appointments" } }
        var color: Color { if case .kind(let k) = self { k.color } else { .appointment } }
        var icon: String { if case .kind(let k) = self { k.icon } else { "calendar" } }
    }

    /// One counted stretch of time: a session, or (part of) an appointment.
    struct Item {
        let key: String       // activity ID, or "appt:<category>"
        let name: String
        let group: Group
        let start: Date
        let minutes: Int
    }

    struct Row: Identifiable {
        let id: String
        let name: String
        let group: Group
        let minutes: Int
        let sessions: Int
        let previousMinutes: Int
        let last: Date?
    }

    struct Bar: Identifiable {
        let id = UUID()
        let period: Date
        let series: String
        let hours: Double
    }

    var body: some View {
        let _ = model.revision
        let cal = Calendar.current
        let end = Date.now
        let start = cal.startOfDay(for: cal.date(byAdding: .day, value: -range.days + 1, to: end)!)
        let prevStart = cal.date(byAdding: .day, value: -range.days, to: start)!
        let all = Self.items(model: model, from: prevStart, to: end)
            .filter { filter.group == nil || $0.group == filter.group }
        let current = all.filter { $0.start >= start }
        let previous = all.filter { $0.start < start }
        let rows = Self.rows(current, previous)
        let bars = Self.bars(current, rows: rows, filter: filter, byMonth: range.byMonth, calendar: cal)
        let total = current.reduce(0) { $0 + $1.minutes }
        let activeDays = Set(current.map { cal.startOfDay(for: $0.start) }).count
        let weeks = max(Double(range.days) / 7, 1)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Picker("Range", selection: $range) { ForEach(Range.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(maxWidth: 360)
                    Spacer()
                    Picker("Show", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }
                        .frame(maxWidth: 200)
                }

                HStack(spacing: 12) {
                    tile("Time", Fmt.short(total), sub: "~\(Fmt.short(Int(Double(total) / weeks))) a week")
                    tile("Sessions", "\(current.count)", sub: "\(String(format: "%.1f", Double(current.count) / weeks)) a week")
                    tile("Active days", "\(activeDays)", sub: "of \(range.days)")
                    tile("Most time", rows.first?.name ?? "—", sub: rows.first.map { Fmt.short($0.minutes) } ?? "")
                }

                SectionCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(range.byMonth ? "Hours per month" : "Hours per week").font(.headline)
                        if bars.isEmpty {
                            Text("Nothing yet")
                                .foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 160)
                        } else {
                            Chart(bars) { b in
                                BarMark(x: .value("Period", b.period, unit: range.byMonth ? .month : .weekOfYear),
                                        y: .value("Hours", b.hours))
                                    .foregroundStyle(by: .value("What", b.series))
                            }
                            .chartXAxis {
                                AxisMarks(values: range.byMonth ? .stride(by: .month) : .stride(by: .weekOfYear)) { _ in
                                    AxisGridLine()
                                    AxisValueLabel(format: range.byMonth ? .dateTime.month(.abbreviated) : .dateTime.day().month(.abbreviated))
                                }
                            }
                            .chartForegroundStyleScale(domain: filter == .all ? Group.all.map(\.title) : Array(Set(bars.map(\.series))).sorted(),
                                                       range: filter == .all ? Group.all.map(\.color) : Self.palette)
                            .frame(height: 240)
                        }
                    }
                }

                SectionCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("By activity").font(.headline)
                        if rows.isEmpty {
                            Text("No completed sessions or appointments in this range.").foregroundStyle(.tertiary)
                        }
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                            if !rows.isEmpty {
                                GridRow {
                                    Text("").gridColumnAlignment(.leading)
                                    Text("Time").gridColumnAlignment(.trailing)
                                    Text("Sessions").gridColumnAlignment(.trailing)
                                    Text("Per week").gridColumnAlignment(.trailing)
                                    Text("vs before").gridColumnAlignment(.trailing)
                                    Text("Last")
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(rows) { r in
                                GridRow {
                                    Label(r.name, systemImage: r.group.icon).foregroundStyle(r.group.color).lineLimit(1)
                                    Text(Fmt.short(r.minutes)).monospacedDigit()
                                    Text("\(r.sessions)").monospacedDigit()
                                    Text(Fmt.short(Int(Double(r.minutes) / weeks))).monospacedDigit()
                                    trend(r)
                                    Text(r.last.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Stats")
    }

    private func tile(_ title: String, _ value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(sub).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func trend(_ r: Row) -> some View {
        if r.previousMinutes == 0 {
            Text(r.minutes > 0 ? "new" : "—").foregroundStyle(.secondary)
        } else {
            let change = Double(r.minutes - r.previousMinutes) / Double(r.previousMinutes)
            Text("\(change >= 0 ? "+" : "")\(Int((change * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(abs(change) < 0.1 ? Color.secondary : change > 0 ? Color.green : Color.orange)
        }
    }

    static let palette: [Color] = [.indigo, .teal, .orange, .pink, .green, .purple, .gray]

    /// Completed sessions and past appointment time, as one list.
    static func items(model: AppModel, from: Date, to: Date) -> [Item] {
        let sessions = model.sessions(from: from, to: to).filter { $0.outcome == .completed }.map {
            Item(key: $0.activityID.uuidString, name: model.activity($0.activityID)?.name ?? $0.activityName,
                 group: .kind($0.bucket), start: $0.start, minutes: $0.minutes)
        }
        let appointments = model.appointmentTime(from: from, to: to).map {
            Item(key: "appt:\($0.appointment.category)", name: $0.appointment.statsName, group: .appointments,
                 start: $0.interval.start, minutes: $0.minutes)
        }
        return sessions + appointments
    }

    static func rows(_ current: [Item], _ previous: [Item]) -> [Row] {
        let prev = previous.reduce(into: [String: Int]()) { $0[$1.key, default: 0] += $1.minutes }
        return Dictionary(grouping: current, by: \.key).map { key, items in
            Row(id: key, name: items.last?.name ?? "—", group: items.last?.group ?? .kind(.mainWork),
                minutes: items.reduce(0) { $0 + $1.minutes }, sessions: items.count, previousMinutes: prev[key] ?? 0,
                last: items.map(\.start).max())
        }
        .sorted { ($0.minutes, $0.name) > ($1.minutes, $1.name) }
    }

    /// Everything: stacked by kind. A single kind: stacked by its top activities (+ "Other").
    static func bars(_ items: [Item], rows: [Row], filter: Filter, byMonth: Bool, calendar cal: Calendar) -> [Bar] {
        let top = Set(rows.prefix(6).map(\.id))
        func series(_ s: Item) -> String {
            if filter == .all { return s.group.title }
            return top.contains(s.key) ? s.name : "Other"
        }
        func period(_ d: Date) -> Date {
            cal.dateInterval(of: byMonth ? .month : .weekOfYear, for: d)?.start ?? cal.startOfDay(for: d)
        }
        var sums: [Date: [String: Int]] = [:]
        for s in items { sums[period(s.start), default: [:]][series(s), default: 0] += s.minutes }
        return sums.keys.sorted().flatMap { p in
            sums[p]!.keys.sorted().map { Bar(period: p, series: $0, hours: Double(sums[p]![$0]!) / 60) }
        }
    }
}
