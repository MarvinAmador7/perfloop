---
title: The PerfLoop journey
subtitle: How a by-hand performance session became an agent-run loop, and what the loop found
dates: 2026-10-30 to 2026-10-31
status: the loop is parked here (Phases 0–4 built, on the local branch perfloop/phase-0-1); raw material for the
  product story and the website, with the numbers and their caveats
---

This is the record of how PerfLoop was built and what it measured, written so that whoever designs PerfLoop as a
product (site, launch post, demo) has the true story and the numbers behind each claim. Every number here comes from
a run on the capcomd desktop app; where a number has a caveat, the caveat is next to it. Section 6 lists the claims
the story can make and what backs each one; section 7 lists what it must not claim.

Related files: `SPEC.md` (the design), `CAPABILITIES.md` (C1–C10), `SCHEMAS.md`, `FEASIBILITY.md`, and
`apps/menubar/app/LAYOUT.md` (the native-path design note with every measurement of the last round).

# 1. The one-line story

A coding agent spent an evening making a Mac app's window fast by hand, and it worked, but it was a craft: 40
profiler recordings, a parser written on the spot, two wrong turns. So we turned the craft into a loop an agent can
run alone: measure honestly, change one thing, keep it only if it wins and breaks nothing visible, write it down.
Then we let the loop loose on the app. It refused to be fooled by noise, caught a build that cheated, found real bugs
in the app, found a bug in its own bench that had doubled every number, and told us, with data, not to build the
custom rendering engine we were tempted to build.

# 2. Where it started: the by-hand session (2026-10-30)

The capcomd desktop app shows a "reel": a horizontally scrolling row of columns, one per coding agent in a run, each
streaming that agent's thread. With 17 agents, stepping from column to column stuttered.

One session fixed much of it by hand with the existing bench (`deskbench`):

| | before | after |
|---|---:|---:|
| step, frame time p95 | 67.7 ms | 12.6 ms |
| project switch latency | 544 ms | 153 ms |
| compositor hitches in 12 s | 257 | 52 |

(Commits 3a6b5b7 → 9bcd41a. Measured with the bench as it was then; see §5.4 for a bench bug found later, so treat
these as relative, not absolute.)

What it cost is the reason PerfLoop exists: about an hour of bench wall time, roughly 40 xctrace recordings, 16 A/B
runs, a Python parser written mid-session to read `xctrace export` XML, and two wrong turns. One wrong turn came from
a stale trace; one came from `lateFrames` looking like a regression when the display had merely switched from 24 to
120 Hz. SPEC §1 lists the nine things that session could not see; each became a capability.

# 3. What we built

PerfLoop is a separate Swift package (`tools/perfloop`, zero imports from the app) plus an app adapter (`deskbench`).
An agent talks to it through a CLI, JSON files and an append-only ledger. The loop: a candidate build is measured
against the current champion in interleaved pairs; a quick *screen* rejects losers cheaply; a *full* run decides; the
champion changes only if the objective wins and every guard passes. Each experiment's result, reasoning and
provenance go into the ledger.

The ten capabilities, as built:

| | Capability | What it gives the agent |
|---|---|---|
| C1 | In-process main-thread sampler | stacks inside every long stretch, every run, at ~1.3 % overhead, no profiler needed |
| C2 | `perfloop diff` | a differential call tree, A vs B, per step: "what grew in B" |
| C3 | Low-noise objective | main-thread CPU ms and instructions retired per step; frame metrics that don't change meaning with refresh rate; a quiet-machine check before every rep |
| C4 | Runtime knobs | compare settings in one binary, no rebuild per idea |
| C5 | Ledger and champion | a content-addressed build store, provenance stamped into every binary, an append-only experiment ledger |
| C6 | Correctness guards | the search can't make the app faster by making it wrong (§5.2) |
| C7 | "Why did this body run" | each SwiftUI body re-evaluation charged to the state mutation that caused it |
| C8 | Sweeps | cost curves over crew size, thread length and knobs, with a fitted slope |
| C9 | Recorded-gesture replay | a real trackpad swipe replayed into the window, scored for how well the content followed the fingers |
| C10 | A machine nobody is using | an idle-gated local runner, an `ssh://` runner for a spare Mac, and an overnight queue |

Pace: the spec planned Phases 0–4 at roughly seven to eight weeks of work. Coding agents built them between the spec
(2026-10-30) and the evening of 2026-10-31, in parallel worktrees, each phase merged only after its tests and its
acceptance checks on the real window passed. About 65 commits; `tools/perfloop` alone is ~8,000 lines with 120 tests,
plus the adapter's 77 bench tests.

# 4. How it was built: the phases

**Phase 0–1, truth first.** Before any optimising, the bench had to be believable.
- It now waits for a quiet machine before each rep and counts the stretch it waits in.
- The same build against itself gives the noise floor: −0.8 % on CPU, +4.5 % on instructions, both inside their
  bands (±5.4 % for instructions). If the bench can't tell a build from itself, nothing else it says counts.
