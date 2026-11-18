import MomentumCore
import SwiftUI

// MARK: - Start Day

struct StartDaySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var wake = Date.now
    @State private var energy: EnergyLevel = .normal
    @State private var bedtime = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Start your day", systemImage: "sunrise.fill").font(.title2.bold())
            Form {
                DatePicker("I woke up at", selection: $wake, displayedComponents: .hourAndMinute)
                HStack {
                    Button("Just now") { wake = .now }
                    Button("An hour ago") { wake = .now.addingTimeInterval(-3600) }
                }
                .controlSize(.small)
                DatePicker("I'll probably sleep around", selection: $bedtime, displayedComponents: .hourAndMinute)
                Picker("Energy", selection: $energy) {
                    ForEach(EnergyLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Plan my day") {
                    model.startDay(wake: normalizedWake, energy: energy,
                                   bedtime: normalizedWake.addingTimeInterval(Double(awakeMinutes) * 60))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            if let r = model.todayRecord, let w = r.wake, model.hasStartedToday {
                wake = w
                energy = r.energy
            } else {
                wake = .now
            }
            bedtime = model.expectedBedtime ?? wake.addingTimeInterval(model.settings.defaultAwakeHours * 3600)
        }
    }

    /// The picker only edits the time; anchor it to today (or yesterday, if you woke before midnight).
    private var normalizedWake: Date { TimeOfDay.latest(wake, notAfter: .now.addingTimeInterval(3600)) }

    private var awakeMinutes: Int {
        let end = TimeOfDay.next(bedtime, after: max(normalizedWake.addingTimeInterval(1800), .now))
        return Int(end.timeIntervalSince(normalizedWake) / 60)
    }

    private var energyHint: String {
        switch energy {
        case .low: "A lighter day: shorter anchors and less focus time. Still counts."
        case .normal: "A balanced day with breaks and free time built in."
        case .high: "More room for focus — still with breaks and slack."
        }
    }
}

// MARK: - Sleep

/// Time pickers only edit hour and minute; these anchor the chosen time to a real date.
enum TimeOfDay {
    /// "4:07 pm", with the weekday if it isn't today.
    static func short(_ d: Date) -> String {
        Calendar.current.isDateInToday(d)
            ? d.formatted(date: .omitted, time: .shortened)
            : d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// The first occurrence of `time`'s clock time strictly after `ref`.
    static func next(_ time: Date, after ref: Date) -> Date {
        let cal = Calendar.current
        let t = cal.dateComponents([.hour, .minute], from: time)
        return cal.nextDate(after: ref, matching: DateComponents(hour: t.hour, minute: t.minute), matchingPolicy: .nextTime) ?? ref
    }

    /// The most recent occurrence of `time`'s clock time at or before `ref`.
    static func latest(_ time: Date, notAfter ref: Date) -> Date {
        let candidate = next(time, after: ref.addingTimeInterval(-86_400))
        return candidate <= ref ? candidate : candidate.addingTimeInterval(-86_400)
    }
}

struct BedtimeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var bedtime = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("When will you sleep next?", systemImage: "moon.zzz").font(.title2.bold())
            Form {
                DatePicker("I'll probably sleep around", selection: $bedtime, displayedComponents: .hourAndMinute)
                HStack {
                    ForEach([1, 2, 3, 5], id: \.self) { h in
                        Button("In \(h)h") { bedtime = .now.addingTimeInterval(Double(h) * 3600) }
                    }
                }
                .controlSize(.small)
                LabeledContent("That leaves", value: Fmt.minutes(Int(normalized.timeIntervalSinceNow / 60)))
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Update plan") { model.setBedtime(normalized) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { bedtime = model.expectedBedtime ?? .now.addingTimeInterval(4 * 3600) }
    }

    private var normalized: Date { TimeOfDay.next(bedtime, after: .now) }
}

