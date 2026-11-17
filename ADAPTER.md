# The adapter contract

`perfloop` (the runner) never links your app. It drives your app's **bench** (the adapter): an executable that hosts
the app's views on fixture data, runs scenarios in a window of its own process, and prints JSON. This file is the whole
contract between the two, protocol 1.

You don't have to implement it by hand: link `PerfLoopHost`, register fixtures, scenarios, knobs and guards, and call
`bench.main()` (see `Examples/SlowList/Sources/SlowListBench/main.swift`, ~60 lines). PerfLoopHost answers every verb
below. Write your own only for a bench that can't link it; `Tests/PerfLoopRunnerTests/Fixtures/fake-adapter.sh` is a
complete adapter in shell, and `perfloop doctor --bench PATH` checks yours.

## 1. `list --json` (required)

Called by `perfloop store add`. Must exit 0 and print one JSON object with:

| Field | Required | Meaning |
|---|---|---|
| `tool.build` | yes | `perfloop.build/1`: `{ "hash": "sha256:<hex of this executable file>", "commit": "9bcd41a", "dirty": false, "configuration": "release", "stamp": true, "builtAt": "…", "sourceHash": "…", "toolchain": "…" }` |
| `tool.name`, `tool.version` | no | shown in text |
| `scenarios[]` | yes when there is no `describe` | `{ "name", "kind", "params", "summary", "budget" }` |
| `fixtures[]` | yes when there is no `describe` | `{ "name" }` |

`stamp: true` means the commit was compiled into the binary (the `PerfLoopStamp` build plugin), not read from the cwd:
a copied binary still says what it is. `store add` refuses `stamp: false` or a `hash` that isn't the file's ("unstamped",
exit 6). Binaries from before the stamp go in with `perfloop store import DIR --commit SHA --note …`.

## 2. `describe --json` (recommended)

Prints `perfloop.manifest/1` (SCHEMAS.md §2). The runner does everything from it: which scenario exists, the number each
climbs on, the guards that gate acceptance, the knobs, the fixtures. It is read from the **champion's** build, never the
candidate's, so an experiment can't change how it is judged. Without `describe`, the runner derives a manifest from
`list --json` (every scenario guarded by its checks only).

```jsonc
{ "schema": "perfloop.manifest/1", "protocol": 1, "app": "slowlist", "adapter": "slowlist-bench", "build": { … },
  "scenarios": [ { "name": "select", "kind": "smooth", "summary": "…", "params": { "steps": "8" },
                   "objective": "mainThreadCpuMsPerStep",            // | instructionsPerStep | latencyMs
                   "guards": ["checks", "snapshot-diff", "rows-drawn"],
                   "guardParams": { "snapshot-diff.tolerance": 0.005 },
                   "frameGuards": ["hitchTimeRatioMsPerS", "longestStretchMs"],
                   "secondFixture": "rows500", "latencyBudgetMs": null,
                   "fixture": "rows2000" } ],                        // optional: the scenario's own fixture
  "fixtures": [ { "name": "rows2000", "params": { "rows": "2000" }, "parametric": { "rows": [10, 50000] } } ],
  "knobs": [ { "name": "rows.rank", "type": "choice", "default": "sort", "choices": ["sort", "index"] } ],
  "defaultFixture": "rows2000", "isolationGuards": [],
  "verbs": ["help", "list", "describe", "knobs", "run", "snapdiff", "profile", "diff"],   // optional; absent = deskbench's (with ab)
  "privatePaths": [".secrets/"],                                       // optional; never recorded in a patch
  "fixtureSchemes": ["file"] }                                         // optional; the scheme: forms --fixture takes
```

`kind`: `smooth` and `isolation` climb on main-thread CPU per step, `latency` on the time to the frame that shows the
change. `guards`: `checks` (the scenario's own checks), `snapshot-diff` (§5), and any name your bench judges itself.

`fixture` (optional, added 2026-11): the fixture this scenario runs on when nobody names one, before `defaultFixture`.
Give one to every scenario whose data isn't the default's (a palette scenario that needs a search index, a reel that
needs five asks): the runner always passes `--fixture`, and without this field it passes `defaultFixture`, so a
scenario that picks its own data inside the bench when `--fixture` is absent never gets it from the runner. Every
verb uses it (`exp new` on a scenario other than the champion's, `run`, `baseline`, `profile`, `sweep`, the isolation
scenarios); a `--fixture` the manifest doesn't list is refused with the list (`name@k=v` of a listed one and a
`scheme:…` form such as `file:PATH` pass), and `doctor --bench` fails a scenario whose `fixture` isn't listed. It is
part of the contract: a candidate that changes it needs the owner to be promoted.

