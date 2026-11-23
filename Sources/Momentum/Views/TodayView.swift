import AppKit
import MomentumCore
import SwiftUI

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var showFullDay = false
    @State private var showWhy = false
    @State private var showExtras = false

    var body: some View {
        let _ = model.revision
        let plan = model.todayPlan
        let now = Date.now
        let upcoming = (plan?.flexibleBlocks ?? []).sorted { $0.start < $1.start }
        let current = upcoming.first { $0.start <= now && $0.end > now } ?? upcoming.first { !$0.isOptional } ?? upcoming.first
        let next = Self.nextPriorities(upcoming, excluding: current, limit: 2)

        let main = VStack(alignment: .leading, spacing: 18) {
                header(plan)

                if let sleep = model.currentSleep {
                    SleepingCard(since: sleep.start)
                } else if let r = model.running {
                    TimerCard(session: r)
                } else if let current {
                    NowCard(block: current, isNow: current.start <= now)
                } else {
                    EmptyDayCard(hasActivities: !model.activities.isEmpty)
                }

                if model.running == nil, model.currentSleep == nil, !next.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Then").font(.headline).foregroundStyle(.secondary)
                        ForEach(next, id: \.first!.id) { group in
                            PriorityRow(blocks: group)
                        }
                    }
                }

                ProgressCard()

                SetAsideRow()

                TimeSoFarCard()

                let optional = upcoming.filter(\.isOptional)
                if !(plan?.bonusIdeas.isEmpty ?? true) || !optional.isEmpty {
                    if model.baselineRemaining == 0 {
                        BonusSection(ideas: plan?.bonusIdeas ?? [], optional: optional)
                    } else {
                        DisclosureGroup(isExpanded: $showExtras) {
                            BonusSection(ideas: plan?.bonusIdeas ?? [], optional: optional, showTitle: false)
                                .padding(.top, 6)
                        } label: {
                            Text("Extras").font(.headline)
                        }
                    }
                }

                DisclosureGroup(isExpanded: $showFullDay) {
                    FullDayTimeline(plan: plan)
                        .padding(.top, 8)
                } label: {
                    Text("Full day").font(.headline)
                }

            }
        ScrollView {
            // Errands sit off to the side when there's room, and below everything when there isn't.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    main.frame(minWidth: 420, idealWidth: 440, maxWidth: 760, alignment: .leading)
                    ErrandsPanel().frame(width: 230)
                }
                VStack(alignment: .leading, spacing: 18) {
                    main
                    ErrandsPanel()
                }
            }
            .padding(24)
            .frame(maxWidth: 1060, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Today")
        .toolbar {
            ToolbarItemGroup {
                EnergyPicker()
                Button { model.showStartDay = true } label: {
                    Label(model.hasStartedToday ? "Adjust Day" : "Start Day", systemImage: "sunrise")
                }
                .help("Set wake time, bedtime and energy")
                StartAnythingMenu(title: "Start…")
                    .disabled(model.running != nil)
                    .help("Start a session of anything, planned or not")
                Button { model.logActivityID = nil; model.showLogTime = true } label: {
                    Label("Log Time", systemImage: "clock.badge.checkmark")
                }
                .help("Add time you spent on something outside the app (⇧⌘T)")
                if model.currentSleep == nil {
                    Button { model.goToSleep() } label: { Label("Going to Sleep", systemImage: "moon.zzz") }
                        .help("Pause suggestions until you're up again (⇧⌘L)")
                } else {
                    Button { model.showWakeSheet = true } label: { Label("I'm Awake", systemImage: "sun.horizon") }
                        .help("Tell Momentum when you woke up (⇧⌘L)")
                }
            }
        }
    }

    /// Groups the remaining baseline blocks by activity, in order, so "Interview prep ×3" is one priority.
    static func nextPriorities(_ blocks: [PlannedBlock], excluding current: PlannedBlock?, limit: Int) -> [[PlannedBlock]] {
        var order: [UUID] = []
        var groups: [UUID: [PlannedBlock]] = [:]
        for b in blocks where b.id != current?.id && !b.isOptional {
            guard let id = b.activityID else { continue }
            if id == current?.activityID { continue }
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(b)
        }
        return order.prefix(limit).compactMap { groups[$0] }
    }

    @ViewBuilder
    private func header(_ plan: MomentumCore.DayPlan?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.subheadline).foregroundStyle(.secondary)
            Text(greeting).font(.largeTitle.bold())
            if let plan {
                HStack(spacing: 8) {
                    if model.hasStartedToday, let wake = model.todayRecord?.wake {
                        Tag(text: "Up since \(wake.formatted(date: .omitted, time: .shortened))", icon: "sunrise")
                    }
                    if model.currentSleep == nil, let bed = model.expectedBedtime {
                        Button { model.showBedtimeSheet = true } label: {
                            Tag(text: "Sleep ~\(bed.formatted(date: .omitted, time: .shortened))\(model.activeSleepEstimate == nil ? "?" : "")", icon: "moon")
                        }
                        .buttonStyle(.plain)
                        .help("When you expect to sleep next. Click to change it (⇧⌘B).")
                    }
                    Tag(text: "\(Fmt.short(plan.plannedFlexibleMinutes)) planned", icon: "hourglass")
                        .help("\(Fmt.minutes(plan.plannedFlexibleMinutes)) suggested out of \(Fmt.minutes(plan.freeMinutes)) free. The rest is slack on purpose.")
                }
            }
            if !model.hasStartedToday && model.currentSleep == nil && model.activeSleepEstimate == nil {
                Button {
                    model.showStartDay = true
                } label: {
                    Label("Start your day", systemImage: "sunrise.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
            }
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        switch h {
        case 4..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Hello, night owl"
        }
    }
}

