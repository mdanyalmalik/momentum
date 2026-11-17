import Foundation

/// Every tunable number the scheduler uses. See docs/SCHEDULING.md for what each one does.
///
/// These are *heuristics*, chosen to produce sensible plans — not psychologically validated
/// constants. Tune them in Settings → Scheduling until the plans feel right to you.
public struct SchedulerConfig: Codable, Hashable, Sendable {
    // MARK: Horizon & capacity
    /// Rolling planning horizon in days (today included).
    public var horizonDays = 7
    /// Share of free waking time the scheduler may fill. The rest is deliberate slack for breaks,
    /// meals, life and spontaneity. The objective is never 100% utilisation.
    public var utilisationTarget = 0.6
    /// Daily caps on Main Work minutes per energy level. Missed work never raises tomorrow's cap.
    public var mainWorkCapLow = 150
    public var mainWorkCapNormal = 300
    public var mainWorkCapHigh = 390
    /// Evening hobby budget per energy level.
    public var hobbyBudgetLow = 60
    public var hobbyBudgetNormal = 90
    public var hobbyBudgetHigh = 150
    public var breakMinutes = 10
    public var longBreakMinutes = 30
    /// Long break after this many consecutive focus sessions.
    public var sessionsBeforeLongBreak = 2
    /// Padding kept free around fixed commitments (travel, context).
    public var commitmentBufferMinutes = 10
    public var morningPhaseHours = 1.5
    public var eveningPhaseHours = 4.0
    /// If the previous day ran late, assume at least this much sleep before the next default wake.
    public var minimumSleepHours = 7.0

    // MARK: Main Work policy (urgency, importance, momentum)
    public var maxMainActivitiesPerDay = 2
    public var importanceWeight = 1.0
    public var urgencyWeight = 1.5
    public var agingWeight = 0.6
    public var fairnessWeight = 0.8
    public var momentumWeight = 0.4
    /// Momentum = 1 - decay^consecutiveDays → diminishing returns, bounded by 1.
    public var momentumDecay = 0.5
    /// Aging saturates after this many days without a session (bounded, never infinite).
    public var agingCapDays = 7.0
    /// Urgency rises linearly from 0 (this many days out) to 1 (due today).
    public var deadlineHorizonDays = 14.0
    /// With a work estimate, needing this many minutes a day to finish on time counts as maximum urgency.
    public var paceFullMinutesPerDay = 180.0
    /// Score cost of switching to a different project between consecutive sessions.
    public var contextSwitchCost = 0.35
    /// Score reduction per session already given to an activity today (CFS-like "virtual runtime").
    public var servicePenalty = 0.5
    /// Below this score a session isn't worth suggesting: leave the time free instead.
    public var minimumMainScore = 0.3
    /// Urgency at or above which work may preempt (trim) the evening hobby budget.
    public var preemptionUrgency = 0.8
    /// Hobby time preemption can never cut below.
    public var hobbyFloorMinutes = 30
    /// Starvation guard: an activity with a weekly target gets a short guaranteed session after this many idle days.
    public var starvationDays = 5.0
    /// Only "important" work (priority ≥ this) is protected by the starvation guard; the rest relies on aging.
    public var starvationMinPriority = 3
    /// Maximum share of the day's Main Work a boosted activity may take.
    public var boostDailyShare = 0.75

    // MARK: Hobby policy (consistency, recency, preference, recovery)
    public var consistencyWeight = 1.2
    public var recencyWeight = 0.8
    public var preferenceWeight = 0.5
    /// Momentum for hobbies: days in a row make it likelier to continue (diminishing, bounded).
    public var hobbyMomentumWeight = 1.2
    /// A hobby you haven't done for this many days interrupts another hobby's run.
    public var hobbyRunBreakDays = 7.0
    /// Hobbies suggested by default each evening.
    public var hobbiesPerDay = 1
    /// Hard ceiling — a second hobby needs a high score (`secondHobbyThreshold`).
    public var maxHobbiesPerDay = 2
    public var secondHobbyThreshold = 1.6
    public var minimumHobbyScore = 0.3

    // MARK: Fair-share scheduling (CFS-style)
    /// How fast past time fades: a session counts half as much after this many days.
    public var serviceHalfLifeDays = 5.0
    /// Stickiness for the day's main project: keep yesterday's unless another is behind its share by more than
    /// this (about a day's worth) — runs of days, not daily rotation.
    public var focusGranularityMinutes = 240.0
    /// The main project's part of the day's focus time; the rest goes to whichever is most behind.
    public var mainFocusShare = 0.67
    /// `focusGranularityMinutes` as whole minutes (for settings fields).
    public var focusGranularityMinutesInt: Int {
        get { Int(focusGranularityMinutes) }
        set { focusGranularityMinutes = Double(newValue) }
    }
    /// Stickiness for hobbies, in sessions (gives runs of ~2–3 evenings instead of rotation).
    public var hobbyGranularitySessions = 1.5

    // MARK: Auto-balance (rank → share)
    /// Each project gets this fraction of the share of the one ranked above it (1, 0.7, 0.49…).
    public var rankDecayMain = 0.7
    /// Same for hobbies, which share evening slots.
    public var rankDecayHobby = 0.8

    /// Minutes before each sleep left free (no sessions right up to bedtime).
    public var windDownMinutes = 30

    // MARK: Errands
    /// Errands suggested per day (anything due by tomorrow is always included).
    public var errandsPerDay = 3

