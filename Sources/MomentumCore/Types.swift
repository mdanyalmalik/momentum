import Foundation

// MARK: - Buckets, energy, phases

public enum BucketKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case anchor
    case mainWork
    case hobby
    /// Small unrelated things (errands, chores, admin). A side checklist: not timed, not part of the baseline.
    case errand

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .anchor: "Habits"
        case .mainWork: "Projects"
        case .hobby: "Hobbies"
        case .errand: "Errands"
        }
    }

    public var singular: String {
        switch self {
        case .anchor: "Habit"
        case .mainWork: "Project"
        case .hobby: "Hobby"
        case .errand: "Errand"
        }
    }

    /// One line on what this kind means, for the editor.
    public var explainer: String {
        switch self {
        case .anchor: "Small and daily, first thing after you wake. Gets you going."
        case .mainWork: "Real work. Gets daytime focus — more the higher it's ranked."
        case .hobby: "For you. Suggested in the evening, spread across the week."
        case .errand: "A little thing to tick off whenever. Never takes a time slot."
        }
    }

    public var subtitle: String {
        switch self {
        case .anchor: "Small daily things that get you going"
        case .mainWork: "Ranked: higher gets more focus time"
        case .hobby: "Enjoyment, health and growth"
        case .errand: "Little things to fit in when you can"
        }
    }

    public var phase: DayPhase {
        switch self {
        case .anchor: .morning
        case .mainWork: .daytime
        case .hobby: .evening
        case .errand: .daytime
        }
    }
}

public enum EnergyLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case low
    case normal
    case high

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }
}

public enum DayPhase: String, Codable, CaseIterable, Sendable {
    case morning
    case daytime
    case evening

    public var title: String {
        switch self {
        case .morning: "Morning · Momentum"
        case .daytime: "Daytime · Projects"
        case .evening: "Evening · Hobbies"
        }
    }
}

// MARK: - Engine inputs

/// A snapshot of an activity as the scheduler sees it. Value type, independent of persistence.
public struct ActivitySpec: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var bucket: BucketKind
    /// 1 (low) ... 5 (critical)
    public var priority: Int
    public var minMinutes: Int
    public var preferredMinutes: Int
    /// Weekly target. 0 means "no target": the activity is only offered as an optional extra.
    public var sessionsPerWeek: Int
    public var deadline: Date?
    public var isKeystone: Bool
    /// Indefinite manual pause (toggle). Time-limited pauses are `OverrideSpec.Kind.pause`.
    public var isPaused: Bool
    /// Hard recovery constraint: minimum hours between the end of one session and the start of the next.
    public var minRestHours: Double
    public var maxSessionsPerDay: Int
    /// 1...5 personal preference, used mostly by the hobby policy.
    public var enjoyment: Int
    public var sortIndex: Int
    public var createdAt: Date
    /// Share weight within its kind (projects share daytime focus, hobbies share evenings). Derived from rank.
    public var weight: Double = 1
    /// Optional estimate of the work still left before `deadline`, as of the start of `SchedulerInput.planningDay`
    /// (completed sessions already subtracted). With a deadline, urgency follows the pace this requires.
    public var remainingWorkMinutes: Int?

    public init(
        id: UUID = UUID(),
        name: String,
        bucket: BucketKind,
        priority: Int = 3,
        minMinutes: Int = 25,
        preferredMinutes: Int = 50,
        sessionsPerWeek: Int = 3,
        deadline: Date? = nil,
        isKeystone: Bool = false,
        isPaused: Bool = false,
        minRestHours: Double = 0,
        maxSessionsPerDay: Int = 1,
        enjoyment: Int = 3,
        sortIndex: Int = 0,
        createdAt: Date = .distantPast,
        remainingWorkMinutes: Int? = nil
    ) {
        self.remainingWorkMinutes = remainingWorkMinutes
        self.id = id
        self.name = name
        self.bucket = bucket
        self.priority = priority
        self.minMinutes = minMinutes
        self.preferredMinutes = max(preferredMinutes, minMinutes)
        self.sessionsPerWeek = sessionsPerWeek
        self.deadline = deadline
        self.isKeystone = isKeystone
        self.isPaused = isPaused
        self.minRestHours = minRestHours
        self.maxSessionsPerDay = maxSessionsPerDay
        self.enjoyment = enjoyment
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}