`fixtureSchemes` (optional, added 2026-11): the `scheme:` forms your `--fixture` takes besides the listed names, e.g.
`["file"]`. Without it any scheme reaches you as before; with it, another scheme is refused before a rep runs (`[]`:
none; a PerfLoopHost bench with fixtures says `[]`, since it takes listed names only). A `file:PATH` fixture (`file:///abs`
too) is checked on the Mac the reps run on before any of them start, whatever this says: perfloop refuses it when the
file isn't readable there (this Mac: from perfloop's working directory when relative; an `ssh://` runner: asked over
ssh, absolute paths only, as perfloop copies builds there but never fixture files; a VM: once it is up, at the stage's
start). `doctor --bench` warns when a `file:` fixture the manifest names isn't on this Mac.

## 3. `run SCENARIO --fixture F --reps 1 --json [--set k=v …] [--quiet-check 0]`

Opens the window, drives the scenario, prints a result, exits. `--quiet-check 0`: the runner has already waited for a
quiet machine (its quiet gate) and records what it saw on the rep's side of the pair, so the bench shouldn't wait again
(PerfLoopHost's `run`, called directly, waits up to `--quiet-check S`, 10 s, and marks a rep that started busy
`"quiet": false`). The runner calls it once per side of every pair (fresh
process each time) and interleaves champion and candidate itself. Exit 0 (pass), 3 (a check, guard or budget failed),
4 (regression) or 5 (untrusted) all carry numbers, but a rep that exits 5 never decides; anything else is a harness
error and the pair is redone once.

The environment it runs with:

| Variable | Meaning |
|---|---|
| `PERFLOOP_KNOBS` | `name=value,name=value`: the knob values for this process (C4); unset = every default |
| `PERFLOOP_GUARDS` | the guards to judge after each rep, comma separated (never `checks`: those always run) |
| `PERFLOOP_GUARD_PARAMS` | `k=v,…` from the champion's manifest (and only the owner's override) |
| `PERFLOOP_ARTIFACTS` | the directory guard files go to (snapshots) |

The result (`perfloop.result/2`; `deskbench.result/1` is read the same way). The runner looks fields up by path, so
extra fields are fine and missing optional ones fall back. What it reads, per rep (`reps[]`):

