import XCTest
@testable import MomentumCore

final class SchedulerTests: XCTestCase {
    let f = Fixture()
    let scheduler = Scheduler()
    var cal: Calendar { Fixture.calendar }

    // MARK: Baseline sanity

    func testBaselinePlanIsSensible() {
        let plan = scheduler.plan(f.input())
        XCTAssertEqual(plan.days.count, 7)
        XCTAssertTrue(assertNoOverlaps(plan))
        for day in plan.days {
            // LeetCode every day, capped at 20 minutes, in the morning.
            let lc = day.blocks.filter { $0.activityID == f.leetcode.id }
            XCTAssertEqual(lc.count, 1)
            XCTAssertLessThanOrEqual(lc.first?.minutes ?? 99, 20)
            // Exactly one primary focus.
            XCTAssertEqual(Set(day.blocks.filter(\.isPrimary).compactMap(\.activityID)).count, 1)
            // At most two main-work projects (+1 short starvation-guard session), never more than the cap.
            let projects = Set(day.blocks.filter { $0.kind == .focus }.compactMap(\.activityID)).count
            let guarded = day.blocks.contains { $0.reasons.contains { $0.contains("keeps it alive") } }
            XCTAssertLessThanOrEqual(projects, guarded ? 3 : 2)
            XCTAssertLessThanOrEqual(day.mainMinutes, SchedulerConfig.default.mainWorkCapNormal)
            // Evening hobbies: one by default, never more than the ceiling.
            XCTAssertLessThanOrEqual(day.blocks.filter { $0.kind == .hobby }.count, 2)
            // Spare time is preserved.
            XCTAssertLessThanOrEqual(day.plannedFlexibleMinutes, day.flexibleBudget)
        }
        XCTAssertFalse(plan.notes.isEmpty, "Plan should explain itself")
    }

    func testDeterministic() {
        let a = scheduler.plan(f.input())
        let b = scheduler.plan(f.input())
        XCTAssertEqual(a, b)
    }

    // MARK: Boost / focus sprint

    func testBoostMakesItTheFocusAndBalanceResumes() {
        let boost = OverrideSpec(activityID: f.interview.id, kind: .boost, start: Fixture.day(0), end: Fixture.day(5), factor: 2.5)
        let plan = scheduler.plan(f.input(overrides: [boost]))
        let during = plan.days[0..<5]
        let interview = during.reduce(0) { $0 + $1.minutes(for: f.interview.id) }
        let total = during.reduce(0) { $0 + $1.mainMinutes }
        // ×2.5 weight among three equal projects → ~56% of focus.
        XCTAssertGreaterThanOrEqual(Double(interview) / Double(total), 0.45)
        XCTAssertGreaterThanOrEqual(during.filter { $0.primaryActivityID == f.interview.id }.count, 3)
        let normally = scheduler.plan(f.input()).days[0..<5].reduce(0) { $0 + $1.minutes(for: f.interview.id) }
        XCTAssertGreaterThan(Double(interview), Double(normally) * 1.3, "Boost gives substantially more time")
        XCTAssertTrue(during.flatMap(\.blocks).contains { $0.reasons.contains { $0.hasPrefix("Boosted") } })
        XCTAssertTrue(plan.notes.contains { $0.contains("boosted") })
        // Balance resumes afterwards.
        XCTAssertTrue(plan.days[5...].contains { $0.primaryActivityID != f.interview.id })
    }

    func testNeglectedProjectsReturnAfterFocusSprint() {
        // Five days of interview prep just happened; thesis and side project were last touched 9 days ago.
        var history: [SessionRecord] = []
        for d in 1...5 {
            for s in 0..<4 { history.append(SessionRecord(activityID: f.interview.id, start: Fixture.at(-d, 9 + s), minutes: 50)) }
        }
        history.append(SessionRecord(activityID: f.thesis.id, start: Fixture.at(-9, 10), minutes: 50))
        history.append(SessionRecord(activityID: f.sideProject.id, start: Fixture.at(-9, 14), minutes: 50))
        let plan = scheduler.plan(f.input(history: history))
        XCTAssertNotEqual(plan.days[0].primaryActivityID, f.interview.id, "The neglected ones lead the day after a sprint")
        XCTAssertTrue(plan.days[0].blocks.contains { $0.reasons.contains("Behind its share lately") })
        for id in [f.thesis.id, f.sideProject.id] {
            XCTAssertTrue(plan.days.prefix(3).contains { $0.count(of: id) > 0 }, "Back within 3 days")
        }
    }

    func testNothingStarvesEvenUnderALongStrongBoost() {
        let boost = OverrideSpec(activityID: f.interview.id, kind: .boost, start: Fixture.day(0), end: Fixture.day(7), factor: 4)
        var config = SchedulerConfig()
        config.maxMainActivitiesPerDay = 1  // the harshest case: only one project per day
        let plan = Scheduler(config: config).plan(f.input(overrides: [boost]))
        // Proportional share: a small share is still a share.
        XCTAssertTrue(plan.days.contains { $0.count(of: f.thesis.id) > 0 }, "Thesis should not starve")
    }

    // MARK: Hobbies