struct EnergyPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = model.todayPlan?.energy ?? .normal
        Picker("Energy", selection: Binding(get: { current }, set: { model.setEnergy($0) })) {
            ForEach(EnergyLevel.allCases) { e in Text(e.title).tag(e) }
        }
        .pickerStyle(.segmented)
        .help("Your energy today. Lower energy means a lighter plan.")
        .frame(width: 190)
    }
}

// MARK: - Now card

struct NowCard: View {
    @Environment(AppModel.self) private var model
    let block: PlannedBlock
    let isNow: Bool

    var body: some View {
        let activity = model.activity(block.activityID)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(isNow ? "Now" : "Up next · \(block.start.formatted(date: .omitted, time: .shortened))",
                      systemImage: block.bucket?.icon ?? "circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(block.tint)
                Spacer()
                if block.isPrimary { Tag(text: "Primary focus", icon: "scope", color: block.tint) }
                if block.isPinned { Tag(text: "Pinned", icon: "pin.fill", color: .orange) }
                if block.isOptional { Tag(text: "Optional", color: .secondary) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(block.title).font(.system(size: 28, weight: .bold, design: .rounded))
                HStack(spacing: 10) {
                    Text(Fmt.minutes(block.minutes))
                    if let a = activity, a.hasTwoPhaseTimer {
                        Text("· \(a.attemptMinutes) + \(a.reviewMinutes)")
                    }
                }
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button { model.start(block) } label: { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .tint(block.tint)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [.command])
                Button { model.complete(block) } label: { Label("Done", systemImage: "checkmark") }
                    .controlSize(.large)
                    .keyboardShortcut("d", modifiers: [.command])
                    .help("Mark as done (⌘D)")
                    .fixedSize()
                Spacer()
                Menu {
                    SwapMenuItems(block: block)
                } label: {
                    Label("Swap", systemImage: "arrow.triangle.2.circlepath")
                }
                .fixedSize()
                .help("Do something else instead")
                Menu {
                    ForEach(DoLaterOption.allCases) { o in
                        Button(o.title) { model.doLater(block, o) }
                    }
                } label: {
                    Label("Later", systemImage: "clock.arrow.circlepath")
                }
                .fixedSize()
                Button { model.skip(block) } label: { Label("Skip", systemImage: "forward") }
                    .fixedSize()
                    .help("Not today — no penalty")
            }
        }
        .padding(22)
        .background(
            LinearGradient(colors: [block.tint.opacity(0.16), block.tint.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(block.tint.opacity(0.25)))
    }
}

struct SleepingCard: View {
    @Environment(AppModel.self) private var model
    let since: Date

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Resting", systemImage: "moon.zzz.fill")
                    .font(.title3.weight(.semibold))
                Text("Since \(since.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                HStack {
                    Button {
                        model.showWakeSheet = true
                    } label: {
                        Label("I'm awake", systemImage: "sun.horizon.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button("I didn't sleep") { model.cancelSleep() }
                        .controlSize(.large)
                }
            }
        }
    }
}

struct EmptyDayCard: View {
    @Environment(AppModel.self) private var model
    let hasActivities: Bool

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 8) {
                Label(hasActivities ? "Nothing more suggested today" : "No activities yet",
                      systemImage: hasActivities ? "moon.stars" : "tray")
                    .font(.title3.weight(.semibold))
                Text(hasActivities
                     ? "Rest, or keep going with anything you like. It all counts."
                     : "Add a few activities to your buckets and Momentum will suggest a gentle plan.")
                    .foregroundStyle(.secondary)
                if hasActivities {
                    StartAnythingMenu(title: "Start Something")
                        .buttonStyle(.borderedProminent)
                }
                if !hasActivities {
                    Button("Open Activities") { model.screen = .buckets }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct PriorityRow: View {
    @Environment(AppModel.self) private var model
    let blocks: [PlannedBlock]

    var body: some View {
        let b = blocks[0]
        let total = blocks.reduce(0) { $0 + $1.minutes }
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(b.tint).frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(b.title).font(.body.weight(.medium))
                Text(blocks.count > 1
                     ? "\(blocks.count) sessions · \(Fmt.minutes(total)) · from \(b.start.formatted(date: .omitted, time: .shortened))"
                     : "\(Fmt.minutes(total)) · \(b.start.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Start") { model.start(b) }.controlSize(.small)
            BlockActionsMenu(block: b)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct BlockActionsMenu: View {
    @Environment(AppModel.self) private var model
    let block: PlannedBlock

    var body: some View {
        Menu {
            Button("Start") { model.start(block) }
            Button("Mark Done") { model.complete(block) }
            Divider()
            Menu("Swap for…") { SwapMenuItems(block: block) }
            Menu("Do Later") {
                ForEach(DoLaterOption.allCases) { o in Button(o.title) { model.doLater(block, o) } }
            }
            Button("Skip Today") { model.skip(block) }
            if let id = block.activityID {
                Divider()
                Button("Edit Activity…") { model.editor = .edit(id) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions for \(block.title)")
    }
}

// MARK: - Timer

struct TimerCard: View {
    @Environment(AppModel.self) private var model
    let session: RunningSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            TimerFace(session: session, now: ctx.date)
        }
    }
}

private struct TimerFace: View {
    @Environment(AppModel.self) private var model
    let session: RunningSession
    let now: Date

    enum Phase: Equatable { case work, attempt, review, overtime }

    var body: some View {
        let elapsed = session.activeSeconds(at: now)
        let (phase, remaining, fraction) = compute(elapsed)
        let tint = session.isPaused ? Color.secondary : session.bucket.color

        HStack(spacing: 28) {
            ZStack {
                Circle().stroke(tint.opacity(0.15), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(phase == .review ? Color.purple : tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: fraction)
                VStack(spacing: 2) {
                    Text(phase == .overtime ? "+" + Fmt.clock(-remaining) : Fmt.clock(remaining))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(session.isPaused ? "paused" : label(phase)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, height: 160)

            VStack(alignment: .leading, spacing: 12) {
                Text(session.title).font(.title.bold())
                if session.isTwoPhase {
                    HStack(spacing: 8) {
                        PhasePill(title: "Attempt · \(session.attemptMinutes) min", active: phase == .attempt, done: phase != .attempt, color: tint)
                        PhasePill(title: "Review · \(session.reviewMinutes) min", active: phase == .review, done: phase == .overtime, color: .purple)
                    }
                    Text(hint(phase)).font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(session.isPaused ? "Paused. Paused time doesn't count." :
                            phase == .overtime ? "Planned time is up — finish when you're ready." : "Stay with it. You can stop any time.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button { model.completeRunning() } label: { Label(model.runningIsOneOffErrand ? "Done" : "Complete", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.large)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .help(model.runningIsOneOffErrand ? "Errand done: tick it off (⌘↩)" : "Complete (⌘↩)")
                    if model.runningIsOneOffErrand {
                        Button { model.completeRunning(finished: false) } label: { Label("Stop", systemImage: "stop.fill") }
                            .controlSize(.large)
                            .help("Not finished yet: keep the time, leave the errand on your list")
                    }
                    Button { model.togglePauseTimer() } label: {
                        Image(systemName: session.isPaused ? "play.fill" : "pause.fill").frame(width: 18)
                    }
                    .accessibilityLabel(session.isPaused ? "Resume" : "Pause")
                    .controlSize(.large)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .help(session.isPaused ? "Resume (⇧⌘P)" : "Pause (⇧⌘P)")
                    if session.isTwoPhase && phase == .attempt && !session.isPaused {
                        Button("Review solution now") { model.startReview() }
                            .controlSize(.large)
                    }
                    Button("Cancel", role: .cancel) { model.cancelTimer() }
                        .controlSize(.large)
                        .keyboardShortcut(.escape, modifiers: [])
                }
                .fixedSize()
            }
            Spacer()
        }
        .padding(22)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(session.isPaused ? 0.85 : 1)
        .onChange(of: phase) { _, _ in NSSound(named: "Glass")?.play() }
    }

    private func compute(_ elapsed: TimeInterval) -> (Phase, TimeInterval, Double) {
        if session.isTwoPhase {
            let attempt = Double(session.attemptMinutes) * 60
            let review = Double(session.reviewMinutes) * 60
            let reviewStart = session.reviewStartActive
                ?? session.reviewStartedAt.map { $0.timeIntervalSince(session.startedAt) } ?? attempt
            if elapsed < reviewStart {
                return (.attempt, reviewStart - elapsed, elapsed / max(reviewStart, 1))
            }
            let inReview = elapsed - reviewStart
            if inReview < review {
                return (.review, review - inReview, inReview / review)
            }
            return (.overtime, review - inReview, 1)
        }
        let total = Double(session.plannedMinutes) * 60
        if elapsed < total { return (.work, total - elapsed, elapsed / max(total, 1)) }
        return (.overtime, total - elapsed, 1)
    }

    private func label(_ p: Phase) -> String {
        switch p {
        case .work: "remaining"
        case .attempt: "attempt"
        case .review: "review"
        case .overtime: "over time"
        }
    }

    private func hint(_ p: Phase) -> String {
        switch p {
        case .attempt: "Try the problem on your own. The review phase starts automatically."
        case .review: "Read the solution and note one idea to remember."
        case .overtime: "Planned time is up. Extra time still counts — finish when you're ready."
        case .work: ""
        }
    }
}

private struct PhasePill: View {
    let title: String
    let active: Bool
    let done: Bool
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: done && !active ? "checkmark.circle.fill" : active ? "circle.inset.filled" : "circle")
            Text(title)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(active ? color.opacity(0.2) : Color.secondary.opacity(0.1), in: Capsule())
        .foregroundStyle(active ? color : .secondary)
    }
}

// MARK: - Progress & bonus

struct ProgressCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let wins = model.winsToday
        let remaining = model.baselineRemaining
        let total = wins + remaining
        let fraction = total == 0 ? 0 : Double(wins) / Double(total)
        let complete = remaining == 0 && wins > 0
        SectionCard {
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(Color.green.opacity(0.15), lineWidth: 7)
                    Circle().trim(from: 0, to: fraction)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.spring, value: fraction)
                    Image(systemName: complete ? "star.fill" : "checkmark")
                        .foregroundStyle(complete ? .yellow : .green)
                        .symbolEffect(.bounce, value: complete)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(complete ? "Good day" : "\(wins) done")
                        .font(.headline)
                    if !complete && remaining > 0 {
                        Text("\(remaining) to go").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                let done = model.todaySessions.filter { $0.outcome == .completed && !$0.isProgress }
                HStack(spacing: -6) {
                    ForEach(done.suffix(6)) { s in
                        Circle().fill(s.bucket.color).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                            .help(s.activityName)
                    }
                }
            }
        }
    }
}

struct BonusSection: View {
    @Environment(AppModel.self) private var model
    let ideas: [UUID]
    let optional: [PlannedBlock]
    var showTitle = true

    var body: some View {
        // One chip per activity, even if it has several optional sessions.
        var seen = Set<UUID>()
        let optional = self.optional.filter { $0.activityID.map { seen.insert($0).inserted } ?? false }
        let activities = ideas.filter { !seen.contains($0) }.compactMap { model.activity($0) }
        VStack(alignment: .leading, spacing: 8) {
            if showTitle { Text("Extras").font(.headline) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(optional.prefix(3)) { b in
                        BonusChip(title: b.title, subtitle: "Secondary · \(Fmt.minutes(b.minutes))", color: b.tint) { model.start(b) }
                    }
                    ForEach(activities) { a in
                        BonusChip(title: a.name, subtitle: "\(a.kind.title) · \(Fmt.minutes(a.preferredMinutes))", color: a.kind.color) {
                            model.startBonus(a.id)
                        }
                    }
                }
            }
        }
    }
}

private struct BonusChip: View {
    let title: String
    let subtitle: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").foregroundStyle(color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium))
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Full day

struct FullDayTimeline: View {
    @Environment(AppModel.self) private var model
    let plan: MomentumCore.DayPlan?

    var body: some View {
        let done = model.todaySessions.filter { $0.outcome == .completed }
        let blocks = plan?.blocks ?? []
        VStack(alignment: .leading, spacing: 0) {
            ForEach(done) { s in
                TimelineRow(time: s.start, title: s.activityName, detail: "Done · \(Fmt.minutes(s.minutes))",
                            color: s.bucket.color, icon: "checkmark.circle.fill", dimmed: true)
            }
            ForEach(DayPhase.allCases, id: \.self) { phase in
                let items = blocks.filter { $0.phase == phase || ($0.isFixed && $0.phase == phase) }
                if !items.isEmpty {
                    Text(phase.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, 10).padding(.bottom, 4)
                    ForEach(items) { b in
                        TimelineRow(time: b.start, title: b.title,
                                    detail: b.isFixed ? "Fixed · \(b.timeRange)" :
                                        ([Fmt.minutes(b.minutes)] + (b.isOptional ? ["optional"] : []) + b.reasons.prefix(2)).joined(separator: " · "),
                                    color: b.isFixed ? .gray : b.tint,
                                    icon: b.isFixed ? "lock.fill" : b.isPinned ? "pin.fill" : nil,
                                    dimmed: false)
                        .contextMenu {
                            if b.isFixed {
                                CommitmentMenu(id: b.commitmentID)
                            } else {
                                Button("Start") { model.start(b) }
                                Button("Mark Done") { model.complete(b) }
                                Menu("Swap for…") { SwapMenuItems(block: b) }
                                Button("Skip Today") { model.skip(b) }
                            }
                        }
                    }
                }
            }
            if blocks.isEmpty && done.isEmpty {
                Text("Nothing planned.").foregroundStyle(.secondary)
            }
        }
    }
}

private struct TimelineRow: View {
    let time: Date
    let title: String
    let detail: String
    let color: Color
    let icon: String?
    let dimmed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(time.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(dimmed ? 0.4 : 1)).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if let icon { Image(systemName: icon).font(.caption).foregroundStyle(color) }
                    Text(title).font(.callout.weight(.medium)).strikethrough(false)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
        .padding(.vertical, 5)
        .opacity(dimmed ? 0.65 : 1)
    }
}

// MARK: - Swap / set aside / start anything

/// "Let Momentum pick" plus every activity, the block's own kind first.
struct SwapMenuItems: View {
    @Environment(AppModel.self) private var model
    let block: PlannedBlock

    var body: some View {
        Button("Let Momentum Pick") { model.swap(block) }
        let all = model.startableActivities(excluding: block.activityID)
        let kind = block.bucket
        let same = all.filter { $0.kind == kind }
        let others = all.filter { $0.kind != kind }
        if !same.isEmpty {
            Section(kind?.title ?? "") {
                ForEach(same) { a in Button(a.name) { model.swap(block, with: a.id) } }
            }
        }
        if !others.isEmpty {
            Section("Other") {
                ForEach(others) { a in Button(a.name) { model.swap(block, with: a.id) } }
            }
        }
    }
}

/// Things skipped or swapped out today, with a way back in.
struct SetAsideRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.setAsideToday
        if !items.isEmpty {
            HStack(spacing: 8) {
                Text("Set aside today").font(.caption).foregroundStyle(.secondary)
                ForEach(items) { a in
                    Button { model.bringBack(a.id) } label: {
                        Label(a.name, systemImage: "arrow.uturn.backward")
                    }
                    .controlSize(.small)
                    .help("Put \(a.name) back in today's plan")
                }
            }
        }
    }
}

/// Start a session of anything, whether or not it's planned today.
struct StartAnythingMenu: View {
    @Environment(AppModel.self) private var model
    let title: String

    var body: some View {
        Menu {
            ForEach([BucketKind.mainWork, .hobby, .anchor, .errand], id: \.self) { kind in
                let items = kind == .errand ? model.openErrands : model.startableActivities().filter { $0.kind == kind }
                if !items.isEmpty {
                    Section(kind.title) {
                        ForEach(items) { a in Button(a.name) { model.startBonus(a.id) } }
                    }
                }
            }
        } label: {
            Label(title, systemImage: "play.circle")
        }
        .fixedSize()
    }
}

// MARK: - Time so far

/// What's actually been tracked: a ribbon of the day so far, sessions with exact times, and unlogged gaps.
struct TimeSoFarCard: View {
    @Environment(AppModel.self) private var model
    @State private var dayOffset = 0

    private enum Row: Identifiable {
        case entry(AppModel.TrackedEntry)
        case gap(DateInterval)
        var id: String {
            switch self {
            case .entry(let e): "e-\(e.id)"
            case .gap(let g): "g-\(g.start.timeIntervalSinceReferenceDate)"
            }
        }
        var start: Date {
            switch self {
            case .entry(let e): e.interval.start
            case .gap(let g): g.start
            }
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            content(now: ctx.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: dayOffset, to: model.planningDay)!
        let isToday = dayOffset == 0
        let entries = model.trackedEntries(on: day)
        let gaps = isToday ? model.untrackedGaps(now: now) : []
        let rows = (entries.map(Row.entry) + gaps.map(Row.gap)).sorted { $0.start < $1.start }
        let tracked = AppModel.unionDuration(entries.map(\.interval))
        let span: DateInterval? = {
            let first = entries.first?.interval.start
            let lo = isToday ? min(model.trackingDayStart, first ?? model.trackingDayStart) : first
            let hi = isToday ? now : entries.map(\.interval.end).max()
            guard let lo, let hi, hi > lo else { return nil }
            return DateInterval(start: lo, end: hi)
        }()

        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(isToday ? "Today so far" : day.formatted(.dateTime.weekday(.wide).day().month()),
                          systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                    Spacer()
                    Text("\(Fmt.minutes(Int(tracked / 60))) tracked").font(.callout).foregroundStyle(.secondary)
                    Button { dayOffset -= 1 } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless).help("Previous day")
                    Button { dayOffset += 1 } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless).disabled(isToday).help("Next day")
                }

                if let span {
                    Ribbon(span: span, entries: entries, gaps: gaps)
                        .frame(height: 14)
                    HStack {
                        Text(TimeOfDay.short(span.start))
                        Spacer()
                        Text(isToday ? "now" : TimeOfDay.short(span.end))
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                }

                if rows.isEmpty {
                    Text(isToday ? "Nothing tracked yet." : "Nothing tracked that day.").font(.callout).foregroundStyle(.tertiary)
                }
                ForEach(rows) { row in
                    switch row {
                    case .entry(let e): EntryRow(entry: e)
                    case .gap(let g): GapRow(gap: g, isLatest: abs(g.end.timeIntervalSince(now)) < 90)
                    }
                }
            }
        }
    }

