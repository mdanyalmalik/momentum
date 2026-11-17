import AppKit
import MomentumCore
import SwiftUI

/// Developer tool: `MOMENTUM_SNAPSHOT_DIR=/path` runs a scripted demo through the real model API,
/// renders each screen of the app's own window to PNG, then quits. Use with MOMENTUM_STORE_DIR.
@MainActor
enum Snapshotter {
    static var model: AppModel?

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
