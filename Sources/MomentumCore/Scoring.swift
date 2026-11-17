import Foundation

/// One additive term of a score, kept for explanations and debugging.
public struct ScoreComponent: Hashable, Sendable {
    public let name: String
    /// Normalised signal in 0...1.
    public let value: Double
    public let weight: Double
    public var contribution: Double { value * weight }
}

public struct ScoreBreakdown: Hashable, Sendable {
    public let components: [ScoreComponent]
    /// Multiplicative boost from a Boost override (1 = none).
    public let boost: Double
    public let reasons: [String]

    public var base: Double { components.reduce(0) { $0 + $1.contribution } }
    public var total: Double { base * boost }

    public func value(_ name: String) -> Double {
        components.first { $0.name == name }?.value ?? 0
    }
}

// MARK: - Main Work

/// Measurements the scheduler gathers for one Main Work activity on one day.
public struct MainWorkSignals: Hashable, Sendable {
    public var priority: Int
    public var daysSinceLast: Double
    public var daysUntilDeadline: Int?
    /// Minutes received in the rolling 7-day window (history + already-planned days).
    public var minutesInWindow: Int
    public var targetMinutesPerWeek: Int
    /// Consecutive days immediately before this one with at least one session.
    public var consecutiveDays: Int
    public var boost: Double
    /// < 1 when another, higher-priority activity is boosted today (lower-priority work is deferred).
    public var deferral: Double
    /// Estimated work still left before the deadline, as of this day. nil = no estimate.
    public var remainingWorkMinutes: Int?

    public init(priority: Int, daysSinceLast: Double, daysUntilDeadline: Int?, minutesInWindow: Int,
                targetMinutesPerWeek: Int, consecutiveDays: Int, boost: Double = 1, deferral: Double = 1,
                remainingWorkMinutes: Int? = nil) {
        self.deferral = deferral
        self.remainingWorkMinutes = remainingWorkMinutes
        self.priority = priority
        self.daysSinceLast = daysSinceLast
        self.daysUntilDeadline = daysUntilDeadline
        self.minutesInWindow = minutesInWindow
        self.targetMinutesPerWeek = targetMinutesPerWeek
        self.consecutiveDays = consecutiveDays
        self.boost = boost
    }
}

/// score = (wI·importance + wU·urgency + wA·aging + wF·fairness + wM·momentum) × boost
public struct MainWorkPolicy: Sendable {
    public var config: SchedulerConfig
    public init(config: SchedulerConfig) { self.config = config }

    public func evaluate(_ s: MainWorkSignals) -> ScoreBreakdown {
        let importance = Double(min(max(s.priority, 1), 5) - 1) / 4
        let dateUrgency = Self.urgency(daysLeft: s.daysUntilDeadline, horizon: config.deadlineHorizonDays)
        // With an estimate, urgency is the pace needed to finish on time, not just how close the date is:
        // 2 h left in 10 days is relaxed, 20 h left in 10 days is pressing.
        var urgency = dateUrgency
        var paceReason: String?
        if let rem = s.remainingWorkMinutes, let d = s.daysUntilDeadline, d >= 0 {
            if rem <= 0 {
                urgency = 0
                paceReason = "Estimated work is done — update the estimate if there's more"
            } else {
                let perDay = Self.requiredPerDay(remaining: rem, daysLeft: d)
                let pace = min(perDay / max(config.paceFullMinutesPerDay, 1), 1)
                urgency = d <= 1 ? max(pace, dateUrgency) : pace
                paceReason = "~\(Self.hm(rem)) left · about \(Self.hm(Int(perDay.rounded()))) a day to finish on time"
            }
        }
        let aging = Self.aging(daysSince: s.daysSinceLast, cap: config.agingCapDays)
        // Signed lag, as in weighted fair queueing: positive when behind, negative when over-served.
        // While boosted, over-service is not penalised (the user asked for it).
        let fairness = max(Self.fairness(received: s.minutesInWindow, target: s.targetMinutesPerWeek),
                           s.boost > 1 ? 0 : -1)
        let momentum = Self.momentum(consecutiveDays: s.consecutiveDays, decay: config.momentumDecay)

        var reasons: [String] = []
        if s.boost > 1 { reasons.append("Boosted ×\(Self.fmt(s.boost))") }
        if let d = s.daysUntilDeadline, d >= 0, urgency > 0 || paceReason != nil {
            reasons.append(d == 0 ? "Due today" : d == 1 ? "Due tomorrow" : "Due in \(d) days")
        }
        if let paceReason { reasons.append(paceReason) }
        if importance >= 0.75 { reasons.append("High priority") }
        if aging >= 0.5 { reasons.append("Not touched for \(Int(s.daysSinceLast)) days") }
        if fairness >= 0.6 && s.targetMinutesPerWeek > 0 { reasons.append("Behind its weekly share") }
        if fairness <= -0.5 { reasons.append("Already had more than its weekly share") }
        if s.deferral < 1 { reasons.append("Lower priority — deferred during a focus sprint") }
        if momentum >= 0.5 { reasons.append("Builds on \(s.consecutiveDays) day\(s.consecutiveDays == 1 ? "" : "s") of momentum") }

        return ScoreBreakdown(
            components: [
                ScoreComponent(name: "importance", value: importance, weight: config.importanceWeight),
                ScoreComponent(name: "urgency", value: urgency, weight: config.urgencyWeight),
                ScoreComponent(name: "aging", value: aging, weight: config.agingWeight),
                ScoreComponent(name: "fairness", value: fairness, weight: config.fairnessWeight),
                ScoreComponent(name: "momentum", value: momentum, weight: config.momentumWeight),
            ],
            boost: max(s.boost, 0) * min(max(s.deferral, 0), 1),
            reasons: reasons
        )
    }

