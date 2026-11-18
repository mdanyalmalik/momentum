<p align="center">
  <img src="assets/logo.svg" width="128" alt="Momentum logo">
</p>

# Momentum

**A self-adjusting scheduler for macOS, designed for people who find it hard to organise their time.**

Momentum replaces rigid to-do lists and calendars with a plan that adapts to you. You list what matters and
rank it. Momentum decides what to work on next, fits it around your actual day, and reorganises the rest of
the week automatically when plans change.

> **You decide what matters. The scheduler decides when to suggest it. You can always override it.**

## Who it's for

- People with **irregular schedules**, whose days rarely start or end at the same time.
- People who find **planning overwhelming** or struggle to decide what to work on next.
- People balancing **several projects and interests** who want each to get a fair share of time without managing it by hand.
- Anyone who prefers a planner that **adapts instead of penalising**: no streaks to break and no backlog building up.

## Features

- **A clear next step.** Today shows the current suggestion with Start, Done, Swap, Later and Skip, plus at most two
  upcoming items. The full day is one click away.
- **Minimal configuration.** No weekly targets or session counts. Rank activities by dragging, and rank determines
  each one's share of time. Before saving a change, Momentum shows what else in the week it affects.
- **Fair-share scheduling.** Inspired by CPU schedulers, the next slot goes to whatever is furthest behind its share.
  Work runs in focused stretches of a few days rather than rotating daily, and time away never creates a catch-up backlog.
- **Built around your day.** Each calendar day has its own set of activities. Habits come first after you start your day,
  and the remaining work is arranged around your expected end of day.
- **Deadline pacing.** Add an optional work estimate to a deadline and Momentum schedules the daily pace required,
  flagging early when it won't fit.
- **Easy to correct.** Skips carry no penalty. Swap a suggestion for any other activity, undo a mistaken action,
  or restore anything set aside for the day.
- **Work beyond the plan.** Start a session of any activity at any time. All of it counts.
- **Reliable timer.** Pause and resume sessions. A running session is saved, so quitting or a crash never loses it.
- **Errands.** A separate checklist for small tasks that never disrupts the main plan.
- **Plans and stats.** Markdown documents for each activity, and a history of time spent over weeks or months.
- **Private.** All data stays on your Mac. No accounts, network calls or AI services.

## Run it

Requires macOS 15+ and Xcode 16+ (built and tested with Xcode 27.2 / Swift 6.4).

```sh
scripts/install.sh               # builds and installs /Applications/Momentum.app
open -a Momentum
```

Re-run `scripts/install.sh` after any change. If Momentum is open, the sidebar shows **Update installed — Restart**;
restarting keeps a running timer. `scripts/build-app.sh` builds `build/Momentum.app` without installing.

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
| **Today** (⌘1) | The current or next suggestion, a timer with pause, a progress ring, things set aside today, the full day on demand, and a side list of errands. |
| **Week** (⌘2) | Seven day columns of suggested blocks and appointments. Drag a block to another day to move it. Right-click an appointment to edit it. Shows balance (actual vs intended share), notes and explanations. |
| **Activities** (⌘3) | Habits, Projects and Hobbies, ranked by dragging (higher gets more time), plus a narrow **Errands** checklist. Click a card to edit it. Right-click for Pause, Boost, Pin, Open Plan and Log Time. |
| **Plans** (⌘4) | A folder of Markdown documents per activity: create, rename, edit with a live preview, or focus on one document. Plain `.md` files on disk. |
| **Stats** (⌘5) | Look back 4 weeks to a year: hours per week or month, and per-activity time, sessions and change vs the period before. |

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Start Day | ⇧⌘S |
| Going to Sleep / I'm Awake | ⇧⌘L |
| Set Bedtime (expected end of day) | ⇧⌘B |
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
5. On **Today**, press **Start Day** and set when your day started and roughly when it will end. Use Start, Done, Swap, Later or Skip.
   The rest of the plan adjusts.
6. Did something outside the app? **Log Time** (⇧⌘T). Want to keep going after the plan is done? **Start…**.

## Architecture

```
Sources/MomentumCore/        Pure Swift scheduling engine (no UI, no persistence)
  Types.swift                ActivitySpec, SessionRecord, OverrideSpec, DayContext → WeekPlan/DayPlan/PlannedBlock
  SchedulerConfig.swift      Every tunable number, with tolerant decoding
  FairShare.swift            CFS-style weights, decayed service, vruntime, wake-up placement, stickiness
  Allocation.swift           Rank → share, and plan diffs for "what this changes"
  Scheduler.swift            Day timeline and the day-by-day pipeline: pins, habits, focus, hobbies, errands, placement
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
