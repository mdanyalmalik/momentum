import MomentumCore
import SwiftUI

struct WeekView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedBlock: PlannedBlock?

    var body: some View {
        let _ = model.revision
        let days = model.plan.days
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(days, id: \.day) { day in
                        DayColumn(day: day, selected: $selectedBlock)
                    }
                }
                .frame(minHeight: 380)

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        ExplanationCard(selected: selectedBlock)
                        OverridesCard()
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 16) {
                        WeeklyTargetsCard()
                        CommitmentsCard()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
        .navigationTitle("Week")
        .toolbar {
            ToolbarItemGroup {
                Button { model.newCommitment() } label: { Label("Add Appointment", systemImage: "calendar.badge.plus") }
                Button { model.replan("Replanned manually") } label: { Label("Replan", systemImage: "arrow.clockwise") }
            }
        }
    }
}

private struct DayColumn: View {
    @Environment(AppModel.self) private var model
    let day: MomentumCore.DayPlan
    @Binding var selected: PlannedBlock?
    @State private var isTargeted = false

    var body: some View {
        let cal = Calendar.current
        let isToday = cal.isDate(day.day, inSameDayAs: model.planningDay)
        let deadlines = model.activities.filter { a in a.completedAt == nil && a.deadline.map { cal.isDate($0, inSameDayAs: day.day) } ?? false }
        let focus = model.focusDay(day.day)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(day.day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isToday ? Color.accentColor : .secondary)
                    Text(day.day.formatted(.dateTime.day()))
                        .font(.title2.weight(isToday ? .bold : .regular))
                }
                Spacer(minLength: 0)
                Menu {
                    DayMenu(day: day.day)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("Add something to \(day.day.formatted(.dateTime.weekday(.wide))), or make it a focus day")
            }
            if let focus, let name = model.activity(focus.activityID)?.name {
                Tag(text: "Focus: \(name)", icon: "scope", color: BucketKind.mainWork.color)
                    .lineLimit(1)
                    .help("Focus day: all project time goes to \(name). Change it from the ⋯ menu.")
            }
            ForEach(deadlines) { a in
                Tag(text: "Due: \(a.name)", icon: "flag.fill", color: .red)
                    .lineLimit(1)
            }
            Text("\(Fmt.short(day.plannedFlexibleMinutes)) planned")
                .font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1)
                .help("\(Fmt.minutes(day.plannedFlexibleMinutes)) suggested out of \(Fmt.minutes(day.freeMinutes)) free waking time. The rest is deliberate slack.")

            ForEach(Self.merge(day.blocks), id: \.first!.id) { group in
                BlockChip(blocks: group, isSelected: group.contains { $0.id == selected?.id })
                    .onTapGesture { selected = group.first }
                    .contextMenu {
                        if group[0].isFixed { CommitmentMenu(id: group[0].commitmentID) } else { BlockMenu(block: group[0]) }
                    }
            }
            Spacer(minLength: 0)
            let errands = day.errands.compactMap { model.activity($0)?.name }
            if !errands.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Label("Errands", systemImage: BucketKind.errand.icon)
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(BucketKind.errand.color)
                    ForEach(errands, id: \.self) { Text("· \($0)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                }
                .help("Errands suggested for this day. Untimed: do them whenever.")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isToday ? Color.accentColor.opacity(0.06) : Color.secondary.opacity(isTargeted ? 0.14 : 0.05),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 2))
        .dropDestination(for: String.self) { items, _ in
            guard let blockID = items.compactMap(DragPayload.blockID).first else {
                if let aid = items.compactMap(DragPayload.activityID).first {
                    model.addPin(aid, day: day.day, time: nil)
                    return true
                }
                return false
            }
            model.moveBlock(blockID, to: day.day)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    /// Consecutive sessions of the same activity are shown as one chip ("Thesis · 3×50 min").
    static func merge(_ blocks: [PlannedBlock]) -> [[PlannedBlock]] {
        var out: [[PlannedBlock]] = []
        for b in blocks {
            if let last = out.last?.last, !b.isFixed, last.activityID == b.activityID, last.kind == b.kind,
               last.overrideID == b.overrideID {
                out[out.count - 1].append(b)
            } else {
                out.append([b])
            }
        }
        return out
    }
}

