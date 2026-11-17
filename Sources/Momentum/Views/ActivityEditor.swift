import MomentumCore
import SwiftUI

/// Editable copy of an activity. Most numbers are derived (auto-balance); only what you can't infer is asked.
struct ActivityDraft: Equatable {
    var name = ""
    var bucket: BucketKind = .mainWork
    var minMinutes = 25
    var preferredMinutes = 50
    /// Derive how often / how important from rank. Off = "Set amount manually".
    var autoBalance = true
    /// Manual weekly target, or an errand's repeat.
    var sessionsPerWeek = 3
    var maxSessionsPerDay = 2
    var priority = 3
    var enjoyment = 3
    var hasDeadline = false
    var deadline = Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now
    var hasEstimate = false
    var estimateMinutes = 5 * 60
    private var originalEstimate: Int?
    var minRestHours = 0.0
    var notes = ""
    var twoPhaseTimer = false
    var attemptMinutes = 15
    var reviewMinutes = 5
    private var isKeystone = false
    private var isPaused = false
    private var createdAt = Date.now

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var remainingMinutes: Int? { hasDeadline && hasEstimate && bucket == .mainWork ? estimateMinutes : nil }

    init(bucket: BucketKind) {
        self.bucket = bucket
        applyDefaults(for: bucket)
    }

    /// Sensible per-kind session lengths; everything else is derived.
    mutating func applyDefaults(for kind: BucketKind) {
        switch kind {
        case .anchor: minMinutes = 10; preferredMinutes = 15; sessionsPerWeek = 7; maxSessionsPerDay = 1
        case .mainWork: minMinutes = 25; preferredMinutes = 50; sessionsPerWeek = 4; maxSessionsPerDay = 2
        case .hobby: minMinutes = 20; preferredMinutes = 30; sessionsPerWeek = 3; maxSessionsPerDay = 1
        case .errand: minMinutes = 5; preferredMinutes = 15; sessionsPerWeek = 0; maxSessionsPerDay = 1
        }
    }

    init(_ a: Activity, remainingWork: Int? = nil) {
        if let r = remainingWork {
            hasEstimate = true
            estimateMinutes = r
            originalEstimate = r
        }
        name = a.name
        bucket = a.kind
        priority = a.priority
        minMinutes = a.minMinutes
        preferredMinutes = a.preferredMinutes
        autoBalance = a.autoBalance
        sessionsPerWeek = a.sessionsPerWeek
        maxSessionsPerDay = a.maxSessionsPerDay
        hasDeadline = a.deadline != nil
        deadline = a.deadline ?? deadline
        isKeystone = a.isKeystone
        isPaused = a.isPaused
        createdAt = a.createdAt
        minRestHours = a.minRestHours
        enjoyment = a.enjoyment
        notes = a.notes
        twoPhaseTimer = a.hasTwoPhaseTimer
        attemptMinutes = a.attemptMinutes > 0 ? a.attemptMinutes : 15
        reviewMinutes = a.reviewMinutes > 0 ? a.reviewMinutes : 5
    }

    private var sessionMinutes: (min: Int, preferred: Int) {
        if twoPhaseTimer && bucket == .anchor {
            let p = attemptMinutes + reviewMinutes
            return (min(minMinutes, p), p)
        }
        return (min(minMinutes, preferredMinutes), max(preferredMinutes, minMinutes))
    }

    /// The scheduler's view of this draft, for previews.
    func spec(id: UUID, sortIndex: Int) -> ActivitySpec {
        let m = sessionMinutes
        return ActivitySpec(id: id, name: trimmedName, bucket: bucket, priority: priority, minMinutes: m.min, preferredMinutes: m.preferred,
                            sessionsPerWeek: sessionsPerWeek, deadline: hasDeadline ? Calendar.current.startOfDay(for: deadline) : nil,
                            isKeystone: bucket == .anchor, isPaused: isPaused, minRestHours: minRestHours,
                            maxSessionsPerDay: maxSessionsPerDay, enjoyment: enjoyment, sortIndex: sortIndex,
                            createdAt: createdAt, remainingWorkMinutes: remainingMinutes)
    }

