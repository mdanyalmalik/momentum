<p align="center">
  <img src="assets/logo.svg" width="128" alt="Momentum logo">
</p>

# Momentum

**A calm, self-adjusting scheduler for macOS, built for people who struggle to organise their time.**

If planning your day feels like a chore, if to-do lists turn into guilt lists, or if your sleep, energy
and motivation are all over the place, Momentum is for you. You tell it what matters and roughly how much.
It works out what to do next, around when you actually woke up, and quietly rearranges itself when life
gets in the way.

> **You decide what matters. The scheduler decides when to suggest it. You can always override it.**

## Who it's for

- People with **irregular days or sleep**: night owls, shift workers, students, anyone who naps or sleeps twice a day.
- People who find **planning overwhelming**, procrastinate on choosing what to do, or abandon rigid schedules after one bad day.
- People juggling **several projects and hobbies** who want each to get a fair share of time without micromanaging it.
- Anyone who wants a planner that **never punishes missed days**: no streaks to break, no backlog piling up.

## What it does

- **Tells you what to do now.** Today shows one suggestion with Start, Done, Swap, Later and Skip, plus at most two more.
  The full day is one click away.
- **Minimal setup.** No weekly targets or session counts. Drag things into order and rank sets each one's share of time.
  Adding something new shows exactly what else changes before you save.
- **Schedules like a CPU.** A fair-share scheduler gives the next slot to whatever is furthest behind its share,
  in runs of a few days rather than a jittery round-robin. Coming back after time away never creates a catch-up pile.
- **Fits around your sleep.** Each calendar day has its own set of things. Habits come right after you wake, once a day.
  Tell it roughly when you'll sleep, or press *Going to Sleep* and *I'm Awake*, and work splits around it.
- **Deadlines that keep pace.** Give a deadline an optional work estimate and it plans the daily pace needed,
  telling you honestly when it won't fit.
- **Forgiving by design.** Skipping is never penalised and missed time never becomes debt. Swap or skip by mistake?
  Undo it, or bring it back from *Set aside today*.
- **Work beyond the plan.** Start a session of anything at any time from **Start…**. It all counts.
- **A timer that survives.** Pause and resume, and quitting or a crash never loses a running session.
- **Errands on the side.** A small checklist (groceries, bills) that never clutters or reshuffles your plan.
- **Plans and stats.** A folder of Markdown documents per project, and a look back over weeks or months of what you did.
- **Private.** Everything stays on your Mac. No accounts, network calls or AI APIs.

## Run it

Requires macOS 15+ and Xcode 16+ (built and tested with Xcode 27.2 / Swift 6.4).

```sh
scripts/build-app.sh             # builds build/Momentum.app (release)
open build/Momentum.app
```

Other options:

- `swift run Momentum` runs straight from SwiftPM.
- `open Package.swift` opens the package in Xcode. Pick the *Momentum* scheme and press ⌘R.
- `swift test` runs the scheduling engine's unit tests.
- `swift scripts/make-icon.swift` re-renders `assets/logo.svg` into `Resources/AppIcon.icns`.

Data (the database, plan documents in `Plans/`, and backups) is stored locally in `~/Library/Application Support/Momentum/`
by default. Change it in **Settings → General → Data location**: Momentum moves everything there and restarts
(or uses the Momentum data already in that folder). Set `MOMENTUM_STORE_DIR=/some/dir` to use a throwaway store.

## Screens

| Screen | What it's for |
|---|---|
| **Today** (⌘1) | The current or next suggestion, a timer with pause, a gentle progress ring, things set aside today, the full day on demand, and a side list of errands. |
| **Week** (⌘2) | Seven day columns of suggested blocks and appointments. Drag a block to another day to move it. Right-click an appointment to edit it. Shows balance (actual vs intended share), notes and explanations. |
| **Activities** (⌘3) | Habits, Projects and Hobbies, ranked by dragging (higher gets more time), plus a narrow **Errands** checklist. Click a card to edit it. Right-click for Pause, Boost, Pin, Open Plan and Log Time. |
| **Plans** (⌘4) | A folder of Markdown documents per activity: create, rename, edit with a live preview, or focus on one document. Plain `.md` files on disk. |
| **Stats** (⌘5) | Look back 4 weeks to a year: hours per week or month, and per-activity time, sessions and change vs the period before. |

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Start Day | ⇧⌘S |
| Going to Sleep / I'm Awake | ⇧⌘L |
| Set bedtime (when you expect to sleep next) | ⇧⌘B |
| Log time spent outside the app | ⇧⌘T |
| New Activity | ⌘N |
| New Appointment | ⇧⌘N |
| Replan | ⌘R |
| Start / complete the current item | ⌘↩ |
| Mark done | ⌘D |
| Pause / resume the timer | ⇧⌘P |
| Cancel a timer | Esc |
| New plan document (in Plans) | ⇧⌘D |
| Focus on a plan document (in Plans) | ⇧⌘F · Esc to exit |
| Settings | ⌘, |

## Quick tour

1. On first launch, choose **Start with examples** or **Start empty**.
2. **Activities → Projects → + Add**: add "Thesis". Optionally give it a deadline and a work estimate ("about 15h left").
   The editor shows what else changes this week before you save.
3. Add a few **Hobbies** and **Habits**, then drag them into order. Higher means a bigger share.
4. Right-click a project → **Boost…** to give it a bigger share for a few days. Balance returns afterwards with no backlog.
5. On **Today**, press **Start Day** and set your wake time and bedtime. Use Start, Done, Swap, Later or Skip.
   The rest of the plan adjusts.
6. Did something outside the app? **Log Time** (⇧⌘T). Want to keep going after the plan is done? **Start…**.

## Architecture

```
Sources/MomentumCore/        Pure Swift scheduling engine (no UI, no persistence)
  Types.swift                ActivitySpec, SessionRecord, OverrideSpec, DayContext → WeekPlan/DayPlan/PlannedBlock
  SchedulerConfig.swift      Every tunable number, with tolerant decoding
  FairShare.swift            CFS-style weights, decayed service, vruntime, wake-up placement, stickiness
  Allocation.swift           Rank → share, and plan diffs for "what this changes"
  Scheduler.swift            Sleep timeline and the day-by-day pipeline: pins, habits, focus, hobbies, errands, placement
  Ledger.swift               Free-time arithmetic and per-activity service accounting
  Duration.swift, Markdown.swift   Duration parsing ("1h30") and a small Markdown parser
Sources/Momentum/            The macOS app (SwiftUI + SwiftData)
  Persistence/               SwiftData models, data location, Markdown plan files, sample data
  AppModel.swift             Bridge: every mutation → save → replan → persist the plan for stability
  Views/                     Today, Week, Activities, Plans, Stats, editor, sheets, settings
  Snapshotter.swift          Dev tool: renders screens to PNG against a throwaway store
Tests/MomentumCoreTests/     Engine tests and multi-week simulations
```

How the scheduler works, with every formula, default and tuning tip: **[docs/SCHEDULING.md](docs/SCHEDULING.md)**.

## Design principles

- Optimise for **starting** meaningful things, not for maximising scheduled hours. About 40% of free time is left unplanned on purpose.
- At most three actionable priorities are visible at first.
- Finishing the day's baseline counts as a good day. Everything else is a bonus.
- Missed time never becomes debt. Skipping is never penalised. There are no streaks, only "active days" dots that never reset.
- Configuration is kept to a minimum: rank things, and the app works out the rest and tells you what it changed.
- Appointments keep their real clock times. Everything else is a suggestion that moves with your day.

## License

[MIT](LICENSE)