private struct BlockChip: View {
    let blocks: [PlannedBlock]
    let isSelected: Bool

    var body: some View {
        let b = blocks[0]
        let total = blocks.reduce(0) { $0 + $1.minutes }
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                if b.isFixed { Image(systemName: "lock.fill").font(.system(size: 8)) }
                if b.hold == .fixed {
                    Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(b.tint)
                } else if b.isPinned && !b.isFixed {
                    Image(systemName: "pin.fill").font(.system(size: 8))
                }
                if b.isPrimary { Image(systemName: "scope").font(.system(size: 8)) }
                Text(b.title).font(.caption.weight(.semibold)).lineLimit(2)
            }
            let uniform = blocks.allSatisfy { $0.minutes == b.minutes }
            Text(b.isFixed ? b.timeRange :
                    "\(b.start.formatted(date: .omitted, time: .shortened)) · \(blocks.count > 1 && uniform ? "\(blocks.count)× \(Fmt.minutes(b.minutes))" : Fmt.minutes(total))")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(b.isFixed ? AnyShapeStyle(.gray.opacity(0.18)) : AnyShapeStyle(b.tint.opacity(b.isOptional ? 0.08 : 0.18)),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(isSelected ? b.tint : (b.isOptional ? b.tint.opacity(0.35) : .clear),
                          style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: b.isOptional && !isSelected ? [3, 2] : [])))
        .contentShape(Rectangle())
        .modifier(DraggableIf(enabled: !b.isFixed, payload: DragPayload.block(b.id), title: b.title))
        .help(b.reasons.joined(separator: "\n"))
        .accessibilityElement(children: .combine)
    }
}

private struct DraggableIf: ViewModifier {
    let enabled: Bool
    let payload: String
    let title: String

    func body(content: Content) -> some View {
        if enabled {
            content.draggable(payload) { Text(title).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)) }
        } else {
            content
        }
    }
}

// MARK: - Cards below the planner

private struct ExplanationCard: View {
    @Environment(AppModel.self) private var model
    let selected: PlannedBlock?

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Why", systemImage: "lightbulb").font(.headline)
                if let b = selected {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(b.title) · \(b.start.formatted(.dateTime.weekday(.wide).hour().minute()))")
                            .font(.subheadline.weight(.semibold))
                        ForEach(b.reasons, id: \.self) { r in
                            Label(r, systemImage: "arrow.turn.down.right").font(.callout).foregroundStyle(.secondary)
                        }
                        if let id = b.activityID, !b.isFixed {
                            HStack {
                                Button("Edit…") { model.editPlanItem(b) }
                                if b.hold != .fixed {
                                    Button("Fix Here") { model.setHold(b, fixed: true) }
                                        .help("Keep this exact time and length; everything else is planned around it")
                                }
                                if b.hold == nil {
                                    Button("Keep on This Day") { model.setHold(b, fixed: false) }
                                        .help("Flexible: stays on this day; its time and length give only if they must")
                                } else {
                                    Button("Let Momentum Decide") { model.releaseBlock(b) }
                                }
                                Button("Edit Activity…") { model.editor = .edit(id) }
                            }
                            .controlSize(.small)
                            .padding(.top, 4)
                        }
                    }
                    .padding(10)
                    .background(b.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("Click a block").font(.callout).foregroundStyle(.tertiary)
                }
                if !model.plan.notes.isEmpty {
                    DisclosureGroup("Notes (\(model.plan.notes.count))") {
                        ForEach(model.plan.notes, id: \.self) { n in
                            Label(n, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

private struct OverridesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.userOverrides
        SectionCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Overrides", systemImage: "hand.raised").font(.headline)
                if items.isEmpty {
                    Text("None")
                        .font(.callout).foregroundStyle(.tertiary)
                }
                ForEach(items) { o in OverrideRow(o: o, showName: true) }
            }
        }
    }
}

/// Intended share (from rank) vs what actually happened in the last 7 days. No quotas.
private struct WeeklyTargetsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Balance", systemImage: "chart.pie").font(.headline)
                ForEach([BucketKind.mainWork, .hobby]) { kind in
                    let acts = model.activities(in: kind).filter { !$0.isPaused }
                    let actual = acts.map { model.minutesLastWeek($0.id) }
                    let total = max(actual.reduce(0, +), 1)
                    if !acts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(kind.title).font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(acts.enumerated()), id: \.element.id) { i, a in
                                let share = model.allotment(for: a)?.share ?? 0
                                let real = Double(actual[i]) / Double(total)
                                HStack {
                                    Text(a.name).font(.callout).lineLimit(1)
                                    Spacer()
                                    Text("\(Int((real * 100).rounded()))% / \(Int((share * 100).rounded()))%")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        .help("Actual share of the last 7 days / intended share from its rank")
                                }
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(a.kind.color.opacity(0.15))
                                        Capsule().fill(a.kind.color).frame(width: g.size.width * real)
                                        Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 2).offset(x: g.size.width * share - 1)
                                    }
                                }
                                .frame(height: 5)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct CommitmentsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let upcoming = model.commitments.filter { $0.end > .now }
        SectionCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Appointments", systemImage: "calendar").font(.headline)
                    Spacer()
                    Button { model.newCommitment() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add appointment")
                }
                if upcoming.isEmpty {
                    Text("None").font(.callout).foregroundStyle(.tertiary)
                }
                ForEach(upcoming) { c in
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.title).font(.callout)
                            Text("\(c.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))–\(c.end.formatted(date: .omitted, time: .shortened))\(c.category.isEmpty ? "" : " · \(c.category)")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.editCommitment(c.id) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            .help("Edit")
                        Button { model.deleteCommitment(c) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.editCommitment(c.id) }
                    .contextMenu { CommitmentMenu(id: c.id) }
                }
            }
        }
    }
}

