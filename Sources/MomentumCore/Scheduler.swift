import Foundation

/// Deterministic, explainable scheduler inspired by OS CPU schedulers.
///
/// Pipeline, per day of the rolling horizon (today first, so later days see earlier plans):
///  1. Hard constraints: waking window, fixed commitments (+buffer), pauses, exclusions, recovery.
///  2. Capacity: free minutes × utilisation target, capped per energy level. The rest is slack.
///  3. Pins (hard), then Anchors (small keystone habits, morning).
///  4. Split remaining capacity between Main Work and Hobbies (urgent work may preempt evening time).
///  5. Main Work: quantum-by-quantum weighted selection with service penalty, context-switch cost,
///     stability bonus, boost multipliers and a starvation guard.
///  6. Hobbies: fair share by rank with stickiness (runs), recovery as a hard constraint, no debt.
///  7. Placement into free time: anchors → focus sessions with breaks → hobbies in the evening.
/// See docs/SCHEDULING.md for the full description.
public struct Scheduler: Sendable {
    public var config: SchedulerConfig

    public init(config: SchedulerConfig = .default) {
        self.config = config
    }

    public func plan(_ input: SchedulerInput) -> WeekPlan {
        let cal = input.calendar
        let today = input.planningDay
        var ledger = ServiceLedger(history: input.history)
        var days: [DayPlan] = []
        let horizonEnd = cal.date(byAdding: .day, value: max(1, config.horizonDays) + 1, to: today) ?? input.now
        let sleeps = Self.sleepTimeline(input, until: horizonEnd)
        for offset in 0..<max(1, config.horizonDays) {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            var planner = DayPlanner(config: config, input: input, day: day, isToday: offset == 0, sleeps: sleeps)
            days.append(planner.run(ledger: &ledger))
        }
        return WeekPlan(generatedAt: input.now, days: days, notes: weekNotes(input: input, days: days))
    }

    /// Known sleeps, then the same rhythm repeated every 24 h.
    ///
    /// If nothing ahead is known, the next sleep is your usual bedtime (`defaultWake − (24 − awake)`).
    /// Rule: a usual sleep that should already have started is never assumed while you're clearly awake.
    /// Inside the usual sleep window: in its first half (just past bedtime) sleep is assumed to start in an
    /// hour; in its second half (near your usual wake time) you're assumed to be up already.
    static func sleepTimeline(_ input: SchedulerInput, until end: Date) -> [DateInterval] {
        let cal = input.calendar
        let length = max(0, 24 - input.defaultAwakeHours) * 3600
        var out = input.sleeps.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        guard length > 0 else { return out }
        var next: Date
        if let last = out.filter({ $0.end > input.now }).max(by: { $0.end < $1.end }) {
            next = last.end.addingTimeInterval(input.defaultAwakeHours * 3600)
        } else {
            let usualBedtime = input.defaultWakeMinutes * 60 - Int(length)
            let today = cal.startOfDay(for: input.now)
            var bedtime = today.addingTimeInterval(Double(usualBedtime))
            while bedtime.addingTimeInterval(length) <= input.now { bedtime.addTimeInterval(86_400) }
            if bedtime > input.now {
                next = bedtime
            } else if input.now.timeIntervalSince(bedtime) < length / 2 {
                next = input.now.addingTimeInterval(3600)          // just past bedtime: sleep soon
            } else {
                next = bedtime.addingTimeInterval(86_400)          // near usual wake time: already up
            }
        }
        while next < end {
            out.append(DateInterval(start: next, duration: length))
            next.addTimeInterval(86_400)
        }
        return out
    }

    // MARK: Week-level explanations

    func weekNotes(input: SchedulerInput, days: [DayPlan]) -> [String] {
        let cal = input.calendar
        let today = input.planningDay
        let horizonEnd = cal.date(byAdding: .day, value: days.count, to: today) ?? input.now
        let byID = input.activities.reduce(into: [UUID: ActivitySpec]()) { $0[$1.id] = $1 }
        var notes: [String] = []

        func dayName(_ d: Date) -> String { Self.relativeDayName(d, today: today, calendar: cal) }

        for o in input.overrides.sorted(by: { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) })
        where o.overlaps(today, horizonEnd) {
            guard let a = byID[o.activityID] else { continue }
            switch o.kind {
            case .boost:
                let last = o.end.addingTimeInterval(-1)
                notes.append("\(a.name) is boosted ×\(MainWorkPolicy.fmt(o.factor)) through \(dayName(last)): it gets most of the focus time, lower-priority work is deferred, and balanced scheduling resumes afterwards.")
            case .pause:
                notes.append("\(a.name) is paused — it resumes \(dayName(o.end)).")
            case .pin:
                notes.append("\(a.name) is pinned to \(dayName(o.start)).")
            case .exclude, .deferUntil:
                break
            }
        }