    func testGymRecoveryConstraintRespected() {
        var gym = f.gym
        gym.weight = 4   // wants far more than recovery allows
        let acts = f.all.filter { $0.id != f.gym.id } + [gym]
        let history = [SessionRecord(activityID: gym.id, start: Fixture.at(-1, 19), minutes: 60)]
        let plan = scheduler.plan(f.input(activities: acts, history: history))
        let sessions = plan.allBlocks.filter { $0.activityID == gym.id }.sorted { $0.start < $1.start }
        XCTAssertEqual(plan.days[0].count(of: gym.id), 0, "Gym yesterday evening → rest today")
        XCTAssertGreaterThan(sessions.count, 0)
        var lastEnd = Fixture.at(-1, 20)
        for s in sessions {
            XCTAssertGreaterThanOrEqual(s.start.timeIntervalSince(lastEnd), 40 * 3600, "Recovery violated at \(s.start)")
            lastEnd = s.end
        }
        XCTAssertTrue(plan.days[0].notes.contains { $0.contains("Gym") && $0.contains("rest") })
    }

    func testMissedHobbiesDoNotBuildABacklog() {
        // Guitar: nothing for three weeks, and today's session was skipped.
        let history = [SessionRecord(activityID: f.guitar.id, start: Fixture.at(0, 6), minutes: 0, outcome: .skipped)]
        let plan = scheduler.plan(f.input(history: history))
        let guitarDays = plan.days.map { $0.count(of: f.guitar.id) }
        XCTAssertEqual(guitarDays[0], 0, "Skipped today stays skipped")
        XCTAssertTrue(guitarDays.allSatisfy { $0 <= 1 }, "Never doubled up to catch up")
        // Three equal hobbies over 7 evenings: guitar gets roughly its third, not a catch-up pile.
        XCTAssertLessThanOrEqual(guitarDays.reduce(0, +), 4)
        for day in plan.days { XCTAssertLessThanOrEqual(day.blocks.filter { $0.kind == .hobby }.count, 1) }
    }

    func testSkippingTodayDoesNotOverloadTomorrow() {
        let base = scheduler.plan(f.input())
        let skips = base.days[0].flexibleBlocks.compactMap { b in
            b.activityID.map { SessionRecord(activityID: $0, start: Fixture.at(0, 9), minutes: 0, outcome: .skipped) }
        }
        let later = Fixture.at(0, 10)
        let plan = scheduler.plan(f.input(now: later, history: skips, previous: base))
        let skipped = Set(skips.map(\.activityID))
        XCTAssertFalse(plan.days[0].flexibleBlocks.contains { skipped.contains($0.activityID!) }, "Skipped stays skipped today")
        let tomorrow = plan.days[1]
        let config = SchedulerConfig.default
        XCTAssertLessThanOrEqual(tomorrow.mainMinutes, config.mainWorkCapNormal, "No catch-up beyond the normal cap")
        XCTAssertLessThanOrEqual(tomorrow.minutes(for: .hobby), config.hobbyBudgetNormal)
        XCTAssertLessThanOrEqual(tomorrow.plannedFlexibleMinutes, tomorrow.flexibleBudget)
        XCTAssertLessThanOrEqual(tomorrow.blocks.filter { $0.kind == .hobby }.count, 2)
    }

    // MARK: Day shape & constraints

    func testDayStartingUnusuallyLate() {
        // Woke at 14:00, expects to sleep around 05:00.
        let wake = Fixture.at(0, 14)
        let now = Fixture.at(0, 14, 20)
        let ctx = [Fixture.today: DayContext(wake: wake, energy: .normal)]
        let sleep = DateInterval(start: Fixture.at(1, 5), end: Fixture.at(1, 13))
        let plan = scheduler.plan(f.input(now: now, dayContexts: ctx, sleeps: [sleep]))
        let today = plan.days[0]
        XCTAssertTrue(assertNoOverlaps(plan))
        XCTAssertFalse(today.flexibleBlocks.isEmpty)
        for b in today.flexibleBlocks {
            XCTAssertGreaterThanOrEqual(b.start, now)
            XCTAssertLessThanOrEqual(b.end, sleep.start, "The day runs until you sleep (past midnight if you're up)")
        }
        // Habits come first: right after waking.
        XCTAssertEqual(today.flexibleBlocks.first?.kind, .anchor)
        // Tomorrow's habits wait until after the sleep; nothing is planned while asleep.
        let tomorrow = plan.days[1]
        for b in tomorrow.flexibleBlocks where b.kind == .anchor { XCTAssertGreaterThanOrEqual(b.start, sleep.end) }
        for b in tomorrow.flexibleBlocks { XCTAssertFalse(b.interval.intersection(with: sleep).map { $0.duration > 0 } ?? false) }
    }

