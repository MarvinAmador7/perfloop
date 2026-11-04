# Schemas

Every document `perfloop` or an adapter writes carries `"schema": "perfloop.<kind>/<n>"`. Rules, kept from
`deskbench.result/1`: within a version a field is never renamed or removed, only added; a reader of version n reads
n−1 (decoders for `deskbench.*/1` stay in `PerfLoopKit` and upgrade in memory); numbers are measured values rounded
as today (`Stats.round`), never interpolations; times are ms since the harness started unless named `*At` (ISO 8601).
JSON is pretty-printed with sorted keys (`JSONOut.encode`), so diffs of results are readable.

Exit codes stay: 0 pass · 1 usage · 2 harness error · 3 budget failed · 4 regression beyond noise · 5 untrusted.
Added: 6 refused (provenance: stale trace, unstamped binary, mixed runners) · 7 interrupted (the user touched the
machine; rerun).

## 1. Common objects

```jsonc
"build": {                       // perfloop.build/1, embedded wherever a binary is involved
  "hash": "sha256:…",            // of the executable file; the store's key
  "commit": "9bcd41a" | null,    // from the build stamp, not the cwd
  "dirty": false,                // uncommitted changes in tracked sources at build time
  "sourceHash": "sha256:…",      // tracked source paths' content hash: two clean builds of one commit agree
  "builtAt": "2026-10-30T15:31:02Z",
  "configuration": "release",
  "toolchain": "Xcode 27.1 (27A9275)",
  "stamp": true                  // false for binaries imported with `store import` (pre-stamp)
}
"machine": { …as today…, "runner": "local" | "ssh://mac-mini" | "vm:tart/…" }   // runner added
"tree": { "n": "symbol", "v": 123, "c": [ …tree… ] }     // folded call tree; v = samples (profile) or ms (diff)
```

## 2. `perfloop.manifest/1` (adapter `describe --json`)

```jsonc
{ "schema": "perfloop.manifest/1", "protocol": 1,
  "app": "capcomd-desktop", "adapter": "deskbench", "build": { …build… },
  "scenarios": [ {
      "name": "step", "summary": "…", "kind": "latency|smooth|isolation",
      "budget": "Reel scroll: no dropped frames at 120 Hz with 17 agents", "rule": "…", "latencyBudgetMs": null,
      "params": { "steps": "8" },
      "objective": "mainThreadCpuMsPerStep" | "instructionsPerStep" | "latencyMs",
      "guards": [ "landed", "built-within", "snapshot-diff" ],
      "guardParams": { "built-within.ms": 300, "snapshot-diff.tolerance": 0.005 },
      "frameGuards": [ "hitchTimeRatioMsPerS", "longestStretchMs" ],   // judged by their bands (Acceptance)
      "secondFixture": "swarm64"                 // promotion needs not-worse here
  } ],
  "isolationGuards": [ "burst", "typing" ],      // their checks run on every promotion, whatever the experiment climbs
  "fixtures": [ { …FixtureSpec as today…, "parametric": { "agents": [1, 64], "items": [50, 600] } } ],
  "knobs": [ { "name": "reel.slide", "type": "choice", "default": "ca", "choices": ["ca", "clip"], "since": "0.7" },
             { "name": "build.perFrame", "type": "int", "default": 2, "range": [1, 8] } ],
  "hosts": [ "scene", "window" ], "defaultHost": "scene", "defaultFixture": "crew17",
  "probes": [ "Column", "ColumnHead", "ColumnThread", "EntryRow", "ColumnComposer", "CrewTab", "TitleBar", "OpenGroup", "Reel", "RootView", "DecisionBar", "FoldedDeck" ],
  "exitCodes": { "ok": 0, … } }
```

## 3. `perfloop.result/2` (from `deskbench.result/1`)

Everything in `deskbench.result/1` (`Results.swift`) stays with the same names and meaning. Added:

