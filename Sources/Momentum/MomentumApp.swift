import AppKit
import MomentumCore
import SwiftData
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run`); harmless inside the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in Snapshotter.runIfRequested() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MomentumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        // A data-location change requested in Settings happens here, before the database opens.
        let moveMessage = DataLocation.applyPendingMove()
        let container: ModelContainer
        do {
            container = try MomentumSchema.makeContainer()
        } catch {
            NSLog("Momentum: could not open the store (\(error)). Falling back to in-memory storage.")
            container = try! MomentumSchema.makeContainer(inMemory: true)
        }
        let model = AppModel(container: container)
        model.notice = moveMessage
        _model = State(initialValue: model)
        Snapshotter.model = model
    }

    var body: some Scene {
        WindowGroup("Momentum", id: "main") {
            RootView()
                .environment(model)
                .modelContainer(model.container)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
        .commands { MomentumCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .modelContainer(model.container)
        }
    }
}

struct MomentumCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Activity") { model.screen = .buckets; model.editor = .new(.mainWork) }
                .keyboardShortcut("n")
            Button("New Appointment…") { model.newCommitment() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu("Plan") {
            Button("Start Day…") { model.screen = .today; model.showStartDay = true }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Log Time…") { model.logActivityID = nil; model.showLogTime = true }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Set Bedtime…") { model.screen = .today; model.showBedtimeSheet = true }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            // Decided at click time, so it's right even if the menu title is stale.
            Button(model.currentSleep == nil ? "Going to Sleep" : "I'm Awake…") {
                model.screen = .today
                if model.currentSleep == nil { model.goToSleep() } else { model.showWakeSheet = true }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Replan Now") { model.replan("Replanned manually") }
                .keyboardShortcut("r")
            Divider()
            Menu("Energy") {
                ForEach(EnergyLevel.allCases) { e in
                    Button(e.title) { model.setEnergy(e) }
                }
            }
        }
        CommandGroup(after: .sidebar) {
            ForEach(Array(Screen.allCases.enumerated()), id: \.element) { i, s in
                Button(s.title) { model.screen = s }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
            Divider()
        }
    }
}