/// Something that happened (or was declined) in the past.
public struct SessionRecord: Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// Counts as service: feeds fairness, aging, momentum and weekly targets.
        case completed
        /// Declined for today. Excludes the activity for the rest of that day. No penalty, no debt.
        case skipped
        /// Swapped out for something else today. Same scheduling effect as `skipped`.
        case swapped
    }

    public var activityID: UUID
    public var start: Date
    public var minutes: Int
    public var outcome: Outcome

    public init(activityID: UUID, start: Date, minutes: Int, outcome: Outcome = .completed) {
        self.activityID = activityID
        self.start = start
        self.minutes = minutes
        self.outcome = outcome
    }
}

/// A fixed appointment. Hard constraint: never moved by the scheduler.
public struct CommitmentSpec: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var start: Date
    public var end: Date

    public init(id: UUID = UUID(), title: String, start: Date, end: Date) {
        self.id = id
        self.title = title
        self.start = start
        self.end = max(end, start)
    }
}

/// User overrides. Each one is applied inside the calculation (constraint or weight), not as a post-filter.
public struct OverrideSpec: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Force the activity onto a day (`start..<end`), optionally at an exact time.
        case pin
        /// Multiply the activity's score by `factor` during `start..<end`.
        case boost
        /// Exclude the activity from scheduling during `start..<end`.
        case pause
        /// Internal: exclude on specific day(s) (used when moving a block to another day).
        case exclude
        /// Internal: "Do later" — don't suggest before `end`.
        case deferUntil
    }

    public var id: UUID
    public var activityID: UUID
    public var kind: Kind
    public var start: Date
    public var end: Date
    public var factor: Double
    public var pinnedTime: Date?

    public init(
        id: UUID = UUID(),
        activityID: UUID,
        kind: Kind,
        start: Date,
        end: Date,
        factor: Double = 1,
        pinnedTime: Date? = nil
    ) {
        self.id = id
        self.activityID = activityID
        self.kind = kind
        self.start = start
        self.end = max(end, start)
        self.factor = factor
        self.pinnedTime = pinnedTime
    }

    public func overlaps(_ from: Date, _ to: Date) -> Bool {
        start < to && end > from
    }
}

/// What the user told us about a (calendar) day.
public struct DayContext: Hashable, Sendable {
    /// When you woke up on this day, if you have. Habits go right after waking; if you haven't woken
    /// yet today (still up from yesterday), they wait until after your next sleep.
    public var wake: Date?
    public var energy: EnergyLevel

    public init(wake: Date? = nil, energy: EnergyLevel = .normal) {
        self.wake = wake
        self.energy = energy
    }
}

public struct SchedulerInput: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var activities: [ActivitySpec]
    public var history: [SessionRecord]
    public var commitments: [CommitmentSpec]
    public var overrides: [OverrideSpec]
    /// Keyed by `calendar.startOfDay(for:)`.
    public var dayContexts: [Date: DayContext]
    /// Known sleeps: logged ones, the one in progress, and your estimate of the next one.
    /// After the last of these, sleep is assumed to repeat every 24 h for `24 − defaultAwakeHours`.
    public var sleeps: [DateInterval]
    /// Your usual wake time (minutes after midnight), used when nothing better is known.
    public var defaultWakeMinutes: Int
    /// Usual hours awake per 24 h; the rest is assumed sleep.
    public var defaultAwakeHours: Double
    public var defaultEnergy: EnergyLevel
    /// The plan currently shown to the user. Used to minimise disruption when replanning.
    public var previousPlan: WeekPlan?

    /// Days are calendar days: each 24 h has its own set of things to do.
    public var planningDay: Date { calendar.startOfDay(for: now) }

    public init(
        now: Date,
        calendar: Calendar = .current,
        activities: [ActivitySpec],
        history: [SessionRecord] = [],
        commitments: [CommitmentSpec] = [],
        overrides: [OverrideSpec] = [],
        dayContexts: [Date: DayContext] = [:],
        sleeps: [DateInterval] = [],
        defaultWakeMinutes: Int = 8 * 60,
        defaultAwakeHours: Double = 16,
        defaultEnergy: EnergyLevel = .normal,
        previousPlan: WeekPlan? = nil
    ) {
        self.sleeps = sleeps
        self.now = now
        self.calendar = calendar
        self.activities = activities
        self.history = history
        self.commitments = commitments
        self.overrides = overrides
        self.dayContexts = dayContexts
        self.defaultWakeMinutes = defaultWakeMinutes
        self.defaultAwakeHours = defaultAwakeHours
        self.defaultEnergy = defaultEnergy
        self.previousPlan = previousPlan
    }
}

