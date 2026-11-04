# SlowList: PerfLoop on an app that isn't capcomd

A small AppKit + SwiftUI app (an AppKit window, a SwiftUI list of 1,000 items over an AppKit status line) with a
deliberately slow path, and its PerfLoop bench. It is the second app PerfLoop runs on, and the template for yours.

| File | What it shows |
|---|---|
| `Sources/SlowListKit/Model.swift` | a knob (`ListKnobs.rank`) where an idea varies, and `Mutations.record` on the state that drives bodies |
| `Sources/SlowListKit/Views.swift` | `Probe.body("Row", id:)` in the bodies worth counting; the slow path; the fix (`SLOWLIST_ROW_VALUES`); a cheat (`SLOWLIST_CHEAT`) |
| `Sources/SlowListBench/main.swift` | the whole adapter: fixtures, three scenarios (one replays a trackpad gesture), a knob, a guard of its own, `bench.main()` |
| `Package.swift` | depends on PerfLoop like an outside app; the `PerfLoopStamp` plugin on the bench target |
| `walkthrough.sh` | the loop end to end on this app |

## The slow path

Every row's body reads the selection and computes its rank by sorting the whole list with localized comparisons. A
selection change re-evaluates every row on screen (~15), and each sorts 1,000 titles: ~90 ms of main-thread CPU per
click on an M-series Mac. Two fixes are built in:

- the knob `rows.rank=index`: ranks come from a table built once (no rebuild to try it);
- the code fix (`-Xswiftc -DSLOWLIST_ROW_VALUES`): rows take values (`Equatable`), so a selection re-evaluates the two
  rows whose values changed, and ranks come from one sort.

And one cheat (`-DSLOWLIST_CHEAT`): rows draw nothing. It is very fast and wrong; the guards refuse it.

## Run it

```sh
swift build -c release --product SlowListBench
B=.build/release/SlowListBench
$B describe                                  # the manifest the runner reads
../../.build/release/perfloop doctor --bench $B   # (build the runner first: swift build -c release at the repository root)
$B run select --reps 1                       # opens a window for ~3 s; prints where the time went
PERFLOOP_KNOBS=rows.rank=index $B run select --reps 1
$B run scroll --reps 1                       # a trackpad flick replayed into the list: how closely the content followed
$B run scroll --set gesture=synthetic:drag-down --set inject-block-ms=60 --reps 1   # the meter's self-check: stalls
$B record-gesture scroll --name my-swipe     # your own swipe over the list, for --set gesture=FILE
$B profile select                            # the same scenario under xctrace: call trees per step
./walkthrough.sh --dry-run                   # the whole loop, printed
./walkthrough.sh --lock /tmp/window.lock     # …and run (~5 min of builds, then ~2 min of windows: a free Mac)
```

## A run (2026-11-04, MacBookPro18,3, macOS 27, the walkthrough at f3bbae2)

The whole loop took 1 min 40 s of windows (3 screens, 1 full and its second-fixture check: 34 bench runs, each a fresh process).
Main-thread CPU per selection (ms), interleaved pairs:

| Experiment | Champion | Candidate | Verdict |
|---|---:|---:|---|
| knob `rows.rank=index` (screen, 3 pairs) | 86.5–89.6 | 3.2–14.2 | promising: won 3/3, median gain 85.7 % |
| cheat: rows draw nothing (screen) | 79.0–88.4 | 11.1–12.9 | **rejected**: `rows-drawn` failed (0 rows of 12), snapshot 8.8 % different (owner review); its objective "won" 3/3 by 86 % |
| fix: rows take values (screen) | 78.6–92.1 | 12.1–18.9 | promising: won 3/3, 84.6 % |
| fix (full, 5 + 5) | 80.7–85.9 | 3.1–13.3 | **won**: Mann-Whitney p = 0.0079, effect 85.2 %; hitch time 398 → 43 ms/s, longest stretch 88.6 → 21.7 ms; not worse on `rows300`; promoted |

What the bench said, without a profiler: the champion's worst stretch was `ListModel.rankBySorting` under
`RowView.body.getter` (Row×15 per selection). After the fix, the first selection's worst stretch (89 ms) was AppKit
showing the filter field's completion list (`SPCompletionListRemoteViewController resizeRemoteWindow`) and the focus
ring: the next real cost in this app, found the same way. These numbers are from a developer's Mac in use (last input
0 s before the run), which the noise bands absorbed here because the effect is 85 %; smaller effects want a free Mac.

A sweep over the list's size and the knob, the same day (1 rep a point, so a cost curve, not a verdict):

```sh
perfloop sweep select --bench .build/release/SlowListBench --set rows=200..1000/400 --set rows.rank=sort,index --reps 1 --lock /tmp/window.lock
```

| rows | `sort` ms/step | `index` ms/step |
|---:|---:|---:|
| 200 | 27.2 | 15.8 |
| 600 | 36.8 | 15.9 |
| 1000 | 83.5 | 3.7 |

`fit: ms/step grows 0.07 ms per row at rows.rank=sort (r² 0.87)`; with `index` the cost doesn't grow with the list
(the slope the fit reports there, −0.015, is noise on a Mac in use).

## Gestures and profiles (2026-11-04, MacBookPro18,3, macOS 27, a Mac in use: single runs, not verdicts)

`scroll` replays a gesture three times from the top of the list. With `synthetic:drag-down` (48 frames of finger
motion, no momentum) the content followed the fingers with 0 pt p95 error, one frame behind, in every swipe, on both the
slow path and `rows.rank=index`; the slow path's first swipe had 7 stalls (rows scrolling in for the first time sort
the list), the knob's first two 3 each. The meter's self-check (`--set inject-block-ms=60`: the main thread held 60 ms in
the middle of the drag) reported 16 stalls, a 28 pt worst error and an 86 ms longest stretch.

`profile select` (Time Profiler, 1 rep, the in-process sampler off): 8 of 8 steps from the `step` signposts, 89.0 ms per
step on the slow path, 8.8 with `rows.rank=index`; `diff` of the two names `ListModel.rankBySorting`'s sort (insertion
sort −61.5 ms, `CFStringCompareWithOptionsAndLocale` −40.6 ms per step) as what shrank. The trace was deleted after its
tables were exported.