struct WakeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var wake = Date.now
    @State private var bedtime = Date.now
    @State private var userChoseBedtime = false
    @State private var energy: EnergyLevel = .normal

    var body: some View {
        let sleep = model.currentSleep
        VStack(alignment: .leading, spacing: 16) {
            Label("Good to see you", systemImage: "sun.horizon.fill").font(.title2.bold())
            if let sleep {
                Text("Slept \(Fmt.minutes(sleptMinutes))")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                DatePicker("I woke up at", selection: $wake, displayedComponents: .hourAndMinute)
                HStack {
                    Button("Just now") { wake = .now }
                    Button("30 min ago") { wake = .now.addingTimeInterval(-1800) }
                    Button("An hour ago") { wake = .now.addingTimeInterval(-3600) }
                }
                .controlSize(.small)
                DatePicker("I'll probably sleep again around", selection: Binding(get: { bedtime }, set: { bedtime = $0; userChoseBedtime = true }),
                           displayedComponents: .hourAndMinute)
                Picker("Energy", selection: $energy) {
                    ForEach(EnergyLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            HStack {
                Button("Still sleeping") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("I didn't sleep") { model.cancelSleep(); dismiss() }
                Spacer()
                Button("I'm up") {
                    model.wakeUp(at: normalizedWake, bedtime: TimeOfDay.next(bedtime, after: max(normalizedWake, .now)), energy: energy)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            wake = .now
            energy = model.todayRecord?.energy ?? .normal
            refresh()
        }
        .onChange(of: wake) { refresh() }
    }

    private var normalizedWake: Date {
        let w = TimeOfDay.latest(wake, notAfter: .now)
        return max(w, model.currentSleep?.start ?? w)
    }

    private var sleptMinutes: Int {
        guard let s = model.currentSleep else { return 0 }
        return max(Int(normalizedWake.timeIntervalSince(s.start) / 60), 0)
    }

    private func refresh() {
        if !userChoseBedtime { bedtime = model.suggestedBedtime(wake: normalizedWake) }
    }
}

// MARK: - Log time

struct LogTimeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var activityID: UUID?
    @State private var sinceLast = true
    @State private var merge = true
    @State private var startPick = Date.now.addingTimeInterval(-3600)
    @State private var endIsNow = true
    @State private var endPick = Date.now
    @State private var keepRunning = false

    private var now: Date { .now }
    private var last: ActivitySession? { model.lastSessionToday }
    private var canMerge: Bool { sinceLast && last != nil && last?.activityID == activityID }
    private var merging: Bool { canMerge && merge }

    private var start: Date {
        if merging, let last { return last.start }
        return sinceLast ? model.sinceLastStart : AppModel.wholeMinute(startPick)
    }
    private var end: Date { (endIsNow || keeping) ? AppModel.wholeMinute(now) : AppModel.wholeMinute(min(endPick, now)) }
    private var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }

    private var canKeepRunning: Bool { model.running == nil && (endIsNow || now.timeIntervalSince(endPick) <= 120) }
    private var keeping: Bool { keepRunning && model.running == nil }

    private var conflicts: [(name: String, interval: DateInterval)] {
        model.logConflicts(start: start, end: end, ignoring: merging ? last?.id : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Log time", systemImage: "clock.badge.checkmark").font(.title2.bold())
            Form {
                Picker("For", selection: $activityID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach([BucketKind.mainWork, .anchor, .hobby]) { kind in
                        Section(kind.title) {
                            ForEach(model.activities(in: kind)) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                }

                Section {
                    DatePicker("Started at", selection: Binding(
                        get: { start },
                        set: { startPick = $0; sinceLast = false }
                    ), in: ...Date.now, displayedComponents: [.date, .hourAndMinute])
                    Toggle(isOn: $sinceLast) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Since last session")
                            Text(sinceLastDetail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    if canMerge, let last {
                        Toggle(isOn: $merge) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Merge into that \(last.activityName) session")
                                Text("One continuous session from \(TimeOfDay.short(last.start)), as if you never stopped")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.leading, 20)
                    }
                }

                Section {
                    DurationField(title: "How long", minutes: Binding(
                        get: { minutes },
                        set: { m in
                            endPick = min(start.addingTimeInterval(Double(m) * 60), .now)
                            endIsNow = false
                            keepRunning = false
                        }
                    ), range: 1...(16 * 60), step: 5, help: "Exact to the minute: 47, 1h07, 1:07 or 1.5h")
                    LabeledContent("Finished at") {
                        HStack {
                            if !endIsNow {
                                Button("Now") { endIsNow = true }.controlSize(.small)
                            }
                            DatePicker("Finished at", selection: Binding(
                                get: { end },
                                set: { endPick = $0; endIsNow = false; keepRunning = false }
                            ), in: ...Date.now, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .disabled(keeping)
                        }
                    }
                    Toggle(isOn: $keepRunning) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Keep the timer running")
                            Text(model.running != nil ? "A timer is already running"
                                 : "Count this and carry on from here as one live session")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!canKeepRunning)
                    .onChange(of: keepRunning) { _, on in if on { endIsNow = true } }
                }

                Section {
                    LabeledContent("Counts") {
                        Text("\(TimeOfDay.short(start)) – \(keeping ? "now, still going" : TimeOfDay.short(end)) · \(Fmt.minutes(minutes))")
                            .monospacedDigit()
                            .foregroundStyle(conflicts.isEmpty && minutes > 0 ? Color.secondary : Color.red)
                    }
                    if !conflicts.isEmpty {
                        ForEach(Array(conflicts.enumerated()), id: \.offset) { _, c in
                            Label("Overlaps \(c.name) · \(TimeOfDay.short(c.interval.start))–\(TimeOfDay.short(c.interval.end))",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                        Text("That time is already counted. Logged time can't overlap it.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let t = trimmedStart {
                            Button("Start after \(conflicts.last?.name ?? "it") ends: \(TimeOfDay.short(t)) – \(TimeOfDay.short(end)) · \(Fmt.minutes(Int(end.timeIntervalSince(t) / 60)))") {
                                startPick = t; sinceLast = false
                            }
                            .controlSize(.small)
                        } else if let fit = model.latestFreeEnd(minutes: max(1, minutes), notAfter: end) {
                            Button("End it before that: \(TimeOfDay.short(fit.addingTimeInterval(-Double(minutes) * 60))) – \(TimeOfDay.short(fit))") {
                                startPick = fit.addingTimeInterval(-Double(minutes) * 60); sinceLast = false
                                endPick = fit; endIsNow = false; keepRunning = false
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(keeping ? "Log & Keep Timer Running" : "Log It") {
                    guard let id = activityID else { return }
                    if model.logRange(id, start: start, end: end, mergeInto: merging ? last?.id : nil, keepRunning: keeping) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(activityID == nil || !conflicts.isEmpty || minutes < 1)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            activityID = model.logActivityID ?? last?.activityID ?? model.todayPlan?.primaryActivityID
            if let p = model.logPrefill {
                sinceLast = false
                endPick = p.ended; endIsNow = false
                startPick = p.ended.addingTimeInterval(-Double(p.minutes) * 60)
                model.logPrefill = nil
            }
        }
    }

    private var sinceLastDetail: String {
        if let last, model.sinceLastStart > model.trackingDayStart {
            return "From \(TimeOfDay.short(model.sinceLastStart)), when \(last.activityName) ended"
        }
        return "From \(TimeOfDay.short(model.sinceLastStart)), the start of your day"
    }

    /// For a clash: the first whole minute after the clashing time, if the finish time itself is free.
    /// Logging from there to the finish time counts only the untracked part.
    private var trimmedStart: Date? {
        guard let lastEnd = conflicts.map(\.interval.end).max(), lastEnd < end else { return nil }
        let up = AppModel.wholeMinute(lastEnd) < lastEnd ? AppModel.wholeMinute(lastEnd).addingTimeInterval(60) : lastEnd
        guard end.timeIntervalSince(up) >= 60, model.logConflicts(start: up, end: end).isEmpty else { return nil }
        return up
    }
}

// MARK: - Edit a recorded session

struct SessionEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date.now
    @State private var minutes = 30
    @State private var name = ""
    @State private var sessionID: UUID?

    private var end: Date { AppModel.wholeMinute(start).addingTimeInterval(Double(minutes) * 60) }
    private var conflicts: [(name: String, interval: DateInterval)] {
        model.logConflicts(start: AppModel.wholeMinute(start), end: end, ignoring: sessionID)
    }
    private var inFuture: Bool { end > Date.now.addingTimeInterval(60) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Edit \(name)", systemImage: "clock").font(.title2.bold())
            Form {
                DatePicker("Started", selection: $start, in: ...Date.now, displayedComponents: [.date, .hourAndMinute])
                DurationField(title: "How long", minutes: $minutes, range: 1...(16 * 60), step: 5)
                LabeledContent("Ends") {
                    Text(TimeOfDay.short(end)).monospacedDigit()
                        .foregroundStyle(conflicts.isEmpty && !inFuture ? Color.secondary : Color.red)
                }
                ForEach(Array(conflicts.enumerated()), id: \.offset) { _, c in
                    Label("Overlaps \(c.name) · \(TimeOfDay.short(c.interval.start))–\(TimeOfDay.short(c.interval.end))",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                if inFuture { Text("It can't end in the future.").foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    if let id = sessionID { model.deleteSession(id) }
                    dismiss()
                }
                Spacer()
                Button("Save") {
                    if let id = sessionID, model.updateSession(id, start: start, minutes: minutes) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(sessionID == nil || !conflicts.isEmpty || inFuture)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            guard let s = model.session(model.editingSessionID) else { return }
            sessionID = s.id; start = s.start; minutes = s.minutes; name = s.activityName
        }
    }
}

// MARK: - Appointments

struct CommitmentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var day = Date.now
    @State private var start = Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: .now) ?? .now
    @State private var end = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: .now) ?? .now
    @State private var editingID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(editingID == nil ? "New Appointment" : "Edit Appointment", systemImage: "calendar.badge.plus").font(.title2.bold())
            Form {
                TextField("Title", text: $title, prompt: Text("Dentist, interview, call…"))
                DatePicker("Day", selection: $day, displayedComponents: .date)
                DatePicker("From", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("To", selection: $end, displayedComponents: .hourAndMinute)
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if let id = editingID {
                    Button("Delete", role: .destructive) {
                        model.deleteCommitment(id: id)
                        dismiss()
                    }
                }
                Spacer()
                Button(editingID == nil ? "Add" : "Save") {
                    let s = combine(day, start), e0 = combine(day, end)
                    let e = e0 > s ? e0 : e0.addingTimeInterval(86_400)
                    let t = title.trimmingCharacters(in: .whitespaces)
                    if let id = editingID {
                        model.updateCommitment(id, title: t, start: s, end: e)
                    } else {
                        model.addCommitment(title: t, start: s, end: e)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            guard let c = model.commitment(model.editingCommitmentID) else { return }
            editingID = c.id
            title = c.title
            day = c.start
            start = c.start
            end = c.end
        }
    }

    private func combine(_ day: Date, _ time: Date) -> Date {
        let cal = Calendar.current
        let t = cal.dateComponents([.hour, .minute], from: time)
        return cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0, of: day) ?? day
    }
}

/// Right-click menu for an appointment, wherever it's shown.
struct CommitmentMenu: View {
    @Environment(AppModel.self) private var model
    let id: UUID?

    var body: some View {
        if let id {
            Button("Edit Appointment…") { model.editCommitment(id) }
            Button("Delete Appointment", role: .destructive) { model.deleteCommitment(id: id) }
        }
    }
}

// MARK: - Overrides (Pin / Boost / Pause)

struct OverrideSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: OverrideRequest
    @State private var kind: OverrideSpec.Kind = .boost
    @State private var days = 5
    @State private var factor = 2.5
    @State private var date = Date.now
    @State private var useTime = false
    @State private var time = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: .now) ?? .now

    var body: some View {
        let name = model.activity(request.activityID)?.name ?? "Activity"
        VStack(alignment: .leading, spacing: 16) {
            Text(name).font(.title2.bold())
            Picker("Override", selection: $kind) {
                Label("Boost", systemImage: "flame").tag(OverrideSpec.Kind.boost)
                Label("Pin", systemImage: "pin").tag(OverrideSpec.Kind.pin)
                Label("Pause", systemImage: "pause").tag(OverrideSpec.Kind.pause)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Form {
                switch kind {
                case .boost:
                    NumberField(title: "For", value: $days, range: 1...21,
                                unit: "day\(days == 1 ? "" : "s") · through \(endOfBoost.formatted(.dateTime.weekday(.wide)))")
                    VStack(alignment: .leading) {
                        Slider(value: $factor, in: 1.5...5, step: 0.5) { Text("Strength ×\(factor, specifier: "%.1f")") }
                        Text("Boosted work gets up to \(Int(model.settings.config.boostDailyShare * 100))% of focus time; lower-priority work is deferred. Balance resumes automatically afterwards.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .pin:
                    DatePicker("Day", selection: $date, in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date)
                    Toggle("At a specific time", isOn: $useTime)
                    if useTime {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    }
                    Text("Pins are hard constraints: the activity is placed on that day even if it's paused.")
                        .font(.caption).foregroundStyle(.secondary)
                default:
                    DatePicker("Resume on", selection: $date, in: Date.now..., displayedComponents: .date)
                    Text("Paused activities are excluded from scheduling until then. Nothing accumulates while paused.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") {
                    switch kind {
                    case .boost: model.addBoost(request.activityID, days: days, factor: factor)
                    case .pin: model.addPin(request.activityID, day: date, time: useTime ? time : nil)
                    default: model.addPause(request.activityID, until: date)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            kind = request.kind
            factor = model.settings.config.defaultBoostFactor
            if let d = request.day { date = d }
            else if kind == .pause { date = Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now }
        }
    }

    private var endOfBoost: Date {
        Calendar.current.date(byAdding: .day, value: days - 1, to: .now) ?? .now
    }
}