/// Right-click on a block: change it, fix it, keep it, move it or take it off the day.
private struct BlockMenu: View {
    @Environment(AppModel.self) private var model
    let block: PlannedBlock

    var body: some View {
        let dayName = block.start.formatted(.dateTime.weekday(.wide))
        Button("Edit…") { model.editPlanItem(block) }
        Menu("Change To") {
            ForEach([BucketKind.mainWork, .hobby, .anchor]) { kind in
                Section(kind.title) {
                    ForEach(model.activities(in: kind).filter { !$0.isPaused && $0.id != block.activityID }) { a in
                        Button(a.name) { model.replaceBlock(block, with: a.id) }
                    }
                }
            }
        }
        Menu("Move To") {
            ForEach(model.plan.days, id: \.day) { d in
                if !Calendar.current.isDate(d.day, inSameDayAs: block.start) {
                    Button(d.day.formatted(.dateTime.weekday(.wide).day())) { model.moveBlock(block.id, to: d.day) }
                }
            }
        }
        Divider()
        Toggle("Fixed — exact time and length", isOn: Binding(get: { block.hold == .fixed }, set: { model.setHold(block, fixed: $0) }))
        Toggle("Flexible — keep it on \(dayName)", isOn: Binding(get: { block.hold == .flexible }, set: { on in
            if on { model.setHold(block, fixed: false) } else { model.releaseBlock(block) }
        }))
        if block.hold != nil {
            Button("Let Momentum Decide") { model.releaseBlock(block) }
        }
        Divider()
        Button("Remove From \(dayName)", role: .destructive) { model.removeBlock(block) }
    }
}

/// The ⋯ menu on a day: add something, or give the day to one project.
private struct DayMenu: View {
    @Environment(AppModel.self) private var model
    let day: Date

    var body: some View {
        let dayName = day.formatted(.dateTime.weekday(.wide))
        let current = model.focusDay(day)?.activityID
        Button("Add to \(dayName)…") { model.newPlanItem(day: day) }
        Menu("Focus \(dayName) On") {
            ForEach(model.activities(in: .mainWork)) { a in
                Toggle(a.name, isOn: Binding(get: { current == a.id }, set: { model.setFocusDay(day, activityID: $0 ? a.id : nil) }))
            }
        }
        if current != nil {
            Button("Back to the Usual Mix") { model.setFocusDay(day, activityID: nil) }
        }
    }
}