- The sampler caught 24 of 24 long stretches.

**Phase 2, the loop's bones.** Knobs, the manifest, `describe`, the ledger, the champion. The first knob checks
already earned their keep:
- `reel.slide=clip` vs the Core Animation slide: +91 % CPU. Rejected, and the bench says so in one line.
- `build.perFrame=2/4` vs 1: no latency win and the longest stall 35–44 % longer. The default stays.

**Phase 3, guards, causes, sweeps.** The loop learnt to refuse wins that break things, to explain why views
re-rendered, and to draw cost curves (§5.2, §5.3).

**Phase 4, feel and machines.** Recorded gestures and the smoothness score (C9); the runners and the queue (C10);
and a round of real experiments on the app's rendering path, run through the loop (§5.5).

# 5. What the loop found

## 5.1 It refuses to be fooled by noise

Every comparison reports a verdict per metric: *same*, *better*, *worse*, *unsure*. A difference counts only if it
is outside the noise band measured for that metric and significant across interleaved pairs (Mann-Whitney). Runs on a
busy or distracted machine are marked **untrusted** and never decide anything.

That rule held even when it was inconvenient. On the developer's Mac, frames came in late even while the window sat
idle, so every run there was marked untrusted. On the spare Mac mini, the screen was locked, so the bench window
could never become active: the runner now refuses to start reps on a locked screen instead of collecting numbers that
look fine and mean nothing.

## 5.2 It caught a build that cheated

The obvious way for an optimiser to win is to do less work than it should: show a blank column, skip a build, leave
a thread half drawn. So PerfLoop has guards the search cannot edit: `built-within` (every column in view must be built
once the window is at rest) and `snapshot-diff` (the window at rest must look like the champion's, pixel for pixel,
within 0.5 %).

To test them, we wrote a cheating build on purpose. It switched projects in **67 ms instead of 114 ms**, which would
read as a 41 % win. It failed `built-within` in both reps, and its snapshot differed by 1.9 %. An honest build
against an honest build differed by 0.13 %.

It happened for real too: in the last round, a layout experiment (`frames-hide`) showed an apparent **−27 %**. The
guards flagged it: the speed came from columns that were blank. The fix went in (`fd33c02`), and the "win"
disappeared.

## 5.3 It found real bugs in the app

- **Threads filled in late.** After a project switch, threads appeared 2–3 s after the columns (the guards saw the
  column on screen before its content). Occasionally a thread rested mostly empty. Both reported to the owner, not
  fixed by the loop: behaviour is the owner's call.
- **The reel didn't snap after a real swipe.** Replaying a swipe with real timestamps showed AppKit's own
  deceleration carrying the reel up to ~200 pt past the column edge, and a queued scroll delta could be dropped. The
  old synthetic "fling" sent no timestamps, which hid the bug and its cost: a realistic swipe costs about twice the
  CPU of the synthetic one.
- **Every column body ran twice per update.** Found by the cause records (C7); explained in §5.4.

## 5.4 It found a bug in its own bench

The biggest finding of the last round was not in the app. The bench's command started before SwiftUI had made the
app's window, so it made a second window in front of it. Every default run had been measuring **two reels on one
model**: that was the "every body runs twice". With the fix (`7db3144`), a 17-agent step went from ~180 to ~120 ms
of main-thread CPU. Every number recorded before the fix is about twice one window's cost.

This is a good story because it is the loop working as intended: the cause records showed something that made no
sense, and an agent chased it until the instrument itself was the answer.

## 5.5 It told us not to build the engine (yet)

We were tempted by a GPUI-style custom renderer, or at least a Rust layout engine. The owner's direction was to push
native macOS (AppKit, Core Animation, Core Text) first and let the data decide. The loop ran each idea as a knob,
against the champion, with guards:

| Experiment (knob) | Idea | Result on a step |
|---|---|---|
| `desk.column=native` | AppKit column chrome instead of SwiftUI | −13 % instructions (better in 5 of 5 pairs, but inside a ±14 % noise band); the one promising change |
| `desk.layout=frames` | our own frame-based layout instead of Auto Layout | no faster; longest stall +40 % |
| `reel.columns=park` | keep only nearby columns in the scrolling document | +16 % worse: re-parenting views costs more than it saves |
| `reel.columns=reuse` | true virtualization: fixed slots reconfigured in place | +38 % on 17 agents, but the cost per agent fell from 3.28 to 2.40 ms |
| `reel.cache=bitmap` | slide cached bitmaps instead of live views | +778 % worse: rasterising a column takes 100–150 ms |

