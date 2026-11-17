import Foundation
@testable import MomentumCore

/// Shared fixture: a realistic set of activities on a fixed Monday, UTC.
struct Fixture {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    /// Monday 16 Nov 2026, 07:00 UTC.
    static let now: Date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 7))!
    static var today: Date { calendar.startOfDay(for: now) }
    static let longAgo = calendar.date(byAdding: .day, value: -30, to: now)!

    static func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
    static func at(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(byAdding: .minute, value: hour * 60 + minute, to: day(offset))!
    }

    var leetcode = ActivitySpec(name: "Daily LeetCode", bucket: .anchor, priority: 4, minMinutes: 15, preferredMinutes: 20,
                                sessionsPerWeek: 7, isKeystone: true, sortIndex: 0, createdAt: Fixture.longAgo)
    var motivation = ActivitySpec(name: "Morning motivation", bucket: .anchor, priority: 3, minMinutes: 10, preferredMinutes: 15,
                                  sessionsPerWeek: 7, isKeystone: true, sortIndex: 1, createdAt: Fixture.longAgo)
    var interview = ActivitySpec(name: "Interview prep", bucket: .mainWork, priority: 4, minMinutes: 25, preferredMinutes: 50,
                                 sessionsPerWeek: 4, maxSessionsPerDay: 3, sortIndex: 0, createdAt: Fixture.longAgo)
    var thesis = ActivitySpec(name: "Thesis extension", bucket: .mainWork, priority: 4, minMinutes: 25, preferredMinutes: 50,
                              sessionsPerWeek: 4, maxSessionsPerDay: 3, sortIndex: 1, createdAt: Fixture.longAgo)
    var sideProject = ActivitySpec(name: "Side project", bucket: .mainWork, priority: 2, minMinutes: 25, preferredMinutes: 50,
                                   sessionsPerWeek: 2, maxSessionsPerDay: 2, sortIndex: 2, createdAt: Fixture.longAgo)
    var guitar = ActivitySpec(name: "Guitar", bucket: .hobby, priority: 3, minMinutes: 20, preferredMinutes: 30,
                              sessionsPerWeek: 3, enjoyment: 4, sortIndex: 0, createdAt: Fixture.longAgo)
    var gym = ActivitySpec(name: "Gym", bucket: .hobby, priority: 3, minMinutes: 45, preferredMinutes: 60,
                           sessionsPerWeek: 3, minRestHours: 40, enjoyment: 4, sortIndex: 1, createdAt: Fixture.longAgo)
    var reading = ActivitySpec(name: "Reading", bucket: .hobby, priority: 2, minMinutes: 20, preferredMinutes: 30,
                               sessionsPerWeek: 2, enjoyment: 3, sortIndex: 2, createdAt: Fixture.longAgo)

    var all: [ActivitySpec] { [leetcode, motivation, interview, thesis, sideProject, guitar, gym, reading] }

    func input(
        now: Date = Fixture.now,
        activities: [ActivitySpec]? = nil,
        history: [SessionRecord] = [],
        commitments: [CommitmentSpec] = [],
        overrides: [OverrideSpec] = [],
        dayContexts: [Date: DayContext] = [:],
        sleeps: [DateInterval] = [],
        previous: WeekPlan? = nil
    ) -> SchedulerInput {
        SchedulerInput(now: now, calendar: Fixture.calendar, activities: activities ?? all, history: history,
                       commitments: commitments, overrides: overrides, dayContexts: dayContexts, sleeps: sleeps,
                       defaultWakeMinutes: 8 * 60, defaultAwakeHours: 16, previousPlan: previous)
    }

    /// Simulates having done every planned flexible block of `plan` as completed history.
    static func history(from plan: WeekPlan, through dayCount: Int) -> [SessionRecord] {
        plan.days.prefix(dayCount).flatMap { day in
            day.flexibleBlocks.compactMap { b in
                b.activityID.map { SessionRecord(activityID: $0, start: b.start, minutes: b.minutes) }
            }
        }
    }
}

extension DayPlan {
    func count(of id: UUID) -> Int { blocks.filter { $0.activityID == id }.count }
    var mainMinutes: Int { minutes(for: .focus) }
}

func assertNoOverlaps(_ plan: WeekPlan, file: StaticString = #filePath, line: UInt = #line) -> Bool {
    for day in plan.days {
        let blocks = day.blocks.sorted { $0.start < $1.start }
        for (a, b) in zip(blocks, blocks.dropFirst()) where a.end > b.start {
            print("Overlap: \(a.title) \(a.start)-\(a.end) and \(b.title) \(b.start)")
            return false
        }
    }
    return true
}
