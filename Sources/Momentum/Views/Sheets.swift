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
    @State private var minutes = 60
    @State private var ended = Date.now

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
                DurationField(title: "How long", minutes: $minutes, range: 5...(12 * 60), step: 15)
                DatePicker("Finished at", selection: $ended, in: ...Date.now, displayedComponents: [.date, .hourAndMinute])
                HStack {
                    Button("Just now") { ended = .now }
                    Button("An hour ago") { ended = .now.addingTimeInterval(-3600) }
                }
                .controlSize(.small)
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Log it") {
                    if let id = activityID { model.logTime(id, minutes: minutes, endedAt: ended) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(activityID == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { activityID = model.logActivityID ?? model.todayPlan?.primaryActivityID }
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