        for a in input.activities.sorted(by: { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }) {
            guard let d = a.deadline, d >= today, !a.isPaused else { continue }
            guard let estimate = a.remainingWorkMinutes else {
                if d < horizonEnd { notes.append("\(a.name) is due \(dayName(d)) — its urgency rises as the date approaches.") }
                continue
            }
            // Honest feasibility check: does the estimated work fit before the deadline?
            let doneToday = input.history.filter { $0.activityID == a.id && $0.outcome == .completed && $0.start >= today }
                .reduce(0) { $0 + $1.minutes }
            let left = max(0, estimate - doneToday)
            let due = d < horizonEnd ? dayName(d) : d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            if left == 0 {
                notes.append("\(a.name): the estimated work is done ahead of the deadline (\(due)).")
                continue
            }
            let daysLeft = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: d)).day ?? 0
            let perDay = MainWorkPolicy.requiredPerDay(remaining: left, daysLeft: daysLeft)
            let dueStart = cal.startOfDay(for: d)
            let planned = days.filter { $0.day < dueStart }.reduce(0) { $0 + $1.minutes(for: a.id) }
            let tooMuch = perDay > Double(config.mainWorkCapNormal) * config.boostDailyShare
            if d < horizonEnd && planned + 15 < left {
                notes.append("\(a.name): ~\(MainWorkPolicy.hm(left)) left before \(due), but only ~\(MainWorkPolicy.hm(planned)) fits in the plan. Consider boosting it, trimming the scope or moving the deadline.")
            } else if tooMuch {
                notes.append("\(a.name): ~\(MainWorkPolicy.hm(left)) left needs about \(MainWorkPolicy.hm(Int(perDay))) a day until \(due) — more than a normal day holds. Consider trimming the scope or moving the deadline.")
            } else {
                notes.append("\(a.name): ~\(MainWorkPolicy.hm(left)) left, about \(MainWorkPolicy.hm(Int(perDay.rounded()))) a day until \(due).\(d < horizonEnd ? " The plan covers it." : "")")
            }
        }

        // Runs: "today–Wed: Interview prep · Thu: Thesis", for focus and for evenings.
        func runs(_ pickID: (DayPlan) -> UUID?) -> String? {
            var runs: [(UUID, Date, Date)] = []
            for d in days {
                guard let p = pickID(d) else { continue }
                if let last = runs.last, last.0 == p,
                   let next = cal.date(byAdding: .day, value: 1, to: last.2), cal.isDate(next, inSameDayAs: d.day) {
                    runs[runs.count - 1].2 = d.day
                } else {
                    runs.append((p, d.day, d.day))
                }
            }
            let parts = runs.compactMap { run -> String? in
                guard let a = byID[run.0] else { return nil }
                let range = cal.isDate(run.1, inSameDayAs: run.2) ? dayName(run.1) : "\(dayName(run.1))–\(dayName(run.2))"
                return "\(range): \(a.name)"
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        if let r = runs({ $0.primaryActivityID }) { notes.append("Focus — " + r) }
        if let r = runs({ d in d.blocks.first { $0.kind == .hobby && !$0.isOptional }?.activityID }) { notes.append("Evenings — " + r) }
        return notes
    }

    static func relativeDayName(_ d: Date, today: Date, calendar cal: Calendar) -> String {
        let day = cal.startOfDay(for: d)
        let diff = cal.dateComponents([.day], from: today, to: day).day ?? 0
        if diff == 0 { return "today" }
        if diff == 1 { return "tomorrow" }
        let symbols = cal.shortWeekdaySymbols
        let w = cal.component(.weekday, from: d)
        return symbols.indices.contains(w - 1) ? symbols[w - 1] : "day \(diff)"
    }
}

// MARK: - Day planner

private struct Pending {
    var activity: ActivitySpec
    var minutes: Int
    var kind: PlannedBlock.Kind
    var exactStart: Date?
    var notBefore: Date?
    var isPinned = false
    var isPrimary = false
    var isOptional = false
    var reasons: [String]
}

struct DayPlanner {
    let config: SchedulerConfig
    let input: SchedulerInput
    let cal: Calendar
    let day: Date
    let nextDay: Date
    let isToday: Bool
    let energy: EnergyLevel
    /// When habits start: right after waking (today: now, if you've already woken).
    let wake: Date
    let windowStart: Date
    let windowEnd: Date
    /// Sessions in [day, membershipEnd) belong to this day: a calendar day.
    let membershipEnd: Date
    /// Sleep overlapping this day: busy time the plan works around.
    let sleeps: [DateInterval]
    /// The last stretch before the next sleep (or midnight): hobby time.
    let eveningStart: Date
    let previousDay: DayPlan?
    let dayOverrides: [OverrideSpec]
    let mainPolicy: MainWorkPolicy
    let hobbyPolicy: HobbyPolicy
    private var notes: [String] = []
    private var blockCounters: [UUID: Int] = [:]

    init(config: SchedulerConfig, input: SchedulerInput, day: Date, isToday: Bool, sleeps allSleeps: [DateInterval]) {
        self.config = config
        self.input = input
        self.cal = input.calendar
        self.day = day
        self.isToday = isToday
        let nextDay = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        self.nextDay = nextDay
        let ctx = input.dayContexts[day]
        self.energy = ctx?.energy ?? input.defaultEnergy
        let windowStart = isToday ? min(max(day, Self.roundUp(input.now)), nextDay) : day
        self.windowStart = windowStart
        self.windowEnd = nextDay
        self.membershipEnd = nextDay
        self.sleeps = allSleeps.filter { $0.end > day && $0.start < nextDay }

        // Habits go right after waking. Today: if you've woken since midnight (told us, or a logged sleep
        // ended today), that's now; otherwise you're still up from yesterday, so after your next sleep.
        let now = input.now
        let sleepEnds = self.sleeps.map(\.end).filter { $0 > day && $0 < nextDay }
        let wokeToday = isToday && ((ctx?.wake).map { $0 >= day && $0 <= now } ?? false
            || input.sleeps.contains { $0.end >= day && $0.end <= now })
        let wake: Date
        if wokeToday {
            wake = windowStart
        } else if let after = sleepEnds.filter({ $0 >= windowStart }).min() {
            wake = after
        } else {
            wake = windowStart
        }
        self.wake = wake
        // Evening: the last few hours before the next sleep after waking, or before midnight.
        let stretchEnd = allSleeps.map(\.start).filter { $0 > wake }.min().map { min($0, nextDay) } ?? nextDay
        self.eveningStart = max(stretchEnd.addingTimeInterval(-config.eveningPhaseHours * 3600), windowStart)
        self.previousDay = input.previousPlan?.days.first { input.calendar.isDate($0.day, inSameDayAs: day) }
        let membershipEnd = self.membershipEnd
        self.dayOverrides = input.overrides.filter { $0.overlaps(day, membershipEnd) }
        self.mainPolicy = MainWorkPolicy(config: config)
        self.hobbyPolicy = HobbyPolicy(config: config)
    }