    /// Linear ramp: 0 when `horizon` days away, 1 on the due date. Past deadlines contribute 0
    /// (the event has happened; the activity falls back to normal priority).
    public static func urgency(daysLeft: Int?, horizon: Double) -> Double {
        guard let d = daysLeft, d >= 0, horizon > 0 else { return 0 }
        return min(max(1 - Double(d) / horizon, 0), 1)
    }

    /// Minutes a day needed to finish `remaining` by the deadline. Work days are the days before the
    /// due date (at least one), so "due tomorrow" means today has to cover it.
    public static func requiredPerDay(remaining: Int, daysLeft: Int) -> Double {
        Double(max(remaining, 0)) / Double(max(daysLeft, 1))
    }

    /// "45 min", "2h", "1h 30m".
    public static func hm(_ minutes: Int) -> String {
        let m = max(minutes, 0)
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    /// Capped aging: grows linearly, saturates at 1 after `cap` days. Never infinite.
    public static func aging(daysSince: Double, cap: Double) -> Double {
        guard cap > 0 else { return 0 }
        return min(max(daysSince, 0) / cap, 1)
    }

    /// Weighted-fair lag: 1 when nothing received this week, 0 when the weekly share is met,
    /// down to -1 when it has had double its share or more.
    public static func fairness(received: Int, target: Int) -> Double {
        guard target > 0 else { return 0 }
        return min(max(1 - Double(received) / Double(target), -1), 1)
    }

    /// Diminishing returns: 0, 0.5, 0.75, 0.875… → bounded by 1.
    public static func momentum(consecutiveDays n: Int, decay: Double) -> Double {
        guard n > 0 else { return 0 }
        return 1 - pow(min(max(decay, 0), 0.99), Double(n))
    }

    static func fmt(_ x: Double) -> String {
        x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x)
    }
}

// MARK: - Hobbies

public struct HobbySignals: Hashable, Sendable {
    public var sessionsInWindow: Int
    public var targetPerWeek: Int
    public var daysSinceLast: Double
    public var enjoyment: Int
    public var boost: Double
    /// Consecutive days immediately before this one with a session: being "on a roll".
    public var consecutiveDays: Int

    public init(sessionsInWindow: Int, targetPerWeek: Int, daysSinceLast: Double, enjoyment: Int, boost: Double = 1,
                consecutiveDays: Int = 0) {
        self.consecutiveDays = consecutiveDays
        self.sessionsInWindow = sessionsInWindow
        self.targetPerWeek = targetPerWeek
        self.daysSinceLast = daysSinceLast
        self.enjoyment = enjoyment
        self.boost = boost
    }

    /// Sessions still wanted in the rolling week. Never exceeds the target → no accumulated debt.
    public var need: Int { max(0, targetPerWeek - sessionsInWindow) }

    /// On a roll (2+ days running): worth one more even if the week's count is met.
    public var onARoll: Bool { consecutiveDays >= 2 && sessionsInWindow <= targetPerWeek }
}

/// score = (wC·consistency + wR·recency + wP·preference) × boost
/// Recovery constraints (min rest) are *not* scored — they are hard constraints in the scheduler.
public struct HobbyPolicy: Sendable {
    public var config: SchedulerConfig
    public init(config: SchedulerConfig) { self.config = config }

    public func evaluate(_ s: HobbySignals) -> ScoreBreakdown {
        let consistency = s.targetPerWeek > 0 ? Double(s.need) / Double(s.targetPerWeek) : 0
        let recency = Self.recency(daysSince: s.daysSinceLast, targetPerWeek: s.targetPerWeek)
        let preference = Double(min(max(s.enjoyment, 1), 5) - 1) / 4
        // Same diminishing-returns momentum as projects: keep going with what you're into.
        let momentum = MainWorkPolicy.momentum(consecutiveDays: s.consecutiveDays, decay: config.momentumDecay)

        var reasons: [String] = []
        if s.boost > 1 { reasons.append("Boosted ×\(MainWorkPolicy.fmt(s.boost))") }
        if s.targetPerWeek > 0 {
            let done = min(s.sessionsInWindow, s.targetPerWeek)
            reasons.append("\(done) of \(s.targetPerWeek) this week")
        }
        if s.daysSinceLast >= 2 && s.daysSinceLast < 365 { reasons.append("Last session \(Int(s.daysSinceLast)) days ago") }
        if preference >= 0.75 { reasons.append("You enjoy this") }
        if s.consecutiveDays >= 2 { reasons.append("On a roll — \(s.consecutiveDays) days running") }

        return ScoreBreakdown(
            components: [
                ScoreComponent(name: "consistency", value: consistency, weight: config.consistencyWeight),
                ScoreComponent(name: "recency", value: recency, weight: config.recencyWeight),
                ScoreComponent(name: "preference", value: preference, weight: config.preferenceWeight),
                ScoreComponent(name: "momentum", value: momentum, weight: config.hobbyMomentumWeight),
            ],
            boost: max(s.boost, 0),
            reasons: reasons
        )
    }

    /// Time since last session relative to the ideal spacing (7 / target), capped at 1.5× then normalised.
    public static func recency(daysSince: Double, targetPerWeek: Int) -> Double {
        let ideal = targetPerWeek > 0 ? 7.0 / Double(targetPerWeek) : 7.0
        return min(max(daysSince, 0) / ideal, 1.5) / 1.5
    }
}
