import Foundation

/// What rank means for one activity: its share of its kind's time. A *share*, not a quota — the scheduler
/// keeps everything close to its share over time (CPU-style), with no weekly counts.
public struct Allotment: Hashable, Sendable {
    public var rank: Int
    /// Fraction of its kind's time (projects: daytime focus, hobbies: evenings). 0…1.
    public var share: Double
    public var weight: Double
    /// Rough aim for the next 7 days, for display ("~16h"). The simulated plan is what actually happens.
    public var weeklyMinutes: Int
    /// Plain-language "why", e.g. "2nd of 3 projects · 34% of focus".
    public var reason: String
}

/// Turns rank order into share weights: w = ρ^rank (projects ρ = 0.7, hobbies ρ = 0.8).
/// Habits stay daily. Errands keep their own repeat. That's all the user has to decide: the order.
public enum Allocator {
    public static func balance(
        _ specs: [ActivitySpec], config: SchedulerConfig, defaultAwakeHours: Double
    ) -> (specs: [ActivitySpec], allotments: [UUID: Allotment]) {
        var out = specs.reduce(into: [UUID: ActivitySpec]()) { $0[$1.id] = $1 }
        var allot: [UUID: Allotment] = [:]
        func ranked(_ kind: BucketKind) -> [ActivitySpec] {
            specs.filter { $0.bucket == kind && !$0.isPaused }
                .sorted { ($0.sortIndex, $0.name, $0.id.uuidString) < ($1.sortIndex, $1.name, $1.id.uuidString) }
        }

        let habits = ranked(.anchor)
        for h in habits {
            if out[h.id]!.sessionsPerWeek <= 0 { out[h.id]?.sessionsPerWeek = 7 }
            out[h.id]?.isKeystone = true
        }

        // Nominal daily focus and evening time, for the "~16h" display only.
        let habitPerDay = habits.reduce(0.0) { $0 + Double($1.preferredMinutes) }
        let flexiblePerDay = defaultAwakeHours * 60 * config.utilisationTarget
        let focusPerWeek = 7 * max(0, min(Double(config.mainWorkCapNormal), flexiblePerDay - habitPerDay - Double(config.hobbyBudgetNormal)))

        for (kind, rho, label, perWeek) in [(BucketKind.mainWork, config.rankDecayMain, "project", focusPerWeek),
                                            (BucketKind.hobby, config.rankDecayHobby, "hobb", Double(config.hobbiesPerDay * 7))] {
            let list = ranked(kind)
            let weights = list.indices.map { pow(rho, Double($0)) }
            let total = weights.reduce(0, +)
            for (r, a) in list.enumerated() {
                let share = total > 0 ? weights[r] / total : 0
                out[a.id]?.weight = weights[r]
                out[a.id]?.priority = max(3, 5 - r)
                let aim = kind == .mainWork ? Int(share * perWeek) : Int((share * perWeek).rounded()) * a.preferredMinutes
                let noun = kind == .mainWork ? (list.count == 1 ? "project" : "projects") : (list.count == 1 ? "hobby" : "hobbies")
                allot[a.id] = Allotment(rank: r, share: share, weight: weights[r], weeklyMinutes: aim,
                                        reason: "\(ordinal(r + 1)) of \(list.count) \(noun) · \(Int((share * 100).rounded()))% of \(kind == .mainWork ? "focus" : "evenings")")
                _ = label
            }
        }
        return (specs.map { out[$0.id] ?? $0 }, allot)
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}

/// Per-activity planned minutes over the horizon, for "what changes if…" previews.
public enum PlanDiff {
    public struct Change: Hashable, Sendable {
        public let activityID: UUID
        public let before: Int
        public let after: Int
    }

    public static func minutes(_ plan: WeekPlan) -> [UUID: Int] {
        plan.allBlocks.reduce(into: [UUID: Int]()) { acc, b in
            if !b.isFixed, let id = b.activityID { acc[id, default: 0] += b.minutes }
        }
    }

    /// Changes of at least `threshold` minutes, biggest first.
    public static func changes(from a: WeekPlan, to b: WeekPlan, threshold: Int = 15) -> [Change] {
        let ma = minutes(a), mb = minutes(b)
        return Set(ma.keys).union(mb.keys)
            .map { Change(activityID: $0, before: ma[$0] ?? 0, after: mb[$0] ?? 0) }
            .filter { abs($0.after - $0.before) >= threshold }
            .sorted { (abs($0.after - $0.before), $0.activityID.uuidString) > (abs($1.after - $1.before), $1.activityID.uuidString) }
    }
}