    func apply(to a: Activity) {
        a.name = trimmedName
        let m = sessionMinutes
        a.minMinutes = m.min
        a.preferredMinutes = m.preferred
        if twoPhaseTimer && bucket == .anchor {
            a.attemptMinutes = attemptMinutes
            a.reviewMinutes = reviewMinutes
        } else {
            a.attemptMinutes = 0
            a.reviewMinutes = 0
        }
        a.autoBalance = true
        // Shares come from rank; only an errand's repeat (and a habit's frequency) is stored.
        if bucket == .errand {
            if let t = a.weeklyTarget { t.sessionsPerWeek = sessionsPerWeek } else { a.weeklyTarget = WeeklyTarget(sessionsPerWeek: sessionsPerWeek) }
            a.maxSessionsPerDay = maxSessionsPerDay
            a.priority = priority
            a.enjoyment = enjoyment
        }
        a.deadline = hasDeadline ? Calendar.current.startOfDay(for: deadline) : nil
        if let r = remainingMinutes {
            // Only restart the countdown when the number was actually changed.
            if originalEstimate != r || a.estimatedWorkMinutes == nil {
                a.estimatedWorkMinutes = r
                a.estimateSetAt = .now
            }
        } else {
            a.estimatedWorkMinutes = nil
            a.estimateSetAt = nil
        }
        a.minRestHours = bucket == .errand ? 0 : minRestHours
        a.notes = notes
    }
}

struct ActivityEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: EditorTarget
    @State private var draft = ActivityDraft(bucket: .mainWork)
    @State private var loaded = false
    @State private var confirmDelete = false
    @State private var overrideRequest: OverrideRequest?
    @State private var showMore = false
    @State private var impact: [String] = []
    @FocusState private var nameFocused: Bool

    private var editingID: UUID? {
        if case .edit(let id) = target { return id }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: draft.bucket.icon).foregroundStyle(draft.bucket.color)
                Text(editingID == nil ? "New \(draft.bucket.singular.lowercased())" : "Edit \(draft.bucket.singular.lowercased())")
                    .font(.title2.bold())
                Spacer()
            }
            .padding([.horizontal, .top], 22)

            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text(namePrompt))
                        .focused($nameFocused)
                    Picker("Kind", selection: Binding(get: { draft.bucket }, set: { k in
                        if editingID == nil { draft.applyDefaults(for: k) }
                        draft.bucket = k
                    })) {
                        ForEach(BucketKind.allCases) { Text($0.singular).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                if draft.bucket == .errand {
                    Section {
                        Picker("Repeats", selection: $draft.sessionsPerWeek) {
                            Text("Just once").tag(0)
                            Text("Weekly").tag(1)
                            Text("Twice a week").tag(2)
                            Text("Every other day").tag(3)
                            Text("Daily").tag(7)
                        }
                        deadlineRows(withEstimate: false)
                    }
                } else if draft.bucket == .mainWork {
                    Section {
                        deadlineRows(withEstimate: true)
                    }
                }

                if draft.bucket != .errand {
                    Section("This week") {
                        if let id = editingID, let a = model.activity(id), let allot = model.allotment(for: a) {
                            Label(allot.reason, systemImage: "list.number").font(.callout)
                        }
                        ForEach(impact, id: \.self) { line in
                            Label(line, systemImage: "arrow.turn.down.right").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    DisclosureGroup("More options", isExpanded: $showMore) {
                        moreOptions
                    }
                }

                Section("Notes") {
                    TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(2...5)
                }

                if let id = editingID {
                    OverridesSection(activityID: id, request: $overrideRequest)
                }
            }
            .formStyle(.grouped)

            HStack {
                if let id = editingID {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                        .confirmationDialog("Delete \(draft.trimmedName)?", isPresented: $confirmDelete) {
                            Button("Delete", role: .destructive) { model.deleteActivity(id); dismiss() }
                        } message: {
                            Text("Past sessions stay in your history.")
                        }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editingID == nil ? "Add" : "Save") {
                    if let id = editingID { model.updateActivity(id, with: draft) } else { model.addActivity(draft) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmedName.isEmpty)
            }
            .padding(18)
        }
        .frame(width: 520, height: 640)
        .sheet(item: $overrideRequest) { OverrideSheet(request: $0) }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            switch target {
            case .new(let kind):
                draft = ActivityDraft(bucket: kind)
                nameFocused = true
            case .edit(let id):
                if let a = model.activity(id) { draft = ActivityDraft(a, remainingWork: model.remainingWork(a)) }
            }
        }
        // Simulate the week with this draft (debounced while typing).
        .task(id: draft) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, draft.bucket != .errand else { return }
            impact = model.previewImpact(of: draft, editing: editingID)
        }
    }

    private var namePrompt: String {
        switch draft.bucket {
        case .anchor: "e.g. One LeetCode question"
        case .mainWork: "e.g. Thesis"
        case .hobby: "e.g. Guitar"
        case .errand: "e.g. Groceries"
        }
    }

    @ViewBuilder
    private func deadlineRows(withEstimate: Bool) -> some View {
        Toggle("Has a deadline", isOn: $draft.hasDeadline)
        if draft.hasDeadline {
            DatePicker("Due", selection: $draft.deadline, displayedComponents: .date)
            if withEstimate {
                Toggle("I know roughly how much work is left", isOn: $draft.hasEstimate)
                if draft.hasEstimate {
                    DurationField(title: "Work left", minutes: $draft.estimateMinutes, bareUnit: .hours,
                                  range: 15...20_000, step: 60, help: "Type hours, e.g. 6 or 6h or 6h30")
                    Text(estimateHint).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var moreOptions: some View {
        if draft.bucket == .anchor {
            Toggle("Two-phase timer (attempt, then review)", isOn: $draft.twoPhaseTimer)
        }
        if draft.twoPhaseTimer && draft.bucket == .anchor {
            DurationField(title: "Attempt", minutes: $draft.attemptMinutes, range: 1...120)
            DurationField(title: "Review, up to", minutes: $draft.reviewMinutes, range: 1...60, step: 1)
        } else {
            DurationField(title: "Session length", minutes: $draft.preferredMinutes, range: 5...480)
            DurationField(title: "Shortest worthwhile", minutes: $draft.minMinutes, range: 5...480)
        }
        if draft.bucket != .errand {
            DurationField(title: "Rest between sessions", minutes: Binding(get: { Int(draft.minRestHours * 60) },
                                                                          set: { draft.minRestHours = Double($0) / 60 }),
                          bareUnit: .hours, range: 0...(96 * 60), step: 240, help: "e.g. 40h for gym recovery. 0 for none.")
        }
    }

    /// "About 1h a day until Fri" — the pace this estimate implies.
    private var estimateHint: String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: draft.deadline)).day ?? 0
        let perDay = MainWorkPolicy.requiredPerDay(remaining: draft.estimateMinutes, daysLeft: days)
        return "≈ \(MainWorkPolicy.hm(Int(perDay.rounded()))) a day"
    }
}

