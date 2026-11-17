import MomentumCore
import SwiftData
import SwiftUI

enum DragPayload {
    static func activity(_ id: UUID) -> String { "activity:\(id.uuidString)" }
    static func block(_ id: String) -> String { "block:\(id)" }

    static func activityID(_ s: String) -> UUID? {
        s.hasPrefix("activity:") ? UUID(uuidString: String(s.dropFirst("activity:".count))) : nil
    }

    static func blockID(_ s: String) -> String? {
        s.hasPrefix("block:") ? String(s.dropFirst("block:".count)) : nil
    }
}

struct BucketsView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: [SortDescriptor(\Activity.sortIndex), SortDescriptor(\Activity.name)]) private var activities: [Activity]

    var body: some View {
        let _ = model.revision
        HStack(alignment: .top, spacing: 16) {
            ForEach(BucketKind.allCases.filter { $0 != .errand }) { kind in
                BucketColumn(kind: kind, activities: activities.filter { $0.kind == kind })
            }
            // Errands: smaller, off to the side.
            ErrandsColumn(activities: activities.filter { $0.kind == .errand })
        }
        .padding(20)
        .navigationTitle("Activities")
        .navigationSubtitle("Drag to rank")
        .toolbar {
            ToolbarItem {
                Menu {
                    ForEach(BucketKind.allCases) { k in
                        Button(k.title) { model.editor = .new(k) }
                    }
                } label: {
                    Label("Add Activity", systemImage: "plus")
                } primaryAction: {
                    model.editor = .new(.mainWork)
                }
            }
        }
    }
}

private struct BucketColumn: View {
    @Environment(AppModel.self) private var model
    let kind: BucketKind
    let activities: [Activity]
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(kind.title, systemImage: kind.icon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(kind.color)
                }
                Spacer()
                Text("\(activities.filter { !$0.isPaused }.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            Button {
                model.editor = .new(kind)
            } label: {
                Label("Add", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(kind.color)
            .controlSize(.large)
            .help("Add an activity to \(kind.title)")

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(activities) { a in
                        ActivityCard(activity: a)
                            .dropDestination(for: String.self) { items, _ in
                                guard let id = items.compactMap(DragPayload.activityID).first, id != a.id else { return false }
                                model.move(id, to: kind, before: a.id)
                                return true
                            }
                    }
                    if activities.isEmpty {
                        Text("Drop activities here, or use + Add.")
                            .font(.callout).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(kind.color.opacity(isTargeted ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(kind.color.opacity(isTargeted ? 0.6 : 0.15), lineWidth: isTargeted ? 2 : 1))
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.compactMap(DragPayload.activityID).first else { return false }
            model.move(id, to: kind)
            return true
        } isTargeted: { isTargeted = $0 }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

struct ActivityCard: View {
    @Environment(AppModel.self) private var model
    let activity: Activity

    var body: some View {
        let _ = model.revision
        let kind = activity.kind
        let done = model.completedThisWeek(activity.id)
        let planned = model.plannedUpcoming(activity.id)
        let overrides = model.overrides(for: activity.id)
        let boosted = overrides.contains { $0.kind == .boost }
        let pausedUntil = overrides.first { $0.kind == .pause }

        Button {
            model.editor = .edit(activity.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                let allot = model.allotment(for: activity)
                Text(activity.name).font(.body.weight(.semibold)).lineLimit(2)
                Text(amountText(allot: allot))
                    .font(.caption).foregroundStyle(.secondary)
                    .help(allot?.reason ?? "")
                if let allot {
                    // Share of its kind's time: a share, not a quota.
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(kind.color.opacity(0.15))
                            Capsule().fill(kind.color).frame(width: max(4, g.size.width * allot.share))
                        }
                    }
                    .frame(height: 5)
                    .help(allot.reason)
                }

                let tags = badges(boosted: boosted, pausedUntil: pausedUntil)
                if !tags.isEmpty {
                    FlowLayout(spacing: 4) { ForEach(tags, id: \.text) { $0.fixedSize() } }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                    .fill(kind.color)
                    .frame(width: 4)
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
            .opacity(activity.isPaused || pausedUntil != nil ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .draggable(DragPayload.activity(activity.id)) {
            Text(activity.name)
                .padding(8)
                .background(kind.color.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
        }
        .contextMenu { menu }
        .accessibilityHint("Opens the editor. Use the context menu to pause, boost, pin or move.")
    }

    /// "34% · 2h this week", "Daily · 15 min".
    private func amountText(allot: Allotment?) -> String {
        let session = activity.hasTwoPhaseTimer ? "\(activity.attemptMinutes)+\(activity.reviewMinutes) min" : Fmt.minutes(activity.preferredMinutes)
        switch activity.kind {
        case .anchor: return "Daily · \(session)"
        case .errand: return session
        case .mainWork, .hobby:
            let pct = allot.map { "\(Int(($0.share * 100).rounded()))%" } ?? "—"
            let done = model.minutesLastWeek(activity.id)
            return done > 0 ? "\(pct) · \(Fmt.short(done)) last 7 days" : pct
        }
    }

    private func badges(boosted: Bool, pausedUntil: SchedulingOverride?) -> [Tag] {
        var out: [Tag] = []
        if activity.isPaused { out.append(Tag(text: "Paused", icon: "pause.fill")) }
        if let p = pausedUntil { out.append(Tag(text: "Until \(p.end.formatted(.dateTime.weekday(.abbreviated)))", icon: "pause.fill")) }
        if boosted { out.append(Tag(text: "Boosted", icon: "flame.fill", color: .orange)) }
        if let d = activity.deadline {
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: d).day ?? 0
            if days >= 0 {
                out.append(Tag(text: days == 0 ? "Due today" : "Due in \(days)d", icon: "flag.fill", color: days <= 3 ? .red : .secondary))
            }
            if let left = model.remainingWork(activity) {
                out.append(Tag(text: left == 0 ? "Estimate done" : "~\(MainWorkPolicy.hm(left)) left", icon: "hourglass"))
            }
        }
        if activity.minRestHours > 0 { out.append(Tag(text: "\(Int(activity.minRestHours))h rest", icon: "bed.double")) }
        return out
    }

    @ViewBuilder private var menu: some View {
        Button("Edit…") { model.editor = .edit(activity.id) }
        if activity.kind != .errand {
            Button("Open Plan") { model.planActivityID = activity.id; model.screen = .plans }
            Button("Log Time…") { model.logActivityID = activity.id; model.showLogTime = true }
        }
        Button(activity.isPaused ? "Resume" : "Pause") { model.togglePause(activity.id) }
        Divider()
        Button("Boost…") { model.overrideRequest = OverrideRequest(activityID: activity.id, kind: .boost) }
        Button("Pin to a Day…") { model.overrideRequest = OverrideRequest(activityID: activity.id, kind: .pin) }
        Button("Pause Until…") { model.overrideRequest = OverrideRequest(activityID: activity.id, kind: .pause) }
        Divider()
        Button("Move Up") { model.nudge(activity.id, by: -1) }
        Button("Move Down") { model.nudge(activity.id, by: 1) }
        Menu("Move to") {
            ForEach(BucketKind.allCases.filter { $0 != activity.kind }) { k in
                Button(k.title) { model.move(activity.id, to: k) }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { model.deleteActivity(activity.id) }
    }
}