```jsonc
{ "schema": "perfloop.result/2",
  "tool": { …, "build": { …build… } },                 // ToolInfo.commit kept, now equal to build.commit
  "params": { …, "knobs": { "reel.slide": "ca", "build.perFrame": "2" } },   // the full knob vector, defaults included
  "profiled": false,                                   // true when a profiler was attached: never an objective input
  "runner": "local",
  "summary": {
    …as today…,
    "objective": { "name": "mainThreadCpuMsPerStep", "value": 41.2, "dist": { …Dist… } },
    "mainThreadCpuMsPerStep": { …Dist… },
    "instructionsPerStep": { …Dist… } | null,          // null where counters read zero (VM)
    "hitchTimeRatioMsPerS": { …Dist… },                // in-process: Σ max(0, interval − steadyFrame) / step seconds
    "guardsFailed": [ "built-within" ]
  },
  "reps": [ {
    …as today…,
    "sampler": { "hz": 1000, "samples": 2310, "overheadPct": 0.6, "gateMs": 4 },
    "steps": [ { …as today…, "cpuMs": 38.9, "instructions": 61200000, "hitchTimeRatioMsPerS": 0.0,
                 "causes": [ { "keyPath": "AgentSlice.onScreen", "count": 2, "ids": 2,      // sets, distinct objects
                               "bodies": { "Column": 34, "CrewTab": 4 }, "objects": { "Column": 17, "CrewTab": 2 } } ],
                 "smoothness": { "positionErrorP95Pt": 0.8, "stalls": 0, "jerkP95": 1.9, "latencyFrames": 1, … } | null } ],   // §8
    "worstStretches": [ { …as today…,
                 "stacks": { …tree… } | null,          // folded, symbolised; null when the sampler was off
                 "samples": 231,
                 "topOurs": [ { "symbol": "ReelView.slide", "samples": 180 } ],
                 "topFramework": [ { "symbol": "LayoutEngineBox.sizeThatFits", "samples": 229, "under": "ReelRepresentable" } ],
                 "causes": [ … ] } ],
    "guards": [ { "name": "snapshot-diff", "pass": true, "detail": "0.1 % of pixels differ", "artifacts": ["…/step-rep0.png"],
                  "value": 0.001, "limit": 0.005, "review": null } ]   // review: true = over tolerance, the owner decides
  } ] }
```

`checks[]` is unchanged; `guards[]` is the subset that gates acceptance plus the new ones. `Budgets.evaluate` keeps
its rule text and adds nothing: the verdict words (`pass|fail|untrusted|regression`) are kept.

## 4. `perfloop.profile/2` (from `deskbench.profile/1`)

Kept: `template`, `trace`, `scenario`, `fixture`, `process`, `durationS`, `hitches`, `timeProfile`, `swiftUI`,
`signposts`, `inProcess`, `notes`. Added:

```jsonc
{ "schema": "perfloop.profile/2", "build": { …build… }, "machine": { … }, "runner": "local",
  "steps": [ { "name": "step#3 9→12", "startNs": …, "endNs": …, "source": "signpost|inProcess" } ],
  "tree": { …tree… },                    // main thread, whole recording, v = samples
  "treePerStep": [ { "step": "step#3 9→12", "tree": { …tree… } } ],
  "msPerStep": 312.4, "sampleIntervalMs": 1.0, "stepsCovered": 16, "stepsExpected": 16,
  "hitches": { …as today…, "timeRatioMsPerS": 60.4, "recordingS": 12.0 },
  "swiftUI": { "tables": [ …as today… ], "rows": { "swiftui-updates": 0, … },   // rows per table: 0 = recorded nothing
               "edges": { "label: changed-properties": 3 }, "changes": { "…": 1 },
               "rootCauses": [ { "cause": "DeskModel.onScreen", "updates": 33, "views": { "Column": 17, "CrewTab": 16 } } ],
               "longUpdates": [ { "view": "Column", "ms": 23.1, "cause": "…", "severity": "…" } ] } }
```

## 5. `perfloop.diff/1`

```jsonc
{ "schema": "perfloop.diff/1", "scenario": "step", "normalisation": "msPerStep",
  "a": { "build": { … }, "profile": "…/base-step-time.json", "msPerStep": 630.5, "steps": 16 },
  "b": { "build": { … }, "profile": "…/v3-step-time.json",   "msPerStep": 590.7, "steps": 16 },
  "deltaMsPerStep": -39.8, "deltaPct": -6.3,
  "tree": { "n": "main thread", "a": 630.5, "b": 590.7, "d": -39.8, "c": [ … ] },
  "gains":  [ { "path": ["…", "NSScrollAnimationHelper"], "a": 153.2, "b": 0.0, "d": -153.2, "under": "HostingScrollView" } ],
  "losses": [ { "path": ["…", "LayoutEngineBox.sizeThatFits"], "a": 0.0, "b": 384.0, "d": 384.0, "under": "ReelRepresentable" } ],
  "moved":  [ { "symbol": "propagate_dirty", "fromUnder": "ScrollViewCommitMutation", "toUnder": "sizeThatFits" } ],
  "provenance": { "stale": false, "crossOS": false, "allowed": [] },
  "notes": [ "signposts missing in a: steps aligned on the in-process result" ] }
```

## 6. `perfloop.experiment/1` and the ledger