| Path | Used for |
|---|---|
| `steps[]` (count) and `cpuMsPerStep`, else `mainThread.cpuMs` / steps | `mainThreadCpuMsPerStep` |
| `steps[].instructions` (all steps) | `instructionsPerStep` |
| `steps[].latencyMs` (median) | `latencyMs` |
| `frames.hitchTimeRatioMsPerS`, `mainThread.longestMs` | frame guards (not worse beyond their band) |
| `frames.ticks` (else `frames.p95Ms`) | 0: the rep presented no frame (screen locked, window off-screen): its frame metrics are missing, not 0, and the rep is untrusted. Report the tick count |
| `frames.steadyHz`, `frames.late` | information; `explain` reports a rate change |
| `checks[]` `{ name, pass, detail }` | the `checks` guard: a check the candidate fails while the champion passes vetoes it |
| `guards[]` `{ name, pass, detail, artifacts, value, limit, review }` | the named guards; `review: true` asks the owner |
| `window { appActive, keyWindow, visible, occluded }` | all four right, or the rep is untrusted and never decides (a rep without one: the result's top-level `window`) |
| top-level `fixture` | the fixture that ran (`name` or `name@k=v`). A rep that says it ran another than the one the runner asked for has no numbers (`ran fixture X, asked for Y`): its data was the wrong one. PerfLoopHost adds `expectedFixture`, the scenario's own |
| `quiet`, `busyPct`, `busy[]` | the machine when the rep started: `quiet: false` makes the rep untrusted; `busyPct` (share of the cores busy) and `busy` (what kept them busy) say why. Per rep or top level; `noise.quiet` / `noise.reasons` (deskbench) are read the same way. Optional: the local runner's own quiet gate fills the same fields on each side (and its wait under `machine`), false when either saw a busy machine |
| `worstStretches[] { step, durationMs, topOurs[], topFramework[], causes[] }` | `explain`'s "where the time went" |
| `smoothness { positionErrorP95Pt, stalls, jerkP95 }` | gesture-replay frame guards (C9) |
| top-level `profiled: true` | the rep never feeds the objective |

`keyWindow` is true when the bench window is key, **or a visible window it owns is**: a child window (a panel, a
popover) or a sheet, at any depth. A palette or search panel that takes the keyboard is the design, not a distraction,
and a bench that reports `keyWindow: false` for it makes every rep untrusted, every time. PerfLoopHost counts it so and
adds `keyWindowIsChild: true`; an adapter of its own does the same (`w.isKeyWindow`, or `NSApp.keyWindow`'s
`parent`/`sheetParent` chain reaches `w`).

**Trust.** A rep decides only when its `window` was right, the machine was quiet (when the adapter or the runner's quiet
gate says), it presented frames, and it didn't exit 5. A pair with an untrusted rep is redone once. A stage whose pairs are still untrusted decides nothing: its
verdict is `untrusted` with the count and the cause (`screen: UNTRUSTED (6/6 reps untrusted: not quiet ×6 (busy up to
99.8 %: swift-build)) …`), and rerunning it measures only those pairs again. The exception is one side's window wrong
the same way in both orders while the other side's is right: the build does that, a rerun can't change it, and the
stage says `deterministic` and stops early. (A guard the candidate failed on a trusted pair still rejects it, or, for
an `--expect same` check, makes it `regressed`, whatever the untrusted pairs say.)

## 3a. What `perfloop run` and `perfloop baseline` use

They measure one build with no champion on the other side, through `run` (§3) only, one process per rep, with
`--fixture` always given. So every protocol-1 adapter that answers `run` works with them unchanged, including one whose
pairs go through its own `ab` (deskbench): `ab` is never called. What they read from each rep is what a pair's side
reads: the objective, `checks[]` and `guards[]`, `worstStretches[]`, and for trust the rep's `window`, its exit code
(5), `frames.ticks` (0: no frames) and `quiet` (the local runner's gate fills it too). A rep is untrusted on the same
rule as in a pair, and its number is never quoted: a run whose reps were all untrusted prints `UNTRUSTED` and no number,
and a baseline isn't recorded. An adapter that reports none of the trust fields still runs; its runs say `trust: not
checked`.

`--reference S2` runs the champion's S2 beside each rep (alternating which goes first), so it needs nothing more.
`baseline` keeps a reference picture when the scenario guards `snapshot-diff` and the rep writes its capture as §5
says; a later `run` of the scenario is compared with it through the champion adapter's `snapdiff` (or the measured
build's, while the champion doesn't have the scenario). Without `snapshot-diff` there is no picture, only numbers.

## 4. `ab --a EXE --b EXE S --fixture F --reps 1 --json --out FILE` (optional)

deskbench's own interleaved pair. An adapter whose manifest lists `verbs` without `ab` is measured through two `run`s per
pair instead, which is what PerfLoopHost benches do. Output: `summaryA/summaryB` (the objective's median under its
name, and `frameP95Ms` or `frameTicks`: a median of 0 means the side drew no frame), `buildA/buildB`,
`guardsA/guardsB`, `failures[]`. The runner's quiet gate runs once before each `ab` call, so both sides of the pair
record the same machine reading.

The runner can't see the processes `ab` starts, so for its trust rule (§3) `ab` also reports each side's reps, one of:

- `runs[]`, one per process: `{ "side": "A" | "B", "exit": 5, "quiet": false, "busyPct": 99.8, "builds": ["swift-build"],
  "window": { … } }` (`busy` or deskbench's `builds`; every field but `side` optional, `window` as in §3);
- `repsA` / `repsB` (or `reps[]` with `variant: "A" | "B"`): the reps as `run` reports them.

An `ab` that reports neither still runs and decides as before, but nothing in it can be untrusted: every stage it
measured says `trust: not checked` in `explain`.

The runner decides; the adapter's own judgement of the pair isn't read. Each `ab` call is one pair (`--reps 1`), and the
runner judges across pairs, so an `ab`'s `regression`, `improvement`, `guardsFailed`, noise-band lines and exit 4
(regression by its own rule) change nothing: exit 4 is a pair with numbers like exit 0. That holds for `exp new
--expect same` too (a feature check: does it cost anything?), which reads from each side: the objective (`summaryA`/`B`
under its name, or `objective { name, value }`), and for its frame guards `hitchTimeRatioMsPerS` and `longestStretchMs`
(medians, as deskbench's summary has them; `smoothness` for a gesture). A side without the frame metrics is judged on
the objective alone, and the stage says `not checked: hitchTimeRatioMsPerS, longestStretchMs (the adapter reports none
per side)`. Report `runs[]` (or the reps) as above, or an expect-same check can't tell a busy Mac's noise from a cost.

## 5. `snapdiff A.png B.png --json --diff-out D.png [--guard-param snapshot-diff.tolerance=X]`

Needed when a scenario guards `snapshot-diff`. After each rep the bench writes the window, at rest, to
`$PERFLOOP_ARTIFACTS/<scenario>-rep<N>.settled.png` and half a second later to `….settled.later.png`, and reports
`{ "name": "snapshot-diff", "pass": true, "artifacts": [png, later] }`. The runner then asks the **champion's**
`snapdiff` to compare the champion's picture with the candidate's (pixels that moved between a picture and its `.later`
are left out). Print `{ "guard": { "name": "snapshot-diff", "pass", "detail", "value", "limit", "review" } }`; exit 0
within tolerance, 3 over it (`review: true`: the owner decides; never a win).

## 6. `profile` and `diff` (optional)

`profile SCENARIO --template time|hitches|swiftui --fixture F --out DIR --json [--knob k=v] [--keep-trace]` records the
scenario under xctrace and writes `DIR/SCENARIO-TEMPLATE.json` (`perfloop.profile/2`, SCHEMAS.md §4), the same document
on stdout. Called by `perfloop profile champion|exp/ID`, which indexes it in the store. PerfLoopHost's does it this way:
the bench starts itself as a child (`run … --wait-for FILE --profiled --sampler off`, scrubbed environment), the child
shows the window and writes `FILE.waiting`, `xctrace record --attach PID` attaches, the parent writes `FILE` once
xctrace says it is recording, the child runs its reps and writes `FILE.done`, and the recording is stopped with SIGINT,
so every step is inside it. Every `run.step` is a `step` signpost (subsystem `dev.perfloop.bench`, Points of Interest),
which is what the per-step trees are cut on. The trace is deleted once exported unless `--keep-trace` (it holds the
recorded process's environment); a delete that fails leaves `traceKept: true` and a note, never a claim that it is gone.
The document adds, to SCHEMAS.md §4: `traceKept` (whether the trace is on disk at `trace`), `keepTrace` (it is there on
purpose), `os` and `model` (from the trace's TOC), `knobs`, `treeInSteps` (what `diff` compares), and `inProcess` (the
run's own `perfloop.result/2`, `profiled: true`).

Whatever the adapter does with its trace, `perfloop profile` checks the disk afterwards: it deletes every `.trace` under
`--out DIR` (and the one the document's `trace` names) unless `--keep-trace`, checks each is gone, and rewrites
`traceKept`/`trace`/`keepTrace` in the document to what it found, so its `trace:` line ("deleted", or "KEPT at PATH") is
what is on disk. Write the trace under `--out DIR`, so the runner finds it. While recording into the store, a `.recording`
file in the folder holding your pid keeps `perfloop store gc` and `doctor` off the trace (PerfLoopHost writes one).

`diff A B --json [--champion BUILD] [--allow-stale] [--allow-cross-os] [--per step|run]`: A and B are profile JSONs or
`.trace` files; prints `perfloop.diff/1` (SCHEMAS.md §5), exit 6 when provenance refuses. Called by `perfloop diff`,
which first resolves `champion` and `exp/ID` to their newest profiles and refuses inputs of other builds.

## 6a. Gestures (optional)

A scenario that replays a gesture takes it as its `gesture` parameter: `synthetic:NAME` (the manifest's `gestures` lists
the built-in ones) or a `perfloop.gesture/1` file. Its steps carry `smoothness` (SCHEMAS.md §8), the rep the worst of
them (`reps[].smoothness`), the summary the medians (`summary.smoothness`), which the runner reads as frame guards when
the scenario lists `positionErrorP95Pt` and `stalls` in `frameGuards`. PerfLoopHost: `run.swipe(gesture)` replays into
the window's largest NSScrollView (CGEvent-built NSEvents handed to `scrollWheel(with:)` at the recorded times; nothing
posted to the system). `record-gesture SCENARIO [--name N] [--out FILE] [--count N] [--timeout S]` shows the scenario's
window and records a hand's gestures over it (a local event monitor: deltas, phases, times) into
`${PERFLOOP_HOME:-~/.perfloop}/APP/gestures/NAME.json`, where `perfloop gestures list` looks; it refuses a path inside a
git checkout. `gestures [--json]` lists the built-in ones.

## 6b. The window lock

Two windows on one Mac spoil each other's numbers. A bench verb that opens a window when someone runs it directly (`run`,
`ab`, `profile`, `record-gesture`) should hold the window lock for its whole run: mkdir the directory `$PERFLOOP_LOCK`
(else `/tmp/perfloop-window-UID.lock`, UID the numeric user id; `PERFLOOP_LOCK=off`: none), retrying every 2 s while it
exists, then write `owner` in it, `{"pid": PID, "command": "the command line", "label": "$PERFLOOP_LOCK_OWNER", "since":
"<ISO 8601>"}`, export `PERFLOOP_LOCK_HELD=<its path>` to your children, and remove the directory on exit and on
SIGINT/SIGTERM. Two rules keep it from deadlocking or sticking: when `PERFLOOP_LOCK_HELD` names a lock whose owner's pid is
alive, you are inside that hold (perfloop runs you while holding it): take nothing; and a lock whose owner's pid is dead
may be broken (moved aside and removed). PerfLoopHost does all of this (`--lock DIR` moves it, `--no-lock` skips it); an
adapter that can't can be wrapped instead: `perfloop lock -- BENCH ab …`.

## 7. Exit codes

0 ok · 1 usage · 2 harness error · 3 budget/check/guard failed · 4 regression beyond noise · 5 untrusted (never decides) ·
6 refused (provenance) · 7 interrupted (input during the rep; the local runner's idle gate)

## 8. Schema versions

| Document | Version | Written by | Stability |
|---|---|---|---|
| `perfloop.manifest` | 1 (`protocol: 1`) | adapter `describe` | fields only added; `verbs`, `privatePaths`, `scenarios[].fixture`, `fixtureSchemes` added 2026-11 |
| `perfloop.build` | 1 | adapter (`tool.build`), store (`build.json`) | stable |
| `perfloop.result` | 2 (reads `deskbench.result/1`) | adapter `run` | fields only added; PerfLoopHost's adds `expectedFixture` (2026-11) |
| `perfloop.measure`, `perfloop.baseline` | 1 | runner (`runs/<id>/run.json`, `baselines/<scenario>/baseline.json`) | new (2026-11); a pair's `Side` gained `fixture` (what the rep ran) |
| `perfloop.snapdiff` | 1 (reads `deskbench.snapdiff/1`) | adapter `snapdiff` | stable |
| `perfloop.experiment`, `perfloop.ledger`, `perfloop.champion` | 1 | runner (store) | stable since Phase 2 |
| `perfloop.sweep`, `perfloop.queue`, `perfloop.gesture`, `perfloop.gestures` | 1 | runner / probe | stable since Phase 3–4; `perfloop.sweep` gained `walls` (2026-11) |
| `perfloop.doctor` | 1 | runner `doctor --json` | new |
| `perfloop.profile` | 2 | adapter `profile` | fields only added; PerfLoopHost's adds `traceKept`, `os`, `model`, `knobs`, `treeInSteps`, `inProcess` (2026-11), `keepTrace` (2026-11; the runner sets it and `traceKept` from the disk) |
| `perfloop.diff` | 1 | adapter `diff` | stable |

Within a version a field is never renamed or removed, only added; a reader of version n reads n−1.