    func testStillUpAfterMidnightGetsHabitsAfterTheNextSleep() {
        // The real case: woke Monday 21:15, it's Tuesday 01:30, expects to sleep ~05:15 until ~13:15.
        let now = Fixture.at(1, 1, 30)
        let sleep = DateInterval(start: Fixture.at(1, 5, 15), end: Fixture.at(1, 13, 15))
        let done = [SessionRecord(activityID: f.leetcode.id, start: Fixture.at(0, 21, 45), minutes: 20)]
        let plan = scheduler.plan(f.input(now: now, history: done, sleeps: [sleep]))
        let tuesday = plan.days[0]
        XCTAssertEqual(tuesday.day, Fixture.day(1), "Each calendar day has its own set of things")
        XCTAssertTrue(assertNoOverlaps(plan))
        // Tuesday's habits (LeetCode included — Monday's doesn't count) go right after waking.
        let habits = tuesday.flexibleBlocks.filter { $0.kind == .anchor }
        XCTAssertEqual(habits.filter { $0.activityID == f.leetcode.id }.count, 1)
        for h in habits { XCTAssertGreaterThanOrEqual(h.start, sleep.end) }
        // Nothing while asleep, nothing past midnight.
        for b in tuesday.flexibleBlocks {
            XCTAssertFalse(b.interval.intersection(with: sleep).map { $0.duration > 0 } ?? false, "\(b.title) during sleep")
            XCTAssertGreaterThanOrEqual(b.start, now)
            XCTAssertLessThanOrEqual(b.end, Fixture.day(2))
        }
        // Focus can use the time before sleeping as well as after.
        XCTAssertTrue(tuesday.flexibleBlocks.contains { $0.kind == .focus && $0.end <= sleep.start })
        XCTAssertTrue(tuesday.flexibleBlocks.contains { $0.kind == .focus && $0.start >= sleep.end })
        // The hobby is in the evening.
        for h in tuesday.flexibleBlocks where h.kind == .hobby { XCTAssertGreaterThanOrEqual(h.start, Fixture.at(1, 18)) }
        // Future days: habits, then work — not work at midnight before you've even woken.
        let wednesday = plan.days[1]
        let wake = wednesday.sleeps.map(\.end).filter { $0 > Fixture.day(2) }.min()!
        for b in wednesday.flexibleBlocks where b.kind == .focus { XCTAssertGreaterThanOrEqual(b.start, wake, "\(b.title) before waking") }
    }

    func testSessionCutShortBySleepContinuesAfterwardsAndBedtimeStaysFree() {
        // 03:58, sleeping 05:15–13:15, one long-session project (4 h, min 1 h).
        var big = f.interview
        big.preferredMinutes = 240
        big.minMinutes = 60
        big.sessionsPerWeek = 6
        let now = Fixture.at(1, 3, 58)
        let sleep = DateInterval(start: Fixture.at(1, 5, 15), end: Fixture.at(1, 13, 15))
        let plan = scheduler.plan(f.input(now: now, activities: [f.leetcode, big], sleeps: [sleep]))
        let day = plan.days[0]
        let focus = day.flexibleBlocks.filter { $0.activityID == big.id }
        // Nothing in the 30 min before sleep; no stub shorter than the minimum.
        for b in focus {
            let windDownAndSleep = DateInterval(start: sleep.start.addingTimeInterval(-30 * 60), end: sleep.end)
            XCTAssertFalse(b.interval.intersection(with: windDownAndSleep).map { $0.duration > 0 } ?? false, "\(b.start) \(b.minutes)")
            XCTAssertGreaterThanOrEqual(b.minutes, big.minMinutes)
        }
        // The day still gets its full share of focus (cap 300 min), not a stub plus a remainder thrown away.
        XCTAssertGreaterThanOrEqual(focus.reduce(0) { $0 + $1.minutes }, 240)
    }

    func testHobbiesHaveMomentumNotRoundRobin() {
        // Guitar the last two evenings, reading three days ago. Plain rotation would pick reading;
        // guitar is on a roll and continues. (A hobby neglected for weeks still wins — momentum is bounded.)
        let guitar = f.guitar, reading = f.reading
        let history = [-1, -2].map { SessionRecord(activityID: guitar.id, start: Fixture.at($0, 20), minutes: 30) }
            + [SessionRecord(activityID: reading.id, start: Fixture.at(-3, 20), minutes: 30)]
        let plan = scheduler.plan(f.input(activities: [guitar, reading], history: history))
        let tonight = plan.days[0].blocks.filter { $0.kind == .hobby && !$0.isOptional }
        XCTAssertEqual(tonight.first?.activityID, guitar.id)
        XCTAssertTrue(tonight.first!.reasons.contains { $0.contains("run going — day 3") })
        // Bounded: it doesn't take every evening — reading still gets its turns in the week.
        XCTAssertGreaterThanOrEqual(plan.days.filter { $0.count(of: reading.id) > 0 }.count, 1)
    }

    func testHobbiesComeInRunsAcrossTheWeek() {
        // Fresh start, three hobbies (3, 2, 2 a week): runs, not Guitar–Reading–Guitar–GeoGuessr–…
        var guitar = f.guitar, reading = f.reading
        var geo = ActivitySpec(name: "GeoGuessr", bucket: .hobby, minMinutes: 20, preferredMinutes: 30, sessionsPerWeek: 2,
                               enjoyment: 3, sortIndex: 2, createdAt: Fixture.longAgo)
        guitar.sessionsPerWeek = 3; reading.sessionsPerWeek = 2; geo.sortIndex = 2
        let plan = scheduler.plan(f.input(activities: [guitar, reading, geo]))
        let sequence = plan.days.compactMap { d in d.blocks.first { $0.kind == .hobby && !$0.isOptional }?.activityID }
        let switches = zip(sequence, sequence.dropFirst()).filter { $0 != $1 }.count
        XCTAssertLessThanOrEqual(switches, 3, "Runs of the same hobby, not a rotation")
        XCTAssertTrue(plan.days.flatMap(\.blocks).contains { $0.reasons.contains { $0.hasPrefix("Keeping the run going") } })
        // Still bounded by each hobby's weekly count.
        XCTAssertLessThanOrEqual(sequence.filter { $0 == guitar.id }.count, 3)
    }