```jsonc
{ "schema": "perfloop.experiment/1", "id": "0007", "createdAt": "…", "state": "new|built|screened|promising|rejected|full|won|lost|needsReview|promoted|abandoned",
  "hypothesis": "sizeThatFits answers itself so Auto Layout never sizes 16 hosting views",
  "kind": "code" | "knob", "behaviourChange": false,
  "parent": { "experiment": "0005", "build": { …build… } },     // the champion at creation
  "patch": "exp/0007/patch.diff" | null, "knobs": { "reel.slide": "clip" } | null,
  "build": { …build… } | null,
  "scenario": "step", "fixture": "crew17", "secondFixture": "swarm64",
  "screen": { "pairs": 3, "results": [ "screen/a1.json", "screen/b1.json", … ], "objective": { "a": [..], "b": [..] },
              "wins": 3, "medianGainPct": 61.2, "band": 8.1, "guardsPassed": true, "guardReviews": null, "verdict": "promising" },   // needsReview: a guard asks the owner
  "full":   { "repsPerSide": 5, "extendedTo": 8, "mwuP": 0.004, "effectPct": 58.9, "band": 7.0,
              "frameGuards": { "hitchTimeRatioMsPerS": { "a": 41.0, "b": 2.1, "pass": true }, "longestStretchMs": { … } },
              "verdict": "won" },
  "isolation": [ { "scenario": "burst", "pair": { … }, "pass": true, "failures": [] } ],   // after a won full
  "guardRuns": [ { "at": "…", "pair": { … }, "isolation": [ … ], "params": { … }, "override": null, "failures": [], "reviews": [] } ],
  "guardParams": { "snapshot-diff.tolerance": 0.01 } | null,     // the owner's, from perfloop guards --guard-tolerance
  "confirmation": { "hitchesTrace": "/Users/…/.perfloop/capcomd-desktop/traces/0007-step-hitches.trace", "timeTrace": "…", "profile": "exp/0007/profile.json",
                    "compositorHitchTimeRatioMsPerS": 3.4 },
  "diff": "exp/0007/diff.json", "explain": "exp/0007/explain.txt",
  "promotedAt": "…" | null, "pr": "https://github.com/…/pull/48" | null,
  "notes": [ "ran on local, idle-gated; 1 rep interrupted and redone" ] }
```

`ledger.jsonl`: one line per state change, `{ "schema": "perfloop.ledger/1", "at": "…", "experiment": "0007",
"state": "promoted", "objective": { "before": 41.2, "after": 16.9 }, "build": "sha256:…", "by": "agent|owner",
"runner": "ssh://Marvins-Mac-mini.local", "machine": "Mac16,11" }` (`runner`/`machine` on a stage's line: where its
numbers came from).

