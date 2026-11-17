# How Momentum schedules

> **You decide what matters. The scheduler decides when to suggest it. You can always override it.**

The engine lives in `Sources/MomentumCore` and has no UI or persistence dependencies.
It is **deterministic** (same input → same plan), **explainable** (every block carries plain-language
reasons), and **tunable** (every number lives in `SchedulerConfig` and is editable in *Settings → Scheduling*).

The weights are heuristics chosen to produce sensible plans. They are **not** psychologically
validated. Tune them until the plans feel right to you.

---

## Inputs

| Input | Source in the app |
|---|---|
| Activities (`ActivitySpec`) | Activities screen: rank (→ share weight), session length, deadline + optional estimate, rest |
| History (`SessionRecord`) | Completed, skipped and swapped sessions (last 21 days) |
| Fixed commitments | Appointments. Hard constraints, never moved |
| Overrides | Pin, Boost, Pause (user-facing). Exclude and Defer (created by *Move* and *Do Later*) |
| Day contexts | **Start Day**: wake time, hours awake, energy. Future days use the defaults |
| Previous plan | The plan currently shown, so changes stay small |

## Pipeline (per day, today first, across a rolling 7-day horizon)

Days are planned in order. Each day's planned sessions are written to a **service ledger**,
so later days see them, much like a CPU scheduler accounting for runtime.

1. **Days and sleep.** A day is a calendar day (midnight to midnight) with its own set of things to do.
   Sleep is cut out of it as busy time. The engine builds one **sleep timeline**: logged sleeps, the one in progress,
   your next-sleep estimate (Start Day, the "Sleep ~" chip, or "I'm up"), then the same rhythm repeated every 24 h
   (`24 − defaultAwakeHours` long). With no estimate, the next sleep is your usual bedtime. A usual sleep that should
   already have started is never assumed while you're awake: in its first half, sleep is assumed in an hour; in its
   second half, you're assumed to be up.
   - **Habits** go right after you wake. Today, if you've woken since midnight, that's now. If you're still up from
     yesterday, it's after your next sleep. They happen once per day, so a nap doesn't repeat them.
   - **Focus** fills awake time from now, splitting around sleep and appointments (a session takes the earliest gap
     that fits its minimum, shortened if needed).
   - **Evening** is the last `eveningPhaseHours` before the next sleep or midnight, whichever is first. Hobbies go there.
2. **Hard constraints.**
   - Fixed commitments, padded by `commitmentBufferMinutes`, are cut out of free time.
   - Paused activities (toggle, or a Pause override covering the day) are excluded.
   - Skipped or swapped today, moved away from this day, or deferred past the window end: excluded for the day.
   - Recovery: no session may start within `minRestHours` of another session of the same activity.
3. **Capacity.** `flexibleBudget = freeMinutes × utilisationTarget` (default 60%).
   The other 40% is deliberate slack. The scheduler **never aims for 100% utilisation**.
4. **Pins** are placed first, at their exact time if one was given. They win over pauses.
   If a pinned time clashes with a commitment, the pin moves to the next free slot. It never overlaps.
5. **Habits** run daily (or spaced if set less often), right after waking. Low energy uses the minimum duration.
6. **Bucket split.** Main Work is capped per energy level (`mainWorkCap*`: 150/300/390 min) and
   the evening hobby budget likewise (`hobbyBudget*`: 60/90/150). Minutes already done today count
   against the caps. If the day is short, both shrink, with hobbies keeping at least `hobbyFloorMinutes`.
   **Preemption:** if deadline pace needs more than the focus time, the evening is borrowed from, never below the hobby floor.
7. **Projects** and 8. **Hobbies**: fair share (below).
9. **Placement.** Anchors go first after waking, then focus sessions in order (primary first) with
   `breakMinutes` between them and `longBreakMinutes` after every `sessionsBeforeLongBreak` sessions,
   then hobbies from the evening phase (`eveningPhaseHours` before the window ends). If a session doesn't
   fit, it tries its minimum duration. If that still fails, it is dropped with a note. It is never squeezed
   over a commitment.

## Fair share: scheduling like a CPU

There are **no weekly counts**. You rank things by dragging. Rank sets a *share*, and the scheduler keeps
everything close to its share over time, like a CPU scheduler (CFS) sharing time between processes.

```
weight     w = ρ^rank × boost              (projects ρ = rankDecayMain 0.7, hobbies ρ = rankDecayHobby 0.8)
share        = w / Σw within its kind     (projects share daytime focus, hobbies share evenings)
service    S = minutes done, fading with a half-life of serviceHalfLifeDays (5): nothing resets on Monday
vruntime   v = S / w                       → the next slot goes to the lowest v (most behind its share)
```

