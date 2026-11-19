import MomentumCore
import SwiftUI

/// Today's errands: a small checklist off to the side. Tick them off, or time one. Never part of the baseline.
struct ErrandsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.revision
        let today = model.errandsToday
        let more = model.otherOpenErrands
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Errands", systemImage: BucketKind.errand.icon)
                    .font(.headline).foregroundStyle(BucketKind.errand.color)
                Spacer()
                let open = today.filter { !model.isErrandDoneToday($0) }.count
                if open > 0 {
                    Text("\(open)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if today.isEmpty {
                Text(more.isEmpty ? "Nothing to run around for." : "Nothing pressing today.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(today) { a in ErrandRow(activity: a, done: model.isErrandDoneToday(a)) }
            ErrandQuickAdd()
            if !more.isEmpty {
                Button("\(more.count) more on the list") { model.screen = .buckets }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(14)
        .background(BucketKind.errand.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(BucketKind.errand.color.opacity(0.18)))
    }
}

struct ErrandRow: View {
    @Environment(AppModel.self) private var model
    let activity: Activity
    let done: Bool
    @State private var hovering = false
    private var isRunningThis: Bool { model.running?.activityID == activity.id }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { model.toggleErrand(activity.id) } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? BucketKind.errand.color : .secondary)
                    .font(.body)
            }
            .buttonStyle(.plain)
            .help(done ? "Untick" : "Tick off")
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.name)
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                    .lineLimit(2)
                if let detail { Text(detail).font(.caption2).foregroundStyle(dueSoon ? .red : .secondary) }
            }
            Spacer(minLength: 0)
            if !done && (hovering || isRunningThis) {
                Button { if !isRunningThis { model.startBonus(activity.id) } } label: {
                    Image(systemName: isRunningThis ? "timer" : "play.circle")
                        .foregroundStyle(isRunningThis ? BucketKind.errand.color : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(model.running != nil && !isRunningThis)
                .help(isRunningThis ? "Timer running" : model.running != nil ? "Another timer is running" : "Start a timer for this errand")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.editor = .edit(activity.id) }
        .contextMenu {
            Button(done ? "Untick" : "Tick Off") { model.toggleErrand(activity.id) }
            if !done {
                Button("Start Timer") { model.startBonus(activity.id) }
                    .disabled(model.running != nil)
            }
            Button("Edit…") { model.editor = .edit(activity.id) }
            Button("Not Today") { model.excludeToday(activity.id) }
            Divider()
            Button("Delete", role: .destructive) { model.deleteActivity(activity.id) }
        }
        .draggable(DragPayload.activity(activity.id))
    }

    private var daysLeft: Int? {
        activity.deadline.map {
            Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: $0).day ?? 0
        }
    }

    private var dueSoon: Bool { (daysLeft ?? 99) <= 1 }

    private var detail: String? {
        var parts: [String] = []
        if let d = daysLeft {
            parts.append(d < 0 ? "Was due \(activity.deadline!.formatted(.dateTime.weekday(.abbreviated)))" :
                            d == 0 ? "Due today" : d == 1 ? "Due tomorrow" : "Due in \(d) days")
        }
        if activity.sessionsPerWeek > 0 { parts.append("\(activity.sessionsPerWeek)× a week") }
        if activity.isPaused { parts.append("Paused") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct ErrandQuickAdd: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus").foregroundStyle(.secondary).font(.caption)
            TextField("Add an errand", text: $text)
                .textFieldStyle(.plain)
                .onSubmit { model.addErrand(text); text = "" }
        }
        .padding(.vertical, 2)
    }
}

/// Buckets screen: the narrow 4th column.
struct ErrandsColumn: View {
    @Environment(AppModel.self) private var model
    let activities: [Activity]
    @State private var isTargeted = false

    var body: some View {
        let open = activities.filter { $0.completedAt == nil }
        let finished = activities.filter { $0.completedAt != nil }
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label(BucketKind.errand.title, systemImage: BucketKind.errand.icon)
                    .font(.headline).foregroundStyle(BucketKind.errand.color)
            }
            ErrandQuickAdd()
                .padding(8)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(open) { a in ErrandRow(activity: a, done: model.isErrandDoneToday(a)) }
                    if open.isEmpty {
                        Text("Groceries, bills, returns… type one above.")
                            .font(.callout).foregroundStyle(.tertiary)
                    }
                    if !finished.isEmpty {
                        Divider().padding(.vertical, 4)
                        ForEach(finished) { a in ErrandRow(activity: a, done: true) }
                        Button("Clear finished") { model.clearFinishedErrands() }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .padding(12)
        .frame(width: 230, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(BucketKind.errand.color.opacity(isTargeted ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(BucketKind.errand.color.opacity(isTargeted ? 0.6 : 0.15), lineWidth: isTargeted ? 2 : 1))
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.compactMap(DragPayload.activityID).first else { return false }
            model.move(id, to: .errand)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