    func testANeglectedHobbyComesBackSoon() {
        // Guitar yesterday (a run), reading last done 10 days ago: reading gets back in within two evenings.
        let history = [SessionRecord(activityID: f.guitar.id, start: Fixture.at(-1, 20), minutes: 30),
                       SessionRecord(activityID: f.reading.id, start: Fixture.at(-10, 20), minutes: 30)]
        let plan = scheduler.plan(f.input(activities: [f.guitar, f.reading], history: history))
        XCTAssertTrue(plan.days.prefix(2).contains { $0.count(of: f.reading.id) > 0 })
    }

    func testHabitsAreOncePerDayEvenAfterANap() {
        // Woke at 08:00, did the habits, napped 13:00–15:00. No habits again after the nap.
        let now = Fixture.at(0, 15, 5)
        let nap = DateInterval(start: Fixture.at(0, 13), end: Fixture.at(0, 15))
        let done = [f.leetcode, f.motivation].map { SessionRecord(activityID: $0.id, start: Fixture.at(0, 8), minutes: 20) }
        let plan = scheduler.plan(f.input(now: now, history: done, dayContexts: [Fixture.today: DayContext(wake: Fixture.at(0, 8))],
                                          sleeps: [nap]))
        XCTAssertTrue(plan.days[0].flexibleBlocks.allSatisfy { $0.kind != .anchor })
        XCTAssertEqual(plan.days[1].flexibleBlocks.filter { $0.kind == .anchor }.count, 2, "New day, new habits")
    }

    func testAwakePastUsualBedtimeAssumesSleepSoonNotNow() {
        // Usual sleep 00:00–08:00; it's 01:00, no estimate. Don't assume they're asleep already.
        let now = Fixture.at(1, 1)
        let plan = scheduler.plan(f.input(now: now))
        let sleeps = plan.days[0].sleeps
        XCTAssertEqual(sleeps.first?.start, now.addingTimeInterval(3600))
        // Near the usual wake time (07:00), assume they're up.
        let morning = scheduler.plan(f.input(now: Fixture.at(1, 7)))
        XCTAssertFalse(morning.days[0].sleeps.contains { $0.start <= Fixture.at(1, 7) && $0.end > Fixture.at(1, 7) })
        XCTAssertEqual(morning.days[0].flexibleBlocks.first?.kind, .anchor)
    }

    func testUnexpectedAppointmentIsRespectedAndLocal() {
        let base = scheduler.plan(f.input())
        let appt = CommitmentSpec(title: "Dentist", start: Fixture.at(0, 11), end: Fixture.at(0, 13))
        let plan = scheduler.plan(f.input(commitments: [appt], previous: base))
        let today = plan.days[0]
        XCTAssertTrue(today.blocks.contains { $0.commitmentID == appt.id && $0.start == appt.start })
        for b in today.flexibleBlocks {
            XCTAssertFalse(b.interval.intersects(DateInterval(start: appt.start, end: appt.end)) && b.end != appt.start && b.start != appt.end,
                           "\(b.title) overlaps the appointment")
        }
        XCTAssertTrue(assertNoOverlaps(plan))
        // Later days barely change.
        let laterA = WeekPlan(generatedAt: base.generatedAt, days: Array(base.days.dropFirst()), notes: [])
        let laterB = WeekPlan(generatedAt: plan.generatedAt, days: Array(plan.days.dropFirst()), notes: [])
        XCTAssertGreaterThanOrEqual(PlanStability.similarity(laterA, laterB, calendar: cal), 0.85)
    }

    func testImpossibleDayAndExcessiveWorkloadAreAvoided() {
        // Many urgent, high-priority projects; a day almost full of meetings.
        var acts = f.all
        for i in 0..<6 {
            acts.append(ActivitySpec(name: "Urgent \(i)", bucket: .mainWork, priority: 5, minMinutes: 25, preferredMinutes: 90,
                                     sessionsPerWeek: 7, deadline: Fixture.day(1), maxSessionsPerDay: 5, sortIndex: 10 + i,
                                     createdAt: Fixture.longAgo))
        }
        let meetings = [
            CommitmentSpec(title: "Workshop", start: Fixture.at(0, 8, 30), end: Fixture.at(0, 17)),
            CommitmentSpec(title: "Dinner", start: Fixture.at(0, 18), end: Fixture.at(0, 21)),
        ]
        let plan = scheduler.plan(f.input(activities: acts, commitments: meetings))
        XCTAssertTrue(assertNoOverlaps(plan))
        for day in plan.days {
            XCTAssertLessThanOrEqual(day.plannedFlexibleMinutes, day.flexibleBudget, "Over-utilised \(day.day)")
            XCTAssertLessThanOrEqual(day.mainMinutes, SchedulerConfig.default.mainWorkCapNormal)
            for b in day.flexibleBlocks {
                XCTAssertGreaterThanOrEqual(b.start, day.windowStart)
                XCTAssertLessThanOrEqual(b.end, day.windowEnd)
            }
        }
        let today = plan.days[0]
        XCTAssertLessThan(today.mainMinutes, 200, "A day of meetings leaves little focus time")
    }