    private struct Ribbon: View {
        let span: DateInterval
        let entries: [AppModel.TrackedEntry]
        let gaps: [DateInterval]

        var body: some View {
            GeometryReader { g in
                let w = g.size.width
                let x = { (d: Date) -> CGFloat in CGFloat(d.timeIntervalSince(span.start) / span.duration) * w }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    ForEach(gaps, id: \.start) { gap in
                        Rectangle()
                            .fill(Color.orange.opacity(0.25))
                            .frame(width: max(1, x(gap.end) - x(gap.start)))
                            .offset(x: x(gap.start))
                    }
                    ForEach(entries) { e in
                        Rectangle()
                            .fill(e.isAppointment ? Color.appointment.opacity(0.7) : e.kind.color.opacity(e.isRunning ? 0.6 : 0.9))
                            .frame(width: max(2, x(e.interval.end) - x(e.interval.start)))
                            .offset(x: x(e.interval.start))
                    }
                }
                .clipShape(Capsule())
            }
        }
    }

    private struct EntryRow: View {
        @Environment(AppModel.self) private var model
        let entry: AppModel.TrackedEntry

        var body: some View {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(entry.isAppointment ? Color.appointment : entry.kind.color).frame(width: 4, height: 28)
                Text("\(TimeOfDay.short(entry.interval.start)) – \(entry.ongoing ? "now" : TimeOfDay.short(entry.interval.end))")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 150, alignment: .leading)
                Text(entry.name).font(.callout.weight(.medium)).lineLimit(1)
                if entry.isAppointment {
                    Image(systemName: "calendar").font(.caption).foregroundStyle(.secondary).help("Appointment")
                }
                Spacer()
                Text(entry.ongoing ? "running" : Fmt.minutes(Int((entry.interval.duration / 60).rounded())))
                    .font(.callout).foregroundStyle(.secondary)
                if let id = entry.appointmentID {
                    Menu {
                        Button("Edit Appointment…") { model.editCommitment(id) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                } else if let id = entry.sessionID {
                    Menu {
                        Button("Edit Times…") { model.editingSessionID = id; model.showSessionEditor = true }
                        Button("Delete", role: .destructive) { model.deleteSession(id) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            .contentShape(Rectangle())
            .contextMenu {
                if let id = entry.appointmentID {
                    Button("Edit Appointment…") { model.editCommitment(id) }
                } else if let id = entry.sessionID {
                    Button("Edit Times…") { model.editingSessionID = id; model.showSessionEditor = true }
                    Button("Delete", role: .destructive) { model.deleteSession(id) }
                }
            }
        }
    }

    private struct GapRow: View {
        @Environment(AppModel.self) private var model
        let gap: DateInterval
        let isLatest: Bool

        var body: some View {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).strokeBorder(Color.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: 4, height: 28)
                Text("\(TimeOfDay.short(gap.start)) – \(isLatest ? "now" : TimeOfDay.short(gap.end))")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 150, alignment: .leading)
                Text("Not logged").font(.callout).foregroundStyle(.orange)
                Spacer()
                Text(Fmt.minutes(Int(gap.duration / 60))).font(.callout).foregroundStyle(.secondary)
                Button("Log…") {
                    model.logActivityID = nil
                    // The latest gap is exactly "since last session"; earlier ones open as a custom range.
                    if !isLatest { model.logPrefill = (Int(gap.duration / 60), gap.end) }
                    model.showLogTime = true
                }
                .controlSize(.small)
                .disabled(isLatest && model.running != nil)
            }
        }
    }
}
