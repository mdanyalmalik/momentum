import MomentumCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            SchedulingSettings().tabItem { Label("Scheduling", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 560, height: 620)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmErase = false
    @State private var pendingMove: URL?

    private var moveTitle: String {
        guard let to = pendingMove else { return "" }
        return DataLocation.hasExistingData(at: to) ? "Use the Momentum data in this folder?" : "Move your data here?"
    }

    private var moveMessage: String {
        guard let to = pendingMove else { return "" }
        let path = to.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if DataLocation.hasExistingData(at: to) {
            return "\(path) already has Momentum data. Momentum will restart and use it. Your current data stays where it is."
        }
        return "Momentum will restart and move everything to \(path). Avoid folders synced by iCloud or Dropbox if you use Momentum on more than one Mac at a time."
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where Momentum keeps your data and plan documents."
        panel.directoryURL = DataLocation.current.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url, url.standardizedFileURL != DataLocation.current.standardizedFileURL {
            pendingMove = url
        }
    }

    var body: some View {
        Form {
            Section("Your usual rhythm (used until you tell it otherwise)") {
                DatePicker("Usual wake time", selection: Binding(
                    get: { Calendar.current.date(byAdding: .minute, value: model.settings.defaultWakeMinutes, to: Calendar.current.startOfDay(for: .now))! },
                    set: { d in
                        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                        model.settings.defaultWakeMinutes = (c.hour ?? 8) * 60 + (c.minute ?? 0)
                        model.save()
                        model.replan("Default wake time changed")
                    }), displayedComponents: .hourAndMinute)
                DurationField(title: "Usually awake for", minutes: Binding(
                    get: { Int(model.settings.defaultAwakeHours * 60) },
                    set: { model.settings.defaultAwakeHours = Double($0) / 60; model.save(); model.replan("Default day length changed") }),
                    bareUnit: .hours, range: (8 * 60)...(20 * 60), step: 30)
            }
            Section("Data location") {
                LabeledContent("Everything is saved in") {
                    Text(DataLocation.current.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([DataLocation.current]) }
                    Button("Change…") { chooseLocation() }
                        .disabled(DataLocation.isOverriddenByEnvironment)
                    if DataLocation.current.standardizedFileURL != DataLocation.defaultDirectory.standardizedFileURL
                        && !DataLocation.isOverriddenByEnvironment {
                        Button("Use Default") { pendingMove = DataLocation.defaultDirectory }
                    }
                }
                if DataLocation.isOverriddenByEnvironment {
                    Text("Set by MOMENTUM_STORE_DIR for this run.").font(.caption).foregroundStyle(.orange)
                }
            }
            .confirmationDialog(moveTitle, isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } })) {
                Button("Move and Restart") {
                    if let to = pendingMove { DataLocation.requestMove(to: to); DataLocation.relaunch() }
                }
                Button("Cancel", role: .cancel) { pendingMove = nil }
            } message: {
                Text(moveMessage)
            }
            Section("Data") {
                LabeledContent("Storage", value: "Local only (SwiftData)")
                Button("Add Sample Activities") { model.loadSampleData() }
                Button("Erase All Data…", role: .destructive) { confirmErase = true }
                    .confirmationDialog("Erase all activities, history and plans?", isPresented: $confirmErase) {
                        Button("Erase", role: .destructive) { model.eraseAllData() }
                    }
            }
        }
        .formStyle(.grouped)
    }
}

/// Every weight in `SchedulerConfig`, grouped and explained. Changes replan immediately.
private struct SchedulingSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Capacity") {
                slider("Share of free time to plan", \.utilisationTarget, 0.3...0.9, 0.05, percent: true)
                durationField("Focus · low energy", \.mainWorkCapLow, 30...480, 15)
                durationField("Focus · normal energy", \.mainWorkCapNormal, 60...600, 15)
                durationField("Focus · high energy", \.mainWorkCapHigh, 60...720, 15)
                durationField("Hobby time · normal energy", \.hobbyBudgetNormal, 0...300, 15)
                durationField("Break between sessions", \.breakMinutes, 0...30, 5)
                durationField("Wind-down before sleep", \.windDownMinutes, 0...120, 15)
            }
            Section("Sharing") {
                slider("How much rank matters · projects", \.rankDecayMain, 0.3...1, 0.05,
                       help: "Each project gets this fraction of the one above it. 1 = everyone equal.")
                slider("How much rank matters · hobbies", \.rankDecayHobby, 0.3...1, 0.05)
                slider("Memory (days until past time counts half)", \.serviceHalfLifeDays, 1...14, 0.5)
                durationField("Stick with a project unless another is behind by", \.focusGranularityMinutesInt, 0...300, 15)
                slider("Hobby runs (sessions of stickiness)", \.hobbyGranularitySessions, 0...4, 0.5)
                intStepper("Projects per day", \.maxMainActivitiesPerDay, 1...4, 1)
                intStepper("Hobbies per evening", \.hobbiesPerDay, 0...3, 1)
            }
            Section("Boost") {
                slider("Default boost strength", \.defaultBoostFactor, 1.5...5, 0.5)
            }
            Section {
                Button("Restore Defaults") { model.config = .default }
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, _ key: WritableKeyPath<SchedulerConfig, Double>, _ range: ClosedRange<Double>,
                        _ step: Double, percent: Bool = false, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title) {
                Text(percent ? "\(Int((model.config[keyPath: key] * 100).rounded()))%" : String(format: "%.2f", model.config[keyPath: key]))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { model.config[keyPath: key] }, set: { var c = model.config; c[keyPath: key] = $0; model.config = c }),
                   in: range, step: step)
            if let help { Text(help).font(.caption).foregroundStyle(.tertiary) }
        }
    }

    private func binding(_ key: WritableKeyPath<SchedulerConfig, Int>) -> Binding<Int> {
        Binding(get: { model.config[keyPath: key] }, set: { var c = model.config; c[keyPath: key] = $0; model.config = c })
    }

    private func intStepper(_ title: String, _ key: WritableKeyPath<SchedulerConfig, Int>, _ range: ClosedRange<Int>, _ step: Int) -> some View {
        NumberField(title: title, value: binding(key), range: range)
    }

    private func durationField(_ title: String, _ key: WritableKeyPath<SchedulerConfig, Int>, _ range: ClosedRange<Int>, _ step: Int) -> some View {
        DurationField(title: title, minutes: binding(key), range: range, step: step)
    }
}
