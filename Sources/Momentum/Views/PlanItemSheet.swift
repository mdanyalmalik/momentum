import MomentumCore
import SwiftUI

/// Week view: put something on a day yourself. Fixed = this exact time and length, everything else is
/// planned around it. Flexible = it stays on this day; its time and length give only if they must.
struct PlanItemSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: PlanItemDraft
    @State private var atTime = false
    @State private var time = Date.now

    init(draft: PlanItemDraft) {
        _draft = State(initialValue: draft)
        _atTime = State(initialValue: draft.time != nil || draft.fixed)
        _time = State(initialValue: draft.time
            ?? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: draft.day) ?? draft.day)
    }

    private var editing: Bool { draft.overrideID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(editing ? "Edit" : draft.replacing != nil ? "Change This Block" : "Add to \(draft.day.formatted(.dateTime.weekday(.wide)))",
                  systemImage: "calendar.day.timeline.left")
                .font(.title2.bold())
            Form {
                Picker("Activity", selection: $draft.activityID) {
                    ForEach([BucketKind.mainWork, .hobby, .anchor]) { kind in
                        Section(kind.title) {
                            ForEach(model.activities(in: kind)) { a in Text(a.name).tag(a.id) }
                        }
                    }
                }
                DatePicker("Day", selection: $draft.day, displayedComponents: .date)
                Toggle("At a set time", isOn: $atTime)
                    .disabled(draft.fixed)
                if atTime || draft.fixed {
                    DatePicker("Start", selection: $time, displayedComponents: .hourAndMinute)
                }
                Stepper(value: $draft.minutes, in: 15...720, step: 15) {
                    HStack {
                        Text("How long")
                        Spacer()
                        Text(Fmt.minutes(draft.minutes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker("", selection: $draft.fixed) {
                        Text("Flexible").tag(false)
                        Text("Fixed").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(draft.fixed
                         ? "Stays at exactly this time and length. Everything else is planned around it, like an appointment."
                         : "Stays on this day and keeps its length. If something fixed comes up, its time can shift — and if the day fills up completely, it moves to the next day rather than disappearing.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { model.planItemDraft = nil; dismiss() }.keyboardShortcut(.cancelAction)
                if editing {
                    Button("Let Momentum Decide") {
                        if let oid = draft.overrideID, let b = model.plan.allBlocks.first(where: { $0.overrideID == oid }) {
                            model.releaseBlock(b)
                        } else if let oid = draft.overrideID, let o = model.overrides.first(where: { $0.id == oid }) {
                            model.removeOverride(o)
                        }
                        model.planItemDraft = nil
                        dismiss()
                    }
                    .help("Forget this; Momentum plans the day as usual")
                }
                Spacer()
                Button(editing ? "Save" : draft.replacing != nil ? "Change" : "Add") {
                    var d = draft
                    d.time = (atTime || d.fixed) ? time : nil
                    model.savePlanItem(d)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