    // MARK: Overrides

    func testPinForcesActivityToDayAndTime() {
        let pinTime = Fixture.at(2, 10, 30)
        let pin = OverrideSpec(activityID: f.reading.id, kind: .pin, start: Fixture.day(2), end: Fixture.day(3), pinnedTime: pinTime)
        let plan = scheduler.plan(f.input(overrides: [pin]))
        let block = plan.days[2].blocks.first { $0.activityID == f.reading.id }
        XCTAssertEqual(block?.start, pinTime)
        XCTAssertEqual(block?.isPinned, true)
        XCTAssertTrue(assertNoOverlaps(plan))
    }

    func testPinOntoCommitmentMovesToNextFreeSlotNotOverlap() {
        let appt = CommitmentSpec(title: "Call", start: Fixture.at(1, 10), end: Fixture.at(1, 11))
        let pin = OverrideSpec(activityID: f.thesis.id, kind: .pin, start: Fixture.day(1), end: Fixture.day(2), pinnedTime: Fixture.at(1, 10))
        let plan = scheduler.plan(f.input(commitments: [appt], overrides: [pin]))
        let block = plan.days[1].blocks.first { $0.activityID == f.thesis.id && $0.isPinned }
        XCTAssertNotNil(block)
        XCTAssertGreaterThanOrEqual(block!.start, appt.end)
        XCTAssertTrue(assertNoOverlaps(plan))
    }

    func testPauseExcludesUntilDate() {
        let pause = OverrideSpec(activityID: f.gym.id, kind: .pause, start: Fixture.now, end: Fixture.day(4))
        let pauseThesis = OverrideSpec(activityID: f.thesis.id, kind: .pause, start: Fixture.now, end: Fixture.day(3))
        let plan = scheduler.plan(f.input(overrides: [pause, pauseThesis]))
        for i in 0..<4 { XCTAssertEqual(plan.days[i].count(of: f.gym.id), 0, "Gym paused on day \(i)") }
        for i in 0..<3 { XCTAssertEqual(plan.days[i].count(of: f.thesis.id), 0, "Thesis paused on day \(i)") }
        XCTAssertTrue(plan.days[3...].contains { $0.count(of: f.thesis.id) > 0 }, "Thesis resumes after pause")
        XCTAssertTrue(plan.days[4...].contains { $0.count(of: f.gym.id) > 0 }, "Gym resumes after pause")
    }

    func testDeferUntilAndExclude() {
        let later = OverrideSpec(activityID: f.leetcode.id, kind: .deferUntil, start: Fixture.now, end: Fixture.at(0, 15))
        let moved = OverrideSpec(activityID: f.guitar.id, kind: .exclude, start: Fixture.day(0), end: Fixture.day(1))
        let plan = scheduler.plan(f.input(overrides: [later, moved]))
        let lc = plan.days[0].blocks.first { $0.activityID == f.leetcode.id }
        XCTAssertNotNil(lc)
        XCTAssertGreaterThanOrEqual(lc!.start, Fixture.at(0, 15))
        XCTAssertEqual(plan.days[0].count(of: f.guitar.id), 0)
    }

    // MARK: Stability

    func testSmallChangesPreserveSchedule() {
        let base = scheduler.plan(f.input())
        // Small edit 1: tweak a hobby's enjoyment.
        var reading = f.reading
        reading.enjoyment = 4
        let acts1 = f.all.map { $0.id == reading.id ? reading : $0 }
        let p1 = scheduler.plan(f.input(activities: acts1, previous: base))
        XCTAssertGreaterThanOrEqual(PlanStability.similarity(base, p1, calendar: cal), 0.8)
        // Small edit 2: add a low-priority, low-frequency activity.
        let extra = ActivitySpec(name: "Tax admin", bucket: .mainWork, priority: 1, minMinutes: 25, preferredMinutes: 30,
                                 sessionsPerWeek: 1, sortIndex: 9, createdAt: Fixture.now)
        let p2 = scheduler.plan(f.input(activities: acts1 + [extra], previous: p1))
        // A new project genuinely takes a share (the Add sheet previews this), so allow a bit more movement.
        XCTAssertGreaterThanOrEqual(PlanStability.similarity(p1, p2, calendar: cal), 0.6)
        // Replanning later the same morning with nothing changed keeps today's plan.
        let p3 = scheduler.plan(f.input(now: Fixture.at(0, 7, 30), activities: acts1 + [extra], previous: p2))
        XCTAssertGreaterThanOrEqual(PlanStability.similarity(p2, p3, calendar: cal), 0.9)
    }

