# Momentum

A native macOS app (SwiftUI + SwiftData) that helps you organise your life around flexible routines,
shifting priorities, irregular sleep and fluctuating motivation, without creating overwhelming to-do lists.

**You decide what matters. The scheduler decides when to suggest it. You can always override it.**

## Run it

Requires macOS 15+ and Xcode 16+ (built and tested with Xcode 27.2 / Swift 6.4).

```sh
scripts/build-app.sh            # builds build/Momentum.app (release)
swift scripts/make-icon.swift    # re-renders assets/logo.svg into Resources/AppIcon.icns
open build/Momentum.app
```

Other options:

- `swift run Momentum` runs straight from SwiftPM.
- `open Package.swift` opens the package in Xcode. Pick the *Momentum* scheme and press ⌘R.
- `swift test` runs the scheduling engine's unit tests.

Data (the database, plan documents in `Plans/`, and backups) is stored locally in `~/Library/Application Support/Momentum/` by default. Change it in **Settings → General → Data location**: Momentum moves everything there and restarts (or uses the Momentum data already in that folder).
There are no accounts, network calls or AI APIs.
Set `MOMENTUM_STORE_DIR=/some/dir` to use a throwaway store.

## Screens

| Screen | What it's for |
|---|---|
| **Today** (⌘1) | The current or next suggestion with **Start · Done · Swap · Later · Skip**, at most two more priorities, a gentle progress ring, the full day on demand, optional extras, and "why today looks like this". |
| **Week** (⌘2) | Seven day columns of suggested blocks and fixed appointments. Drag a block to another day to move it. Also shows the balance (actual vs intended share), deadlines, overrides and explanations. |
| **Activities** (⌘3) | Habits, Projects and Hobbies, ranked by dragging (higher gets more time), plus a narrow **Errands** checklist. Drag cards to reorder them or move them between buckets. Click a card to edit it. Right-click for Pause, Boost, Pin and Move. |
| **Plans** (⌘4) | A folder of Markdown documents for each habit, project and hobby: create, rename, edit with a live preview (tick task boxes right in the preview). Plain `.md` files in `~/Library/Application Support/Momentum/Plans/`. |
| **Stats** (⌘5) | Look back 4 weeks to a year: hours per week or month, and per-activity time, sessions, weekly average and change vs the period before. |

Keyboard shortcuts:

| Action | Shortcut |
|---|---|
| Start Day | ⇧⌘S |
| Going to Sleep / I'm Awake | ⇧⌘L |
| Set bedtime (when you expect to sleep next) | ⇧⌘B |
| New plan document (in Plans) | ⇧⌘D |
| Plan document full screen (in Plans) | ⇧⌘F · Esc to exit |
| Settings | ⌘, (or the Settings button at the bottom of the sidebar) |
| Log time you spent outside the app | ⇧⌘T |
| New Activity | ⌘N |
| New Appointment | ⇧⌘N |
| Replan | ⌘R |
| Start / complete the current item | ⌘↩ |
| Mark done | ⌘D |
| Cancel a timer | Esc |

Scheduling weights are in **Settings (⌘,) → Scheduling**.

## Walkthrough (the acceptance scenario)

1. On first launch, choose **Start with examples** or **Start empty**.
2. **Activities → Hobbies → + Add**: add "Guitar". Drag it up or down to change its share.
3. **Main Work → + Add**: add "Thesis" and "Interview prep". You can give a deadline an optional work estimate
   ("about 15h left"). The plan then keeps pace with it, and completed sessions count it down.
4. **Anchors → + Add**: add "LeetCode" and turn on *Two-phase timer* (15 + 5 min).
   Starting it shows an attempt phase, then a review phase, capped at 20 minutes.
5. Right-click "Interview prep" → **Boost…** → 5 days. It becomes the primary focus each day,
   lower-priority work is deferred, and the Week view shows balance returning afterwards.
6. On **Today**, press **Start Day** and set your wake time and energy. Use Skip, Swap, Later or Done,
   or drag blocks around in **Week**. The rest of the plan adjusts.
7. Quit and reopen. Everything is persisted with SwiftData.

## Architecture

```
Sources/MomentumCore/        Pure Swift scheduling engine (no UI, no persistence)
  Types.swift                ActivitySpec, SessionRecord, OverrideSpec, DayContext → WeekPlan/DayPlan/PlannedBlock
  SchedulerConfig.swift      Every tunable weight, with tolerant decoding
  Scoring.swift              MainWorkPolicy and HobbyPolicy (pure functions → ScoreBreakdown + reasons)
  Ledger.swift               Free-time arithmetic and per-activity service accounting
  Scheduler.swift            The day-by-day pipeline, quantum allocation, placement, explanations
Sources/Momentum/            The macOS app
  Persistence/Models.swift   SwiftData models: Bucket, Activity, WeeklyTarget, ActivitySession,
                             FixedCommitment, SchedulingOverride, DailyPlan, CompletionHistory, AppSettings
  AppModel.swift             Bridge: every mutation → save → replan (Scheduler) → persist the plan for stability
  Views/                     Today, Week, Buckets, editor, sheets, settings
  Snapshotter.swift          Dev tool: MOMENTUM_SNAPSHOT_DIR renders screens to PNG via a scripted demo
Tests/MomentumCoreTests/     Engine tests (boost sprints, neglected projects, gym recovery, late starts,
                             appointments, pin/boost/pause, stability, overload, hobby debt…)
```

The scheduling formula, defaults, assumptions and tuning guide are in
**[docs/SCHEDULING.md](docs/SCHEDULING.md)**.

## Design principles

- Optimise for **starting** meaningful things, not for maximising scheduled hours. About 40% of free time is left unplanned on purpose.
- At most three actionable priorities are visible at first. The full day is one click away.
- Finishing the baseline counts as a good day. Extras are labelled optional.
- Errands are a side checklist: untimed, a few suggested per day, never counted against your day.
- Missed time never becomes debt. Skipping is never penalised. There are no streaks, only "active days" dots that never reset.
- Each calendar day has its own set of things. Habits come right after you wake (from any sleep), once a day.
  Everything else fits around your sleep: tell it roughly when you'll sleep, and work splits around it.
- No weekly targets. You rank things; rank sets each one's share of time and a CPU-style fair scheduler keeps
  things near their share — in runs, with no catch-up pile after time away. Adding something shows what it changes.
- Fixed appointments keep their real clock times. Everything else is a suggestion relative to when you woke up.
