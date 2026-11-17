import Foundation
import MomentumCore
import SwiftData

/// One of the three buckets. Activities belong to a bucket; dragging a card between columns changes it.
@Model
final class Bucket {
    @Attribute(.unique) var kindRaw: String
    var title: String
    var sortIndex: Int
    @Relationship(deleteRule: .nullify, inverse: \Activity.bucket)
    var activities: [Activity] = []

    init(kind: BucketKind, sortIndex: Int) {
        self.kindRaw = kind.rawValue
        self.title = kind.title
        self.sortIndex = sortIndex
    }

    var kind: BucketKind { BucketKind(rawValue: kindRaw) ?? .mainWork }
}

@Model
final class Activity {
    @Attribute(.unique) var id: UUID
    var name: String
    var bucket: Bucket?
    /// 1...5
    var priority: Int
    var minMinutes: Int
    var preferredMinutes: Int
    var deadline: Date?
    var isKeystone: Bool
    var isPaused: Bool
    var minRestHours: Double
    var maxSessionsPerDay: Int
    /// 1...5
    var enjoyment: Int
    var sortIndex: Int
    var notes: String
    /// Two-phase timer (e.g. LeetCode: 15 min attempt + 5 min review). 0 = simple timer.
    var attemptMinutes: Int
    var reviewMinutes: Int
    var createdAt: Date
    /// Optional "about this much work left" for a deadline, as entered at `estimateSetAt`.
    /// Completed sessions since then count it down.
    var estimatedWorkMinutes: Int?
    var estimateSetAt: Date?
    /// One-off errands: when it was ticked off. Finished errands leave the plan and can be cleared.
    var completedAt: Date?
    /// Let Momentum derive how often / how important from rank order. When false, the stored
    /// weekly target, per-day limit, priority and enjoyment are used as-is ("Set amount manually").
    var autoBalance: Bool = true
    @Relationship(deleteRule: .cascade, inverse: \WeeklyTarget.activity)
    var weeklyTarget: WeeklyTarget?

    init(name: String, bucket: Bucket?, priority: Int = 3, minMinutes: Int = 25, preferredMinutes: Int = 50,
         sessionsPerWeek: Int = 3, deadline: Date? = nil, isKeystone: Bool = false, minRestHours: Double = 0,
         maxSessionsPerDay: Int = 1, enjoyment: Int = 3, sortIndex: Int = 0, notes: String = "",
         attemptMinutes: Int = 0, reviewMinutes: Int = 0) {
        self.id = UUID()
        self.name = name
        self.bucket = bucket
        self.priority = priority
        self.minMinutes = minMinutes
        self.preferredMinutes = preferredMinutes
        self.deadline = deadline
        self.isKeystone = isKeystone
        self.isPaused = false
        self.minRestHours = minRestHours
        self.maxSessionsPerDay = maxSessionsPerDay
        self.enjoyment = enjoyment
        self.sortIndex = sortIndex
        self.notes = notes
        self.attemptMinutes = attemptMinutes
        self.reviewMinutes = reviewMinutes
        self.createdAt = .now
        self.weeklyTarget = WeeklyTarget(sessionsPerWeek: sessionsPerWeek)
    }

    var kind: BucketKind { bucket?.kind ?? .mainWork }
    var sessionsPerWeek: Int { weeklyTarget?.sessionsPerWeek ?? 0 }
    var hasTwoPhaseTimer: Bool { attemptMinutes > 0 && reviewMinutes > 0 }

    var spec: ActivitySpec {
        ActivitySpec(id: id, name: name, bucket: kind, priority: priority, minMinutes: minMinutes,
                     preferredMinutes: preferredMinutes, sessionsPerWeek: sessionsPerWeek, deadline: deadline,
                     isKeystone: isKeystone, isPaused: isPaused, minRestHours: minRestHours,
                     maxSessionsPerDay: maxSessionsPerDay, enjoyment: enjoyment, sortIndex: sortIndex,
                     createdAt: createdAt)
    }
}

@Model
final class WeeklyTarget {
    var sessionsPerWeek: Int
    var activity: Activity?

    init(sessionsPerWeek: Int) {
        self.sessionsPerWeek = sessionsPerWeek
    }
}

/// A completed, skipped or swapped session. Kept even if the activity is later deleted.
@Model
final class ActivitySession {
    @Attribute(.unique) var id: UUID
    var activityID: UUID
    var activityName: String
    var bucketRaw: String
    var start: Date
    var minutes: Int
    var outcomeRaw: String
    var isBonus: Bool

    init(activityID: UUID, activityName: String, bucket: BucketKind, start: Date, minutes: Int,
         outcome: SessionRecord.Outcome, isBonus: Bool = false) {
        self.id = UUID()
        self.activityID = activityID
        self.activityName = activityName
        self.bucketRaw = bucket.rawValue
        self.start = start
        self.minutes = minutes
        self.outcomeRaw = outcome.rawValue
        self.isBonus = isBonus
    }