    func testCompletingABlockAdjustsRemainingPlanGently() {
        let base = scheduler.plan(f.input())
        guard let first = base.days[0].flexibleBlocks.first, let id = first.activityID else { return XCTFail() }
        let done = [SessionRecord(activityID: id, start: first.start, minutes: first.minutes)]
        let plan = scheduler.plan(f.input(now: first.end, history: done, previous: base))
        XCTAssertFalse(plan.days[0].blocks.contains { $0.activityID == id && $0.kind == .anchor }, "Completed anchor not re-suggested")
        let remainingBefore = base.days[0].flexibleBlocks.dropFirst().compactMap(\.activityID)
        let remainingAfter = plan.days[0].flexibleBlocks.compactMap(\.activityID)
        XCTAssertEqual(Set(remainingBefore), Set(remainingAfter))
    }

    // MARK: Energy

    func testLowEnergyShrinksTheDay() {
        let ctxLow = [Fixture.today: DayContext(wake: Fixture.at(0, 8), energy: .low)]
        let normal = scheduler.plan(f.input()).days[0]
        let low = scheduler.plan(f.input(dayContexts: ctxLow)).days[0]
        XCTAssertLessThan(low.mainMinutes, normal.mainMinutes)
        XCTAssertLessThanOrEqual(low.mainMinutes, SchedulerConfig.default.mainWorkCapLow)
        XCTAssertEqual(low.blocks.first { $0.activityID == f.leetcode.id }?.minutes, f.leetcode.minMinutes)
    }
}

final class PolicyTests: XCTestCase {
    func testAgingIsCapped() {
        XCTAssertEqual(MainWorkPolicy.aging(daysSince: 3.5, cap: 7), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MainWorkPolicy.aging(daysSince: 7, cap: 7), 1)
        XCTAssertEqual(MainWorkPolicy.aging(daysSince: 400, cap: 7), 1)
    }

    func testMomentumHasDiminishingReturns() {
        let m = (0...6).map { MainWorkPolicy.momentum(consecutiveDays: $0, decay: 0.5) }
        XCTAssertEqual(m[0], 0)
        for i in 1..<m.count { XCTAssertGreaterThan(m[i], m[i - 1]) }
        for i in 2..<m.count { XCTAssertLessThan(m[i] - m[i - 1], m[i - 1] - m[i - 2] + 1e-12) }
        XCTAssertLessThan(MainWorkPolicy.momentum(consecutiveDays: 50, decay: 0.5), 1.0000001)
    }

    func testUrgencyRampsTowardsDeadlineAndIgnoresPast() {
        XCTAssertEqual(MainWorkPolicy.urgency(daysLeft: nil, horizon: 14), 0)
        XCTAssertEqual(MainWorkPolicy.urgency(daysLeft: 14, horizon: 14), 0)
        XCTAssertEqual(MainWorkPolicy.urgency(daysLeft: 7, horizon: 14), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MainWorkPolicy.urgency(daysLeft: 0, horizon: 14), 1)
        XCTAssertEqual(MainWorkPolicy.urgency(daysLeft: -2, horizon: 14), 0)
    }

    func testBoostMultipliesScore() {
        let p = MainWorkPolicy(config: .default)
        let base = MainWorkSignals(priority: 3, daysSinceLast: 2, daysUntilDeadline: nil, minutesInWindow: 0,
                                   targetMinutesPerWeek: 200, consecutiveDays: 0)
        var boosted = base
        boosted.boost = 3
        XCTAssertEqual(p.evaluate(boosted).total, p.evaluate(base).total * 3, accuracy: 1e-9)
    }

    func testHobbyNeedNeverExceedsTarget() {
        let s = HobbySignals(sessionsInWindow: 0, targetPerWeek: 3, daysSinceLast: 60, enjoyment: 3)
        XCTAssertEqual(s.need, 3)
        let p = HobbyPolicy(config: .default).evaluate(s)
        XCTAssertLessThanOrEqual(p.value("consistency"), 1)
        XCTAssertLessThanOrEqual(p.value("recency"), 1)
    }

    func testConfigDecodingIsTolerant() throws {
        let json = #"{"urgencyWeight": 2.0, "unknownKey": 5}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(SchedulerConfig.self, from: json)
        XCTAssertEqual(c.urgencyWeight, 2.0)
        XCTAssertEqual(c.agingWeight, SchedulerConfig.default.agingWeight)
    }
}

final class PinnedEveningTests: XCTestCase {
    /// A pin made by swapping in a long project mid-afternoon used to take the whole evening (its full
    /// preferred length counted against the budget), so the hobby silently disappeared.
    func testLongPinnedProjectLeavesRoomForTheEveningHobby() {
        var f = Fixture()
        f.sideProject.minMinutes = 60
        f.sideProject.preferredMinutes = 240
        let done = [f.leetcode, f.motivation].map { SessionRecord(activityID: $0.id, start: Fixture.at(0, 9), minutes: 20) }
        let pin = OverrideSpec(activityID: f.sideProject.id, kind: .pin, start: Fixture.at(0, 15, 30), end: Fixture.day(1))
        for hour in [19, 20, 21] {
            let now = Fixture.at(0, hour, 10)
            let day = Scheduler(config: SchedulerConfig()).plan(f.input(now: now, history: done, overrides: [pin])).days[0]
            XCTAssertNotNil(day.blocks.first { $0.kind == .hobby }, "hobby gone at \(hour):10")
            let pinned = day.blocks.first { $0.activityID == f.sideProject.id }
            XCTAssertNotNil(pinned, "pin gone at \(hour):10")
            if let pinned { XCTAssertGreaterThanOrEqual(pinned.minutes, 60) }
        }
    }
}