- **No catch-up pile (wake-up placement).** History is replayed day by day, and each day nobody is allowed to
  be more than one session (plus the stickiness margin) behind the least-served *other* item. This is CFS
  placing a waking task near `min_vruntime`. Time away or skipped days are forgiven: an item comes back
  straight away but never hogs time to make up for it.
- **Runs, not round-robin (granularity).** The incumbent keeps its slot unless another is behind its share by
  more than a margin: `focusGranularityMinutes` (240, about a day) for the day's main project, and
  `hobbyGranularitySessions` (1.5 sessions) for hobbies. Yesterday's main project or hobby is the incumbent,
  which gives runs of a few days, then the next one's turn.
- **Projects:** the day's main project gets `mainFocusShare` (⅔) of the focus time. The rest goes to whichever
  project is most behind (optional secondary), which is also how a project comes back after time away.
- **Hobbies:** one per evening (`hobbiesPerDay`). Recovery (`minRestHours`) is a hard rule. The others are
  offered as extras.
- **Deadlines (real-time class).** With a work estimate, the pace needed (`remaining / days left` a day) is
  served first, and a project is never planned past its remaining work. If pace needs more than the day's
  focus time, the evening is trimmed (never below `hobbyFloorMinutes`), and the Week notes say honestly
  when it won't fit.
- **Habits** are periodic: daily by default, right after waking. **Errands** keep their own repeat.

Verified by multi-week simulations in the tests: shares converge to rank, hobbies run in stretches,
coming back after 10 days has no catch-up burst, and recovery always holds.

## Errands: a side list

Errands (groceries, bills, returns) are deliberately kept **outside** the day's plan:

- **Untimed, outside the budget, never in the baseline.** Adding 20 errands changes nothing else in the plan.
- Each day lists up to `errandsPerDay` (3) of them, ordered by **deadline**, then **priority**, then **how long they've waited**.
  Anything due by tomorrow is always listed, even past the cap.
- **One-off** errands (repeat: just once) stay on the list until ticked off, then leave the plan. They're spread across
  the week through the ledger, never repeated. **Recurring** errands (e.g. 1×/week) are spaced like anchors, and a new
  one is due straight away.
- **Pin** an errand to a day to put it at the top of that day's list. Pin it to a **time** and it becomes a real block.
- **Not today** excludes it for the day. Unticking undoes a tick-off.

## Overrides

| Override | Effect in the calculation |
|---|---|
| **Pin** | Hard constraint: placed on that day (at that time, if given) before anything else. Counts against budgets. |
| **Boost** | Weight × `factor` for its date range: a bigger share while it lasts. Afterwards shares return to rank, and the others are placed back in with no backlog. |
| **Pause** | Hard exclusion until the resume date. Nothing accumulates while paused. |
| Exclude *(internal)* | Created when you drag a block off a day. |
| Defer *(internal)* | *Do Later*: not before a time today. *Tomorrow* = exclude today. |

## Stability (minimising disruption)

The previous plan is passed back in on every replan.

- **Selection stability:** the previous plan's sessions for a day are the incumbents, so they stay unless something
  is clearly further behind its share. Small edits don't reshuffle the week (≥ 80% identical in tests; adding a
  whole new project ≥ 60%, since it really takes a share, as the Add sheet previews).
- **Locality:** commitments, completions and skips only change the day they touch. Later days change only through
  the ledger (for example, completing something today means it's a little less behind tomorrow).
- Block IDs are deterministic (`activity-yyyyMMdd-n`), so the UI keeps identity across replans.
- `PlanStability.similarity` (Jaccard over day/activity/occurrence) is used in tests: a small edit keeps ≥ 80% of
  the week identical.

## When does it replan?

After every mutation that goes through `AppModel`:

- adding, editing, deleting, pausing, reordering or moving an activity
- completing, skipping, swapping or using Do Later
- adding or removing an appointment
- Start Day or an energy change
- applying or removing an override
- a new (logical) day beginning
- a suggested block's time passing by 15 minutes untouched, which quietly re-slots the rest of today

## Tuning cheatsheet

| You feel… | Try |
|---|---|
| Days are too full | Lower *Share of free time to plan* or the focus times |
| Too much switching | Raise the project stickiness, or set *Projects per day* to 1 |
| Rank doesn't matter enough | Lower *How much rank matters* (0.5 = steep, 1 = everyone equal) |
| Hobby runs too long / too short | Lower / raise *Hobby runs* |
| Neglected things come back too slowly | Lower *Memory* (past time fades faster) |
| Deadlines sneak up | Add a work estimate |

## Assumptions

- A day is a calendar day. Future days are provisional: they follow your next-sleep estimate and usual rhythm.
- Session lengths are the activity's preferred duration. If the time isn't available, they fall back to the minimum.
- Completed sessions count as service. Skips and swaps are not failures: they only exclude the
  activity for that day. Missed time never becomes a backlog.
- The app records completions honestly but never shows streaks, failure counts or backlogs.
