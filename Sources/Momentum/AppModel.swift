import AppKit
import Foundation
import MomentumCore
import Observation
import SwiftData
import SwiftUI

enum Screen: String, Hashable, CaseIterable, Identifiable {
    case today, week, buckets, plans, stats
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: "Today"
        case .week: "Week"
        case .buckets: "Activities"
        case .plans: "Plans"
        case .stats: "Stats"
        }
    }
    var icon: String {
        switch self {
        case .today: "sun.max"
        case .week: "calendar"
        case .buckets: "square.grid.3x1.below.line.grid.1x2"
        case .plans: "doc.text"
        case .stats: "chart.bar.xaxis"
        }
    }
}

/// A timer the user started on a block (or an ad-hoc bonus activity).
struct RunningSession: Equatable, Codable {
    var blockID: String?
    var activityID: UUID
    var title: String
    var bucket: BucketKind
    var startedAt: Date
    var plannedMinutes: Int
    var attemptMinutes: Int
    var reviewMinutes: Int
    var reviewStartedAt: Date?
    var isBonus: Bool

    /// Set while paused. Paused time doesn't count.
    var pausedAt: Date?
    /// Total seconds spent paused before the current pause.
    var pausedSeconds: Double?
    /// Active seconds at the moment the review phase was started early.
    var reviewStartActive: Double?
    /// Minutes already done before the timer was started (logged and continued).
    var carriedMinutes: Int?

    var isTwoPhase: Bool { attemptMinutes > 0 && reviewMinutes > 0 }
    var inReview: Bool { reviewStartedAt != nil }
    var isPaused: Bool { pausedAt != nil }

    /// Seconds actually worked: wall-clock time since start, minus pauses.
    func activeSeconds(at now: Date = .now) -> TimeInterval {
        max(0, (pausedAt ?? now).timeIntervalSince(startedAt) - (pausedSeconds ?? 0))
    }
}

/// "Here's what that changed", with Undo. Shown after reordering.
struct ImpactNote: Identifiable {
    let id = UUID()
    let title: String
    let lines: [String]
    let undo: () -> Void
}

struct Celebration: Equatable, Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum DoLaterOption: String, CaseIterable, Identifiable {
    case inAnHour, thisEvening, tomorrow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .inAnHour: "In an hour"
        case .thisEvening: "This evening"
        case .tomorrow: "Tomorrow"
        }
    }
}

/// Editor presentation target.
enum EditorTarget: Identifiable, Equatable {
    case new(BucketKind)
    case edit(UUID)
    var id: String {
        switch self {
        case .new(let k): "new-\(k.rawValue)"
        case .edit(let id): id.uuidString
        }
    }
}

struct OverrideRequest: Identifiable, Equatable {
    let id = UUID()
    var activityID: UUID
    var kind: OverrideSpec.Kind
    var day: Date? = nil
}

/// The bridge between SwiftData (persistence) and MomentumCore (scheduling).
/// Every mutation goes through here and ends with `replan(_:)`, so the plan is always current.
@MainActor
@Observable
final class AppModel {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let calendar = Calendar.current

    private(set) var plan: WeekPlan
    /// What auto-balance derived for each activity in the last replan.
    private(set) var allotments: [UUID: Allotment] = [:]
    /// "Here's what that changed", shown briefly after a reorder (with Undo).
    var impactNote: ImpactNote?
    /// Which activity's documents the Plans screen shows.
    var planActivityID: UUID?
    /// Plans focus mode: just the document, full screen.
    var planFocus = false
    var sidebarVisibility: NavigationSplitViewVisibility = .automatic
    /// A one-off message to show (e.g. "Moved your data to …").
    var notice: String?
    /// "Log Time…": record work done outside the app (preselected activity, if any).
    var showLogTime = false
    var logActivityID: UUID?
    private(set) var revision = 0
    private(set) var lastReplanReason = "Opened Momentum"
    private(set) var settings: AppSettings
    private var currentDay: Date
    private var timer: Timer?

    // UI state
    var screen: Screen = .today
    /// The session in progress. Saved on every change, so quitting or a crash doesn't lose it:
    /// the timer is wall-clock based, so it simply carries on from `startedAt` after relaunch.
    var running: RunningSession? {
        didSet {
            guard running != oldValue else { return }
            settings.runningSession = running.flatMap { try? JSONEncoder().encode($0) }
            save()
        }
    }
    var celebration: Celebration?
    var editor: EditorTarget?
    var overrideRequest: OverrideRequest?
    var showStartDay = false
    var showBedtimeSheet = false
    var showWakeSheet = false
    var showCommitmentSheet = false
    /// The recorded session being edited (times or delete).
    var editingSessionID: UUID?
    var showSessionEditor = false
    /// Optional starting values for the Log Time sheet (minutes, finished at).
    var logPrefill: (minutes: Int, ended: Date)?
    /// Set when the appointment sheet is editing an existing appointment instead of adding one.
    var editingCommitmentID: UUID?
    var showOnboarding = false

    init(container: ModelContainer) {
        self.container = container
        self.currentDay = Calendar.current.startOfDay(for: .now)
        self.plan = WeekPlan(generatedAt: .now, days: [], notes: [])
        let ctx = container.mainContext
        if let s = try? ctx.fetch(FetchDescriptor<AppSettings>()).first {
            self.settings = s
        } else {
            let s = AppSettings()
            ctx.insert(s)
            self.settings = s
        }
        ensureBuckets()
        restoreRunningSession()
        currentDay = planningDay
        migrateNextSleepEstimate()
        adoptAutoBalanceIfNeeded()
        cleanUpExpiredOverrides()
        // Restore the last plan we showed, so replanning at launch is stable — unless an older engine made it.
        if settings.engineVersion == Self.engineVersion {
            self.plan = loadPersistedPlan() ?? plan
        } else {
            settings.engineVersion = Self.engineVersion
            save()
        }
        showOnboarding = !settings.hasOnboarded
        replan("Opened Momentum")
        startClock()
    }

    /// Bump when scheduling changes enough that old saved plans shouldn't steer new ones.
    static let engineVersion = 2

    var config: SchedulerConfig {
        get { settings.config }
        set {
            settings.config = newValue
            save()
            replan("Scheduling weights changed")
        }
    }

    // MARK: - Fetching

    func fetch<T: PersistentModel>(_ type: T.Type, _ descriptor: FetchDescriptor<T> = FetchDescriptor<T>()) -> [T] {
        (try? context.fetch(descriptor)) ?? []
    }

    var buckets: [Bucket] {
        fetch(Bucket.self, FetchDescriptor(sortBy: [SortDescriptor(\.sortIndex)]))
    }

    func bucket(_ kind: BucketKind) -> Bucket? {
        buckets.first { $0.kind == kind }
    }

