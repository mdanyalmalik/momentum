import XCTest
@testable import MomentumCore

/// Errands: a small side list, not timed, not part of focus/hobby budgets or the baseline.
final class ErrandTests: XCTestCase {
    let scheduler = Scheduler()
    let f = Fixture()

    private func errand(_ name: String, perWeek: Int = 0, dueIn: Int? = nil, priority: Int = 3, sort: Int = 0) -> ActivitySpec {
        ActivitySpec(name: name, bucket: .errand, priority: priority, minMinutes: 5, preferredMinutes: 15,
                     sessionsPerWeek: perWeek, deadline: dueIn.map(Fixture.day), sortIndex: sort, createdAt: Fixture.longAgo)
    }

    func testErrandsAreASideListThatDoesNotTouchTheRestOfThePlan() {
        let errands = (0..<5).map { errand("Errand \($0)", sort: $0) }
        let without = scheduler.plan(f.input())
        let with = scheduler.plan(f.input(activities: f.all + errands))
        // Same blocks either way: errands are untimed and outside the budget.
        XCTAssertEqual(with.days.map(\.blocks), without.days.map(\.blocks))
        XCTAssertEqual(with.days[0].errands.count, 3, "At most errandsPerDay suggested")
        // One-offs are spread across the week, never repeated.
        let all = with.days.flatMap(\.errands)
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(Set(all).count, 5)
    }

    func testDueSoonComesFirstAndIsNeverHeldBack() {
        var list = (0..<4).map { errand("Someday \($0)", priority: 4, sort: $0) }
        let passport = errand("Renew passport", dueIn: 1, priority: 2, sort: 9)
        let parcel = errand("Return parcel", dueIn: 0, priority: 1, sort: 10)
        list += [passport, parcel]
        let today = scheduler.plan(f.input(activities: list)).days[0].errands
        XCTAssertEqual(Array(today.prefix(2)), [parcel.id, passport.id])
        XCTAssertGreaterThanOrEqual(today.count, 3)
    }

    func testRecurringErrandIsSpaced() {
        let groceries = errand("Groceries", perWeek: 2)
        let plan = scheduler.plan(f.input(activities: [groceries],
                                          history: [SessionRecord(activityID: groceries.id, start: Fixture.at(-1, 18), minutes: 30)]))
        let days = plan.days.enumerated().filter { $0.element.errands.contains(groceries.id) }.map(\.offset)
        XCTAssertFalse(days.contains(0), "Done yesterday, so not again today")
        XCTAssertFalse(days.isEmpty)
        XCTAssertLessThanOrEqual(days.count, 2)
    }

    func testDoneTodayLeavesTheList() {
        let bank = errand("Call the bank")
        let done = [SessionRecord(activityID: bank.id, start: Fixture.at(0, 6), minutes: 10)]
        let plan = scheduler.plan(f.input(activities: [bank], history: done))
        XCTAssertTrue(plan.days.allSatisfy { !$0.errands.contains(bank.id) })
    }

    func testPinnedErrandAtATimeBecomesABlock() {
        let pharmacy = errand("Pharmacy")
        let at = Fixture.at(0, 17)
        let plan = scheduler.plan(f.input(activities: f.all + [pharmacy], overrides: [
            OverrideSpec(activityID: pharmacy.id, kind: .pin, start: Fixture.day(0), end: Fixture.day(1), pinnedTime: at),
        ]))
        let block = plan.days[0].blocks.first { $0.activityID == pharmacy.id }
        XCTAssertEqual(block?.kind, .errand)
        XCTAssertEqual(block?.start, at)
        XCTAssertFalse(plan.days[0].errands.contains(pharmacy.id))
        XCTAssertTrue(assertNoOverlaps(plan))
    }

    func testOldSavedPlansStillDecode() throws {
        let plan = scheduler.plan(f.input()).days[0]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as! [String: Any]
        json.removeValue(forKey: "errands")
        let decoded = try JSONDecoder().decode(DayPlan.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.blocks, plan.blocks)
        XCTAssertEqual(decoded.errands, [])
    }
}

extension ErrandTests {
    func testNewRecurringErrandIsDueStraightAway() {
        var groceries = ActivitySpec(name: "Groceries", bucket: .errand, sessionsPerWeek: 1, createdAt: Fixture.now)
        groceries.createdAt = Fixture.now
        let plan = scheduler.plan(f.input(activities: [groceries]))
        XCTAssertTrue(plan.days[0].errands.contains(groceries.id))
        XCTAssertEqual(plan.days.filter { $0.errands.contains(groceries.id) }.count, 1, "1× a week")
    }
}