/// Up past midnight, the day carries on until you sleep: work and hobbies aren't cut off by the clock.
final class ExtendedDayTests: XCTestCase {
    let f = Fixture()
    var habitsDone: [SessionRecord] { [f.leetcode, f.motivation].map { SessionRecord(activityID: $0.id, start: Fixture.at(0, 9), minutes: 20) } }

    func plan(now: Date, planningDay: Date? = nil, history: [SessionRecord], sleep: DateInterval) -> WeekPlan {
        let base = f.input(now: now, history: history, sleeps: [sleep])
        let input = SchedulerInput(now: now, calendar: Fixture.calendar, activities: base.activities, history: history,
                                   sleeps: [sleep], defaultWakeMinutes: 8 * 60, defaultAwakeHours: 16, planningDay: planningDay)
        return Scheduler(config: SchedulerConfig()).plan(input)
    }

    /// Bedtime 3 am: at 23:45 today's plan simply continues past midnight.
    func testTodayRunsUntilBedtimeNotMidnight() {
        let sleep = DateInterval(start: Fixture.at(1, 3), duration: 8 * 3600)
        let day = plan(now: Fixture.at(0, 23, 45), history: habitsDone, sleep: sleep).days[0]
        XCTAssertEqual(day.day, Fixture.day(0))
        let hobby = day.blocks.first { $0.kind == .hobby }
        XCTAssertNotNil(hobby)
        if let hobby { XCTAssertLessThanOrEqual(hobby.end, sleep.start) }
        XCTAssertTrue(day.blocks.contains { $0.kind == .focus && $0.end > Fixture.day(1) }, "work carries on past midnight")
    }

    /// Still up at 00:30 (bed at 4): it's still Monday, with both work and the hobby before sleep.
    func testStillUpAfterMidnightIsTheSameDay() {
        let sleep = DateInterval(start: Fixture.at(1, 4), duration: 8 * 3600)
        let week = plan(now: Fixture.at(1, 0, 30), planningDay: Fixture.day(0), history: habitsDone, sleep: sleep)
        let monday = week.days[0]
        XCTAssertEqual(monday.day, Fixture.day(0))
        XCTAssertTrue(monday.blocks.contains { $0.kind == .hobby && $0.end <= sleep.start })
        XCTAssertTrue(monday.blocks.contains { $0.kind == .focus && $0.end <= sleep.start })
        XCTAssertTrue(monday.flexibleBlocks.allSatisfy { $0.start >= Fixture.at(1, 0, 30) })
        // Tuesday starts when you wake: nothing of Tuesday's before then.
        let tuesday = week.days[1]
        XCTAssertEqual(tuesday.day, Fixture.day(1))
        XCTAssertTrue(tuesday.flexibleBlocks.allSatisfy { $0.start >= sleep.end }, "Tuesday before waking")
        XCTAssertTrue(assertNoOverlaps(week))
    }

    /// Guitar at 00:30 counts for Monday (the day you were still in): Monday's hobby is done, Tuesday keeps its own.
    func testAfterMidnightSessionsCountForTheDayYouWereIn() {
        let sleep = DateInterval(start: Fixture.at(1, 4), duration: 8 * 3600)
        let guitar = SessionRecord(activityID: f.guitar.id, start: Fixture.at(1, 0, 30), minutes: 30)
        let week = plan(now: Fixture.at(1, 1, 15), planningDay: Fixture.day(0), history: habitsDone + [guitar], sleep: sleep)
        XCTAssertFalse(week.days[0].blocks.contains { $0.kind == .hobby }, "Monday's hobby is done")
        XCTAssertTrue(week.days[1].blocks.contains { $0.kind == .hobby }, "Tuesday has its own")
    }
}

/// Things you set in the Week view: fixed (exact time and length), flexible (keeps its day), and focus days.
final class PlanItemTests: XCTestCase {
    let f = Fixture()
    let now = Fixture.at(0, 7)

    func plan(_ overrides: [OverrideSpec], commitments: [CommitmentSpec] = []) -> WeekPlan {
        Scheduler(config: SchedulerConfig()).plan(f.input(now: now, commitments: commitments, overrides: overrides))
    }

    func item(_ a: ActivitySpec, day: Int, hour: Int?, minutes: Int, fixed: Bool) -> OverrideSpec {
        OverrideSpec(activityID: a.id, kind: .pin, start: Fixture.day(day), end: Fixture.day(day + 1),
                     pinnedTime: hour.map { Fixture.at(day, $0) }, minutes: minutes, isFixed: fixed)
    }

