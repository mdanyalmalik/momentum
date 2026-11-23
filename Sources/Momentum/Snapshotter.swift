import AppKit
import MomentumCore
import SwiftUI

/// Developer tool: `MOMENTUM_SNAPSHOT_DIR=/path` runs a scripted demo through the real model API,
/// renders each screen of the app's own window to PNG, then quits. Use with MOMENTUM_STORE_DIR.
@MainActor
enum Snapshotter {
    static var model: AppModel?

    static var isRequested: Bool { ProcessInfo.processInfo.environment["MOMENTUM_SNAPSHOT_DIR"] != nil }

    /// Keeps snapshot runs out of the way: every window (sheets included) is transparent, click-through and
    /// behind other apps. Rendering for the PNGs doesn't depend on the window being visible on screen.
    static func hideWindows() {
        func hide() {
            for w in NSApp.windows {
                w.alphaValue = 0
                w.ignoresMouseEvents = true
                w.orderBack(nil)
            }
        }
        hide()
        NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
            guard let w = note.object as? NSWindow, w.alphaValue != 0 else { return }
            w.alphaValue = 0
            w.ignoresMouseEvents = true
        }
    }

    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["MOMENTUM_SNAPSHOT_DIR"], let model else { return }
        // The demo writes sample data, boosts and fake history: only ever into a throwaway store.
        guard ProcessInfo.processInfo.environment["MOMENTUM_STORE_DIR"] != nil else {
            NSLog("Momentum: snapshot mode needs MOMENTUM_STORE_DIR (a scratch store). Ignoring.")
            return
        }
        let out = URL(filePath: dir, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if ProcessInfo.processInfo.environment["MOMENTUM_SNAPSHOT_ONLY"] != nil {
                for screen in Screen.allCases {
                    model.screen = screen
                    try? await Task.sleep(for: .seconds(0.8))
                    capture(out, "relaunch-\(screen.rawValue)")
                }
                if ProcessInfo.processInfo.environment["MOMENTUM_SNAPSHOT_LOG"] != nil,
                   let first = model.activities(in: .mainWork).first {
                    model.screen = .today
                    model.logActivityID = first.id
                    model.showLogTime = true
                    try? await Task.sleep(for: .seconds(1))
                    capture(out, "log-sheet")
                    model.showLogTime = false
                    try? await Task.sleep(for: .seconds(0.5))
                    model.logTime(first.id, minutes: 120, endedAt: .now)
                    try? await Task.sleep(for: .seconds(1))
                    capture(out, "log-after")
                }
                if ProcessInfo.processInfo.environment["MOMENTUM_SNAPSHOT_WEEKEDIT"] != nil,
                   let grind = model.activities(in: .mainWork).first {
                    let f = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
                    let dump = { (tag: String) in
                        for d in model.plan.days.prefix(3) {
                            NSLog("Momentum snapshot: WEEKEDIT %@ %@ %@ | %@", tag, d.day.formatted(.dateTime.weekday(.abbreviated)),
                                  d.blocks.map { "\($0.title)@\(f($0.start))+\($0.minutes)\($0.hold.map { "[\($0.rawValue)]" } ?? "")" }.joined(separator: ", "),
                                  d.notes.joined(separator: "; "))
                        }
                    }
                    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: model.planningDay)!
                    model.screen = .week
                    dump("before")
                    model.setFocusDay(tomorrow, activityID: grind.id)
                    dump("focus")
                    try? await Task.sleep(for: .seconds(1))
                    capture(out, "week-focus")
                    // Fix the first project block the day after at its time; make a hobby flexible.
                    let dayAfter = model.plan.days[2]
                    if let b = dayAfter.blocks.first(where: { $0.kind == .focus }) { model.setHold(b, fixed: true) }
                    if let h = model.plan.days[2].blocks.first(where: { $0.kind == .hobby }) { model.setHold(h, fixed: false) }
                    dump("held")
                    // Same disturbance: an appointment over the fixed block's time.
                    if let fb = model.plan.days[2].blocks.first(where: { $0.hold == .fixed }) {
                        model.addCommitment(title: "Test call", start: fb.start.addingTimeInterval(-1800), end: fb.start.addingTimeInterval(1800), category: "")
                    }
                    dump("appt")
                    try? await Task.sleep(for: .seconds(1))
                    capture(out, "week-held")
                    if let b = model.plan.days[2].blocks.first(where: { $0.kind == .focus }) { model.editPlanItem(b) }
                    try? await Task.sleep(for: .seconds(1))
                    capture(out, "week-sheet")
                    NSApp.terminate(nil)
                    return
                }
                if ProcessInfo.processInfo.environment["MOMENTUM_SNAPSHOT_ERRAND"] != nil,
                   let a = model.activities(in: .errand).first(where: { $0.completedAt != nil && !model.isErrandDoneToday($0) }) {
                    let state = { (tag: String) in
                        NSLog("Momentum snapshot: ERRAND %@ %@ completed=%@ doneToday=%d open=%@ sessions=%d wins=%d", tag, a.name,
                              a.completedAt.map { "\($0)" } ?? "nil", model.isErrandDoneToday(a) ? 1 : 0,
                              model.openErrands.map(\.name).joined(separator: ","),
                              model.sessions(from: .distantPast, to: .distantFuture).filter { $0.activityID == a.id }.count, model.winsToday)
                    }
                    state("before")
                    model.toggleErrand(a.id); state("reopened")
                    model.startBonus(a.id)
                    model.running?.startedAt = .now.addingTimeInterval(-20 * 60)
                    model.screen = .today
                    try? await Task.sleep(for: .seconds(1))
                    capture(out, "errand-running")
                    model.completeRunning(finished: false); state("stopped-not-done")
                    try? await Task.sleep(for: .seconds(1))
                    capture(out, "errand-after-stop")
                    model.toggleErrand(a.id); state("ticked")
                    try? await Task.sleep(for: .seconds(1))
                    capture(out, "errand-ticked")
                    model.toggleErrand(a.id); state("unticked")
                    NSApp.terminate(nil)
                    return
                }
                if ProcessInfo.processInfo.environment["MOMENTUM_SNAPSHOT_PLANAT"] != nil {
                    let f = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
                    var t = AppModel.wholeMinute(.now)
                    let stop = t.addingTimeInterval(9 * 3600)
                    while t < stop {
                        let plan = Scheduler(config: model.settings.config).plan(model.makeInput(now: t, specs: model.balancedSpecs().specs))
                        let d = plan.days[0]
                        NSLog("Momentum snapshot: PLAN %@ [%@] %@ | sleeps %@ | notes %@", f(t), d.day.formatted(.dateTime.day()),
                              d.blocks.map { "\($0.title)@\(f($0.start))+\($0.minutes)" }.joined(separator: ", "),
                              d.sleeps.map { f($0.start) }.joined(separator: ","), d.notes.joined(separator: "; "))
                        t.addTimeInterval(30 * 60)
                    }
                    NSApp.terminate(nil)
                    return
                }
                if ProcessInfo.processInfo.environment["MOMENTUM_SNAPSHOT_PAUSES"] != nil, let a = model.activities(in: .hobby).first {
                    let f = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
                    let now = AppModel.wholeMinute(.now)
                    model.startBonus(a.id)
                    model.togglePauseTimer(); model.togglePauseTimer()   // a split-second pause: ignored
                    model.running?.startedAt = now.addingTimeInterval(-60 * 60)
                    model.running?.pauses = (model.running?.pauses ?? []) + [DateInterval(start: now.addingTimeInterval(-40 * 60), end: now.addingTimeInterval(-25 * 60))]
                    model.running?.pausedSeconds = 15 * 60
                    @MainActor func dump(_ label: String) {
                        let e = model.trackedEntries(on: model.planningDay).filter { $0.activityID == a.id || $0.isRunning }
                            .map { "\(f($0.interval.start))–\($0.ongoing ? "now" : f($0.interval.end))" }
                        NSLog("Momentum snapshot: [%@] %@ entries %@ | gaps %@ | active %dm", label, a.name, e.joined(separator: ", "),
                              model.untrackedGaps().suffix(2).map { "\(f($0.start))–\(f($0.end))" }.joined(separator: ", "),
                              Int((model.running?.activeSeconds() ?? 0) / 60))
                    }
                    dump("running")
                    model.screen = .today
                    try? await Task.sleep(for: .seconds(1.2))
                    capture(out, "pauses-running")
                    model.completeRunning()
                    let ss = model.todaySessions.filter { $0.activityID == a.id }.sorted { $0.start < $1.start }
                    NSLog("Momentum snapshot: recorded %@", ss.map { "\(f($0.start))–\(f($0.end)) \($0.minutes)m" }.joined(separator: ", "))
                    dump("done")
                    NSApp.terminate(nil)
                    return
                }
                if ProcessInfo.processInfo.environment["MOMENTUM_SNAPSHOT_OVERTIME"] != nil {
                    for a in model.startableActivities().filter({ $0.hasTwoPhaseTimer }).prefix(1) + model.activities(in: .mainWork).prefix(1) {
                        model.startBonus(a.id)
                        model.running?.startedAt = Date.now.addingTimeInterval(-3 * 3600 - 5 * 60)
                        model.running?.pausedSeconds = 300
                        let planned = model.running?.plannedMinutes ?? 0
                        model.completeRunning()
                        let s = model.todaySessions.filter { $0.activityID == a.id }.max { $0.minutes < $1.minutes }
                        NSLog("Momentum snapshot: overtime %@ planned %dm ran 3h active → counted %dm", a.name, planned, s?.minutes ?? -1)
                    }
                    NSApp.terminate(nil)
                    return
                }
                if ProcessInfo.processInfo.environment["MOMENTUM_SNAPSHOT_APPTSTATS"] != nil {
                    let f = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
                    let now = AppModel.wholeMinute(.now)
                    // A past appointment (category Work) and one overlapping a session, then an errand timed for 12 min.
                    model.addCommitment(title: "Standup", start: now.addingTimeInterval(-50 * 60), end: now.addingTimeInterval(-20 * 60), category: "Work")
                    model.addCommitment(title: "Dentist", start: now.addingTimeInterval(-26 * 3600), end: now.addingTimeInterval(-25 * 3600))
                    NSLog("Momentum snapshot: categories %@", model.appointmentCategories.joined(separator: ","))
                    for t in model.appointmentTime(from: now.addingTimeInterval(-3 * 86_400), to: now) {
                        NSLog("Momentum snapshot: appt %@ [%@] %@–%@ counts %dm", t.appointment.title, t.appointment.statsName, f(t.interval.start), f(t.interval.end), t.minutes)
                    }
                    if let errand = model.openErrands.first {
                        model.startBonus(errand.id)
                        model.running?.startedAt = now.addingTimeInterval(-12 * 60)
                        NSLog("Momentum snapshot: errand timer %@ running %d", errand.name, model.running?.activityID == errand.id ? 1 : 0)
                        model.completeRunning()
                        NSLog("Momentum snapshot: errand done today %d, open errands now %d", model.isErrandDoneToday(errand) ? 1 : 0, model.openErrands.count)
                    } else { NSLog("Momentum snapshot: no open errand") }
                    let e = model.trackedEntries(on: model.planningDay).map { "\($0.name)\($0.isAppointment ? "(appt)" : "") \(f($0.interval.start))–\(f($0.interval.end))" }
                    NSLog("Momentum snapshot: entries %@ | gaps %@", e.joined(separator: ", "), model.untrackedGaps().map { "\(f($0.start))–\(f($0.end))" }.joined(separator: ", "))
                    let items = StatsView.items(model: model, from: now.addingTimeInterval(-28 * 86_400), to: now)
                    let rows = StatsView.rows(items, [])
                    NSLog("Momentum snapshot: stats rows %@", rows.prefix(12).map { "\($0.name)=\($0.minutes)m(\($0.group.title))" }.joined(separator: ", "))
                    model.screen = .stats
                    try? await Task.sleep(for: .seconds(1.2))
                    capture(out, "appt-stats")
                    model.screen = .today
                    try? await Task.sleep(for: .seconds(1.2))
                    capture(out, "appt-today")
                    if let c = model.commitments.first(where: { $0.title == "Standup" }) {
                        model.editCommitment(c.id)
                        try? await Task.sleep(for: .seconds(1))
                        capture(out, "appt-sheet")
                    }
                    NSApp.terminate(nil)
                    return
                }
                if let step = ProcessInfo.processInfo.environment["MOMENTUM_SNAPSHOT_TRACK"] {
                    let f = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
                    @MainActor func dump(_ label: String) {
                        let e = model.trackedEntries(on: model.planningDay).map { "\($0.name) \(f($0.interval.start))–\(f($0.interval.end))" }
                        let g = model.untrackedGaps().map { "\(f($0.start))–\(f($0.end))" }
                        NSLog("Momentum snapshot: [%@] entries: %@ | gaps: %@ | running: %@", label, e.joined(separator: ", "), g.joined(separator: ", "),
                              model.running.map { "\($0.title) from \(f($0.startedAt)) active \(Int($0.activeSeconds() / 60))m planned \($0.plannedMinutes)m" } ?? "none")
                    }
                    model.screen = .today
                    try? await Task.sleep(for: .seconds(1))
                    let last = model.lastSessionToday
                    NSLog("Momentum snapshot: last session %@, since-last starts %@", last?.activityName ?? "nil", f(model.sinceLastStart))
                    dump("before")
                    if let id = last?.activityID {
                        switch step {
                        case "sheet":
                            capture(out, "track-today")
                            model.showLogTime = true
                            try? await Task.sleep(for: .seconds(1.2))
                            capture(out, "track-sheet")
                            model.showLogTime = false
                        case "until":
                            if let reading = model.activities.first(where: { $0.name == "Reading" }) {
                                NSLog("Momentum snapshot: until-10m ok %d", model.logRange(reading.id, start: model.sinceLastStart, end: .now.addingTimeInterval(-600), keepRunning: true) ? 1 : 0)
                            }
                        case "trim":
                            if let guitar = model.activities.first(where: { $0.name == "Guitar" }) {
                                model.logActivityID = guitar.id
                                model.logPrefill = (60, .now)
                                model.showLogTime = true
                                try? await Task.sleep(for: .seconds(1.2))
                                capture(out, "track-trim")
                                model.showLogTime = false
                            }
                        case "merge":
                            NSLog("Momentum snapshot: merge ok %d", model.logRange(id, start: model.sinceLastStart, end: .now, mergeInto: model.lastSessionToday?.id) ? 1 : 0)
                        case "mergerun":
                            NSLog("Momentum snapshot: merge+run ok %d", model.logRange(id, start: model.sinceLastStart, end: .now, mergeInto: model.lastSessionToday?.id, keepRunning: true) ? 1 : 0)
                            try? await Task.sleep(for: .seconds(1))
                            dump("running")
                            model.completeRunning()
                        case "newrun":
                            if let reading = model.activities.first(where: { $0.name == "Reading" }) {
                                NSLog("Momentum snapshot: new+run ok %d", model.logRange(reading.id, start: model.sinceLastStart, end: .now, keepRunning: true) ? 1 : 0)
                                try? await Task.sleep(for: .seconds(1))
                                capture(out, "track-running")
                            }
                        default: break
                        }
                    }
                    try? await Task.sleep(for: .seconds(0.8))
                    dump("after")
                    if step != "sheet" { capture(out, "track-after-\(step)") }
                    NSApp.terminate(nil)
                    return
                }
                if ProcessInfo.processInfo.environment["MOMENTUM_SNAPSHOT_LOGOVERLAP"] != nil,
                   let grind = model.activities.first(where: { $0.name.hasPrefix("Job-Related") }),
                   let guitar = model.activities.first(where: { $0.name == "Guitar" }),
                   let reading = model.activities.first(where: { $0.name == "Reading" }),
                   let last = model.todaySessions.last(where: { $0.activityID == grind.id && $0.outcome == .completed }) {
                    let f = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
                    let lastEnd = last.start.addingTimeInterval(Double(last.minutes) * 60)
                    NSLog("Momentum snapshot: existing %@ %@–%@", grind.name, f(last.start), f(lastEnd))
                    let clashEnd = last.start.addingTimeInterval(20 * 60)
                    let c = model.logConflicts(start: clashEnd.addingTimeInterval(-30 * 60), end: clashEnd)
                    NSLog("Momentum snapshot: Guitar 30m ending %@ conflicts: %@", f(clashEnd), c.map { "\($0.name) \(f($0.interval.start))–\(f($0.interval.end))" }.joined(separator: "; "))
                    NSLog("Momentum snapshot: logTime accepted? %d", model.logTime(guitar.id, minutes: 30, endedAt: clashEnd) ? 1 : 0)
                    let fit = model.latestFreeEnd(minutes: 47, notAfter: clashEnd)
                    NSLog("Momentum snapshot: fit 47m ends %@", fit.map(f) ?? "nil")
                    model.screen = .today
                    model.logActivityID = guitar.id
                    model.logPrefill = (47, clashEnd)
                    model.showLogTime = true
                    try? await Task.sleep(for: .seconds(1.2))
                    capture(out, "log-overlap")
                    model.showLogTime = false
                    try? await Task.sleep(for: .seconds(0.6))
                    if let fit {
                        NSLog("Momentum snapshot: logTime 47m at fit accepted? %d", model.logTime(guitar.id, minutes: 47, endedAt: fit) ? 1 : 0)
                        if let s = model.todaySessions.last(where: { $0.activityID == guitar.id && $0.outcome == .completed }) {
                            NSLog("Momentum snapshot: stored Guitar %@ + %d min", f(s.start), s.minutes)
                        }
                    }
                    _ = lastEnd
                    NSLog("Momentum snapshot: continue accepted? %d", model.logRange(reading.id, start: .now.addingTimeInterval(-15 * 60), end: .now, keepRunning: true) ? 1 : 0)
                    try? await Task.sleep(for: .seconds(1.5))
                    NSLog("Momentum snapshot: running %@ started %@ active %.0fs", model.running?.title ?? "nil", model.running.map { f($0.startedAt) } ?? "-", model.running?.activeSeconds() ?? -1)
                    capture(out, "log-continue")
                    model.completeRunning()
                    if let s = model.todaySessions.last(where: { $0.activityID == reading.id && $0.outcome == .completed }) {
                        NSLog("Momentum snapshot: stored Reading %@ + %d min", f(s.start), s.minutes)
                    }
                    NSApp.terminate(nil)
                    return
                }
                if ProcessInfo.processInfo.environment["MOMENTUM_SNAPSHOT_SWAP"] != nil {
                    model.screen = .today
                    @MainActor func log(_ label: String) {
                        let blocks = model.todayPlan?.flexibleBlocks.map { "\($0.title)@\($0.start.formatted(date: .omitted, time: .shortened))" } ?? []
                        NSLog("Momentum snapshot: %@ | set aside: %@ | today: %@", label,
                              model.setAsideToday.map(\.name).joined(separator: ", "), blocks.joined(separator: ", "))
                    }
                    try? await Task.sleep(for: .seconds(1))
                    log("start"); capture(out, "swap-1-start")
                    if let g = model.setAsideToday.first(where: { $0.name == "Guitar" }) {
                        model.bringBack(g.id)
                        try? await Task.sleep(for: .seconds(1))
                        log("brought back Guitar"); capture(out, "swap-2-back")
                    }
                    if let b = model.todayPlan?.flexibleBlocks.first(where: { $0.title == "Guitar" }),
                       let other = model.startableActivities(excluding: b.activityID).first(where: { $0.kind == .mainWork && !model.setAsideToday.contains($0) }) {
                        model.swap(b, with: other.id)
                        try? await Task.sleep(for: .seconds(1))
                        log("swapped Guitar for \(other.name)"); capture(out, "swap-3-with")
                        model.impactNote?.undo()
                        try? await Task.sleep(for: .seconds(1))
                        log("undo")
                    }
                    NSApp.terminate(nil)
                    return
                }
                if let step = ProcessInfo.processInfo.environment["MOMENTUM_SNAPSHOT_TIMER"] {
                    // "start": start a session and quit. "check": relaunch and show Today.
                    if step == "start", let first = model.activities(in: .mainWork).first {
                        model.startBonus(first.id)
                        NSLog("Momentum snapshot: started %@", first.name)
                    } else if step == "pause" {
                        try? await Task.sleep(for: .seconds(2))
                        model.togglePauseTimer()
                        let a = model.running?.activeSeconds() ?? -1
                        try? await Task.sleep(for: .seconds(3))
                        NSLog("Momentum snapshot: paused=%d active %.1f -> %.1f after 3s", model.running?.isPaused == true ? 1 : 0, a, model.running?.activeSeconds() ?? -1)
                        model.screen = .today
                        capture(out, "timer-paused")
                    } else if step == "resume" {
                        NSLog("Momentum snapshot: relaunch paused=%d active %.1f", model.running?.isPaused == true ? 1 : 0, model.running?.activeSeconds() ?? -1)
                        model.togglePauseTimer()
                        try? await Task.sleep(for: .seconds(2))
                        NSLog("Momentum snapshot: resumed, active %.1f after 2s", model.running?.activeSeconds() ?? -1)
                    } else {
                        NSLog("Momentum snapshot: running after relaunch = %@", model.running?.title ?? "nil")
                        model.screen = .today
                        try? await Task.sleep(for: .seconds(1))
                        capture(out, "timer-relaunch")
                    }
                    NSApp.terminate(nil)
                    return
                }
                if ProcessInfo.processInfo.environment["MOMENTUM_SNAPSHOT_APPT"] != nil {
                    if model.commitments.filter({ $0.end > .now }).isEmpty {
                        let s = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: .now.addingTimeInterval(86_400))!
                        model.addCommitment(title: "Dentist", start: s, end: s.addingTimeInterval(3600))
                    }
                    model.screen = .week
                    try? await Task.sleep(for: .seconds(1))
                    capture(out, "appt-week")
                    if let c = model.commitments.first(where: { $0.end > .now }) {
                        model.editCommitment(c.id)
                        try? await Task.sleep(for: .seconds(1))
                        capture(out, "appt-edit")
                        model.showCommitmentSheet = false
                    }
                }
                if ProcessInfo.processInfo.environment["MOMENTUM_SNAPSHOT_INTERACT"] != nil {
                    model.screen = .buckets
                    model.editor = .new(.mainWork)
                    try? await Task.sleep(for: .seconds(1.2))
                    capture(out, "relaunch-add")
                    model.editor = nil
                    try? await Task.sleep(for: .seconds(0.6))
                    if let second = model.activities(in: .mainWork).dropFirst().first {
                        model.editor = .edit(second.id)
                        try? await Task.sleep(for: .seconds(1.2))
                        capture(out, "relaunch-edit")
                        model.editor = nil
                        try? await Task.sleep(for: .seconds(0.6))
                        model.nudge(second.id, by: -1)
                        try? await Task.sleep(for: .seconds(0.8))
                        capture(out, "relaunch-reorder")
                    }
                }
                NSApp.terminate(nil)
                return
            }
            if model.showOnboarding { capture(out, "00-onboarding") }
            model.finishOnboarding(withSamples: true)
            try? await Task.sleep(for: .seconds(0.8))
            capture(out, "01-startday")
            let wake = Calendar.current.date(byAdding: .hour, value: -2, to: .now)!
            model.startDay(wake: wake, energy: .normal, bedtime: wake.addingTimeInterval(16 * 3600))
            if let interview = model.activities.first(where: { $0.name.hasPrefix("Interview") }) {
                model.addBoost(interview.id, days: 5, factor: 2.5)
            }
            if let a = model.activities.first(where: { $0.name.hasPrefix("Personal") }) {
                model.addPause(a.id, until: Calendar.current.date(byAdding: .day, value: 3, to: .now)!)
            }
            let s = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: .now.addingTimeInterval(86_400))!
            model.addCommitment(title: "Dentist", start: s, end: s.addingTimeInterval(5400))
            for screen in Screen.allCases {
                model.screen = screen
                try? await Task.sleep(for: .seconds(0.8))
                capture(out, "10-\(screen.rawValue)")
            }
            model.screen = .today
            if let errand = model.errandsToday.first { model.toggleErrand(errand.id) }
            try? await Task.sleep(for: .seconds(0.6))
            capture(out, "15-today-errand-ticked")
            if let first = model.todayPlan?.flexibleBlocks.first {
                model.start(first)
                try? await Task.sleep(for: .seconds(1.2))
                capture(out, "20-timer")
                model.completeRunning()
                try? await Task.sleep(for: .seconds(0.5))
                capture(out, "21-completed")
            }
            if let next = model.todayPlan?.flexibleBlocks.first { model.skip(next) }
            try? await Task.sleep(for: .seconds(0.8))
            capture(out, "22-after-skip")
            if let id = model.activities.first(where: { $0.name.hasPrefix("Interview") })?.id {
                model.editor = .edit(id)
                try? await Task.sleep(for: .seconds(0.8))
                capture(out, "30-editor")
                model.editor = nil
            }
            try? await Task.sleep(for: .seconds(0.5))
            // Stats & Plans, with some made-up history (scratch stores only).
            let cal = Calendar.current
            for (i, a) in model.activities.filter({ $0.kind != .errand }).enumerated() {
                for d in stride(from: 1, through: 70, by: 1 + i % 3) {
                    let start = cal.date(byAdding: .day, value: -d, to: .now)!
                    model.context.insert(ActivitySession(activityID: a.id, activityName: a.name, bucket: a.kind, start: start,
                                                         minutes: a.preferredMinutes, outcome: .completed, isBonus: false))
                }
            }
            model.save()
            model.replan("Seeded demo history")
            model.screen = .stats
            try? await Task.sleep(for: .seconds(1))
            capture(out, "50-stats")
            if let project = model.activities(in: .mainWork).first {
                try? PlansStore.create(in: project.id, name: "Plan", contents: """
                # \(project.name)

                **Goal:** land the offer. Practise *every* day, keep notes in `notes.md`.

                ## This week
                - [x] Behavioural stories
                - [ ] System design: rate limiter
                  - read the [paper](https://example.com)
                - [ ] Mock interview

                > Small steps beat big plans.

                | Day | Focus |
                |-----|-------|
                | Mon | Arrays |
                | Tue | Graphs |

                ```python
                def two_sum(nums, target): ...
                ```
                """)
                model.planActivityID = project.id
            }
            model.screen = .plans
            try? await Task.sleep(for: .seconds(1))
            capture(out, "51-plans")
            model.planFocus = true
            try? await Task.sleep(for: .seconds(1))
            capture(out, "52-plans-focus")
            model.planFocus = false
            // Sleep → nap → bedtime.
            @MainActor func log(_ label: String) {
                let d = model.todayPlan
                print("SNAP \(label): day=\(model.planningDay.formatted(date: .abbreviated, time: .omitted)) end=\(d?.windowEnd.formatted(date: .omitted, time: .shortened) ?? "-") blocks=\(d?.flexibleBlocks.count ?? 0) sleeping=\(model.currentSleep != nil)")
            }
            log("before-sleep"); model.plan.notes.forEach { print("NOTE", $0) }
            model.goToSleep()
            try? await Task.sleep(for: .seconds(0.8))
            log("sleeping")
            capture(out, "40-sleeping")
            model.showWakeSheet = true
            try? await Task.sleep(for: .seconds(0.8))
            capture(out, "41-wake-sheet")
            model.showWakeSheet = false
            try? await Task.sleep(for: .seconds(0.5))
            model.wakeUp(at: .now, bedtime: .now.addingTimeInterval(5 * 3600), energy: .low)
            try? await Task.sleep(for: .seconds(0.8))
            log("after-nap")
            capture(out, "42-after-nap")
            model.setBedtime(.now.addingTimeInterval(2 * 3600))
            try? await Task.sleep(for: .seconds(0.5))
            log("bedtime-2h")
            model.showBedtimeSheet = true
            try? await Task.sleep(for: .seconds(0.8))
            capture(out, "43-bedtime")
            model.showBedtimeSheet = false
            try? await Task.sleep(for: .seconds(0.3))
            NSApp.terminate(nil)
        }
    }

    static func capture(_ dir: URL, _ name: String) {
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let suffix = i == 0 ? "" : "-w\(i)"
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name)\(suffix).png"))
        }
    }
}
