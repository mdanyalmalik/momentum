import XCTest
@testable import MomentumCore

final class DurationParserTests: XCTestCase {
    func testAcceptsWhatPeopleType() {
        let p = DurationParser.self
        XCTAssertEqual(p.minutes(from: "45"), 45)
        XCTAssertEqual(p.minutes(from: "45m"), 45)
        XCTAssertEqual(p.minutes(from: "45 min"), 45)
        XCTAssertEqual(p.minutes(from: "1.5h"), 90)
        XCTAssertEqual(p.minutes(from: "1,5 h"), 90)
        XCTAssertEqual(p.minutes(from: "1h30"), 90)
        XCTAssertEqual(p.minutes(from: "1h 30m"), 90)
        XCTAssertEqual(p.minutes(from: "1:30"), 90)
        XCTAssertEqual(p.minutes(from: "2 hours"), 120)
        XCTAssertEqual(p.minutes(from: "90 mins"), 90)
        XCTAssertEqual(p.minutes(from: "15", bareUnit: .hours), 900)
        XCTAssertEqual(p.minutes(from: " 3 H "), 180)
    }

    func testRejectsNonsense() {
        for bad in ["", "abc", "1x", "-5", "1:75", "h", "1 h foo"] {
            XCTAssertNil(DurationParser.minutes(from: bad), bad)
        }
    }

    func testRoundTripsItsOwnFormat() {
        for m in [5, 45, 60, 90, 125, 600] {
            XCTAssertEqual(DurationParser.minutes(from: DurationParser.format(m)), m)
        }
    }
}

final class AllocationTests: XCTestCase {
    private func project(_ name: String, _ sort: Int) -> ActivitySpec {
        ActivitySpec(name: name, bucket: .mainWork, sessionsPerWeek: 0, sortIndex: sort, createdAt: Fixture.longAgo)
    }

    func testRankBecomesAShareNotAQuota() {
        let ps = (0..<3).map { project("P\($0)", $0) }
        let hs = (0..<2).map { ActivitySpec(name: "H\($0)", bucket: .hobby, sortIndex: $0, createdAt: Fixture.longAgo) }
        let r = Allocator.balance(ps + hs, config: .default, defaultAwakeHours: 16)
        let shares = ps.map { r.allotments[$0.id]!.share }
        XCTAssertEqual(shares, shares.sorted(by: >))
        XCTAssertEqual(shares.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(hs.reduce(0) { $0 + r.allotments[$1.id]!.share }, 1, accuracy: 1e-9)
        for (w, e) in zip(r.specs.filter { $0.bucket == .mainWork }.map(\.weight), [1, 0.7, 0.49]) { XCTAssertEqual(w, e, accuracy: 1e-9) }
        XCTAssertTrue(r.allotments[ps[1].id]!.reason.hasPrefix("2nd of 3 projects"))
    }

    func testHabitsStayDailyAndErrandsAreLeftAlone() {
        let habit = ActivitySpec(name: "LeetCode", bucket: .anchor, sessionsPerWeek: 0, createdAt: Fixture.longAgo)
        let errand = ActivitySpec(name: "Bank", bucket: .errand, sessionsPerWeek: 1, createdAt: Fixture.longAgo)
        let r = Allocator.balance([habit, errand], config: .default, defaultAwakeHours: 16)
        XCTAssertEqual(r.specs[0].sessionsPerWeek, 7)
        XCTAssertEqual(r.specs[1], errand)
        XCTAssertNil(r.allotments[errand.id])
    }
}

final class FairShareTests: XCTestCase {
    let a = UUID(), b = UUID()

    func testSomeoneComingBackIsPlacedOneSessionBehindNotAWeekBehind() {
        let items = [FairShare.Item(id: a, weight: 2, service: 300, floor: 50, rank: 0),
                     FairShare.Item(id: b, weight: 1, service: 0, floor: 50, rank: 1)]
        let v = FairShare.vruntimes(items)
        XCTAssertEqual(v[a]!, 150, accuracy: 1e-9)
        XCTAssertEqual(v[b]!, 100, accuracy: 1e-9, "Raw 0, but placed just one session behind the other: no debt")
        let lag = FairShare.lags(items)
        XCTAssertLessThan(lag[b]!, 0)
        XCTAssertGreaterThan(lag[a]!, 0)
    }

