---
title: PerfLoop: an agent-first performance loop for native macOS apps
subtitle: Turning CapcomdDeskBench into a project a coding agent can run almost alone
date: 2026-10-30
status: design, for the owner's review; nothing here is implemented
---

Files in this folder:

- `SPEC.md` (this file): the decision, the architecture, the process model, the loop, the migration plan, open questions.
- `CAPABILITIES.md`: the ten capabilities as components (design, CLI surface, data written, feasibility, risks).
- `SCHEMAS.md`: the versioned JSON documents and how they grow out of `deskbench.result/1`.
- `FEASIBILITY.md`: what the probes in `probes/` showed, what is verified vs assumed, references.
- `probes/`: headless Swift probes run on 2026-10-30 (sampler, rusage counters, symbolication).

Today's bench: `apps/menubar/app/Sources/CapcomdDeskBench` (CLI, harness, drivers) and `Sources/DeskBenchKit`
(schemas, stats, xctrace parsing), documented in `apps/menubar/app/DESKBENCH.md`. Budgets: `design/desktop/SPEC.md` §1.

# 0. What this is

A loop that takes a scenario (say `step` on `crew17`), a budget (no late frame at 120 Hz), and a build, and climbs:
read where the main thread's time goes, change one thing, measure against the champion, keep it if it wins and
breaks nothing visible, write it down, repeat. A coding agent runs it; a person checks feel, taste and anything that
changes behaviour.

The 2026-10-30 session did this by hand with `deskbench` (3a6b5b7 → 9bcd41a: step frame p95 67.7 → 12.6 ms, switch
latency 544 → 153 ms, compositor hitches 257 → 52 in 12 s). It took about an hour of bench wall time, roughly 40
xctrace recordings and 16 `ab` runs, a Python parser written on the spot to build call trees from `xctrace export`
XML, and two wrong turns. This spec is what the tool must become so the next session is a loop, not a craft.

# 1. Requirements, from what stayed obscure

| # | What the session could not see | Incident | Requirement |
|---|---|---|---|
| 1 | Where a long stretch went | "231 ms stretch, no view bodies" needed a 12 s xctrace recording with 1.5 cores of profiler overhead (`dtsecurity` at 172 %), marked UNTRUSTED, cut short (14 of 16 steps) | Stacks inside every long stretch, in-process, every run (C1) |
| 2 | Why views were invalidated | Saw `propagate_dirty`, `FocusNavigationSequence.next`; not which state change dirtied which view | Cause records: mutation → bodies (C7) |
| 3 | A differential call tree | Flat top-N lists per trace; the question was always A vs B, answered by eye after writing `parse.py` | `diff` between two profiles, per step (C2) |
| 4 | Rate-invariant metrics | `lateFrames` read as a regression twice (v1→v3: 8 → 30; base→v5: 9 → 14) because the panel moved from 24 to 48/120 Hz | Hitch time ratio (ms/s); CPU ms per step as objective (C3) |
| 5 | Provenance | A stale trace prompted an experiment (H2) that was then reverted; `Runner.gitHead()` runs `git rev-parse` in the cwd, so copied binaries report the wrong commit | Build stamp in the binary; content-addressed store; the ledger (C5) |
| 6 | Feel | Synthetic scroll phases; global synthetic input forbidden on a shared Mac | Recorded gestures replayed in-process (C9) |
| 7 | Noise | Same build 26 vs 709 hitches; one `ab` ≈ 3 min; steals focus; bands ±40–80 % on some metrics | Low-noise objective, interleaving, idle scheduling, a machine nobody uses (C3, C10) |
| 8 | Cheating | A blank column is fast | Correctness guards the search cannot edit (C6) |
| 9 | Rebuild per idea | Every variant was a new binary (~3 min) | Runtime knobs, sweeps (C4, C8) |

# 2. The re-architecture decision

## 2.1 Recommendation