    var outcome: SessionRecord.Outcome { SessionRecord.Outcome(rawValue: outcomeRaw) ?? .completed }
    var bucket: BucketKind { BucketKind(rawValue: bucketRaw) ?? .mainWork }
    var end: Date { start.addingTimeInterval(Double(minutes) * 60) }
    var record: SessionRecord { SessionRecord(activityID: activityID, start: start, minutes: minutes, outcome: outcome) }
}

@Model
final class FixedCommitment {
    @Attribute(.unique) var id: UUID
    var title: String
    var start: Date
    var end: Date
    var notes: String

    init(title: String, start: Date, end: Date, notes: String = "") {
        self.id = UUID()
        self.title = title
        self.start = start
        self.end = end
        self.notes = notes
    }

    var spec: CommitmentSpec { CommitmentSpec(id: id, title: title, start: start, end: end) }
}

@Model
final class SchedulingOverride {
    @Attribute(.unique) var id: UUID
    var activityID: UUID
    var kindRaw: String
    var start: Date
    var end: Date
    var factor: Double
    var pinnedTime: Date?
    var createdAt: Date

    init(activityID: UUID, kind: OverrideSpec.Kind, start: Date, end: Date, factor: Double = 1, pinnedTime: Date? = nil) {
        self.id = UUID()
        self.activityID = activityID
        self.kindRaw = kind.rawValue
        self.start = start
        self.end = end
        self.factor = factor
        self.pinnedTime = pinnedTime
        self.createdAt = .now
    }

    var kind: OverrideSpec.Kind { OverrideSpec.Kind(rawValue: kindRaw) ?? .boost }
    /// Pin, Boost and Pause are user-facing. Exclude / deferUntil are created by Move / Do Later.
    var isUserFacing: Bool { [.pin, .boost, .pause].contains(kind) }
    var spec: OverrideSpec {
        OverrideSpec(id: id, activityID: activityID, kind: kind, start: start, end: end, factor: factor, pinnedTime: pinnedTime)
    }
}

/// Per-day state: what the user said in Start Day, plus the last plan shown (for stability across launches).
@Model
final class DailyPlan {
    @Attribute(.unique) var day: Date
    var wake: Date?
    var awakeHours: Double
    var energyRaw: String
    var startedAt: Date?
    var planData: Data?

    init(day: Date) {
        self.day = day
        self.awakeHours = 16
        self.energyRaw = EnergyLevel.normal.rawValue
    }

    var energy: EnergyLevel {
        get { EnergyLevel(rawValue: energyRaw) ?? .normal }
        set { energyRaw = newValue.rawValue }
    }

    var dayPlan: MomentumCore.DayPlan? {
        planData.flatMap { try? JSONDecoder().decode(MomentumCore.DayPlan.self, from: $0) }
    }
}

/// A sleep the user reported: "Going to sleep" opens it, "I woke up at…" closes it.
/// A nap keeps the same day going; a main sleep ends it and the wake starts a new one.
@Model
final class SleepLog {
    var id: UUID
    /// The logical day this sleep started in.
    var day: Date
    var start: Date
    var end: Date?
    /// True when waking up started a new day; false for a nap that continued the same day.
    var endedDay: Bool

    init(day: Date, start: Date) {
        self.id = UUID()
        self.day = day
        self.start = start
        self.endedDay = false
    }
}

/// One row per day: small, non-punitive record of wins.
@Model
final class CompletionHistory {
    @Attribute(.unique) var day: Date
    var wins: Int
    var bonusWins: Int
    var focusMinutes: Int
    var baselineComplete: Bool

    init(day: Date) {
        self.day = day
        self.wins = 0
        self.bonusWins = 0
        self.focusMinutes = 0
        self.baselineComplete = false
    }
}

@Model
final class AppSettings {
    var configData: Data?
    var defaultWakeMinutes: Int
    var defaultAwakeHours: Double
    var hasOnboarded: Bool
    /// One-time: when auto-balance arrived, order each column by the old priorities so rank keeps their meaning.
    var didAdoptAutoBalance: Bool = false
    /// When you expect to sleep next (from Start Day, the Sleep chip, or waking up).
    var nextSleepEstimate: Date? = nil
    /// Which scheduler produced the saved plans. Plans from an older engine aren't replayed for stability.
    var engineVersion: Int = 0

    init() {
        self.defaultWakeMinutes = 8 * 60
        self.defaultAwakeHours = 16
        self.hasOnboarded = false
    }

    var config: SchedulerConfig {
        get { configData.flatMap { try? JSONDecoder().decode(SchedulerConfig.self, from: $0) } ?? .default }
        set { configData = try? JSONEncoder().encode(newValue) }
    }
}

enum MomentumSchema {
    static let models: [any PersistentModel.Type] = [
        Bucket.self, Activity.self, WeeklyTarget.self, ActivitySession.self, FixedCommitment.self,
        SchedulingOverride.self, DailyPlan.self, CompletionHistory.self, AppSettings.self, SleepLog.self,
    ]

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(models)
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            // Chosen in Settings (DataLocation); MOMENTUM_STORE_DIR overrides it for throwaway stores.
            let dir = DataLocation.current
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            config = ModelConfiguration(schema: schema, url: dir.appending(path: "Momentum.store"))
        }
        return try ModelContainer(for: schema, configurations: [config])
    }
}
