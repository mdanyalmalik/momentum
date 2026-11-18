import MomentumCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                switch model.screen {
                case .today: TodayView()
                case .week: WeekView()
                case .buckets: BucketsView()
                case .plans: PlansView()
                case .stats: StatsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .top) { CelebrationOverlay() }
        .overlay(alignment: .bottom) { ImpactToast() }
        .sheet(item: $model.editor) { target in
            ActivityEditor(target: target)
        }
        .sheet(item: $model.overrideRequest) { req in
            OverrideSheet(request: req)
        }
        .sheet(isPresented: $model.showStartDay) {
            StartDaySheet()
        }
        .sheet(isPresented: $model.showBedtimeSheet) {
            BedtimeSheet()
        }
        .sheet(isPresented: $model.showWakeSheet) {
            WakeSheet()
        }
        .alert(model.notice ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        }
        .sheet(isPresented: $model.showLogTime, onDismiss: { model.logActivityID = nil }) {
            LogTimeSheet()
        }
        .sheet(isPresented: $model.showSessionEditor, onDismiss: { model.editingSessionID = nil }) {
            SessionEditSheet()
        }
        .sheet(isPresented: $model.showCommitmentSheet, onDismiss: { model.editingCommitmentID = nil }) {
            CommitmentSheet()
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingSheet()
                .interactiveDismissDisabled()
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.screen }, set: { if let s = $0 { model.screen = s } })) {
            Section {
                ForEach(Screen.allCases) { s in
                    Label(s.title, systemImage: s.icon).tag(s)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                UpdateAvailableButton()
                WeeklyMomentum()
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings (⌘,)")
            }
            .padding(12)
        }
    }
}

/// Shown when a newer build has been installed over the running app (scripts/install.sh).
/// Restarting is safe: a running timer is saved and picks up where it left off.
struct UpdateAvailableButton: View {
    @State private var launchedBinaryDate = UpdateAvailableButton.binaryDate()
    @State private var available = false
    private let tick = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if available {
                Button {
                    DataLocation.relaunch()
                } label: {
                    Label("Update installed — Restart", systemImage: "arrow.clockwise.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("A newer version of Momentum was installed. Restart to use it — a running timer is kept.")
            }
        }
        .onReceive(tick) { _ in
            if let d = Self.binaryDate(), let l = launchedBinaryDate, d > l { available = true }
        }
    }

    static func binaryDate() -> Date? {
        guard let url = Bundle.main.executableURL else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
    }
}

/// Weekly momentum indicator: dots for active days. Not a streak — gaps never reset anything.
struct WeeklyMomentum: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.revision
        let days = model.activeDaysThisWeek
        let active = days.filter { $0.wins > 0 }.count
        VStack(alignment: .leading, spacing: 6) {
            Text("This week").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                ForEach(days, id: \.day) { d in
                    VStack(spacing: 3) {
                        Circle()
                            .fill(d.wins > 0 ? Color.accentColor : Color.secondary.opacity(0.18))
                            .overlay {
                                if d.baseline {
                                    Image(systemName: "star.fill").font(.system(size: 6)).foregroundStyle(.white)
                                }
                            }
                            .frame(width: 14, height: 14)
                        Text(d.day.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .help("\(d.day.formatted(.dateTime.weekday(.wide))): \(d.wins) win\(d.wins == 1 ? "" : "s")")
                }
            }
            Text(active == 0 ? "Every week starts fresh." : "\(active) active day\(active == 1 ? "" : "s") — momentum building")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct CelebrationOverlay: View {
    @Environment(AppModel.self) private var model
    @State private var visible: Celebration?
    @State private var burst = false

    var body: some View {
        ZStack {
            if let c = visible {
                HStack(spacing: 12) {
                    ZStack {
                        ForEach(0..<8, id: \.self) { i in
                            Circle()
                                .fill([Color.orange, .pink, .green, .blue][i % 4])
                                .frame(width: 5, height: 5)
                                .offset(x: burst ? 22 : 0)
                                .rotationEffect(.degrees(Double(i) * 45))
                                .opacity(burst ? 0 : 1)
                        }
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.green)
                            .symbolEffect(.bounce, value: c.id)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title).font(.headline)
                        Text(c.message).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.top, 14)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.45), value: visible)
        .onChange(of: model.celebration) { _, new in
            guard let new else { return }
            burst = false
            visible = new
            withAnimation(.easeOut(duration: 0.7)) { burst = true }
            Task {
                try? await Task.sleep(for: .seconds(2.6))
                if visible?.id == new.id { visible = nil }
            }
        }
        .allowsHitTesting(false)
    }
}

struct OnboardingSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "arrow.up.forward.circle.fill")
                .font(.system(size: 44)).foregroundStyle(Color.accentColor)
            Text("Welcome to Momentum").font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 8) {
                Label("Add habits, projects, hobbies and errands. Rank them by dragging — Momentum works out the rest.", systemImage: "square.grid.3x1.below.line.grid.1x2")
                Label("Momentum suggests when to do it — around your wake time, energy and appointments.", systemImage: "wand.and.stars")
                Label("You can always override: pin, boost, pause, skip or move anything.", systemImage: "hand.raised")
                Label("Unfinished things never pile up as debt. Finishing the baseline is a good day.", systemImage: "heart")
            }
            .foregroundStyle(.secondary)
            HStack {
                Button("Start empty") { model.finishOnboarding(withSamples: false) }
                Spacer()
                Button("Start with examples") { model.finishOnboarding(withSamples: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 6)
        }
        .padding(28)
        .frame(width: 520)
    }
}


/// After reordering: what moved in the week, with Undo. Fades after a few seconds.
struct ImpactToast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let note = model.impactNote {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.title).font(.callout.weight(.semibold))
                    ForEach(note.lines, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 12)
                Button("Undo") { note.undo() }
                Button { model.impactNote = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(12)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 8, y: 2)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: note.id) {
                try? await Task.sleep(for: .seconds(8))
                if model.impactNote?.id == note.id { withAnimation { model.impactNote = nil } }
            }
        }
    }
}