1. **Stay in the capcomd repo for now; build it as a separate Swift package that could leave.** New package at
   `tools/perfloop/` with its own `Package.swift`, no dependency on any capcomd module, its own tests that run on Linux
   where the code is pure. `apps/menubar/app` depends on it by path. Extraction criterion: a second app adopts it, or
   the result/manifest schemas have gone a month without a breaking change. Until then one PR changes both sides,
   which is what the churn of the next two months needs.
2. **Generic core, capcomd adapter.** Nothing in `tools/perfloop` knows what a reel is. Scenarios, fixtures, drivers,
   knobs and guards live in the app's adapter (today's `CapcomdDeskBench` target, kept under the name `deskbench`).
   The generic runner learns an app's scenarios from the adapter's `describe` output (§3.3), never from code.
3. **Agent interface = CLI + JSON files + an append-only ledger.** No MCP server in the first four phases (§3.5).
4. **Name: PerfLoop** (the owner's choice, 2026-10-30). CLI `perfloop`; libraries `PerfLoopProbe`,
   `PerfLoopHost`, `PerfLoopKit`. The capcomd adapter stays `deskbench`. No repos are created by this spec.

## 2.2 Tradeoffs considered

| Option | For | Against | Verdict |
|---|---|---|---|
| Keep growing `CapcomdDeskBench` in place | Zero plumbing; everything already links | Generic parts keep absorbing capcomd types (`FixtureThread`, `DeskModel`); no way to reuse; test target needs AppKit | No: it is already at the edge (`XCTrace.swift` and `Stats.swift` are generic, `Harness.swift` is not) |
| Standalone repo now | Clean genericity pressure; its own release cadence | Two PRs per change while the schemas churn; CI, tagging, Homebrew for a tool with one user; no second app to validate against | Not yet |
| Separate package inside capcomd (chosen) | One PR, one CI; `swift build` inside `tools/perfloop` alone proves it has no capcomd imports; `git subtree split` later | Path dependency between packages; a package-level CI job to add | Yes |
| capcomd-specific forever | Simpler APIs (`model.scroll(to:)` directly) | The owner's other Swift apps and the menu bar app get nothing; scenario ideas stay locked to one window | No: the adapter boundary costs one protocol and one JSON document |

Genericity gate in CI: `cd tools/perfloop && swift build && swift test` on macOS, `swift test --filter PerfLoopKitTests` on
Linux, and a grep that fails on `import Capcomd` under `tools/perfloop/Sources`.

# 3. Architecture

## 3.1 Packages

```
tools/perfloop/                              Swift package "PerfLoop", no capcomd imports
  Sources/PerfLoopProbe/                     linked by the app itself (macOS only, tiny, no deps)
    Probe.swift                            body/event seam (today's DeskProbe, made public); nil check when no sink
    Knobs.swift                            runtime knobs: register, read (cached), set from env/CLI       (C4)
    Mutations.swift                        optional "property X changed" records for @Observable models     (C7)
    Stretch.swift                          run-loop observer + gated main-thread sampler                 (C1)
    Signposts.swift                        os_signpost step/animation intervals (dev.perfloop.step)
    BuildStamp.swift                       reads the stamp the build plugin embeds                         (C5)
  Plugins/PerfLoopStamp/                     build-tool plugin: writes commit, dirty flag, build time, config
  Sources/PerfLoopHost/                      linked by the app's bench executable (macOS only)
    Host.swift                             window hosting (scene / hand-made), display link, noise floor
    Protocol.swift                         the bench protocol over stdin/stdout (§3.3, §4.1)
    Drivers.swift                          protocols a scenario driver implements; wait/settle helpers
    Gesture.swift                          recorded-gesture replay into an NSScrollView                   (C9)
    Guards.swift                           snapshot diff, built-within, isolation helpers                  (C6)
    Snapshot.swift                         window PNG + view dump (today's Harness.dump)
  Sources/PerfLoopKit/                       pure: builds and tests on Linux
    Schemas/                               result, profile, diff, manifest, experiment, ledger, gesture   (SCHEMAS.md)
    Stats.swift                            Dist, MAD bands, Mann-Whitney U, sign test, sequential rule
    Objective.swift                        objective + guards + acceptance rule                            (§5)
    XCTrace/                               export parsing (today's XCTable), call-tree builder, hitch ratio
    Diff.swift                             differential call tree, per-step normalisation                   (C2)
    Ledger.swift                           experiment store model, champion pointer                          (C5)
    Explain.swift                          result/diff/experiment → text for an agent
  Sources/perfloop/                          the CLI (runner)
    run, ab, screen, profile, trace, diff, exp, sweep, queue, explain, describe, mcp? (§3.5)
    Store/                                 content-addressed builds, experiments, traces (paths only)      (C5)
    Runners/                               local (idle-gated), ssh, vm                                      (C10)
  Tests/PerfLoopKitTests                     Linux-safe
  Tests/PerfLoopHostTests                    macOS, no window (gesture maths, guard maths)

apps/menubar/app/Sources/CapcomdDeskBench/ the capcomd adapter ("deskbench"): scenarios, fixtures, drivers, knobs,
                                           guards; links PerfLoopHost + CapcomdDesk. ~What exists today minus the
                                           generic parts.
apps/menubar/app/Sources/CapcomdDesk/      the app: links PerfLoopProbe; `DeskProbe` becomes a typealias.
```

What moves where, from today's files:

| Today | Goes to |
|---|---|
| `DeskBenchKit/Results.swift`, `Stats.swift`, `XCTrace.swift`, `Explain.swift` | `PerfLoopKit` (schemas renamed `perfloop.*`, v1 decoders kept) |
| `DeskBenchKit/Scenarios.swift`, `Fixtures.swift` | stay in the adapter (`ScenarioSpec` becomes a protocol conformance that `describe` serialises) |
| `CapcomdDeskBench/Harness.swift` sampling, window, waiters, dump | `PerfLoopHost`; the model-specific helpers (`reelScrollView`, `composerField`, `reelMoving`) stay in the adapter |
| `CapcomdDeskBench/Commands.swift` `ab`, `profile`, `summarise` | `perfloop` CLI, driven by the manifest |
| `CapcomdDeskBench/Drive.swift` | adapter |
| `CapcomdDesk/DeskProbe.swift` | `PerfLoopProbe.Probe`; `DeskDebug.swift` keeps its env-var hooks |

## 3.2 What an app must expose (adopter checklist)

1. **Probe seam.** `Probe.body("Name")` / `Probe.body("Name", id:)` as the first statement of the bodies worth counting
   (exists: 14 call sites in `CapcomdDesk`). `Probe.event("reel.phase", 1)` for state the drivers wait on (exists).
2. **A bench executable** (the adapter) that links `PerfLoopHost`, hosts the app's real views on fixture data, and
   speaks the bench protocol (§3.3): `describe`, `run`, `snapshot`. It owns scenario drivers, fixture loading, guards.
3. **Knobs** at the sites an experiment wants to vary: `static let slide = Knob("reel.slide", default: "ca", choices: ["ca", "clip"])`.
   Read cost after the first read: one static load. The adapter's `describe` lists them.
4. **Build stamp**: adopt the `PerfLoopStamp` plugin (or write `build.json` next to the binary). Without it the runner
   refuses `exp` and `ab` on the binary ("unstamped").
5. **Optional**: mutation records on the models whose changes drive bodies (C7); recorded gestures (C9); a fixture
   capture command (C8).

## 3.3 How the generic tool learns an app's scenarios

The adapter prints a manifest (`perfloop.manifest/1`, SCHEMAS.md §2):

```sh
$ deskbench describe --json
{ "schema": "perfloop.manifest/1", "app": "capcomd-desktop", "adapter": "deskbench",
  "build": { "commit": "9bcd41a", "dirty": false, "configuration": "release", "hash": "sha256:…" },
  "scenarios": [ { "name": "step", "kind": "smooth", "budget": "…", "rule": "…", "params": {"steps": "8"},
                   "objective": "mainThreadCpuMsPerStep", "guards": ["landed", "built-within", "snapshot"] }, … ],
  "fixtures": [ { "name": "crew17", "agents": 17, … } ],
  "knobs": [ { "name": "reel.slide", "default": "ca", "choices": ["ca", "clip"] }, { "name": "build.perFrame", "default": "2", "range": [1, 8] } ],
  "hosts": ["scene", "window"], "protocol": 1 }
```

The runner (`perfloop`) does everything from this document: which scenario to run, which metric is the objective,
which guards gate acceptance, what can be swept. It never imports the app. `perfloop describe --bench PATH` prints it;
`perfloop list` reads it from the champion in the store.

## 3.4 The agent's view

The agent uses five verbs and reads JSON:

```
perfloop exp new "sizeThatFits answers itself"      → exp/0007/, builds the working tree into the store, screens vs champion
perfloop exp status 0007 | perfloop explain exp/0007  → verdict, numbers, what to look at next
perfloop diff --champion --exp 0007 step            → differential call tree, per step, ours first
perfloop exp full 0007 && perfloop exp promote 0007   → 5+5 ab, guards, confirmation trace, champion pointer moves
perfloop sweep step --set build.perFrame=1..8       → a knob sweep against the champion, one table
```

Everything the agent needs to decide the next step is in `exp/<id>/explain.txt` (C5). A `PROGRAM.md` in the adapter
folder tells an agent the loop (§5), the budgets, and the checkpoints, in the way Karpathy's `autoresearch`
constrains its agent with `program.md` (FEASIBILITY.md ref 20).

## 3.5 MCP server: not now

Coding agents already have a shell. The CLI's contract is JSON files with versioned schemas, exit codes, and
`explain`; an MCP server would wrap the same five verbs, add a long-running process to keep alive next to the bench
children, and a second schema surface to keep in step. Long jobs (a 3 min `ab`) fit a CLI with `--out` and a
ledger better than a tool call that must return. Revisit when an agent without a shell (or a desktop assistant)
wants to drive it; the manifest already is the tool description such a server would publish.

# 4. Process model

## 4.1 Host, children, profiler

```
perfloop (host, no UI)
  ├─ child: deskbench run step --fixture crew17 --reps 1 --protocol      (one fresh process per rep)
  │     stdout:  ready pid=123 hz=120 noise=quiet          ← window up, noise floor measured
  │     stdin:   go                                        ← host says go (after xctrace attached, if profiling)
  │     stdout:  step 1/8 … done result=/store/exp/0007/screen/r3.json
  │     stdin:   exit                                      ← host had time to symbolicate / snapshot
  └─ xcrun xctrace record --attach 123 --template … --time-limit 10m
        host waits for xctrace's "Ctrl-C to stop the recording" line, then sends `go`
        host sends SIGINT to xctrace when the child prints `done`; xctrace saves (as Ctrl-C does)
```

Changes from today: the `--wait-for FILE` poll becomes stdin/stdout lines; the 2.5 s + 3.0 s sleeps become waits on
the two lines; the time limit no longer cuts runs short (incident 1): the host stops the recording when the scenario
is done. A profiled run is marked `profiled: true` and never feeds the objective.

Activation stays: SwiftUI flushes timer-driven state late in an inactive app, so a measured run must be the active
app and its window key. That is what steals focus on a shared Mac; §4.2 is about when, not whether.

## 4.2 Isolation runners

| Runner | What it is | Objective | Frame guards | Notes |
|---|---|---|---|---|
| `local` | This Mac | CPU ms, instructions | yes | Refuses to start unless the console has been idle ≥ `--idle 120` s (IOKit `HIDIdleTime`); between reps, if the user becomes active, pauses and marks the rep `interrupted` (re-run); `--force` for a bench nobody minds. `perfloop queue` holds experiments and runs them when idle. |
| `ssh://mac-mini` | A spare Mac (no Xcode needed), any user with a key login | CPU ms, instructions | yes | `perfloop` rsyncs the store entry (binary + bundles + `build.json`, checked by hash) into `~/.perfloop/<app>` there, runs the adapter there (not itself: the remote needs nothing but the binary), pulls results and artifacts back with their paths rewritten. The window opens in the console user's GUI session through LaunchServices (`open -W -n` on a tiny launcher app), not from sshd's background session; the runner waits while the remote screen is locked (a window behind the lock screen is never active, so its reps would be untrusted). The only runner that gives unattended real-hardware hitch numbers. |
| `vm` | A macOS VM (Tart) on this Mac | CPU ms only | no | Metal is paravirtualised, so the window renders; PMU counters are not available in guests (FEASIBILITY.md ref 15) and `ri_instructions` may read zero; display-link cadence and hitch numbers in a guest are not trusted. Good for screening code changes that cut main-thread work; final acceptance stays on hardware. |

A second login session on the same Mac was considered and rejected: a background session's windows do not get
display passes, so CADisplayLink and activation are meaningless there (assumed, not verified; not worth verifying).

## 4.3 Store and privacy

Store at `${PERFLOOP_HOME:-~/.perfloop}/<app>/`: `builds/<sha256>/` (binary, bundles, `build.json`), `exp/<id>/`,
`traces/` (paths recorded in the ledger; never copied into a repo), `ledger.jsonl`, `champion.json`. Project-local
`.perfloop/` is allowed and gitignored. **Traces are private**: `xctrace export --toc` of this session's traces
contains the recorded process's full environment, including tokens (verified today). The ledger stores trace paths
and summaries only; `perfloop` warns when a trace path is inside a git checkout.

# 5. The loop

## 5.1 Objective, guards, acceptance

**Objective** (lower is better), per scenario, declared in the manifest:

- `mainThreadCpuMsPerStep`: CPU time of the main thread (`thread_info`, exists today as `Stretch.cpuMs`) summed over
  the steps' stretches, divided by steps. Rate-invariant, independent of the panel, cheap. Noise today: the
  `mainThreadCpuShare` was 97–99 % on a loaded machine, so the CPU clock already told the truth when wall time lied.
- `instructionsPerStep`: `proc_pid_rusage` `ri_instructions` delta over the steps, process-wide. Probe: 0.01 % CV on
  identical work where wall time had 9–15 % (FEASIBILITY.md §1.2). Used when the CPU-ms band exceeds 10 %, and as
  the tie-breaker. Not per-thread; the bench process has little else running.
- Latency scenarios (`open`, `switch`, `follow`) keep `latencyMs` as the objective; CPU ms is the secondary.

**Guards** (pass/fail, never optimised):

- Correctness (C6): `landed`; `built-within`: the on-screen columns' `Column`/`ColumnThread`/`EntryRow` bodies done
  within N ms of settle and the snapshot after settle equal to the champion's within tolerance (anti-blank-column);
  the isolation checks (`burst`, `typing`).
- Frames: in-process hitch time ratio (ms of lateness per second of scenario, C3) not worse than the champion's by
  more than its band; `longestStretchMs` likewise; the SPEC §1 budget verdict reported.
- Fidelity: `window.trustworthy`, `noise.quiet`, `profiled == false`, `build.dirty == false` for promotion.

**Acceptance**, two stages, both interleaved (A B A B …, first side randomised per pair; FEASIBILITY.md ref 13):

- *Screen* (≈ 40 s): 3 pairs. Promising if the candidate's objective beats the champion's in all 3 pairs, the median
  gain ≥ max(5 %, band), and every correctness guard passed in every rep. (Three pairs cannot reach significance;
  this is a filter, not a verdict. The sign test on 3 pairs has p = 0.125.)
- *Full* (≈ 3 min): 5 + 5. Win if Mann-Whitney U on the objective gives p < 0.05 (the minimum at 5 v 5 is 0.0079,
  so it is reachable), the effect ≥ band, and the frame guards hold. If 0.05 ≤ p < 0.2 ("unknown", as Pinpoint
  calls it) extend to 8 + 8, then 10 + 10, then stop as "no decision". The band is today's
  `max(1.4826 × MAD, floorPct, absoluteFloor)`, kept.
- *Confirmation* (≈ 1 min): one `profile --template hitches` and one `--template time` of the new champion for the
  ledger; compositor hitch time ratio recorded. Not an acceptance input.

## 5.2 Where candidates come from

1. **Knob sweep** (no build): `perfloop sweep` over a knob's choices or range; the best setting becomes a candidate
   experiment with `kind: knob`. Promotion of a knob means "make it the default and delete the knob" in a follow-up
   code change, so knobs do not accumulate.
2. **Agent code change**: the agent reads `perfloop explain --champion` (stretch stacks, the profile call tree with
   per-step ms, cause records), picks the largest subtree that is ours or attributable (a framework subtree whose
   nearest app frame is known), writes a hypothesis, edits, and runs `exp new`. The attributable-subtree list is
   the agent's work queue; the session's own history is the pattern: `sizeThatFits` (65 % of the middle build's
   main thread) and `NSScrollAnimationHelper`/`ScrollViewCommitMutation` (24 % of the original).

## 5.3 Stopping rules and budgets

Stop the loop for a scenario when any holds: the SPEC §1 budget verdict passes on the champion with 5 + 5 reps on
hardware; no attributable subtree ≥ 5 % of the objective remains; 5 consecutive non-promising candidates; the time
budget (default 2 h or 20 candidates per session) is spent.

Cost model (release, this Mac): incremental build 1–3 min; screen 40 s; full 3 min; confirmation 1 min; export of a
10 k-sample time profile 3 s (verified). A rejected idea costs ≈ 2–4 min, a promoted one ≈ 8 min. The hour the
session spent on `ab` alone pays for 15–20 candidates.

## 5.4 Human checkpoints

| When | Who | What |
|---|---|---|
| An experiment declares `behaviourChange: true` or a guard's snapshot diff exceeds its tolerance | owner | Approve the behaviour change or reject the experiment |
| Promotion | owner | The ledger entry and the diff go into a PR; the champion pointer moves only after merge (the loop may continue on top of an unmerged champion, marked `unmerged`) |
| Anything touching scenarios, fixtures, guards, bands or the manifest | owner | The agent cannot edit these inside an experiment; such edits are their own PR (anti-Goodhart, §5.5) |
| New animation curve, new gesture replay file, "feel" | owner | On a real trackpad; the bench says smoothness (C9), not feel |
| A run on `local` while the Mac is in use | owner | `--force` only |

## 5.5 Failure modes it must defend against

| Failure | Where it came from | Defence |
|---|---|---|
| Goodharting: fast because blank, fewer bodies because fewer views | Blank columns are fast; the search optimises one number | Correctness guards are read from the champion's manifest, not the candidate's; snapshot equality after settle; `built-within`; guard/fixture edits are outside experiments; the ledger shows guard results next to the gain. Agents special-casing tests is documented (FEASIBILITY.md ref 22) |
| Stale trace | H2: a trace of the original build suggested a focus-walk fix for a build that no longer had it | Every trace, result and diff carries `build.hash`; `diff` and `explain` refuse to compare against anything whose hash is not the champion's or the experiment's, unless `--allow-stale`; the stamp is built in, not read from the cwd |
| Metric artifact | H5: `lateFrames` depends on the presented rate (24 → 48 Hz read as +275 %) | Hitch time ratio (ms/s) and CPU ms per step decide; `lateFrames`, `frameP95Ms` stay in the result as information with `steadyHz` next to them; `explain` says "rate changed 24 → 120 Hz" before any frame number |
| Noisy machine | 26 vs 709 hitches on one build; `dtsecurity` at 172 % | Idle-gated runner; interleaving; the noise floor and `heavyProcesses` as fidelity guards; profiled runs excluded from the objective; the low-noise objective |
| Profiler overhead mistaken for the app | 1.5 cores of profiler during the only run that had stacks | In-process sampler is the default source of stacks; xctrace is confirmation only and marked `profiled` |
| Cut-short recording | 14 of 16 steps | Host stops xctrace with SIGINT when the child is done |
| Wrong binary | `v3-dir` reporting the cwd's commit | Content-addressed store; `build.json` beside the binary; `perfloop` refuses unstamped binaries for `exp` |
| Over-fitting one fixture | crew17 everywhere | Promotion requires the screen on a second fixture (`swarm64` or `crew17-long`) to be not-worse |
| Agent fatigue / drift | Hour-long sessions, state in the agent's head | The ledger is the memory; `exp status` says what is next; `PROGRAM.md` is the procedure |

# 6. Migration plan

Each phase ends with its acceptance test green. Phases 0–1 happen inside today's targets; the package split is
Phase 2, when the schemas are known.

**Phase 0: truth first (days).** Build stamp (plugin writes commit, dirty, time, configuration; `ToolInfo.commit`
reads it; `gitHead()` deleted). Hitch time ratio in `StepResult.frames` and `Summary`. `mainThreadCpuMsPerStep` and
`instructionsPerStep` in `Summary`; `ab` and `compare` take `--objective`. stdin/stdout protocol; xctrace stopped by
SIGINT; `profiled` flag. Trace-privacy warning. CHANGELOG lines for each.
*Acceptance:* a binary copied to another directory reports its build commit; same-build `ab step --reps 5` on a quiet
Mac has a CPU-ms band ≤ 10 % and an instructions band ≤ 2 %; `profile step --reps 2` covers 16/16 steps.

**Phase 1: see inside stretches, compare builds (1–2 weeks).** C1 sampler behind the run-loop observer, stacks on
`worstStretches[]`, symbolised with `dladdr` in-process. Call tree in `perfloop.profile/2` from xctrace exports, per
step via signposts. `diff` (C2).
*Acceptance (uses only files in the session's scratch `bench/`):* `deskbench trace --diff bench/deep/base-step-time/step-time.trace bench/profs-v3/step-time.trace`
ranks the `sizeThatFits` subtree as the largest gain and the `NSScrollAnimationHelper`/`ScrollViewCommitMutation`
subtree as the largest loss, per step, in under 15 s, with no Python. On the `base-dir` binary (run when the Mac is
free), the worst stretch of `step` carries stacks whose top inclusive frames include `ScrollViewCommitMutation.commit`
and `AG::Graph::propagate_dirty`, without xctrace.

**Phase 2: the loop's bones (2 weeks).** Package split (§3.1). Manifest + `describe`. Knobs (C4) with two real
knobs in the reel (`reel.slide=ca|clip`, `build.perFrame`). Store, `exp new/status/full/promote`, ledger,
`explain` for experiments (C5). `PROGRAM.md`.
*Acceptance:* `perfloop exp new "…"` → build → screen → verdict with no paths typed by the agent; the replay below.

**Phase 3: guards and causes (2 weeks).** Snapshot-diff and `built-within` guards (C6); mutation records and cause
attribution on stretches (C7); SwiftUI-template export of `swiftui-causes` as confirmation; sweeps and a fixture
capture from a daemon with anonymisation (C8).
*Acceptance:* a deliberately cheating build (columns left blank after a switch) is rejected by guards although its
objective wins; after a tab click, the cause record attributes `Column×17` to the mutation of the model's
`focused`/`onScreen` properties; `sweep agents=4..64` prints a cost curve with a fitted slope.

**Phase 4: feel and machines (2 weeks).** Gesture recording in the app (dev build, opt-in), replay and smoothness
metric (C9); `ssh://` and `vm` runners, idle-gated `local`, `queue` (C10).
*Acceptance:* a recorded swipe replays on the champion with a per-frame position error ≤ 1 pt (p95) and reports jerk;
an `exp full` runs unattended on a second Mac from `queue` and lands in the ledger.

**Phase 5: extraction (when the criterion in §2.1 holds).** `git subtree split` of `tools/perfloop`; the adapter
depends on a tagged version.

## 6.1 The replay: this session, re-run by the loop

The strong acceptance test for Phase 2. Inputs: the six binaries kept in the scratch `bench/` (`base-dir` = 3a6b5b7's
bench; `v1-dir` = per-column flags, H1; `v2-dir`; `v3-dir` = the first AppKit reel, with the Auto Layout
`sizeThatFits` wall; `v4-dir` = `sizeThatFits` answered by the representable; `v5-dir` = 9bcd41a, slides in the render
server and heads-first open), imported with `perfloop store import --commit <sha> --note <hypothesis>` since they predate
the stamp. The mapping of `v1`–`v5` to hypotheses is read from the session's `ab-*.txt` names and the essay; the
agent that built them should confirm it before the replay plan is written. Then `perfloop exp replay replay.json` runs the session's order as experiments against a moving champion,
on `step` and `switch`, screens first, full only when promising. It must be run when nobody is using the Mac (it
opens windows), ideally on the `ssh://` runner.

What the report must show:

1. **Fewer runs and minutes.** The session spent ≈ 48 min in 16 `ab` runs and ≈ 10 min in ≈ 40 recordings, plus
   exports and `parse.py` (counts from the scratch `bench/`, `perf/` and `prof-step*` folders). The replay budget: 6 screens (≈ 4 min), 3 fulls (≈ 9 min), 2 confirmations (≈ 2 min), 2
   diffs (≈ 30 s). Acceptance: ≤ ⅓ of the session's bench minutes, same promotions (v3 or v4, and v5; H1's v1
   rejected as not promising).
2. **The `sizeThatFits` find without xctrace.** On v3, the screen's worst-stretch stacks name `LayoutEngineBox.sizeThatFits`
   → `PlatformViewLayoutEngine.sizeThatFits` as the top inclusive subtree of the stretch, and `explain` says so.
3. **The render-server slide find.** `diff v4 vs champion` on `step` shows `NSScrollAnimationHelper` /
   `ViewGraph.invalidateTransform` as the largest remaining attributable subtree, which is what v5 removed.
4. **Wrong turn 1 (H2, stale trace) caught.** The replay includes `perfloop diff` with a trace recorded on `base-dir`
   against champion v3: it must refuse ("trace build 3a6b5b7 ≠ champion …") unless `--allow-stale`.
5. **Wrong turn 2 (H5, metric artifact) caught.** v1 → v3 on `step`: `lateFrames` 8 → 30 must not be a regression in
   the verdict; hitch time ratio and CPU ms per step decide, and `explain` reports the rate change (24 → 48 Hz).

# 7. Decisions (owner, 2026-10-30)

1. **Name**: PerfLoop.
2. **A machine**: the Mac mini, reached over SSH, is the `ssh://mac-mini` runner. Unattended hardware runs (hitches,
   ProMotion) go there; this Mac runs only idle-gated work.
3. **Fixtures from a real daemon** (C8): yes, anonymised (text replaced by same-length generated text, structure kept).
4. **Gesture recording** (C9): yes, as proposed: an opt-in recorder in the desktop dev build that writes scroll
   deltas and phases only, to a file the owner names.
5. **Promotion policy**: the loop may climb on an unmerged champion. The ledger records each champion's parent chain
   (`champion.json` → the experiment it came from → its parent champion), so any champion can be traced back to a
   merged commit.
6. **Knob debt**: agreed. A promoted knob is removed, its winning value baked in, within the same phase.
7. **If extracted**: its own new repo, MIT licence.