    var activities: [Activity] {
        fetch(Activity.self, FetchDescriptor(sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.name)]))
    }

    func activities(in kind: BucketKind) -> [Activity] {
        activities.filter { $0.kind == kind }
    }

    func activity(_ id: UUID?) -> Activity? {
        guard let id else { return nil }
        return fetch(Activity.self, FetchDescriptor(predicate: #Predicate { $0.id == id })).first
    }

    /// Estimated work left: the estimate minus completed minutes since it was entered, as of `asOf`
    /// (default: now). The scheduler gets it as of the start of the logical day and counts today itself.
    func remainingWork(_ a: Activity, asOf: Date = .now) -> Int? {
        guard let estimate = a.estimatedWorkMinutes, a.deadline != nil else { return nil }
        let setAt = a.estimateSetAt ?? .distantPast
        let id = a.id
        let done = fetch(ActivitySession.self, FetchDescriptor(predicate: #Predicate { $0.activityID == id }))
            .filter { $0.outcome == .completed }
        let since = done.filter { $0.start >= setAt && $0.start < asOf }.reduce(0) { $0 + $1.minutes }
        // Work done between asOf and the moment the estimate was entered was already included in it.
        let alreadyCounted = done.filter { $0.start >= asOf && $0.start < setAt }.reduce(0) { $0 + $1.minutes }
        return max(0, estimate - since + alreadyCounted)
    }

    func sessions(from: Date, to: Date) -> [ActivitySession] {
        fetch(ActivitySession.self, FetchDescriptor(
            predicate: #Predicate { $0.start >= from && $0.start < to },
            sortBy: [SortDescriptor(\.start)]))
    }

    /// The logical day: a waking window that began yesterday and hasn't ended yet is still "today",
    /// so a night owl's plan doesn't reset at midnight.
    /// Days are calendar days: each 24 h has its own set of things to do.
    var planningDay: Date { calendar.startOfDay(for: .now) }

    var todaySessions: [ActivitySession] {
        let start = planningDay
        let end = max(calendar.date(byAdding: .day, value: 1, to: start)!, todayPlan?.windowEnd ?? start)
        return sessions(from: start, to: end)
    }

    var commitments: [FixedCommitment] {
        fetch(FixedCommitment.self, FetchDescriptor(sortBy: [SortDescriptor(\.start)]))
    }

    var overrides: [SchedulingOverride] {
        fetch(SchedulingOverride.self, FetchDescriptor(sortBy: [SortDescriptor(\.start)]))
    }

    var userOverrides: [SchedulingOverride] {
        let now = Date.now
        return overrides.filter { $0.isUserFacing && $0.end > now }
    }

    func overrides(for activityID: UUID) -> [SchedulingOverride] {
        userOverrides.filter { $0.activityID == activityID }
    }

    func dailyPlan(for day: Date, create: Bool = false) -> DailyPlan? {
        let d = calendar.startOfDay(for: day)
        if let existing = fetch(DailyPlan.self, FetchDescriptor(predicate: #Predicate { $0.day == d })).first {
            return existing
        }
        guard create else { return nil }
        let p = DailyPlan(day: d)
        p.awakeHours = settings.defaultAwakeHours
        context.insert(p)
        return p
    }

    var todayRecord: DailyPlan? { dailyPlan(for: planningDay) }
    /// You've told us you're up today (woke since midnight).
    var hasStartedToday: Bool { todayRecord?.wake.map { $0 >= planningDay } ?? false }
    var todayPlan: MomentumCore.DayPlan? { plan.days.first }

    func completionHistory(for day: Date, create: Bool = false) -> CompletionHistory? {
        let d = calendar.startOfDay(for: day)
        if let existing = fetch(CompletionHistory.self, FetchDescriptor(predicate: #Predicate { $0.day == d })).first {
            return existing
        }
        guard create else { return nil }
        let h = CompletionHistory(day: d)
        context.insert(h)
        return h
    }

    /// Completed sessions in the rolling 7 days ending today.
    func completedThisWeek(_ activityID: UUID) -> Int {
        let to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
        let from = calendar.date(byAdding: .day, value: -7, to: to)!
        return sessions(from: from, to: to).filter { $0.activityID == activityID && $0.outcome == .completed }.count
    }

    func plannedUpcoming(_ activityID: UUID) -> Int {
        let now = Date.now
        return plan.allBlocks.filter { $0.activityID == activityID && $0.end > now }.count
    }

    // MARK: - Scheduling

    /// Specs as the scheduler sees them, with auto-balanced numbers filled in.
    /// `adjust` lets previews add or change an activity without touching the store.
    func balancedSpecs(adjust: ((inout [ActivitySpec]) -> Void)? = nil) -> (specs: [ActivitySpec], allotments: [UUID: Allotment]) {
        let today = planningDay
        var specs = activities.filter { $0.completedAt == nil }.map { a in
            var spec = a.spec
            spec.remainingWorkMinutes = remainingWork(a, asOf: today)
            if a.kind == .anchor { spec.isKeystone = true }
            return spec
        }
        adjust?(&specs)
        return Allocator.balance(specs, config: settings.config, defaultAwakeHours: settings.defaultAwakeHours)
    }

    func allotment(for a: Activity) -> Allotment? { allotments[a.id] }

    /// The weekly target in effect: auto-balanced, or the manual one.
    /// Minutes actually spent on an activity over the last 7 days (completed sessions).
    func minutesLastWeek(_ id: UUID) -> Int {
        let from = calendar.date(byAdding: .day, value: -7, to: .now)!
        return sessions(from: from, to: .now).filter { $0.activityID == id && $0.outcome == .completed }.reduce(0) { $0 + $1.minutes }
    }

    func makeInput(now: Date = .now) -> SchedulerInput {
        makeInput(now: now, specs: balancedSpecs().specs)
    }

    func makeInput(now: Date, specs: [ActivitySpec]) -> SchedulerInput {
        let today = planningDay
        let historyFrom = calendar.date(byAdding: .day, value: -21, to: today)!
        let history = sessions(from: historyFrom, to: .distantFuture).map(\.record)
        var contexts: [Date: DayContext] = [:]
        for p in fetch(DailyPlan.self) where p.day >= today && (p.wake != nil || p.startedAt != nil) {
            // `wake` only counts if it's actually on that day (woke up since midnight).
            contexts[p.day] = DayContext(wake: p.wake.flatMap { $0 >= p.day ? $0 : nil }, energy: p.energy)
        }
        return SchedulerInput(
            now: now,
            calendar: calendar,
            activities: specs,
            history: history,
            commitments: commitments.filter { $0.end > historyFrom }.map(\.spec),
            overrides: overrides.filter { $0.end > today }.map(\.spec),
            dayContexts: contexts,
            sleeps: knownSleeps(now: now),
            defaultWakeMinutes: settings.defaultWakeMinutes,
            defaultAwakeHours: settings.defaultAwakeHours,
            defaultEnergy: .normal,
            previousPlan: plan.days.isEmpty ? nil : plan)
    }

    func replan(_ reason: String) {
        let balanced = balancedSpecs()
        allotments = balanced.allotments
        let newPlan = Scheduler(config: settings.config).plan(makeInput(now: .now, specs: balanced.specs))
        plan = newPlan
        lastReplanReason = reason
        persist(newPlan)
        save()
        revision += 1
    }

    private func persist(_ plan: WeekPlan) {
        let encoder = JSONEncoder()
        for day in plan.days {
            let record = dailyPlan(for: day.day, create: true)
            record?.planData = try? encoder.encode(day)
        }
    }

    private func loadPersistedPlan() -> WeekPlan? {
        let today = planningDay
        let days = fetch(DailyPlan.self, FetchDescriptor(sortBy: [SortDescriptor(\.day)]))
            .filter { $0.day >= today }
            .compactMap(\.dayPlan)
        return days.isEmpty ? nil : WeekPlan(generatedAt: .now, days: days, notes: [])
    }

    func save() {
        do { try context.save() } catch { NSLog("Momentum save failed: \(error)") }
    }

    private func startClock() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        // Nothing to re-slot while you're asleep; waking up replans.
        if currentSleep != nil { return }
        let today = planningDay
        if today != currentDay {
            currentDay = today
            cleanUpExpiredOverrides()
            replan("A new day began")
            return
        }
        // If a suggested block's time has passed untouched, quietly re-slot the rest of today.
        guard running == nil, let today = todayPlan else { return }
        let stale = Date.now.addingTimeInterval(-15 * 60)
        if today.flexibleBlocks.contains(where: { $0.start < stale }) {
            replan("Caught up with the clock")
        }
    }

    // MARK: - Setup

    private func ensureBuckets() {
        let existing = Set(fetch(Bucket.self).map(\.kind))
        for (i, kind) in BucketKind.allCases.enumerated() where !existing.contains(kind) {
            context.insert(Bucket(kind: kind, sortIndex: i))
        }
        save()
    }

    private func cleanUpExpiredOverrides() {
        let cutoff = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))!
        for o in overrides where o.end < cutoff { context.delete(o) }
        let oldPlans = calendar.date(byAdding: .day, value: -60, to: .now)!
        for p in fetch(DailyPlan.self) where p.day < oldPlans { context.delete(p) }
        save()
    }

    func finishOnboarding(withSamples: Bool) {
        if withSamples && activities.isEmpty {
            let map = buckets.reduce(into: [BucketKind: Bucket]()) { $0[$1.kind] = $1 }
            SampleData.insert(into: context, buckets: map)
        }
        settings.hasOnboarded = true
        showOnboarding = false
        save()
        replan(withSamples ? "Loaded sample activities" : "Started fresh")
        if !hasStartedToday {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))  // let the onboarding sheet finish dismissing
                showStartDay = true
            }
        }
    }

    func loadSampleData() {
        let map = buckets.reduce(into: [BucketKind: Bucket]()) { $0[$1.kind] = $1 }
        SampleData.insert(into: context, buckets: map)
        save()
        replan("Loaded sample activities")
    }

    func eraseAllData() {
        running = nil
        for a in activities { context.delete(a) }
        for s in fetch(ActivitySession.self) { context.delete(s) }
        for c in commitments { context.delete(c) }
        for o in overrides { context.delete(o) }
        for p in fetch(DailyPlan.self) { context.delete(p) }
        for h in fetch(CompletionHistory.self) { context.delete(h) }
        plan = WeekPlan(generatedAt: .now, days: [], notes: [])
        save()
        replan("Erased all data")
    }

    // MARK: - Start Day

    /// Start Day: when you woke and when you'll probably sleep. Waking before midnight means you're
    /// still up from yesterday, so today's habits wait until after your next sleep.
    func startDay(wake: Date, energy: EnergyLevel, bedtime: Date) {
        guard let record = dailyPlan(for: planningDay, create: true) else { return }
        record.wake = wake
        record.energy = energy
        record.startedAt = record.startedAt ?? .now
        settings.nextSleepEstimate = max(bedtime, Date.now.addingTimeInterval(15 * 60))
        showStartDay = false
        save()
        replan("Started the day")
    }

    // MARK: - Sleep

    /// Usual sleep length: whatever isn't awake time.
    var sleepLength: TimeInterval { max(0, 24 - settings.defaultAwakeHours) * 3600 }

    var currentSleep: SleepLog? {
        var d = FetchDescriptor<SleepLog>(predicate: #Predicate { $0.end == nil }, sortBy: [SortDescriptor(\.start, order: .reverse)])
        d.fetchLimit = 1
        return fetch(SleepLog.self, d).first
    }

    /// Your next-sleep estimate, if it's still ahead (a passed estimate means nothing any more).
    var activeSleepEstimate: Date? { settings.nextSleepEstimate.flatMap { $0 > .now ? $0 : nil } }

    /// When you'll probably sleep next: your estimate, or what the plan assumes.
    var expectedBedtime: Date? {
        if let e = activeSleepEstimate { return e }
        return plan.days.flatMap(\.sleeps).map(\.start).filter { $0 > .now }.min()
    }

    /// Sleeps the planner should work around: logged, in progress, and your next-sleep estimate.
    private func knownSleeps(now: Date) -> [DateInterval] {
        let since = now.addingTimeInterval(-2 * 86_400)
        var out: [DateInterval] = fetch(SleepLog.self, FetchDescriptor(predicate: #Predicate { $0.start >= since }))
            .compactMap { s in
                if let end = s.end { return end > s.start ? DateInterval(start: s.start, end: end) : nil }
                // Asleep now: assume a usual-length sleep (at least another half hour).
                return DateInterval(start: s.start, end: max(s.start.addingTimeInterval(sleepLength), now.addingTimeInterval(1800)))
            }
        if currentSleep == nil, let e = settings.nextSleepEstimate, e > now {
            out.append(DateInterval(start: e, duration: sleepLength))
        }
        return out
    }

    /// "I'll probably sleep around…". The rest of today fits around it; anything left goes after you wake.
    func setBedtime(_ bedtime: Date) {
        settings.nextSleepEstimate = max(bedtime, Date.now.addingTimeInterval(15 * 60))
        showBedtimeSheet = false
        save()
        replan("Next sleep around \(settings.nextSleepEstimate!.formatted(date: .omitted, time: .shortened))")
    }

    /// "Going to sleep." Pauses suggestions until you say you're up.
    func goToSleep(at start: Date = .now) {
        guard currentSleep == nil else { return }
        if running != nil { cancelTimer() }
        context.insert(SleepLog(day: planningDay, start: min(start, .now)))
        settings.nextSleepEstimate = nil
        save()
        replan("Went to sleep")
    }

    /// Never mind: discard the sleep that's in progress.
    func cancelSleep() {
        guard let s = currentSleep else { return }
        context.delete(s)
        save()
        replan("Not sleeping after all")
    }

    /// A sensible default for "I'll probably sleep again around…" after waking.
    func suggestedBedtime(wake: Date) -> Date {
        max(wake.addingTimeInterval(settings.defaultAwakeHours * 3600), Date.now.addingTimeInterval(3600))
    }

    /// "I woke up at…". Habits for the day come right after this (unless already done today).
    func wakeUp(at wakeTime: Date, bedtime: Date, energy: EnergyLevel) {
        let s = currentSleep
        let wake = min(max(wakeTime, s?.start ?? wakeTime), .now)
        s?.end = wake
        if let record = dailyPlan(for: wake, create: true) {
            record.wake = wake
            record.energy = energy
            record.startedAt = .now
        }
        settings.nextSleepEstimate = max(bedtime, Date.now.addingTimeInterval(30 * 60))
        showWakeSheet = false
        showStartDay = false
        save()
        currentDay = planningDay
        replan("Woke up")
    }

    /// Before calendar days: carry an old "awake until" into the next-sleep estimate, once.
    private func migrateNextSleepEstimate() {
        guard settings.nextSleepEstimate == nil else { return }
        let ends = fetch(DailyPlan.self).compactMap { r in r.wake.map { $0.addingTimeInterval(r.awakeHours * 3600) } }
        if let e = ends.filter({ $0 > .now }).max() { settings.nextSleepEstimate = e; save() }
    }

    func setEnergy(_ energy: EnergyLevel) {
        guard let record = dailyPlan(for: planningDay, create: true) else { return }
        record.energy = energy
        save()
        replan("Energy changed to \(energy.title.lowercased())")
    }

    // MARK: - Activities

    func addActivity(_ draft: ActivityDraft) {
        let siblings = activities(in: draft.bucket)
        let a = Activity(name: draft.trimmedName, bucket: bucket(draft.bucket), sortIndex: (siblings.map(\.sortIndex).max() ?? -1) + 1)
        context.insert(a)
        draft.apply(to: a)
        save()
        replan("Added \(a.name)")
    }

    func updateActivity(_ id: UUID, with draft: ActivityDraft) {
        guard let a = activity(id) else { return }
        let movedBucket = a.kind != draft.bucket
        draft.apply(to: a)
        if movedBucket {
            a.bucket = bucket(draft.bucket)
            a.sortIndex = (activities(in: draft.bucket).filter { $0.id != a.id }.map(\.sortIndex).max() ?? -1) + 1
        }
        save()
        replan("Edited \(a.name)")
    }

    // MARK: - Errands

    /// Today's errand list: suggested ones first, then any ticked off today (shown as done).
    var errandsToday: [Activity] {
        let suggested = (todayPlan?.errands ?? []).compactMap { activity($0) }
        let done = activities(in: .errand).filter { isErrandDoneToday($0) && !suggested.contains($0) }
        return suggested + done
    }

    /// Open errands not on today's list (for "N more on the list").
    var otherOpenErrands: [Activity] {
        let today = Set(errandsToday.map(\.id))
        return activities(in: .errand).filter { $0.completedAt == nil && !$0.isPaused && !today.contains($0.id) }
    }

    func isErrandDoneToday(_ a: Activity) -> Bool {
        todaySessions.contains { $0.activityID == a.id && $0.outcome == .completed }
    }

    func addErrand(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let siblings = activities(in: .errand)
        let a = Activity(name: trimmed, bucket: bucket(.errand), priority: 3, minMinutes: 5, preferredMinutes: 15,
                         sessionsPerWeek: 0, maxSessionsPerDay: 1, sortIndex: (siblings.map(\.sortIndex).max() ?? -1) + 1)
        context.insert(a)
        save()
        replan("Added errand \(trimmed)")
    }

    /// Tick an errand off, or untick it if it was done today. One-offs are then finished.
    func toggleErrand(_ id: UUID) {
        guard let a = activity(id) else { return }
        let doneToday = todaySessions.filter { $0.activityID == id && $0.outcome == .completed }
        if !doneToday.isEmpty {
            doneToday.forEach { context.delete($0) }
            a.completedAt = nil
            if let h = completionHistory(for: planningDay), h.wins > 0 { h.wins -= 1 }
            save()
            replan("Unticked \(a.name)")
            return
        }
        let minutes = a.preferredMinutes
        context.insert(ActivitySession(activityID: a.id, activityName: a.name, bucket: .errand,
                                       start: Date.now.addingTimeInterval(-Double(minutes) * 60),
                                       minutes: minutes, outcome: .completed, isBonus: true))
        if a.sessionsPerWeek == 0 { a.completedAt = .now }
        completionHistory(for: planningDay, create: true)?.wins += 1
        save()
        replan("Ticked off \(a.name)")
    }

    /// Remove finished one-off errands from the list (their history stays).
    func clearFinishedErrands() {
        for a in activities(in: .errand) where a.completedAt != nil && !isErrandDoneToday(a) {
            for o in overrides where o.activityID == a.id { context.delete(o) }
            context.delete(a)
        }
        save()
        replan("Cleared finished errands")
    }

    func deleteActivity(_ id: UUID) {
        guard let a = activity(id) else { return }
        let name = a.name
        for o in overrides where o.activityID == id { context.delete(o) }
        if running?.activityID == id { running = nil }
        context.delete(a)
        save()
        replan("Removed \(name)")
    }

    func togglePause(_ id: UUID) {
        guard let a = activity(id) else { return }
        a.isPaused.toggle()
        save()
        replan(a.isPaused ? "Paused \(a.name)" : "Resumed \(a.name)")
    }

    /// Move an activity to a bucket at a position (drag & drop or keyboard).
    func move(_ id: UUID, to kind: BucketKind, before targetID: UUID? = nil) {
        guard let a = activity(id) else { return }
        let before = plan
        let previousOrder = activities.map { ($0.id, $0.sortIndex, $0.kind) }
        var list = activities(in: kind).filter { $0.id != id }
        let index = targetID.flatMap { t in list.firstIndex { $0.id == t } } ?? list.count
        list.insert(a, at: index)
        let changedBucket = a.kind != kind
        if changedBucket { a.bucket = bucket(kind) }
        for (i, item) in list.enumerated() { item.sortIndex = i }
        save()
        replan(changedBucket ? "Moved \(a.name) to \(kind.title)" : "Reordered \(kind.title)")
        let changes = describe(PlanDiff.changes(from: before, to: plan))
        impactNote = ImpactNote(title: changedBucket ? "\(a.name) is now a \(kind.singular.lowercased())" : "Priorities updated",
                                lines: changes.isEmpty ? ["The week's plan didn't need to change."] : changes) { [weak self] in
            guard let self else { return }
            for (id, index, k) in previousOrder {
                guard let item = self.activity(id) else { continue }
                item.sortIndex = index
                if item.kind != k { item.bucket = self.bucket(k) }
            }
            self.save()
            self.impactNote = nil
            self.replan("Undid reorder")
        }
    }

    /// "Thesis: 5h → 4h this week", biggest change first.
    func describe(_ changes: [PlanDiff.Change], limit: Int = 4) -> [String] {
        changes.prefix(limit).compactMap { c in
            guard let a = activity(c.activityID) else { return nil }
            if c.before == 0 { return "\(a.name): +\(Fmt.short(c.after)) this week" }
            if c.after == 0 { return "\(a.name): not this week (was \(Fmt.short(c.before)))" }
            return "\(a.name): \(Fmt.short(c.before)) → \(Fmt.short(c.after))"
        }
    }

    /// What adding or editing an activity would change, by simulating the week with and without it.
    func previewImpact(of draft: ActivityDraft, editing id: UUID?) -> [String] {
        let now = Date.now
        let current = Scheduler(config: settings.config).plan(makeInput(now: now, specs: balancedSpecs().specs))
        let newID = id ?? UUID()
        let siblings = activities(in: draft.bucket).filter { $0.id != id }
        let hypothetical = balancedSpecs { specs in
            let existing = id.flatMap { self.activity($0) }
            var spec = draft.spec(id: newID, sortIndex: existing?.kind == draft.bucket ? existing!.sortIndex
                                  : (siblings.map(\.sortIndex).max() ?? -1) + 1)
            if let existing { spec.createdAt = existing.createdAt }
            specs.removeAll { $0.id == newID }
            specs.append(spec)
        }
        let after = Scheduler(config: settings.config).plan(makeInput(now: now, specs: hypothetical.specs))
        var lines: [String] = []
        let changes = PlanDiff.changes(from: current, to: after)
        let mine = PlanDiff.minutes(after)[newID] ?? 0
        if draft.bucket != .errand {
            lines.append(mine > 0 ? "~\(Fmt.short(mine)) in the next 7 days" : "No time in the next 7 days at this rank")
        }
        let others = changes.filter { $0.activityID != newID }
        lines += describe(others)
        if others.isEmpty && draft.bucket != .errand { lines.append("Nothing else changes") }
        return lines
    }

    /// When auto-balance arrived: order each column by the old priorities (stable), then trust rank from then on.
    private func adoptAutoBalanceIfNeeded() {
        guard !settings.didAdoptAutoBalance else { return }
        for kind in BucketKind.allCases where kind != .errand {
            let ordered = activities(in: kind).enumerated()
                .sorted { ($1.element.priority, $0.offset) < ($0.element.priority, $1.offset) }
                .map(\.element)
            for (i, a) in ordered.enumerated() { a.sortIndex = i }
        }
        settings.didAdoptAutoBalance = true
        save()
    }

    func nudge(_ id: UUID, by delta: Int) {
        guard let a = activity(id) else { return }
        let list = activities(in: a.kind)
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard list.indices.contains(j) else { return }
        let target = delta < 0 ? list[j].id : (list.indices.contains(j + 1) ? list[j + 1].id : nil)
        move(id, to: a.kind, before: target)
    }

    // MARK: - Commitments

    func addCommitment(title: String, start: Date, end: Date) {
        context.insert(FixedCommitment(title: title, start: start, end: max(end, start.addingTimeInterval(300))))
        save()
        replan("Added appointment “\(title)”")
    }

    func commitment(_ id: UUID?) -> FixedCommitment? {
        guard let id else { return nil }
        return commitments.first { $0.id == id }
    }

    func newCommitment() {
        editingCommitmentID = nil
        showCommitmentSheet = true
    }

    func editCommitment(_ id: UUID) {
        guard commitment(id) != nil else { return }
        editingCommitmentID = id
        showCommitmentSheet = true
    }

    func updateCommitment(_ id: UUID, title: String, start: Date, end: Date) {
        guard let c = commitment(id) else { return }
        c.title = title
        c.start = start
        c.end = max(end, start.addingTimeInterval(300))
        save()
        replan("Edited appointment “\(title)”")
    }

    func deleteCommitment(id: UUID) {
        if let c = commitment(id) { deleteCommitment(c) }
    }

    func deleteCommitment(_ c: FixedCommitment) {
        let t = c.title
        context.delete(c)
        save()
        replan("Removed appointment “\(t)”")
    }

    // MARK: - Overrides

    func addBoost(_ activityID: UUID, days: Int, factor: Double) {
        let start = calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .day, value: max(days, 1), to: start)!
        for o in overrides where o.activityID == activityID && o.kind == .boost { context.delete(o) }
        context.insert(SchedulingOverride(activityID: activityID, kind: .boost, start: start, end: end, factor: factor))
        save()
        replan("Boosted \(activity(activityID)?.name ?? "activity") for \(days) days")
    }

    func addPause(_ activityID: UUID, until: Date) {
        let end = calendar.startOfDay(for: until)
        for o in overrides where o.activityID == activityID && o.kind == .pause { context.delete(o) }
        context.insert(SchedulingOverride(activityID: activityID, kind: .pause, start: .now, end: end))
        save()
        replan("Paused \(activity(activityID)?.name ?? "activity")")
    }

    func addPin(_ activityID: UUID, day: Date, time: Date?) {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        var pinned: Date?
        if let time {
            let t = calendar.dateComponents([.hour, .minute], from: time)
            pinned = calendar.date(bySettingHour: t.hour ?? 9, minute: t.minute ?? 0, second: 0, of: start)
        }
        for o in overrides where o.activityID == activityID && o.kind == .exclude && o.overlaps(start, end) {
            context.delete(o)
        }
        context.insert(SchedulingOverride(activityID: activityID, kind: .pin, start: start, end: end, pinnedTime: pinned))
        save()
        replan("Pinned \(activity(activityID)?.name ?? "activity")")
    }

    func removeOverride(_ o: SchedulingOverride) {
        let name = activity(o.activityID)?.name ?? "activity"
        context.delete(o)
        save()
        replan("Removed \(o.kind.rawValue) on \(name)")
    }

    // MARK: - Today actions

    func start(_ block: PlannedBlock) {
        guard let id = block.activityID, let a = activity(id) else { return }
        beginTimer(for: a, blockID: block.id, minutes: block.minutes, isBonus: block.isOptional)
    }

    func startBonus(_ activityID: UUID) {
        guard let a = activity(activityID) else { return }
        beginTimer(for: a, blockID: nil, minutes: a.preferredMinutes, isBonus: true)
    }

    private func beginTimer(for a: Activity, blockID: String?, minutes: Int, isBonus: Bool) {
        let twoPhase = a.hasTwoPhaseTimer
        running = RunningSession(
            blockID: blockID, activityID: a.id, title: a.name, bucket: a.kind, startedAt: .now,
            plannedMinutes: twoPhase ? a.attemptMinutes + a.reviewMinutes : minutes,
            attemptMinutes: twoPhase ? a.attemptMinutes : 0, reviewMinutes: twoPhase ? a.reviewMinutes : 0,
            reviewStartedAt: nil, isBonus: isBonus)
    }

    func startReview() {
        guard running?.isTwoPhase == true, running?.reviewStartedAt == nil else { return }
        running?.reviewStartedAt = .now
        running?.reviewStartActive = running?.activeSeconds()
    }

    func togglePauseTimer() {
        guard var r = running else { return }
        if let p = r.pausedAt {
            r.pausedSeconds = (r.pausedSeconds ?? 0) + Date.now.timeIntervalSince(p)
            r.pausedAt = nil
        } else {
            r.pausedAt = .now
        }
        running = r
    }

    func cancelTimer() { running = nil }

    /// Picks up a session that was running when the app quit. Dropped if its activity is gone
    /// or it started so long ago (over a day) that it was clearly abandoned.
    private func restoreRunningSession() {
        guard let data = settings.runningSession,
              let r = try? JSONDecoder().decode(RunningSession.self, from: data) else { return }
        if activity(r.activityID) != nil, Date.now.timeIntervalSince(r.startedAt) < 86_400 {
            running = r
        } else {
            settings.runningSession = nil
            save()
        }
    }

    func completeRunning() {
        guard let r = running, let a = activity(r.activityID) else { running = nil; return }
        let elapsed = max(1, Int(r.activeSeconds() / 60))
        let cap = (r.carriedMinutes ?? 0)
            + (r.isTwoPhase ? r.attemptMinutes + r.reviewMinutes : max(r.plannedMinutes * 2, r.plannedMinutes + 30))
        recordCompletion(a, start: r.startedAt, minutes: min(elapsed, cap), isBonus: r.isBonus)
        running = nil
    }

    /// Mark complete without running the timer (counts the planned duration).
    func complete(_ block: PlannedBlock) {
        if running?.blockID == block.id { completeRunning(); return }
        guard let id = block.activityID, let a = activity(id) else { return }
        // Placed where it doesn't overlap time already counted, so nothing is counted twice.
        let guess = min(block.start, Date.now.addingTimeInterval(-Double(block.minutes) * 60))
        let end = latestFreeEnd(minutes: block.minutes, notAfter: guess.addingTimeInterval(Double(block.minutes) * 60))
        let start = end.map { $0.addingTimeInterval(-Double(block.minutes) * 60) } ?? guess
        recordCompletion(a, start: start, minutes: block.minutes, isBonus: block.isOptional)
    }

    /// Logs time done outside the app. Refused if it overlaps time that's already tracked,
    /// so nothing is ever counted twice. Times are whole minutes.
    @discardableResult
    func logTime(_ id: UUID, minutes: Int, endedAt: Date) -> Bool {
        guard let a = activity(id), minutes > 0 else { return false }
        let end = Self.wholeMinute(min(endedAt, .now))
        let start = end.addingTimeInterval(-Double(minutes) * 60)
        guard logConflicts(start: start, end: end).isEmpty else { return false }
        showLogTime = false
        recordCompletion(a, start: start, minutes: minutes, isBonus: false)
        return true
    }

    /// Planned length for a timer that continues earlier work: the usual session, or at least 30 more minutes.
    static func continuedLength(_ a: Activity, carried: Int) -> Int { max(a.preferredMinutes, carried + 30) }

    static func wholeMinute(_ d: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    /// Time already accounted for: completed sessions (errand ticks aside) and the session running now.
    func trackedTime(from: Date, to: Date, ignoring: UUID? = nil) -> [(name: String, interval: DateInterval)] {
        // Sessions are stored by start, so look back far enough to catch long ones that run into the range.
        var out = sessions(from: from.addingTimeInterval(-24 * 3600), to: to)
            .filter { $0.outcome == .completed && $0.bucket != .errand && $0.minutes > 0 && $0.id != ignoring }
            .map { (name: $0.activityName, interval: DateInterval(start: $0.start, duration: Double($0.minutes) * 60)) }
        if let r = running, r.startedAt < .now {
            out.append((name: r.title + " (running)", interval: DateInterval(start: r.startedAt, end: .now)))
        }
        return out.filter { $0.interval.start < to && $0.interval.end > from }.sorted { $0.interval.start < $1.interval.start }
    }

    func logConflicts(start: Date, end: Date, ignoring: UUID? = nil) -> [(name: String, interval: DateInterval)] {
        guard end > start else { return [] }
        return trackedTime(from: start, to: end, ignoring: ignoring)
    }

    // MARK: - What's been tracked

    /// A finished (or running) stretch of tracked time, for the "Today so far" timeline.
    struct TrackedEntry: Identifiable {
        let id: UUID
        let sessionID: UUID?          // nil for the running timer
        let activityID: UUID
        let name: String
        let kind: BucketKind
        let interval: DateInterval
        var isRunning: Bool { sessionID == nil }
    }

    /// Completed sessions on a calendar day (errand ticks aside), plus the running timer.
    func trackedEntries(on day: Date) -> [TrackedEntry] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        var out = sessions(from: start, to: end)
            .filter { $0.outcome == .completed && $0.bucket != .errand && $0.minutes > 0 }
            .map { TrackedEntry(id: $0.id, sessionID: $0.id, activityID: $0.activityID, name: $0.activityName, kind: $0.bucket,
                                interval: DateInterval(start: $0.start, duration: Double($0.minutes) * 60)) }
        if let r = running, r.startedAt >= start, r.startedAt < end {
            out.append(TrackedEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, sessionID: nil,
                                    activityID: r.activityID, name: r.title, kind: r.bucket,
                                    interval: DateInterval(start: r.startedAt, end: max(r.startedAt, .now))))
        }
        return out.sorted { $0.interval.start < $1.interval.start }
    }

    /// When today's tracking could start: when you woke today, else midnight.
    var trackingDayStart: Date {
        let day = planningDay
        if let w = todayRecord?.wake, w >= day, w <= .now { return w }
        return day
    }

    /// Untracked stretches of today (5 min or more) between your day's start and now, skipping sleep.
    func untrackedGaps(now: Date = .now) -> [DateInterval] {
        var busy = trackedEntries(on: planningDay).map(\.interval)
        busy += knownSleeps(now: now)
        busy.sort { $0.start < $1.start }
        var gaps: [DateInterval] = []
        var cursor = trackingDayStart
        for b in busy where b.end > cursor {
            if b.start > cursor, b.start.timeIntervalSince(cursor) >= 300 {
                gaps.append(DateInterval(start: cursor, end: min(b.start, now)))
            }
            cursor = max(cursor, b.end)
            if cursor >= now { break }
        }
        if now.timeIntervalSince(cursor) >= 300 { gaps.append(DateInterval(start: cursor, end: now)) }
        return gaps.filter { $0.duration >= 300 }
    }

    /// The most recent finished session today (errand ticks aside), if any.
    var lastSessionToday: ActivitySession? {
        let now = Date.now
        return sessions(from: planningDay.addingTimeInterval(-24 * 3600), to: now)
            .filter { $0.outcome == .completed && $0.bucket != .errand && $0.minutes > 0 }
            .max { $0.start.addingTimeInterval(Double($0.minutes) * 60) < $1.start.addingTimeInterval(Double($1.minutes) * 60) }
    }

    /// Where "since last session" starts: the end of the last session, or the start of your day.
    var sinceLastStart: Date {
        let dayStart = trackingDayStart
        guard let s = lastSessionToday else { return Self.wholeMinute(dayStart) }
        // Round up, so it starts after the last session rather than inside its final minute.
        let end = s.start.addingTimeInterval(Double(s.minutes) * 60)
        let up = Self.wholeMinute(end) < end ? Self.wholeMinute(end).addingTimeInterval(60) : end
        return max(Self.wholeMinute(dayStart), min(up, Self.wholeMinute(.now)))
    }

    /// One way to log: a start and an end (to the minute).
    /// - `mergeInto`: fold it into that earlier session of the same activity, as one continuous session from its start.
    /// - `keepRunning`: if the end is about now, carry on as a live timer instead of finishing.
    /// Refused if it would overlap time that's already counted.
    @discardableResult
    func logRange(_ id: UUID, start: Date, end: Date, mergeInto: UUID? = nil, keepRunning: Bool = false) -> Bool {
        guard let a = activity(id) else { return false }
        let now = Date.now
        let merge = session(mergeInto).flatMap { $0.activityID == id ? $0 : nil }
        let start = merge?.start ?? Self.wholeMinute(start)
        let end = Self.wholeMinute(min(end, now))
        let minutes = Int(end.timeIntervalSince(start) / 60)
        guard minutes >= 1, logConflicts(start: start, end: end, ignoring: merge?.id).isEmpty else { return false }
        let keepRunning = keepRunning && running == nil && now.timeIntervalSince(end) <= 120
        showLogTime = false
        if keepRunning {
            if let merge {
                // The earlier session becomes the start of the live timer; Complete records it whole.
                adjustHistory(for: merge, by: -1)
                context.delete(merge)
            }
            beginTimer(for: a, blockID: nil, minutes: Self.continuedLength(a, carried: minutes), isBonus: true)
            running?.startedAt = start
            running?.carriedMinutes = minutes
            let gap = now.timeIntervalSince(end)
            if gap >= 1 { running?.pausedSeconds = gap }
            save()
            replan("Continued \(a.name)")
            screen = .today
        } else if let merge {
            let added = minutes - merge.minutes
            merge.minutes = minutes
            if a.kind == .mainWork, let h = completionHistory(for: calendar.startOfDay(for: merge.start)) { h.focusMinutes += added }
            save()
            replan("Extended \(a.name)")
            celebration = Celebration(title: "Extended", message: "\(a.name) · \(Fmt.minutes(minutes)) in one go")
        } else {
            recordCompletion(a, start: start, minutes: minutes, isBonus: false)
        }
        return true
    }

    /// Change when a recorded session happened. Refused if it would overlap other tracked time.
    @discardableResult
    func updateSession(_ id: UUID, start: Date, minutes: Int) -> Bool {
        guard let s = fetch(ActivitySession.self, FetchDescriptor(predicate: #Predicate { $0.id == id })).first, minutes > 0 else { return false }
        let start = Self.wholeMinute(start)
        let end = start.addingTimeInterval(Double(minutes) * 60)
        guard end <= Date.now.addingTimeInterval(60), logConflicts(start: start, end: end, ignoring: id).isEmpty else { return false }
        if s.bucket == .mainWork, let h = completionHistory(for: calendar.startOfDay(for: s.start)) { h.focusMinutes += minutes - s.minutes }
        s.start = start
        s.minutes = minutes
        save()
        replan("Edited a session of \(s.activityName)")
        return true
    }

    func deleteSession(_ id: UUID) {
        guard let s = fetch(ActivitySession.self, FetchDescriptor(predicate: #Predicate { $0.id == id })).first else { return }
        adjustHistory(for: s, by: -1)
        context.delete(s)
        save()
        replan("Deleted a session of \(s.activityName)")
    }

    func session(_ id: UUID?) -> ActivitySession? {
        guard let id else { return nil }
        return fetch(ActivitySession.self, FetchDescriptor(predicate: #Predicate { $0.id == id })).first
    }

    private func adjustHistory(for s: ActivitySession, by sign: Int) {
        guard let h = completionHistory(for: calendar.startOfDay(for: s.start)) else { return }
        h.wins = max(0, h.wins + sign)
        if s.isBonus { h.bonusWins = max(0, h.bonusWins + sign) }
        if s.bucket == .mainWork { h.focusMinutes = max(0, h.focusMinutes + sign * s.minutes) }
    }

    /// The latest end time (no later than `notAfter`) where `minutes` fit without touching tracked time.
    func latestFreeEnd(minutes: Int, notAfter: Date) -> Date? {
        var end = Self.wholeMinute(min(notAfter, .now))
        let limit = end.addingTimeInterval(-7 * 86_400)
        while end > limit {
            let start = end.addingTimeInterval(-Double(minutes) * 60)
            let clashes = logConflicts(start: start, end: end)
            guard let earliest = clashes.map(\.interval.start).min() else { return end }
            end = Self.wholeMinute(earliest)
        }
        return nil
    }

    private func recordCompletion(_ a: Activity, start: Date, minutes: Int, isBonus: Bool) {
        context.insert(ActivitySession(activityID: a.id, activityName: a.name, bucket: a.kind, start: start,
                                       minutes: minutes, outcome: .completed, isBonus: isBonus))
        let wasBaselineDone = baselineRemaining == 0 && winsToday > 0
        if let h = completionHistory(for: planningDay, create: true) {
            h.wins += 1
            if isBonus { h.bonusWins += 1 }
            if a.kind == .mainWork { h.focusMinutes += minutes }
        }
        save()
        replan("Completed \(a.name)")
        let baselineDone = baselineRemaining == 0
        if baselineDone, let h = completionHistory(for: planningDay) { h.baselineComplete = true; save() }
        celebration = Celebration(
            title: baselineDone && !wasBaselineDone ? "Day's baseline complete" : Self.cheers.randomElement()!,
            message: baselineDone && !wasBaselineDone
                ? "That's a successful day. Anything else is a bonus."
                : "\(a.name) · \(minutes) min")
    }

    static let cheers = ["Nice work", "Done", "That counts", "Momentum +1", "Good session"]

    func skip(_ block: PlannedBlock) {
        decline(block, outcome: .skipped)
    }

    /// Swap for whatever the scheduler suggests next.
    func swap(_ block: PlannedBlock) {
        decline(block, outcome: .swapped)
    }

    /// Swap for a specific activity: it takes this block's place today (pinned at the block's time, or now).
    func swap(_ block: PlannedBlock, with otherID: UUID) {
        guard let other = activity(otherID), let record = decline(block, outcome: .swapped, toast: false) else { return }
        let day = planningDay
        let at = max(block.start, Date.now)
        // Starts now (not at midnight) so only sessions from here on count against it.
        let pin = SchedulingOverride(activityID: otherID, kind: .pin, start: min(Date.now, at),
                                     end: calendar.date(byAdding: .day, value: 1, to: day)!, pinnedTime: at)
        context.insert(pin)
        save()
        replan("Swapped \(block.title) for \(other.name)")
        impactNote = ImpactNote(title: "Swapped \(block.title) for \(other.name)", lines: []) { [weak self] in
            guard let self else { return }
            self.context.delete(pin)
            self.context.delete(record)
            self.save()
            self.impactNote = nil
            self.replan("Undid swap")
        }
    }

    /// Records a skip/swap (which only takes the activity off today's plan) and offers Undo.
    @discardableResult
    private func decline(_ block: PlannedBlock, outcome: SessionRecord.Outcome, toast: Bool = true) -> ActivitySession? {
        guard let id = block.activityID, let a = activity(id) else { return nil }
        if running?.blockID == block.id { running = nil }
        let record = ActivitySession(activityID: id, activityName: a.name, bucket: a.kind, start: .now,
                                     minutes: 0, outcome: outcome)
        context.insert(record)
        save()
        replan(outcome == .swapped ? "Swapped out \(a.name)" : "Skipped \(a.name) today")
        if toast {
            impactNote = ImpactNote(title: outcome == .swapped ? "Swapped out \(a.name)" : "Skipped \(a.name) today",
                                    lines: ["Back tomorrow. Nothing is counted against it."]) { [weak self] in
                self?.bringBack(id)
            }
        }
        return record
    }

    /// Activities skipped or swapped out today (and not done since).
    var setAsideToday: [Activity] {
        let today = todaySessions
        let ids = Set(today.filter { $0.outcome == .skipped || $0.outcome == .swapped }.map(\.activityID))
        return activities.filter { ids.contains($0.id) }
    }

    /// Undo a skip/swap: puts the activity back into today's plan.
    func bringBack(_ id: UUID) {
        for s in todaySessions where s.activityID == id && (s.outcome == .skipped || s.outcome == .swapped) {
            context.delete(s)
        }
        save()
        impactNote = nil
        replan("Brought back \(activity(id)?.name ?? "activity")")
    }

    /// Everything you could start right now, for swapping or for working past the plan.
    func startableActivities(excluding: UUID? = nil) -> [Activity] {
        [BucketKind.mainWork, .hobby, .anchor].flatMap { activities(in: $0) }
            .filter { !$0.isPaused && $0.id != excluding }
    }

    /// "Not today" for something that isn't a block (e.g. an errand on today's list).
    func excludeToday(_ id: UUID) {
        let start = planningDay
        context.insert(SchedulingOverride(activityID: id, kind: .exclude, start: start,
                                          end: calendar.date(byAdding: .day, value: 1, to: start)!))
        save()
        replan("Moved an errand off today")
    }

    func doLater(_ block: PlannedBlock, _ option: DoLaterOption) {
        guard let id = block.activityID else { return }
        let now = Date.now
        let todayStart = planningDay
        switch option {
        case .inAnHour:
            context.insert(SchedulingOverride(activityID: id, kind: .deferUntil, start: now, end: now.addingTimeInterval(3600)))
        case .thisEvening:
            let evening = (todayPlan?.windowEnd ?? now).addingTimeInterval(-settings.config.eveningPhaseHours * 3600)
            context.insert(SchedulingOverride(activityID: id, kind: .deferUntil, start: now, end: max(evening, now.addingTimeInterval(3600))))
        case .tomorrow:
            context.insert(SchedulingOverride(activityID: id, kind: .exclude, start: todayStart,
                                              end: calendar.date(byAdding: .day, value: 1, to: todayStart)!))
        }
        if running?.blockID == block.id { running = nil }
        save()
        replan("Moved \(block.title) to later")
    }

    /// Week view drag: move a block's activity from its day to another day.
    func moveBlock(_ blockID: String, to day: Date) {
        guard let source = plan.days.first(where: { $0.blocks.contains { $0.id == blockID } }),
              let block = source.blocks.first(where: { $0.id == blockID }),
              let id = block.activityID else { return }
        let target = calendar.startOfDay(for: day)
        guard !calendar.isDate(source.day, inSameDayAs: target) else { return }
        let sourceEnd = calendar.date(byAdding: .day, value: 1, to: source.day)!
        // Remove a pin that forced it onto the source day; otherwise exclude it there.
        let pins = overrides.filter { $0.activityID == id && $0.kind == .pin && $0.overlaps(source.day, sourceEnd) }
        if pins.isEmpty {
            context.insert(SchedulingOverride(activityID: id, kind: .exclude, start: source.day, end: sourceEnd))
        } else {
            pins.forEach { context.delete($0) }
        }
        let targetEnd = calendar.date(byAdding: .day, value: 1, to: target)!
        for o in overrides where o.activityID == id && o.kind == .exclude && o.overlaps(target, targetEnd) {
            context.delete(o)
        }
        context.insert(SchedulingOverride(activityID: id, kind: .pin, start: target, end: targetEnd))
        save()
        replan("Moved \(block.title) to \(target.formatted(.dateTime.weekday(.wide)))")
    }

    // MARK: - Progress

    var winsToday: Int { todaySessions.filter { $0.outcome == .completed }.count }

    /// Baseline blocks still suggested for today. Skipped items leave the plan, so they never count against you.
    var baselineRemaining: Int { todayPlan?.baselineBlocks.count ?? 0 }

    /// Days in the last 7 with at least one completed session. Not a streak: gaps don't reset anything.
    var activeDaysThisWeek: [(day: Date, wins: Int, baseline: Bool)] {
        let today = planningDay
        return (0..<7).reversed().map { offset in
            let d = calendar.date(byAdding: .day, value: -offset, to: today)!
            let h = completionHistory(for: d)
            return (d, h?.wins ?? 0, h?.baselineComplete ?? false)
        }
    }
}

extension SchedulingOverride {
    func overlaps(_ from: Date, _ to: Date) -> Bool { start < to && end > from }
}