Then the profile split said why. On a step, main-thread time went to AppKit walking the view tree for Auto Layout
(42 ms at 40 agents), recomputing mouse-tracking areas (35 ms), SwiftUI's hosting views re-placing columns (41 ms)
and SwiftUI transactions (46 ms). Layout arithmetic never showed up. The cost grows with the **number of views**
SwiftUI creates for the threads (about 1,100, including a text-field overlay for every piece of selectable text), not
with how hard layout is.

So the answer was: our own layout math, done faster in any language, would not help; a Rust layout engine would have
solved a problem we don't have. The next step the data points to is native thread rows drawn with Core Text and
cached, which is what would make column reuse pay. The engine decision stays open, and now it has a test.

Sweep, step, 4 → 64 agents (main-thread CPU, most points on a busy machine):

| Columns | ms per agent | 4 → 64 agents |
|---|---:|---|
| SwiftUI (today) | 3.28 | 50 → 261 ms |
| AppKit | 2.96 | 46 → 237 ms |
| AppKit + reuse | 2.40 | 43 → 212 ms |

## 5.6 Feel, measured

A recorded trackpad swipe is replayed into the window and scored on how well the content followed the fingers:
position error, stalls, jerk, latency in frames. On three synthetic gestures, the content stayed on the path in all
48 replays (0 pt error at p95; the spec's bar was 1 pt). A real gesture recorded by hand is still to come.

## 5.7 A machine nobody is using

Benchmarks on a laptop someone is typing on are noise. The local runner waits until the Mac has been idle (two
minutes by default), aborts and redoes a rep if someone touches it, and gives up the window between reps. The
`ssh://` runner copies the build to a spare Mac, opens the window in its logged-in session, and fetches the results;
the queue runs experiments overnight until a deadline. Results record their machine and are never mixed across
machines. It ran end to end on a Mac mini; trusted numbers from it wait on an unlocked screen.

# 6. Claims the story can make

| Claim | Backed by |
|---|---|
| "Agents can run performance work on a native Mac app almost alone" | Phases 0–4 built and run by coding agents; the owner made calls on taste, behaviour and money |
| "It won't be fooled by noise" | same-build checks inside their bands; untrusted runs never decide (§5.1) |
| "It can't win by cheating" | the deliberate cheat: 67 vs 114 ms, caught twice; the real −27 % blank-column "win", caught (§5.2) |
| "It finds bugs, not just regressions" | late threads, the snap overshoot, the two-window bench bug (§5.3, §5.4) |
| "It measures feel" | gesture replay: 0 pt p95 error in 48/48 synthetic replays (§5.6) |
| "It tells you what not to build" | the native-path round and the profile split (§5.5) |
| "It runs while you sleep" | idle gating, the ssh runner and the queue (§5.7) |
| "Explainable" | every verdict in words; cause records charge each re-render to a state change |

# 7. What not to claim (yet)

- **No headline speed-up from the loop itself.** No experiment in the last round beat the champion. The by-hand
  session's numbers (§2) were measured before the two-window fix.
- **Not "trusted numbers on dedicated hardware" yet.** The developer's Mac marks its runs untrusted (late idle
  frames); the Mac mini's runs were behind a locked screen.
- **No real recorded gesture yet;** smoothness results are on synthetic gestures.
- **No VM runner;** it is a stub.
- **Not a product yet.** It lives in the capcomd repo as a separate package; extraction (Phase 5) waits for a second
  app or a month of stable schemas. If extracted: its own repo, MIT.
- The original-vs-final check and the six-binary replay (SPEC §6.1) couldn't run: those binaries were lost when the
  disk filled and the machine rebooted.

# 8. Behind the scenes (true, and useful for a post)

- The first run of the bench session filled the disk (a binary copy per variant plus traces) and broke an agent
  with ENOSPC; the Mac rebooted and cleared ~240 GB of temp files. Bench runs now delete binaries and traces as soon
  as their numbers are recorded.
- Profiler traces embed the recorded process's environment, tokens included, so they are never committed or
  published; captured fixtures are anonymised and refuse to be written inside a repo.
- SwiftUI's own Instruments tables came back empty even with Developer Mode on; the in-process sampler and cause
  records are what made SwiftUI's work visible.
- Agents worked in parallel worktrees and shared one physical window through a lock, because two benches on one
  screen measure each other.

# 9. Where it stands (2026-10-31)

Parked by the owner's decision. Phases 0–4 are merged on the local branch `perfloop/phase-0-1`, not pushed; all
knobs are off by default, so the app runs today's code. Open threads, if the loop resumes:

1. Native thread rows with Core Text and cached measurements (the next native step; §5.5).
2. The title bar's tab strip scroll, off the main thread.
3. Trusted runs on the Mac mini (unlock its screen), and a real recorded gesture.
4. Re-measure the earlier phases' numbers after the two-window fix.
5. The app bugs in §5.3, for the owner to decide on.
6. The menu-bar app's release build crashes the Swift compiler (`CapcomdStore.WindowFit.fitted`), on the base commit
   too; check against `main` before a release.