/// Active Pin / Boost / Pause overrides for an activity, with quick actions.
struct OverridesSection: View {
    @Environment(AppModel.self) private var model
    let activityID: UUID
    @Binding var request: OverrideRequest?

    var body: some View {
        let _ = model.revision
        let items = model.overrides(for: activityID)
        Section("Overrides") {
            ForEach(items) { o in
                OverrideRow(o: o)
            }
            HStack {
                Button { request = OverrideRequest(activityID: activityID, kind: .boost) } label: { Label("Boost…", systemImage: "flame") }
                Button { request = OverrideRequest(activityID: activityID, kind: .pin) } label: { Label("Pin…", systemImage: "pin") }
                Button { request = OverrideRequest(activityID: activityID, kind: .pause) } label: { Label("Pause…", systemImage: "pause") }
            }
        }
    }
}

struct OverrideRow: View {
    @Environment(AppModel.self) private var model
    let o: SchedulingOverride
    var showName = false

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                if showName { Text(model.activity(o.activityID)?.name ?? "—").font(.callout.weight(.medium)) }
                Text(description).font(.callout).foregroundStyle(showName ? .secondary : .primary)
            }
            Spacer()
            Button { model.removeOverride(o) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove override")
        }
    }

    private var icon: String {
        switch o.kind {
        case .boost: "flame.fill"
        case .pin: "pin.fill"
        default: "pause.circle.fill"
        }
    }

    private var color: Color {
        switch o.kind {
        case .boost: .orange
        case .pin: .blue
        default: .gray
        }
    }

    private var description: String {
        let last = o.end.addingTimeInterval(-1)
        switch o.kind {
        case .boost:
            return "Boost ×\(String(format: "%.1f", o.factor)) through \(last.formatted(.dateTime.weekday(.wide).day().month()))"
        case .pin:
            let day = o.start.formatted(.dateTime.weekday(.wide).day().month())
            return o.pinnedTime.map { "Pinned \(day) at \($0.formatted(date: .omitted, time: .shortened))" } ?? "Pinned to \(day)"
        default:
            return "Paused — resumes \(o.end.formatted(.dateTime.weekday(.wide).day().month()))"
        }
    }
}
