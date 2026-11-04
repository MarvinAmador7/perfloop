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
                   "secondFixture": "rows500", "latencyBudgetMs": null } ],
  "fixtures": [ { "name": "rows2000", "params": { "rows": "2000" }, "parametric": { "rows": [10, 50000] } } ],
  "knobs": [ { "name": "rows.rank", "type": "choice", "default": "sort", "choices": ["sort", "index"] } ],
  "defaultFixture": "rows2000", "isolationGuards": [],
  "verbs": ["help", "list", "describe", "knobs", "run", "snapdiff"],   // optional; absent = deskbench's (with ab)
  "privatePaths": [".secrets/"] }                                      // optional; never recorded in a patch
```

`kind`: `smooth` and `isolation` climb on main-thread CPU per step, `latency` on the time to the frame that shows the
change. `guards`: `checks` (the scenario's own checks), `snapshot-diff` (§5), and any name your bench judges itself.

## 3. `run SCENARIO --fixture F --reps 1 --json [--set k=v …] [--quiet-check 0]`

Opens the window, drives the scenario, prints a result, exits. The runner calls it once per side of every pair (fresh
process each time) and interleaves champion and candidate itself. Exit 0 (pass), 3 (a check, guard or budget failed),
4 (regression) or 5 (untrusted) all carry numbers; anything else is a harness error and the pair is redone once.

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
| `frames.steadyHz`, `frames.late` | information; `explain` reports a rate change |
| `checks[]` `{ name, pass, detail }` | the `checks` guard: a check the candidate fails while the champion passes vetoes it |
| `guards[]` `{ name, pass, detail, artifacts, value, limit, review }` | the named guards; `review: true` asks the owner |
| `window { appActive, keyWindow, visible, occluded }` | all four right, or the rep is untrusted and never decides |
| `worstStretches[] { step, durationMs, topOurs[], topFramework[], causes[] }` | `explain`'s "where the time went" |
| `smoothness { positionErrorP95Pt, stalls, jerkP95 }` | gesture-replay frame guards (C9) |
| top-level `profiled: true` | the rep never feeds the objective |

## 4. `ab --a EXE --b EXE S --fixture F --reps 1 --json --out FILE` (optional)

deskbench's own interleaved pair. An adapter whose manifest lists `verbs` without `ab` is measured through two `run`s per
pair instead, which is what PerfLoopHost benches do. Output: `summaryA/summaryB` (the objective's median under its
name), `buildA/buildB`, `guardsA/guardsB`, `failures[]`.

## 5. `snapdiff A.png B.png --json --diff-out D.png [--guard-param snapshot-diff.tolerance=X]`

Needed when a scenario guards `snapshot-diff`. After each rep the bench writes the window, at rest, to
`$PERFLOOP_ARTIFACTS/<scenario>-rep<N>.settled.png` and half a second later to `….settled.later.png`, and reports
`{ "name": "snapshot-diff", "pass": true, "artifacts": [png, later] }`. The runner then asks the **champion's**
`snapdiff` to compare the champion's picture with the candidate's (pixels that moved between a picture and its `.later`
are left out). Print `{ "guard": { "name": "snapshot-diff", "pass", "detail", "value", "limit", "review" } }`; exit 0
within tolerance, 3 over it (`review: true`: the owner decides; never a win).

## 6. `diff A B --json` (optional)

A differential call tree of two profiles (deskbench's, from xctrace). PerfLoopHost benches don't have it yet.

## 7. Exit codes

0 ok · 1 usage · 2 harness error · 3 budget/check/guard failed · 4 regression beyond noise · 5 untrusted (rerun) ·
6 refused (provenance) · 7 interrupted (input during the rep; the local runner's idle gate)

## 8. Schema versions

| Document | Version | Written by | Stability |
|---|---|---|---|
| `perfloop.manifest` | 1 (`protocol: 1`) | adapter `describe` | fields only added; `verbs`, `privatePaths` added 2026-11 |
| `perfloop.build` | 1 | adapter (`tool.build`), store (`build.json`) | stable |
| `perfloop.result` | 2 (reads `deskbench.result/1`) | adapter `run` | fields only added |
| `perfloop.snapdiff` | 1 (reads `deskbench.snapdiff/1`) | adapter `snapdiff` | stable |
| `perfloop.experiment`, `perfloop.ledger`, `perfloop.champion` | 1 | runner (store) | stable since Phase 2 |
| `perfloop.sweep`, `perfloop.queue`, `perfloop.gesture`, `perfloop.gestures` | 1 | runner / probe | stable since Phase 3–4 |
| `perfloop.doctor` | 1 | runner `doctor --json` | new |
| `perfloop.profile` 2, `perfloop.diff` 1 | | deskbench only | not yet in PerfLoopHost |

Within a version a field is never renamed or removed, only added; a reader of version n reads n−1.
