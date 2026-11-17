import XCTest
@testable import MomentumCore

/// Optional work estimates on deadlines: urgency follows the pace needed, not just the date.
final class EstimateTests: XCTestCase {
    let scheduler = Scheduler()
    var cal: Calendar { Fixture.calendar }

    private func project(_ name: String, remaining: Int?, dueIn days: Int, target: Int = 2, sort: Int = 0) -> ActivitySpec {
        ActivitySpec(name: name, bucket: .mainWork, priority: 3, minMinutes: 25, preferredMinutes: 50,
                     sessionsPerWeek: target, deadline: Fixture.day(days), maxSessionsPerDay: 2, sortIndex: sort,
                     createdAt: Fixture.longAgo, remainingWorkMinutes: remaining)
    }

    private func week(_ plan: WeekPlan, _ id: UUID) -> Int { plan.days.reduce(0) { $0 + $1.minutes(for: id) } }

    func testBigEstimateGetsMoreTimeThanSmallOneWithSameDeadline() {
        let small = project("Small report", remaining: 120, dueIn: 10, sort: 0)
        let big = project("Big report", remaining: 20 * 60, dueIn: 10, sort: 1)
        let plan = scheduler.plan(Fixture().input(activities: [small, big]))
        XCTAssertGreaterThan(week(plan, big.id), 2 * week(plan, small.id))
        // Same date, but the big one is the primary focus today.
        XCTAssertEqual(plan.days[0].primaryActivityID, big.id)
        XCTAssertTrue(plan.days[0].blocks.first { $0.activityID == big.id }!.reasons.contains { $0.contains("a day to finish on time") })
    }

    func testEstimateOnlyTaskStopsWhenTheWorkIsCovered() {
        // No weekly target: just "about 2 hours, due in 6 days".
        let task = project("Grant form", remaining: 100, dueIn: 6, target: 0)
        let plan = scheduler.plan(Fixture().input(activities: [task]))
        let total = week(plan, task.id)
        XCTAssertGreaterThanOrEqual(total, 100)
        XCTAssertLessThanOrEqual(total, 150, "Shouldn't keep scheduling once the estimate is covered")
        XCTAssertTrue(plan.notes.contains { $0.contains("Grant form") && $0.contains("plan covers it") }, "\(plan.notes)")
    }

    func testCompletedWorkCountsDown() {
        let task = project("Grant form", remaining: 100, dueIn: 6, target: 0)
        // Already did 100 minutes earlier today: nothing left.
        let done = [SessionRecord(activityID: task.id, start: Fixture.at(0, 5), minutes: 100)]
        let plan = scheduler.plan(Fixture().input(activities: [task], history: done))
        XCTAssertEqual(week(plan, task.id), 0)
        XCTAssertTrue(plan.notes.contains { $0.contains("done ahead of the deadline") }, "\(plan.notes)")
    }

    func testInfeasibleEstimateIsFlaggedHonestly() {
        let task = project("Dissertation", remaining: 40 * 60, dueIn: 3)
        let plan = scheduler.plan(Fixture().input(activities: [task]))
        XCTAssertTrue(plan.notes.contains { $0.contains("Dissertation") && $0.contains("fits in the plan") }, "\(plan.notes)")
        // Still respects the day's caps and slack rather than cramming.
        for day in plan.days {
            XCTAssertLessThanOrEqual(day.mainMinutes, SchedulerConfig.default.mainWorkCapNormal)
            XCTAssertLessThanOrEqual(day.plannedFlexibleMinutes, day.flexibleBudget)
        }
    }

    func testPaceUrgencyPolicy() {
        let policy = MainWorkPolicy(config: .default)
        func urgency(_ rem: Int?, _ days: Int) -> Double {
            policy.evaluate(MainWorkSignals(priority: 3, daysSinceLast: 1, daysUntilDeadline: days, minutesInWindow: 0,
                                            targetMinutesPerWeek: 100, consecutiveDays: 0, remainingWorkMinutes: rem))
                .value("urgency")
        }
        XCTAssertEqual(urgency(nil, 7), 0.5, accuracy: 1e-9)          // date ramp only
        XCTAssertLessThan(urgency(60, 7), 0.1)                         // ~9 min/day: relaxed
        XCTAssertEqual(urgency(30 * 60, 7), 1, accuracy: 1e-9)         // ~4h/day: pressing
        XCTAssertEqual(urgency(0, 2), 0)                               // done
        XCTAssertGreaterThanOrEqual(urgency(30, 1), MainWorkPolicy.urgency(daysLeft: 1, horizon: 14)) // last day: at least the date ramp
    }
}