    // MARK: Overrides & stability
    public var defaultBoostFactor = 2.5
    /// While something is boosted, lower-priority Main Work has its score multiplied by this.
    public var boostDeferralFactor = 0.5
    /// Bonus for keeping an activity on the day it was already planned. Penalises churn so small
    /// edits don't reorganise the whole week.
    public var stabilityBonus = 0.3

    public init() {}

    public static let `default` = SchedulerConfig()

    public func mainWorkCap(for energy: EnergyLevel) -> Int {
        switch energy {
        case .low: mainWorkCapLow
        case .normal: mainWorkCapNormal
        case .high: mainWorkCapHigh
        }
    }

    public func hobbyBudget(for energy: EnergyLevel) -> Int {
        switch energy {
        case .low: hobbyBudgetLow
        case .normal: hobbyBudgetNormal
        case .high: hobbyBudgetHigh
        }
    }
}

extension SchedulerConfig {
    /// Tolerant decoding: unknown/missing keys fall back to defaults, so saved settings survive upgrades.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ key: CodingKeys, _ current: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? current
        }
        horizonDays = d(.horizonDays, horizonDays)
        utilisationTarget = d(.utilisationTarget, utilisationTarget)
        mainWorkCapLow = d(.mainWorkCapLow, mainWorkCapLow)
        mainWorkCapNormal = d(.mainWorkCapNormal, mainWorkCapNormal)
        mainWorkCapHigh = d(.mainWorkCapHigh, mainWorkCapHigh)
        hobbyBudgetLow = d(.hobbyBudgetLow, hobbyBudgetLow)
        hobbyBudgetNormal = d(.hobbyBudgetNormal, hobbyBudgetNormal)
        hobbyBudgetHigh = d(.hobbyBudgetHigh, hobbyBudgetHigh)
        breakMinutes = d(.breakMinutes, breakMinutes)
        longBreakMinutes = d(.longBreakMinutes, longBreakMinutes)
        sessionsBeforeLongBreak = d(.sessionsBeforeLongBreak, sessionsBeforeLongBreak)
        commitmentBufferMinutes = d(.commitmentBufferMinutes, commitmentBufferMinutes)
        morningPhaseHours = d(.morningPhaseHours, morningPhaseHours)
        eveningPhaseHours = d(.eveningPhaseHours, eveningPhaseHours)
        minimumSleepHours = d(.minimumSleepHours, minimumSleepHours)
        maxMainActivitiesPerDay = d(.maxMainActivitiesPerDay, maxMainActivitiesPerDay)
        importanceWeight = d(.importanceWeight, importanceWeight)
        urgencyWeight = d(.urgencyWeight, urgencyWeight)
        agingWeight = d(.agingWeight, agingWeight)
        fairnessWeight = d(.fairnessWeight, fairnessWeight)
        momentumWeight = d(.momentumWeight, momentumWeight)
        momentumDecay = d(.momentumDecay, momentumDecay)
        agingCapDays = d(.agingCapDays, agingCapDays)
        deadlineHorizonDays = d(.deadlineHorizonDays, deadlineHorizonDays)
        paceFullMinutesPerDay = d(.paceFullMinutesPerDay, paceFullMinutesPerDay)
        contextSwitchCost = d(.contextSwitchCost, contextSwitchCost)
        servicePenalty = d(.servicePenalty, servicePenalty)
        minimumMainScore = d(.minimumMainScore, minimumMainScore)
        preemptionUrgency = d(.preemptionUrgency, preemptionUrgency)
        hobbyFloorMinutes = d(.hobbyFloorMinutes, hobbyFloorMinutes)
        starvationDays = d(.starvationDays, starvationDays)
        starvationMinPriority = d(.starvationMinPriority, starvationMinPriority)
        boostDailyShare = d(.boostDailyShare, boostDailyShare)
        consistencyWeight = d(.consistencyWeight, consistencyWeight)
        recencyWeight = d(.recencyWeight, recencyWeight)
        preferenceWeight = d(.preferenceWeight, preferenceWeight)
        hobbyMomentumWeight = d(.hobbyMomentumWeight, hobbyMomentumWeight)
        hobbyRunBreakDays = d(.hobbyRunBreakDays, hobbyRunBreakDays)
        hobbiesPerDay = d(.hobbiesPerDay, hobbiesPerDay)
        maxHobbiesPerDay = d(.maxHobbiesPerDay, maxHobbiesPerDay)
        secondHobbyThreshold = d(.secondHobbyThreshold, secondHobbyThreshold)
        minimumHobbyScore = d(.minimumHobbyScore, minimumHobbyScore)
        defaultBoostFactor = d(.defaultBoostFactor, defaultBoostFactor)
        boostDeferralFactor = d(.boostDeferralFactor, boostDeferralFactor)
        stabilityBonus = d(.stabilityBonus, stabilityBonus)
        errandsPerDay = d(.errandsPerDay, errandsPerDay)
        windDownMinutes = d(.windDownMinutes, windDownMinutes)
        rankDecayMain = d(.rankDecayMain, rankDecayMain)
        serviceHalfLifeDays = d(.serviceHalfLifeDays, serviceHalfLifeDays)
        focusGranularityMinutes = d(.focusGranularityMinutes, focusGranularityMinutes)
        mainFocusShare = d(.mainFocusShare, mainFocusShare)
        hobbyGranularitySessions = d(.hobbyGranularitySessions, hobbyGranularitySessions)
        rankDecayHobby = d(.rankDecayHobby, rankDecayHobby)
    }
}