    func testStickinessKeepsTheIncumbentWithinGranularity() {
        let items = [FairShare.Item(id: a, weight: 1, service: 60, floor: 50, rank: 0),
                     FairShare.Item(id: b, weight: 1, service: 0, floor: 50, rank: 1)]
        XCTAssertEqual(FairShare.pick(items, incumbent: a, granularity: 90)?.id, a)
        XCTAssertEqual(FairShare.pick(items, incumbent: a, granularity: 30)?.id, b)
        XCTAssertEqual(FairShare.pick(items, incumbent: nil, granularity: 90)?.id, b)
    }
}

/// Lives the plan for weeks: plan, do today's blocks, move to the next day, repeat. Checks behaviour over
/// time, which a single plan can't show.
final class SimulationTests: XCTestCase {
    let scheduler = Scheduler()

    private func simulate(_ specs: [ActivitySpec], days: Int, skip: (Int, ActivitySpec) -> Bool = { _, _ in false }) -> [SessionRecord] {
        var history: [SessionRecord] = []
        let balanced = Allocator.balance(specs, config: .default, defaultAwakeHours: 16).specs
        for d in 0..<days {
            let plan = scheduler.plan(Fixture().input(now: Fixture.at(d, 7), activities: balanced.filter { !skip(d, $0) }, history: history))
            history += plan.days[0].flexibleBlocks.compactMap { b in
                b.activityID.map { SessionRecord(activityID: $0, start: b.start, minutes: b.minutes) }
            }
        }
        return history
    }

    private func minutes(_ h: [SessionRecord], _ id: UUID, from: Int, to: Int) -> Int {
        h.filter { $0.activityID == id && $0.start >= Fixture.day(from) && $0.start < Fixture.day(to) }.reduce(0) { $0 + $1.minutes }
    }

    func testSharesConvergeToRankWithoutWeeklyCounts() {
        let f = Fixture()
        let ps = [f.interview, f.thesis, f.sideProject].enumerated().map { i, a -> ActivitySpec in
            var a = a; a.sortIndex = i; a.sessionsPerWeek = 0; return a
        }
        let h = simulate(ps, days: 21)
        let m = ps.map { minutes(h, $0.id, from: 7, to: 21) }
        let total = Double(m.reduce(0, +))
        let shares = m.map { Double($0) / total }
        // Runs, not rotation: the main focus mostly stays for 2+ days.
        let mains = (7..<21).compactMap { d -> UUID? in
            let day = h.filter { $0.start >= Fixture.day(d) && $0.start < Fixture.day(d + 1) }
            return Dictionary(grouping: day, by: \.activityID).mapValues { $0.reduce(0) { $0 + $1.minutes } }.max { $0.value < $1.value }?.key
        }
        let switches = zip(mains, mains.dropFirst()).filter { $0 != $1 }.count
        XCTAssertLessThanOrEqual(switches, 8, "Main focus switched \(switches) times in \(mains.count) days")
        // Intended 1 : 0.7 : 0.49 → 46% / 32% / 22%.
        XCTAssertEqual(shares[0], 0.457, accuracy: 0.1, "\(shares)")
        XCTAssertEqual(shares[1], 0.320, accuracy: 0.1, "\(shares)")
        XCTAssertEqual(shares[2], 0.224, accuracy: 0.1, "\(shares)")
    }

    func testHobbiesRunInStretchesNotRoundRobin() {
        let f = Fixture()
        var geo = f.reading; geo.id = UUID(); geo.name = "GeoGuessr"
        let hs = [f.guitar, f.reading, geo].enumerated().map { i, a -> ActivitySpec in var a = a; a.sortIndex = i; return a }
        let h = simulate(hs, days: 21)
        let sequence = (0..<21).compactMap { d in
            h.first { r in hs.contains { $0.id == r.activityID } && r.start >= Fixture.day(d) && r.start < Fixture.day(d + 1) }?.activityID
        }
        let switches = zip(sequence, sequence.dropFirst()).filter { $0 != $1 }.count
        XCTAssertLessThanOrEqual(switches, 11, "Mostly runs of 2+ days: \(switches) switches in \(sequence.count) days")
        for hobby in hs { XCTAssertGreaterThan(sequence.filter { $0 == hobby.id }.count, 2, "Everything still gets its turn") }
    }