// MARK: - Engine outputs

public struct PlannedBlock: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case fixed, anchor, focus, hobby
        /// Only when an errand is pinned to a time; otherwise errands live in `DayPlan.errands`.
        case errand
    }

    /// Deterministic: "<activity>-<yyyyMMdd>-<n>" or "fixed-<commitment>". Stable across replans.
    public var id: String
    public var kind: Kind
    public var activityID: UUID?
    public var commitmentID: UUID?
    public var title: String
    public var bucket: BucketKind?
    public var phase: DayPhase
    public var start: Date
    public var minutes: Int
    public var isPinned: Bool
    public var isPrimary: Bool
    /// Optional = not part of the day's baseline (secondary work, extra hobbies).
    public var isOptional: Bool
    /// Plain-language explanation of why this block is here.
    public var reasons: [String]

    public var end: Date { start.addingTimeInterval(Double(minutes) * 60) }
    public var isFixed: Bool { kind == .fixed }
    public var interval: DateInterval { DateInterval(start: start, duration: Double(minutes) * 60) }
}

public struct DayPlan: Codable, Hashable, Sendable {
    public var day: Date
    public var windowStart: Date
    public var windowEnd: Date
    public var energy: EnergyLevel
    /// Free waking minutes after fixed commitments.
    public var freeMinutes: Int
    /// The share of free time the scheduler was allowed to fill (rest is deliberate slack).
    public var flexibleBudget: Int
    public var blocks: [PlannedBlock]
    public var notes: [String]
    /// Optional extras to offer once the baseline is done. Never scheduled automatically.
    public var bonusIdeas: [UUID]
    /// Errands suggested for this day, most pressing first. A side list: untimed, outside the budget and baseline.
    public var errands: [UUID] = []
    /// Expected or logged sleep overlapping this day (planning works around it).
    public var sleeps: [DateInterval] = []
    /// When habits start: right after you wake (today: now, if you've already woken).
    public var wake: Date?

    public var flexibleBlocks: [PlannedBlock] { blocks.filter { !$0.isFixed } }
    public var baselineBlocks: [PlannedBlock] { flexibleBlocks.filter { !$0.isOptional } }
    public var plannedFlexibleMinutes: Int { flexibleBlocks.reduce(0) { $0 + $1.minutes } }

    public func minutes(for kind: PlannedBlock.Kind) -> Int {
        blocks.filter { $0.kind == kind }.reduce(0) { $0 + $1.minutes }
    }

    public func minutes(for activityID: UUID) -> Int {
        blocks.filter { $0.activityID == activityID }.reduce(0) { $0 + $1.minutes }
    }

    public var primaryActivityID: UUID? { blocks.first(where: { $0.isPrimary })?.activityID }
}

extension DayPlan {
    /// Tolerant decoding, so plans saved before a field existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(Date.self, forKey: .day)
        windowStart = try c.decode(Date.self, forKey: .windowStart)
        windowEnd = try c.decode(Date.self, forKey: .windowEnd)
        energy = try c.decode(EnergyLevel.self, forKey: .energy)
        freeMinutes = try c.decode(Int.self, forKey: .freeMinutes)
        flexibleBudget = try c.decode(Int.self, forKey: .flexibleBudget)
        blocks = try c.decode([PlannedBlock].self, forKey: .blocks)
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        bonusIdeas = try c.decodeIfPresent([UUID].self, forKey: .bonusIdeas) ?? []
        errands = try c.decodeIfPresent([UUID].self, forKey: .errands) ?? []
        sleeps = try c.decodeIfPresent([DateInterval].self, forKey: .sleeps) ?? []
        wake = try c.decodeIfPresent(Date.self, forKey: .wake)
    }
}

public struct WeekPlan: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var days: [DayPlan]
    public var notes: [String]

    public init(generatedAt: Date, days: [DayPlan], notes: [String]) {
        self.generatedAt = generatedAt
        self.days = days
        self.notes = notes
    }

    public func day(containing date: Date, calendar: Calendar) -> DayPlan? {
        days.first { calendar.isDate($0.day, inSameDayAs: date) }
    }

    public var allBlocks: [PlannedBlock] { days.flatMap(\.blocks) }
}