    /// "Tomorrow is all interview prep": no other project that day; other days unchanged in kind.
    func testFocusDayGivesTheDayToOneProject() {
        let focus = OverrideSpec(activityID: f.interview.id, kind: .focusDay, start: Fixture.day(1), end: Fixture.day(2))
        let week = plan([focus])
        let tomorrow = week.days[1].blocks.filter { $0.kind == .focus }
        XCTAssertFalse(tomorrow.isEmpty)
        XCTAssertTrue(tomorrow.allSatisfy { $0.activityID == f.interview.id }, "\(tomorrow.map(\.title))")
        XCTAssertGreaterThanOrEqual(tomorrow.reduce(0) { $0 + $1.minutes }, SchedulerConfig().mainWorkCapNormal - 60)
        XCTAssertTrue(week.days[1].blocks.contains { $0.kind == .hobby }, "the evening stays")
        XCTAssertTrue(week.days.dropFirst(2).contains { d in d.blocks.contains { $0.kind == .focus && $0.activityID != f.interview.id } })
    }

    /// Fixed: exact time and length, never trimmed, and the rest of the day is planned around it.
    func testFixedKeepsItsExactTimeAndLength() {
        let fixed = item(f.thesis, day: 1, hour: 14, minutes: 180, fixed: true)
        let appt = CommitmentSpec(title: "Dentist", start: Fixture.at(1, 10), end: Fixture.at(1, 11))
        for week in [plan([fixed]), plan([fixed], commitments: [appt])] {
            let b = week.days[1].blocks.first { $0.overrideID == fixed.id }
            XCTAssertEqual(b?.start, Fixture.at(1, 14))
            XCTAssertEqual(b?.minutes, 180)
            XCTAssertEqual(b?.hold, .fixed)
            XCTAssertTrue(assertNoOverlaps(week))
        }
    }

    /// The same disturbance for both: an appointment right over their time. Fixed reports the clash;
    /// flexible shifts its time but keeps its day and length.
    func testFlexibleShiftsButKeepsItsDay() {
        let flex = item(f.thesis, day: 1, hour: 14, minutes: 120, fixed: false)
        let appt = CommitmentSpec(title: "Call", start: Fixture.at(1, 13, 30), end: Fixture.at(1, 15))
        let calm = plan([flex]).days[1].blocks.first { $0.overrideID == flex.id }
        XCTAssertEqual(calm?.start, Fixture.at(1, 14), "keeps its time when it can")
        let week = plan([flex], commitments: [appt])
        let moved = week.days[1].blocks.filter { $0.overrideID == flex.id }
        XCTAssertFalse(moved.isEmpty, "still on its day")
        XCTAssertEqual(moved.reduce(0) { $0 + $1.minutes }, 120)
        XCTAssertTrue(moved.allSatisfy { $0.hold == .flexible })
        XCTAssertTrue(assertNoOverlaps(week))
    }

    /// A long fixed block isn't shortened to make room for the evening (quick pins are).
    func testFixedIsNeverTrimmed() {
        let fixed = item(f.thesis, day: 1, hour: 9, minutes: 600, fixed: true)
        let b = plan([fixed]).days[1].blocks.first { $0.overrideID == fixed.id }
        XCTAssertEqual(b?.minutes, 600)
    }

    /// No room at all on its day: a flexible item moves to the next day instead of vanishing.
    func testFlexibleWithNoRoomMovesToTheNextDay() {
        let flex = item(f.thesis, day: 1, hour: nil, minutes: 90, fixed: false)
        let allDay = CommitmentSpec(title: "Away", start: Fixture.at(1, 0), end: Fixture.at(2, 0))
        let week = plan([flex], commitments: [allDay])
        XCTAssertFalse(week.days[1].blocks.contains { $0.overrideID == flex.id })
        let next = week.days[2].blocks.first { $0.overrideID == flex.id }
        XCTAssertNotNil(next)
        XCTAssertEqual(next?.minutes, 90)
    }

    /// Two separate blocks of the same project on one day, both kept.
    func testTwoItemsOfTheSameActivity() {
        let a = item(f.interview, day: 1, hour: 9, minutes: 120, fixed: true)
        let b = item(f.interview, day: 1, hour: 15, minutes: 90, fixed: false)
        let day = plan([a, b]).days[1]
        XCTAssertEqual(day.blocks.first { $0.overrideID == a.id }?.start, Fixture.at(1, 9))
        XCTAssertEqual(day.blocks.first { $0.overrideID == b.id }?.start, Fixture.at(1, 15))
    }
}

extension PlanItemTests {
    /// Tonight runs past midnight (bed at 2 am): tomorrow's focus day and fixed item stay on tomorrow.
    func testTomorrowsSettingsDontLeakIntoTonight() {
        let sleep = DateInterval(start: Fixture.at(1, 2), duration: 8 * 3600)
        let focus = OverrideSpec(activityID: f.interview.id, kind: .focusDay, start: Fixture.day(1), end: Fixture.day(2))
        let fixed = item(f.interview, day: 1, hour: 0, minutes: 60, fixed: true)
        let input = f.input(now: Fixture.at(0, 18), overrides: [focus, fixed], sleeps: [sleep])
        let today = Scheduler(config: SchedulerConfig()).plan(input).days[0]
        XCTAssertFalse(today.blocks.contains { $0.overrideID == fixed.id })
        let plain = Scheduler(config: SchedulerConfig()).plan(f.input(now: Fixture.at(0, 18), sleeps: [sleep])).days[0]
        XCTAssertEqual(today.blocks.filter { $0.kind == .focus }.map(\.activityID), plain.blocks.filter { $0.kind == .focus }.map(\.activityID))
    }
}