    static func roundUp(_ d: Date, minutes: Double = 5) -> Date {
        let step = minutes * 60
        return Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
    }

    // MARK: Constraint helpers

    func overrides(_ kind: OverrideSpec.Kind, _ id: UUID) -> [OverrideSpec] {
        dayOverrides.filter { $0.kind == kind && $0.activityID == id }
    }

    func isPaused(_ a: ActivitySpec) -> Bool {
        a.isPaused || !overrides(.pause, a.id).isEmpty
    }

    func notBefore(_ a: ActivitySpec) -> Date? {
        overrides(.deferUntil, a.id).map(\.end).max()
    }

    /// Skipped/swapped today, moved away from this day, or deferred past the end of the day.
    func isExcluded(_ a: ActivitySpec) -> Bool {
        if !overrides(.exclude, a.id).isEmpty { return true }
        if let nb = notBefore(a), nb >= windowEnd { return true }
        return input.history.contains {
            $0.activityID == a.id && $0.outcome != .completed && $0.start >= day && $0.start < membershipEnd
        }
    }

    func boost(_ a: ActivitySpec) -> OverrideSpec? {
        overrides(.boost, a.id).filter { $0.factor > 0 }.max { $0.factor < $1.factor }
    }

    func doneToday(_ a: ActivitySpec) -> (count: Int, minutes: Int) {
        let done = input.history.filter {
            $0.activityID == a.id && $0.outcome == .completed && $0.start >= day && $0.start < membershipEnd
        }
        return (done.count, done.reduce(0) { $0 + $1.minutes })
    }

    func daysSince(_ a: ActivitySpec, _ ledger: ServiceLedger) -> Double {
        let ref = isToday ? windowStart : day
        let last = ledger.lastStart(a.id, before: ref) ?? a.createdAt
        if last <= Date.distantPast.addingTimeInterval(86_400) { return 365 }
        let d = cal.dateComponents([.day], from: cal.startOfDay(for: last), to: day).day ?? 0
        return Double(min(max(d, 0), 365))
    }

    /// Rolling 7-day window including this day. Rolling (not calendar-week) windows mean a missed
    /// session simply ages out; it is never carried forward as debt.
    var windowFrom: Date { cal.date(byAdding: .day, value: -6, to: day) ?? day }