Every pair and stage records where it ran (C10): `"runner": { "runner": "local" | "ssh://host" | "vm:tart/NAME",
"model": "Mac16,11", "host": "Marvins-Mac-mini", "os": "26.6.2" }`. A pair without one predates runners and counts as
`local` on the store's Mac. A stage never mixes runners (acceptance says `error`; resuming a stage on another runner is
refused, exit 6). A pair the local runner aborted on input has `"interrupted": true` (never judged); the pair that
replaced it has `"interruptions": N`.
`champion.json`: `{ "schema": "perfloop.champion/1", "experiment": "0007", "build": { … }, "merged": false,
"parents": ["0005", "0002"], "mergedAncestor": "9bcd41a", "objectives": { "step": 16.9, "switch": 153.2 }, "since": "…" }`.
`parents` is the chain of earlier champions back to the newest merged one, and `mergedAncestor` is that merged commit,
so the loop can climb on unmerged champions (owner's decision, SPEC §7) and every champion still traces back to `main`.

## 7. `perfloop.sweep/1`

```jsonc
{ "schema": "perfloop.sweep/1", "scenario": "step", "fixture": "crew", "objective": "mainThreadCpuMsPerStep",
  "build": { … }, "reps": 2, "fixed": { "items": "100" },                       // --set with one value: not swept
  "axis": [ { "name": "agents", "role": "fixture", "values": [4, 16, 28, 40, 52, 64] } ],   // role: fixture | knob | param
  "points": [ { "agents": 4, "values": { "agents": 4 },                         // axis values flat (as here) and under values
                "objective": 6.1, "dist": { …Dist… }, "hitchTimeRatioMsPerS": 0.0, "longestStretchMs": 9.8,
                "guardsPassed": true, "checksFailed": [], "reps": 2, "result": "points/agents=4.json", "wallS": 21.4,
                "busy": false, "noise": null, "failure": null, "finishedAt": "…" } ],
  "fit": { "model": "linear", "axis": "agents", "n": 6, "slope": 0.92, "intercept": 2.3, "r2": 0.98, "adjustedR2": 0.975,
           "residuals": [ 0.1, -0.3, … ], "rmse": 0.2, "unit": "ms per step per agent" },
  "fits": [ { …linear… }, { "model": "quadratic", "quadratic": 0.004, … },      // per numeric axis, per slice of the others (`at`)
            { "model": "plane", "coefficients": { "agents": 0.9, "items": 0.02 }, … } ],   // every numeric axis at once (2+ axes)
  "notes": [ "budget of 10 min spent with 3 point(s) left: run the same command again to resume" ],
  "startedAt": "…", "finishedAt": "…", "complete": true }
```

`fit` is the headline: the line through the only numeric axis, or the plane when there are several. A quadratic is
fitted when an axis has ≥ 4 distinct values and reported as curving only when its adjusted r² beats the line's by more
than 0.02. Fits use every point with a number, busy ones included (they are marked; `--redo KEY` measures one again).
Fixture parameters reach the adapter in the fixture's name (manifest protocol 1): `--fixture crew@agents=24,items=100`,
for any fixture whose manifest entry has `parametric` (`{ "agents": [1, 128] }`: each parameter's accepted range).

## 7a. `perfloop.queue/1` (`<store>/queue.jsonl`)

```jsonc
{ "schema": "perfloop.queue/1", "at": "…", "item": "q3", "state": "queued", "experiment": "0007", "stage": "auto",   // auto | screen | full
  "runner": "ssh://Marvins-Mac-mini.local" | null, "force": true | null, "note": "…" }
{ "schema": "perfloop.queue/1", "at": "…", "item": "q3", "state": "running", "runner": "local", "note": "pid 4242 on local (Mac16,1, …)" }
{ "schema": "perfloop.queue/1", "at": "…", "item": "q3", "state": "waiting", "note": "waiting: last input 12 s ago < 120 s (frontmost: Xcode)" }
```

Append-only, like the ledger: an item's state is its newest line. `waiting` lines say why a runner didn't start a rep
(one per change of reason); `stopped` (`--until` reached, a signal) puts the item back in the queue, and its stage
resumes at the first missing pair; then `done` (the note is the experiment's new state) or `failed` (the error).

## 8. `perfloop.gesture/1`

```jsonc
{ "schema": "perfloop.gesture/1", "name": "flick-left", "recordedAt": "…", "device": "trackpad", "hz": 120,
  "synthetic": true | null, "source": "deskbench fling curve: …" | null,      // generated ones only
  "events": [ { "t": 0.0, "dx": -3.0, "dy": 0.0, "phase": "began", "momentum": "none", "precise": true }, … ] }
```

One gesture per file: the fingers touching (`mayBegin`/`began`) → lifting (`ended`/`cancelled`) → the system's
momentum ending, or 0.3 s after lifting when no momentum follows (PerfLoopProbe `GestureRecorder`). `t` is ms since the
first event; `dx`/`dy` are `scrollingDeltaX/Y` (points when `precise`, lines otherwise); `phase` and `momentum` are
`none | mayBegin | began | stationary | changed | ended | cancelled` (NSEvent's phases). `device` is `trackpad` (precise
deltas with phases) or `mouse` unless the recorder was told. `hz`: 1000 / the median interval of the events that moved.
A recorder writing several gestures names them `NAME`, `NAME-2`, … No text, no window contents, no identifiers; still,
recordings of a hand stay out of the repo (only synthetic ones are committed).

What a replay of one reports (`perfloop.result/2` `reps[].steps[].smoothness`; the rep's gestures together in
`reps[].smoothness`: the worst error, every stall, the median jerk; medians across reps in `summary.smoothness` as
`Dist`s):

```jsonc
"smoothness": { "positionErrorP95Pt": 0.0, "positionErrorMaxPt": 0.0, "latencyFrames": 1, "stalls": 0, "jerkP95": 32.1,
                "trackingTicks": 6, "ticks": 41 }
```

`latencyFrames`: the whole number of display frames (0–3) the content was behind the fingers, the alignment the error
is taken at; `positionErrorP95Pt`: |shown − expected| while the fingers were down (nil when no tick fell there);
`stalls`: frames the fingers moved ≥ 1 pt and the content < 0.5 pt, plus vsyncs with no tick meanwhile; `jerkP95`:
the shown position's third derivative, p95, touch to settle, in pt/frame³. The manifest's scenario lists
`positionErrorP95Pt` and `stalls` in `frameGuards`, and the manifest's `gestures` names the adapter's built-in ones
(`synthetic:flick-forward`, …), which its scenario's `gesture` parameter takes as well as a path.
`perfloop gestures list --json` prints `{ "schema": "perfloop.gestures/1", "dirs": [ … ], "gestures": [ { "path",
"name", "device", "events", "durationMs", "finger": [dx, dy], "momentum": [dx, dy], "synthetic", "problems" } ],
"builtIn": [ … ] }`.