    func testComingBackAfterTimeAwayHasNoCatchUpPile() {
        let f = Fixture()
        let ps = [f.interview, f.thesis].enumerated().map { i, a -> ActivitySpec in var a = a; a.sortIndex = i; return a }
        // Thesis is away for days 0–9, then returns.
        let h = simulate(ps, days: 16, skip: { d, a in a.id == f.thesis.id && d < 10 })
        let back = (10..<16).first { minutes(h, f.thesis.id, from: $0, to: $0 + 1) > 0 }
        XCTAssertNotNil(back)
        XCTAssertLessThanOrEqual(back ?? 99, 12, "Gets back in within ~2 days")
        let thesisAfter = minutes(h, f.thesis.id, from: 10, to: 16)
        let interviewAfter = minutes(h, f.interview.id, from: 10, to: 16)
        XCTAssertGreaterThan(interviewAfter, 0)
        XCTAssertLessThanOrEqual(thesisAfter, interviewAfter + 2 * 50, "No catch-up burst: \(thesisAfter) vs \(interviewAfter)")
    }

    func testRecoveryIsNeverViolatedOverWeeks() {
        let f = Fixture()
        let h = simulate([f.gym, f.guitar], days: 21)
        let gym = h.filter { $0.activityID == f.gym.id }.map(\.start).sorted()
        for (x, y) in zip(gym, gym.dropFirst()) { XCTAssertGreaterThanOrEqual(y.timeIntervalSince(x), 40 * 3600 - 3600) }
    }
}

final class BoostTests: XCTestCase {
    func testBoostMultipliesShareSoItBecomesTheFocus() {
        func p(_ n: String, _ s: Int) -> ActivitySpec {
            ActivitySpec(name: n, bucket: .mainWork, sessionsPerWeek: 0, sortIndex: s, createdAt: Fixture.longAgo)
        }
        let specs = Allocator.balance([p("First", 0), p("Second", 1), p("Third", 2)], config: .default, defaultAwakeHours: 16).specs
        let third = specs[2]
        let boost = OverrideSpec(activityID: third.id, kind: .boost, start: Fixture.day(0), end: Fixture.day(5), factor: 4)
        let plan = Scheduler().plan(Fixture().input(activities: specs, overrides: [boost]))
        let boosted = plan.days.prefix(5).reduce(0) { $0 + $1.minutes(for: third.id) }
        let first = plan.days.prefix(5).reduce(0) { $0 + $1.minutes(for: specs[0].id) }
        XCTAssertGreaterThan(boosted, first, "Boosted ×4: the lowest-ranked project leads during the boost")
    }
}

final class MarkdownParserTests: XCTestCase {
    func testBlocks() {
        let md = """
        # Plan
        Some **bold** text
        continues here.

        - [ ] Draft outline
        - [x] Read paper
          - nested point
        1. First
        2. Second

        > A quote

        ```swift
        let x = 1
        ```
        ---
        | Week | Goal |
        |------|------|
        | 1 | Outline |
        """
        let b = MarkdownParser.parse(md)
        XCTAssertEqual(b[0], .heading(level: 1, text: "Plan"))
        XCTAssertEqual(b[1], .paragraph("Some **bold** text\ncontinues here."))
        XCTAssertEqual(b[2], .listItem(indent: 0, marker: .task(done: false), text: "Draft outline"))
        XCTAssertEqual(b[3], .listItem(indent: 0, marker: .task(done: true), text: "Read paper"))
        XCTAssertEqual(b[4], .listItem(indent: 1, marker: .bullet, text: "nested point"))
        XCTAssertEqual(b[5], .listItem(indent: 0, marker: .number(1), text: "First"))
        XCTAssertEqual(b[7], .quote("A quote"))
        XCTAssertEqual(b[8], .code(language: "swift", text: "let x = 1"))
        XCTAssertEqual(b[9], .rule)
        XCTAssertEqual(b[10], .table(header: ["Week", "Goal"], rows: [["1", "Outline"]]))
    }

    func testHashWithoutSpaceIsNotAHeading() {
        XCTAssertEqual(MarkdownParser.parse("#hashtag"), [.paragraph("#hashtag")])
    }
}