    func time(_ d: Date) -> String {
        let c = cal.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    func dayName(_ d: Date) -> String {
        Scheduler.relativeDayName(d, today: input.planningDay, calendar: cal)
    }

    static func kind(for bucket: BucketKind) -> PlannedBlock.Kind {
        switch bucket {
        case .anchor: .anchor
        case .mainWork: .focus
        case .hobby: .hobby
        case .errand: .errand
        }
    }

    // MARK: Run

    mutating func run(ledger: inout ServiceLedger) -> DayPlan {
        var out: [PlannedBlock] = []

        // 1. Hard constraints: fixed commitments are emitted as-is and never moved.
        let commitments = input.commitments
            .filter { $0.end > $0.start && $0.start < windowEnd && $0.end > day }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
        for c in commitments {
            out.append(PlannedBlock(
                id: "fixed-\(c.id.uuidString)", kind: .fixed, activityID: nil, commitmentID: c.id,
                title: c.title, bucket: nil, phase: phase(at: c.start), start: c.start,
                minutes: Int(c.end.timeIntervalSince(c.start) / 60), isPinned: true, isPrimary: false,
                isOptional: false, reasons: ["Fixed commitment — never moved automatically"]))
        }

        guard windowEnd.timeIntervalSince(windowStart) >= 15 * 60 else {
            notes.append("This day's waking window has ended. Rest well.")
            return makePlan(out, freeMinutes: 0, budget: 0, bonus: [])
        }

        let buffer = Double(config.commitmentBufferMinutes) * 60
        var free = FreeTime(
            window: DateInterval(start: windowStart, end: windowEnd),
            busy: commitments.map {
                DateInterval(start: $0.start.addingTimeInterval(-buffer), end: $0.end.addingTimeInterval(buffer))
            } + sleeps.map {
                // Keep a little wind-down before each sleep free.
                DateInterval(start: $0.start.addingTimeInterval(-Double(config.windDownMinutes) * 60), end: $0.end)
            })
        guard free.totalMinutes >= 15 else {
            notes.append(isToday ? "Nothing more fits today — rest well." : "No free time on this day.")
            return makePlan(out, freeMinutes: free.totalMinutes, budget: 0, bonus: [])
        }
        let freeMinutes = free.totalMinutes
        // 2. Capacity: only a share of free time is ever planned.
        let flexibleBudget = Int(Double(freeMinutes) * config.utilisationTarget)
        var budget = flexibleBudget

        let activities = input.activities.sorted {
            ($0.sortIndex, $0.name, $0.id.uuidString) < ($1.sortIndex, $1.name, $1.id.uuidString)
        }
        let byID = activities.reduce(into: [UUID: ActivitySpec]()) { $0[$1.id] = $1 }
        var pending: [Pending] = []
        var pinnedIDs = Set<UUID>()
        var pinnedErrands: [UUID] = []

        // 3a. Pins: hard constraints that force an activity onto this day (they win over pauses).
        for o in dayOverrides.filter({ $0.kind == .pin })
            .sorted(by: { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }) {
            guard let a = byID[o.activityID], !pinnedIDs.contains(a.id), !isExcluded(a),
                  doneToday(a).count < max(1, a.maxSessionsPerDay) else { continue }
            var exact: Date?
            if let t = o.pinnedTime, t >= windowStart, t < windowEnd { exact = t }
            // An errand pinned to a day (no time) just goes to the top of that day's errand list.
            if a.bucket == .errand && exact == nil {
                pinnedErrands.append(a.id)
                pinnedIDs.insert(a.id)
                continue
            }
            var reasons = [exact.map { "Pinned by you at \(time($0))" } ?? "Pinned by you to this day"]
            if isPaused(a) { reasons.append("Your pin takes precedence over the pause") }
            pending.append(Pending(activity: a, minutes: a.preferredMinutes, kind: Self.kind(for: a.bucket),
                                   exactStart: exact, notBefore: notBefore(a), isPinned: true, reasons: reasons))
            pinnedIDs.insert(a.id)
            budget -= a.preferredMinutes
        }

        // 3b. Anchors: small keystone habits that start the day.
        var anchorMinutes = 0
        for a in activities where a.bucket == .anchor && !pinnedIDs.contains(a.id) && !isPaused(a) && !isExcluded(a) {
            guard shouldScheduleAnchor(a, ledger) else { continue }
            let minutes = energy == .low ? a.minMinutes : a.preferredMinutes
            guard anchorMinutes + minutes <= max(budget, 0) else {
                notes.append("Not enough free time for \(a.name) today.")
                continue
            }
            var reasons = [a.isKeystone ? "Keystone habit — a small win that builds momentum" : "Daily anchor"]
            if energy == .low && minutes < a.preferredMinutes { reasons.append("Low energy: shortened to \(minutes) min") }
            pending.append(Pending(activity: a, minutes: minutes, kind: .anchor, notBefore: notBefore(a), reasons: reasons))
            anchorMinutes += minutes
        }
        budget -= anchorMinutes

        // 4. Split capacity between buckets.
        let doneMain = activities.filter { $0.bucket == .mainWork }.reduce(0) { $0 + doneToday($1).minutes }
        let doneHobby = activities.filter { $0.bucket == .hobby }.reduce(0) { $0 + doneToday($1).minutes }
        let pinnedMain = pending.filter { $0.kind == .focus }.reduce(0) { $0 + $1.minutes }
        let pinnedHobby = pending.filter { $0.kind == .hobby }.reduce(0) { $0 + $1.minutes }
        let mainCap = max(0, config.mainWorkCap(for: energy) - doneMain - pinnedMain)
        let hobbyCap = max(0, config.hobbyBudget(for: energy) - doneHobby - pinnedHobby)
        let available = max(0, budget)
        var mainBudget: Int
        var hobbyBudget: Int
        if available >= mainCap + hobbyCap {
            mainBudget = mainCap
            hobbyBudget = hobbyCap
        } else {
            hobbyBudget = min(hobbyCap, max(min(config.hobbyFloorMinutes, available), Int(Double(available) * 0.3)))
            mainBudget = min(mainCap, available - hobbyBudget)
            if mainCap > 0 && mainBudget < mainCap / 2 {
                notes.append("A full day: focus time is scaled down to fit around your commitments.")
            }
        }
        if isToday && doneMain > 0 && mainCap == 0 {
            notes.append("You've already put in a full day of focused work. Anything more is a bonus.")
        }

        // 5. Projects: fair share by rank (CFS-style); deadline pace first.
        let mainEligible = activities.filter { a in
            guard a.bucket == .mainWork, !isPaused(a), !isExcluded(a) else { return false }
            // A deadline whose estimated work is done needs no more time.
            if a.deadline != nil, let rem = remainingWork(a, ledger), rem == 0 { return false }
            return true
        }
        // Preemption: if deadline pace needs more than the day's focus time, borrow from the evening (never below the floor).
        let paceNeed = mainEligible.reduce(0) { $0 + paceMinutes($1, ledger) }
        if paceNeed > mainBudget, mainBudget < mainCap, hobbyBudget > config.hobbyFloorMinutes {
            let shift = min(hobbyBudget - config.hobbyFloorMinutes, mainCap - mainBudget, paceNeed - mainBudget)
            hobbyBudget -= shift
            mainBudget += shift
            notes.append("A deadline needs the time, so the evening is a little shorter.")
        }
        let mainPending = allocateMainWork(eligible: mainEligible, budget: mainBudget, pending: pending, byID: byID, ledger: ledger)

        // 6. Hobbies.
        let (hobbyPending, bonus) = selectHobbies(
            activities: activities, budget: hobbyBudget, eveningStart: eveningStart,
            pinnedIDs: pinnedIDs, pending: pending, ledger: ledger)

        let pinnedPending = pending.filter(\.isPinned)
        let anchorsPending = pending.filter { !$0.isPinned }

        // 7. Placement.
        var unplacedPins: [Pending] = []
        for var p in pinnedPending {
            if let s = p.exactStart {
                let iv = DateInterval(start: s, duration: Double(p.minutes) * 60)
                if free.fits(iv) && ledger.recoveryOK(p.activity.id, start: s, minutes: p.minutes, restHours: p.activity.minRestHours) {
                    emit(p, start: s, minutes: p.minutes, reasons: p.reasons, into: &out)
                    let brk = Double(config.breakMinutes) * 60
                    free.reserve(DateInterval(start: s.addingTimeInterval(-brk), end: iv.end.addingTimeInterval(brk)))
                    ledger.add(p.activity.id, start: s, minutes: p.minutes)
                    continue
                }
                p.notBefore = s
                p.exactStart = nil
                p.reasons.append("Your pinned time clashed with a commitment, so it moved to the next free slot")
                notes.append("\(p.activity.name)'s pinned time clashes with a fixed commitment; it was moved to the next free slot instead.")
            }
            unplacedPins.append(p)
        }

        // Habits right after waking; focus can still use time before then (e.g. before you sleep).
        var habitCursor = wake
        let brk = Double(config.breakMinutes) * 60
        for p in unplacedPins.filter({ $0.kind == .anchor || $0.kind == .errand }) + anchorsPending {
            if let end = place(p, notBefore: habitCursor, free: &free, ledger: &ledger, into: &out) {
                habitCursor = end.addingTimeInterval(brk)
                free.reserve(DateInterval(start: end, end: habitCursor))
            }
        }
        // Today: from now (so time before you sleep gets used). Other days: after waking and habits,
        // falling back to earlier in the day only if the rest of the day is full.
        var cursor = isToday ? windowStart : wake
        var consecutive = 0
        let focus = unplacedPins.filter { $0.kind == .focus } + mainPending
        for p in focus {
            let end = isToday
                ? place(p, notBefore: cursor, free: &free, ledger: &ledger, into: &out)
                : place(p, notBefore: cursor, free: &free, ledger: &ledger, into: &out, quiet: true)
                    ?? place(p, notBefore: windowStart, free: &free, ledger: &ledger, into: &out)
            if let end {
                consecutive += 1
                let long = config.sessionsBeforeLongBreak > 0 && consecutive % config.sessionsBeforeLongBreak == 0
                cursor = max(cursor, end.addingTimeInterval(long ? Double(config.longBreakMinutes) * 60 : brk))
            }
        }
        for p in unplacedPins.filter({ $0.kind == .hobby }) + hobbyPending {
            let start = max(eveningStart, cursor)
            if let end = place(p, notBefore: start, free: &free, ledger: &ledger, into: &out, quiet: true)
                ?? place(p, notBefore: cursor, free: &free, ledger: &ledger, into: &out) {
                _ = end
            }
        }

        // 8. Errands: a short side list. Untimed, outside the budget, never part of the baseline.
        let errands = selectErrands(activities, pinned: pinnedErrands, pinnedIDs: pinnedIDs, ledger: &ledger)

        var plan = makePlan(out, freeMinutes: freeMinutes, budget: flexibleBudget, bonus: bonus)
        plan.errands = errands
        return plan
    }

    /// Due errands, most pressing first: deadline, then priority, then how long they've waited.
    /// One-offs stay until done; recurring ones are spaced like anchors. Chosen ones go into the
    /// ledger so later days don't repeat them.
    private func selectErrands(_ activities: [ActivitySpec], pinned: [UUID], pinnedIDs: Set<UUID>,
                               ledger: inout ServiceLedger) -> [UUID] {
        let due = activities.filter { a in
            guard a.bucket == .errand, !pinnedIDs.contains(a.id), !isPaused(a), !isExcluded(a),
                  doneToday(a).count == 0 else { return false }
            if a.sessionsPerWeek == 0 {
                return ledger.count(a.id, from: min(a.createdAt, windowFrom), to: membershipEnd) == 0
            }
            // Recurring: due once the rolling week is short and the spacing since the last one has passed.
            // A new errand that's never been done is due straight away.
            if ledger.count(a.id, from: windowFrom, to: membershipEnd) >= a.sessionsPerWeek { return false }
            guard let last = ledger.lastStart(a.id, before: isToday ? windowStart : day) else { return true }
            let since = cal.dateComponents([.day], from: cal.startOfDay(for: last), to: day).day ?? 0
            return since >= max(1, Int(7.0 / Double(a.sessionsPerWeek)))
        }
        .sorted { x, y in
            let dx = x.deadline ?? .distantFuture, dy = y.deadline ?? .distantFuture
            if dx != dy { return dx < dy }
            if x.priority != y.priority { return x.priority > y.priority }
            let ax = daysSince(x, ledger), ay = daysSince(y, ledger)
            if ax != ay { return ax > ay }
            return (x.sortIndex, x.id.uuidString) < (y.sortIndex, y.id.uuidString)
        }
        let urgentUntil = cal.date(byAdding: .day, value: 1, to: nextDay) ?? nextDay
        var chosen = pinned
        for a in due where chosen.count < max(config.errandsPerDay, pinned.count) || (a.deadline.map { $0 < urgentUntil } ?? false) {
            chosen.append(a.id)
        }
        let byID = activities.reduce(into: [UUID: ActivitySpec]()) { $0[$1.id] = $1 }
        for id in chosen {
            ledger.add(id, start: windowStart, minutes: byID[id]?.preferredMinutes ?? 15)
        }
        return chosen
    }

    /// Estimated work left at the start of this day: the input's figure minus what's been done or planned since.
    func remainingWork(_ a: ActivitySpec, _ ledger: ServiceLedger) -> Int? {
        guard let r = a.remainingWorkMinutes else { return nil }
        return max(0, r - ledger.minutes(a.id, from: input.planningDay, to: isToday ? input.now : day))
    }

    /// Days in a row (ending yesterday) with a *completed* session — what you actually did, not what was planned,
    /// so the plan can't talk itself into a streak.
    func actualStreak(_ id: UUID) -> Int {
        var n = 0
        var d = day
        while n < 30, let prev = cal.date(byAdding: .day, value: -1, to: d),
              input.history.contains(where: { $0.activityID == id && $0.outcome == .completed && $0.start >= prev && $0.start < d }) {
            n += 1
            d = prev
        }
        return n
    }

    func shouldScheduleAnchor(_ a: ActivitySpec, _ ledger: ServiceLedger) -> Bool {
        if doneToday(a).count >= max(1, a.maxSessionsPerDay) { return false }
        if a.sessionsPerWeek <= 0 { return false }
        if a.sessionsPerWeek >= 7 { return true }
        if ledger.count(a.id, from: windowFrom, to: membershipEnd) >= a.sessionsPerWeek { return false }
        let spacing = max(1, Int(7.0 / Double(a.sessionsPerWeek)))
        return daysSince(a, ledger) >= Double(spacing)
    }

    // MARK: Main Work allocation (quantum by quantum)

    /// Minutes a day a deadline estimate needs to stay on pace (0 if none).
    func paceMinutes(_ a: ActivitySpec, _ ledger: ServiceLedger) -> Int {
        guard let rem = remainingWork(a, ledger), rem > 0, let d = a.deadline else { return 0 }
        let days = cal.dateComponents([.day], from: day, to: cal.startOfDay(for: d)).day ?? -1
        guard days >= 0 else { return 0 }
        return Int(MainWorkPolicy.requiredPerDay(remaining: rem, daysLeft: days).rounded(.up))
    }

    func shareWeight(_ a: ActivitySpec) -> Double { max(a.weight, 0.001) * (boost(a)?.factor ?? 1) }

    /// Fair-share service, replayed day by day from history (and earlier planned days): each day decays the
    /// past, places everyone (nobody more than a session + granularity behind the least-served other — CFS
    /// wake-up placement), then adds that day's minutes. Being away or skipping never builds a backlog.
    func virtualService(_ list: [ActivitySpec], _ ledger: ServiceLedger, granularity: Double) -> [FairShare.Item] {
        let rank = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($1.id, $0) })
        let dayDecay = pow(2, -1 / max(config.serviceHalfLifeDays, 0.1))
        var items = list.map { FairShare.Item(id: $0.id, weight: shareWeight($0), service: 0, floor: Double($0.preferredMinutes), rank: rank[$0.id]!) }
        let at = isToday ? windowStart : day
        var d = cal.date(byAdding: .day, value: -21, to: day) ?? day
        while d < day {
            let next = cal.date(byAdding: .day, value: 1, to: d) ?? day
            items = FairShare.place(items, granularity: granularity)
            for i in items.indices {
                items[i].service = items[i].service * dayDecay + Double(ledger.minutes(items[i].id, from: d, to: next))
            }
            d = next
        }
        // Today so far (completed before now), then a final placement.
        for i in items.indices { items[i].service += Double(ledger.minutes(items[i].id, from: day, to: at)) }
        return FairShare.place(items, granularity: granularity)
    }

    /// Hands out the day's focus time one session at a time, CPU-style: deadline pace first (real-time),
    /// then whichever project is furthest behind its share — staying on the current one unless another is
    /// behind by more than `focusGranularityMinutes`.
    private mutating func allocateMainWork(
        eligible: [ActivitySpec], budget: Int, pending: [Pending], byID: [UUID: ActivitySpec], ledger: ServiceLedger
    ) -> [Pending] {
        var alloc: [UUID: [Int]] = [:]
        var order: [UUID] = []
        var pinnedCount: [UUID: Int] = [:]
        for p in pending where p.kind == .focus {
            alloc[p.activity.id, default: []].append(p.minutes)
            pinnedCount[p.activity.id, default: 0] += 1
            if !order.contains(p.activity.id) { order.append(p.activity.id) }
        }
        var why: [UUID: [String]] = [:]
        var remaining = budget
        // Wake-up allowance: one session. A returning project gets back in through the secondary slot straight away,
        // and takes over as main only once it's genuinely the most behind — no catch-up run.
        let placedItems = virtualService(eligible, ledger, granularity: 0)
        let service = Dictionary(uniqueKeysWithValues: placedItems.map { ($0.id, $0.service) })
        func canStart(_ a: ActivitySpec) -> Bool { alloc[a.id] != nil || order.count < config.maxMainActivitiesPerDay }
        /// With a work estimate, never plan more than what's left.
        func workLeft(_ a: ActivitySpec) -> Int {
            guard let rem = remainingWork(a, ledger) else { return .max }
            return max(0, rem - (alloc[a.id]?.reduce(0, +) ?? 0))
        }

        // Real-time class: deadline pace.
        for a in eligible {
            let pace = paceMinutes(a, ledger)
            guard pace > 0, let d = a.deadline else { continue }
            var need = max(pace, min(a.minMinutes, workLeft(a)))
            while need > 0, remaining > 0, canStart(a) {
                let q = min(a.preferredMinutes, need, remaining, workLeft(a))
                guard q > 0, q >= min(a.minMinutes, need) else { break }
                alloc[a.id, default: []].append(q)
                if !order.contains(a.id) { order.append(a.id) }
                remaining -= q
                need -= q
            }
            why[a.id] = ["Due \(dayName(d)) · ~\(MainWorkPolicy.hm(pace)) a day to finish on time"]
        }

        // Fair class, in two steps — runs, not rotation:
        // 1. The day's main project. Today's (if you've started), else what the plan already had for this day,
        //    else yesterday's stays — unless another is behind its share by more than `focusGranularityMinutes`
        //    (about a day's worth). It gets most of the day (`mainFocusShare`).
        // 2. The rest goes to whichever project is most behind (the optional secondary).
        let yesterday = cal.date(byAdding: .day, value: -1, to: day) ?? day
        let rank = Dictionary(uniqueKeysWithValues: eligible.enumerated().map { ($1.id, $0) })
        let base = service
        func items() -> [FairShare.Item] {
            eligible.map { a in
                FairShare.Item(id: a.id, weight: shareWeight(a), service: base[a.id]! + Double(alloc[a.id]?.reduce(0, +) ?? 0),
                               floor: Double(a.preferredMinutes), rank: rank[a.id]!)
            }
        }
        func fits(_ a: ActivitySpec) -> Bool {
            canStart(a) && workLeft(a) > 0 && min(a.preferredMinutes, remaining, workLeft(a)) >= min(a.minMinutes, workLeft(a))
        }
        func give(_ a: ActivitySpec) {
            let q = min(a.preferredMinutes, remaining, workLeft(a))
            alloc[a.id, default: []].append(q)
            if !order.contains(a.id) { order.append(a.id) }
            remaining -= q
        }
        let todayLast = isToday
            ? input.history.filter { r in r.outcome == .completed && r.start >= day && base[r.activityID] != nil }
                .max { $0.start < $1.start }?.activityID
            : nil
        let yesterdayMain = eligible.map { ($0.id, ledger.minutes($0.id, from: yesterday, to: day)) }.filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
        let incumbent = [todayLast, previousDay?.primaryActivityID, yesterdayMain].compactMap { $0 }
            .first { id in eligible.contains { $0.id == id } }
        let fairBudget = remaining
        let candidates = eligible.filter(fits)
        if !candidates.isEmpty,
           let choice = FairShare.pick(items(), allowed: Set(candidates.map(\.id)), incumbent: incumbent,
                                       granularity: config.focusGranularityMinutes, placed: true),
           let main = candidates.first(where: { $0.id == choice.id }) {
            let lag = FairShare.lags(items())
            if why[main.id] == nil {
                why[main.id] = [choice.stayed ? "Keeps the run going" : lag[main.id]! < -1 ? "Behind its share lately" : "Next in line by rank"]
            }
            let target = eligible.count == 1 || config.maxMainActivitiesPerDay == 1
                ? fairBudget : Int(Double(fairBudget) * config.mainFocusShare)
            var given = 0
            repeat {
                let before = remaining
                give(main)
                given += before - remaining
            } while remaining > 0 && given < target && fits(main)
        }
        var last: UUID?
        while remaining > 0 {
            let candidates = eligible.filter(fits)
            guard !candidates.isEmpty,
                  let choice = FairShare.pick(items(), allowed: Set(candidates.map(\.id)), incumbent: last,
                                              granularity: Double(candidates.map(\.preferredMinutes).max() ?? 50), placed: true),
                  let pick = candidates.first(where: { $0.id == choice.id }) else { break }
            if why[pick.id] == nil { why[pick.id] = ["Behind its share lately"] }
            give(pick)
            last = pick.id
        }

        // Primary focus = most allocated time (first chosen wins ties).
        var primary: UUID?
        var most = -1
        for id in order {
            let total = alloc[id]?.reduce(0, +) ?? 0
            if total > most { most = total; primary = id }
        }
        let sortedOrder = order.sorted { a, b in (a == primary ? 0 : 1) < (b == primary ? 0 : 1) }

        var result: [Pending] = []
        for id in sortedOrder {
            guard let a = byID[id] else { continue }
            let sessions = Array((alloc[id] ?? []).dropFirst(pinnedCount[id] ?? 0))
            var reasons: [String] = []
            if id == primary { reasons.append("Today's main focus") }
            if let b = boost(a) {
                reasons.append("Boosted ×\(MainWorkPolicy.fmt(b.factor)) through \(dayName(b.end.addingTimeInterval(-1)))")
            }
            reasons += why[id] ?? []
            if id != primary { reasons.append("Secondary — optional if you'd rather stop") }
            for m in sessions {
                result.append(Pending(activity: a, minutes: m, kind: .focus, notBefore: notBefore(a),
                                      isPrimary: id == primary, isOptional: id != primary, reasons: reasons))
            }
        }
        return result
    }

    // MARK: Hobbies

    /// One hobby per evening, CPU-style: the one furthest behind its share, but yesterday's hobby keeps going
    /// unless another is behind by more than `hobbyGranularitySessions` sessions (runs, not rotation). Recovery is hard.
    private mutating func selectHobbies(
        activities: [ActivitySpec], budget: Int, eveningStart: Date, pinnedIDs: Set<UUID>,
        pending: [Pending], ledger: ServiceLedger
    ) -> ([Pending], [UUID]) {
        let hobbies = activities.filter { $0.bucket == .hobby && !pinnedIDs.contains($0.id) && !isPaused($0) && !isExcluded($0) }
        let doneCount = activities.filter { $0.bucket == .hobby }.reduce(0) { $0 + doneToday($1).count }
            + pending.filter { $0.kind == .hobby }.count
        let rank = Dictionary(uniqueKeysWithValues: hobbies.enumerated().map { ($1.id, $0) })
        let shortest = Double(hobbies.map(\.preferredMinutes).min() ?? 30)
        let items = virtualService(hobbies, ledger, granularity: config.hobbyGranularitySessions * shortest)
        let lag = FairShare.lags(items)
        let v = items.reduce(into: [UUID: Double]()) { $0[$1.id] = $1.service / max($1.weight, 1e-6) }
        var ok: [ActivitySpec] = []
        for a in hobbies where doneToday(a).count == 0 {
            if ledger.recoveryOK(a.id, start: eveningStart, minutes: a.minMinutes, restHours: a.minRestHours) {
                ok.append(a)
            } else {
                notes.append("\(a.name) is a rest day (at least \(Int(a.minRestHours))h recovery between sessions).")
            }
        }
        ok.sort { (v[$0.id]!, rank[$0.id]!) < (v[$1.id]!, rank[$1.id]!) }
        guard doneCount < config.hobbiesPerDay, !ok.isEmpty else { return ([], ok.map(\.id)) }

        // Incumbent: yesterday's hobby (runs), else the plan's existing choice for this day (stability).
        let yesterday = cal.date(byAdding: .day, value: -1, to: day) ?? day
        let previous = previousDay?.blocks.first { $0.kind == .hobby && !$0.isOptional }?.activityID
        let incumbent = ok.first { ledger.count($0.id, from: yesterday, to: day) > 0 }?.id
            ?? previous.flatMap { p in ok.first { $0.id == p }?.id }
        // Stickiness scales with the current hobby's own session (1.5 × 30 min for a 30-min hobby).
        let granularity = config.hobbyGranularitySessions * Double(incumbent.flatMap { id in ok.first { $0.id == id }?.preferredMinutes } ?? 30)
        guard let choice = FairShare.pick(items, allowed: Set(ok.map(\.id)), incumbent: incumbent,
                                          granularity: granularity, placed: true),
              let pick = ok.first(where: { $0.id == choice.id }) else { return ([], ok.map(\.id)) }
        let stayed = ledger.count(pick.id, from: yesterday, to: day) > 0
        let minutes: Int
        if pick.preferredMinutes <= budget { minutes = pick.preferredMinutes }
        else if pick.minMinutes <= budget { minutes = pick.minMinutes }
        else { return ([], ok.map(\.id)) }
        var reasons: [String] = []
        if let b = boost(pick) { reasons.append("Boosted ×\(MainWorkPolicy.fmt(b.factor))") }
        reasons.append(stayed ? "Keeping the run going — day \(ledger.consecutiveDays(pick.id, before: day, calendar: cal) + 1)"
                       : lag[pick.id]! < -1 ? "Its turn — behind its share lately" : "Next up")
        let chosen = [Pending(activity: pick, minutes: minutes, kind: .hobby, notBefore: notBefore(pick), reasons: reasons)]
        var bonus = ok.filter { $0.id != pick.id }.map(\.id)
        bonus += activities.filter { $0.bucket != .hobby && $0.bucket != .errand && $0.bucket != .mainWork && $0.sessionsPerWeek == 0 && !isPaused($0) && !isExcluded($0) }.map(\.id)
        return (chosen, Array(bonus.prefix(4)))
    }

    // MARK: Placement

    private mutating func place(
        _ p: Pending, notBefore: Date, free: inout FreeTime, ledger: inout ServiceLedger,
        into out: inout [PlannedBlock], quiet: Bool = false
    ) -> Date? {
        let nb = max(notBefore, p.notBefore ?? notBefore, windowStart)
        var minutes = p.minutes
        var reasons = p.reasons
        var start: Date?
        if p.kind == .focus {
            // Focus can be split around sleep and appointments: take the earliest gap that fits the minimum.
            if let slot = free.firstFlexibleSlot(minimum: min(p.activity.minMinutes, minutes), preferred: minutes, notBefore: nb) {
                start = slot.start
                if slot.minutes < minutes { reasons.append("Shortened to fit the time available") }
                minutes = slot.minutes
            }
        } else {
            start = free.firstSlot(minutes: minutes, notBefore: nb)
            if start == nil, p.activity.minMinutes < minutes {
                minutes = p.activity.minMinutes
                start = free.firstSlot(minutes: minutes, notBefore: nb)
                if start != nil { reasons.append("Shortened to fit the time available") }
            }
        }
        guard let s = start else {
            if !quiet { notes.append("No room for \(p.activity.name) today — it will be picked up on another day.") }
            return nil
        }
        guard ledger.recoveryOK(p.activity.id, start: s, minutes: minutes, restHours: p.activity.minRestHours) else {
            if !quiet { notes.append("\(p.activity.name) is a rest day (recovery constraint).") }
            return nil
        }
        emit(p, start: s, minutes: minutes, reasons: reasons, into: &out)
        free.reserve(DateInterval(start: s, duration: Double(minutes) * 60))
        // An optional extra hobby only counts toward its week if you actually do it.
        if p.kind == .hobby && p.isOptional {
            ledger.addRestOnly(p.activity.id, start: s, minutes: minutes)
        } else {
            ledger.add(p.activity.id, start: s, minutes: minutes)
        }
        let end = s.addingTimeInterval(Double(minutes) * 60)
        // A focus session cut short by sleep or an appointment continues afterwards instead of being lost.
        if p.kind == .focus, minutes < p.minutes, p.minutes - minutes >= p.activity.minMinutes {
            var rest = p
            rest.minutes = p.minutes - minutes
            rest.exactStart = nil
            rest.reasons = p.reasons.filter { $0 != "Shortened to fit the time available" } + ["The rest of the session started earlier"]
            let resume = end.addingTimeInterval(Double(config.breakMinutes) * 60)
            return place(rest, notBefore: resume, free: &free, ledger: &ledger, into: &out, quiet: true) ?? end
        }
        return end
    }

    private mutating func emit(_ p: Pending, start: Date, minutes: Int, reasons: [String], into out: inout [PlannedBlock]) {
        let n = blockCounters[p.activity.id, default: 0]
        blockCounters[p.activity.id] = n + 1
        let c = cal.dateComponents([.year, .month, .day], from: day)
        let key = String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        out.append(PlannedBlock(
            id: "\(p.activity.id.uuidString)-\(key)-\(n)", kind: p.kind, activityID: p.activity.id, commitmentID: nil,
            title: p.activity.name, bucket: p.activity.bucket, phase: p.activity.bucket.phase, start: start,
            minutes: minutes, isPinned: p.isPinned, isPrimary: p.isPrimary, isOptional: p.isOptional, reasons: reasons))
    }

    func phase(at d: Date) -> DayPhase {
        if d >= wake && d < wake.addingTimeInterval(config.morningPhaseHours * 3600) { return .morning }
        if d >= eveningStart { return .evening }
        return .daytime
    }

    private func makePlan(_ blocks: [PlannedBlock], freeMinutes: Int, budget: Int, bonus: [UUID]) -> DayPlan {
        var seen = Set<String>()
        let uniqueNotes = notes.filter { seen.insert($0).inserted }
        return DayPlan(
            day: day, windowStart: windowStart, windowEnd: windowEnd, energy: energy,
            freeMinutes: freeMinutes, flexibleBudget: budget,
            blocks: blocks.sorted { ($0.start, $0.id) < ($1.start, $1.id) },
            notes: uniqueNotes, bonusIdeas: bonus, sleeps: sleeps, wake: wake)
    }
}

// MARK: - Stability metric

public enum PlanStability {
    /// Jaccard similarity of (day offset, activity, occurrence) triples across flexible blocks.
    /// 1.0 = identical assignment of activities to days.
    public static func similarity(_ a: WeekPlan, _ b: WeekPlan, calendar: Calendar) -> Double {
        func keys(_ p: WeekPlan) -> Set<String> {
            var set = Set<String>()
            for day in p.days {
                var counts: [UUID: Int] = [:]
                let c = calendar.dateComponents([.year, .month, .day], from: day.day)
                for b in day.flexibleBlocks {
                    guard let id = b.activityID else { continue }
                    let n = counts[id, default: 0]
                    counts[id] = n + 1
                    set.insert("\(c.year!)-\(c.month!)-\(c.day!)|\(id)|\(n)")
                }
            }
            return set
        }
        let ka = keys(a), kb = keys(b)
        let union = ka.union(kb)
        guard !union.isEmpty else { return 1 }
        return Double(ka.intersection(kb).count) / Double(union.count)
    }
}
