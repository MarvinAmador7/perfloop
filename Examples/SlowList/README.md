# SlowList: PerfLoop on an app that isn't capcomd

A small AppKit + SwiftUI app (an AppKit window, a SwiftUI list of 1,000 items over an AppKit status line) with a
deliberately slow path, and its PerfLoop bench. It is the second app PerfLoop runs on, and the template for yours.

| File | What it shows |
|---|---|
| `Sources/SlowListKit/Model.swift` | a knob (`ListKnobs.rank`) where an idea varies, and `Mutations.record` on the state that drives bodies |
| `Sources/SlowListKit/Views.swift` | `Probe.body("Row", id:)` in the bodies worth counting; the slow path; the fix (`SLOWLIST_ROW_VALUES`); a cheat (`SLOWLIST_CHEAT`); a look change (`SLOWLIST_LOOK`: the status line names the item); the details panel (a child window) |
| `Sources/SlowListBench/main.swift` | the whole adapter: fixtures, five scenarios (one replays a trackpad gesture, one presses real keys and clicks through the menu bar, one opens a child panel), ink regions each step must leave drawn (the rows, the status line), which are also the regions snapshots are compared by, a knob, a guard of its own, `bench.main()` |
| `Package.swift` | depends on PerfLoop like an outside app; the `PerfLoopStamp` plugin on the bench target |
| `walkthrough.sh` | the loop end to end on this app |

**Timed scenarios find their targets by view, point or rect; only `find` uses identifiers.** `select`, `details`,
`filter` and `scroll` are measured for speed: their regions are views (`rows`, the scroll view; `details`, the panel's
content), an AppKit view's `identifier` (`status`) and a rect (`filter`), and they click nothing by identifier. A SwiftUI
`.accessibilityIdentifier` (each row's `row-N`, the filter field's `filter`) is found through SwiftUI's accessibility
tree, which the lookup turns on (`AXEnhancedUserInterface`) and every later step of the rep pays for. `find` checks that
real clicks and keys land (the menu item fired, the row hit, the field editor focused), so it clicks `row-3` and expects
focus in `filter` by identifier; its numbers aren't read for speed. Copy that split: in a timed scenario click a view or a
point (`run.click(view)`, `run.click(at:)`), and keep `click(identifier:)` for functional ones (ADAPTER.md §3b).

## The slow path

Every row's body reads the selection and computes its rank by sorting the whole list with localized comparisons. A
selection change re-evaluates every row on screen (~15), and each sorts 1,000 titles: ~90 ms of main-thread CPU per
click on an M-series Mac. Two fixes are built in:

- the knob `rows.rank=index`: ranks come from a table built once (no rebuild to try it);
- the code fix (`-Xswiftc -DSLOWLIST_ROW_VALUES`): rows take values (`Equatable`), so a selection re-evaluates the two
  rows whose values changed, and ranks come from one sort.

And one cheat (`-DSLOWLIST_CHEAT`): rows draw nothing. It is very fast and wrong; the guards refuse it: `rows-drawn`
counts the row bodies, and the built-in ink guard finds the rows region blank after every selection (its crops,
`ink/select-rep0-…-rows.png`, show it).

## Run it

```sh
swift build -c release --product SlowListBench
B=.build/release/SlowListBench
$B describe                                  # the manifest the runner reads
../../.build/release/perfloop doctor --bench $B   # (build the runner first: swift build -c release at the repository root)
$B run select --reps 1                       # opens a window for ~3 s; prints where the time went
PERFLOOP_KNOBS=rows.rank=index $B run select --reps 1
$B run scroll --reps 1                       # a trackpad flick replayed into the list: how closely the content followed
$B run find --reps 1 --pictures /tmp/find    # ⌘F, typing, ⌘K: the menu item each fired, the focus, the window before/after
$B run details --set appearance=dark --reps 1   # the details panel over the list, in dark mode
$B run scroll --set gesture=synthetic:drag-down --set inject-block-ms=60 --reps 1   # the meter's self-check: stalls
$B record-gesture scroll --name my-swipe     # your own swipe over the list, for --set gesture=FILE
$B profile select                            # the same scenario under xctrace: call trees per step
./walkthrough.sh --dry-run                   # the whole loop, printed
./walkthrough.sh                             # …and run (~5 min of builds, then ~2 min of windows: a free Mac)
```

## A run on a spare Mac (2026-11-04, Mac mini Mac16,11, macOS 26.6.2, the walkthrough at 277e356)

`./walkthrough.sh --runner ssh://me@spare-mac.local`: builds on the MacBook Pro, every window on the mini (its
screen unlocked, nobody at it: last input there 1,118 s before). Every rep's window was active, key, visible and
unoccluded, so every pair was trusted and counted. 2 min 56 s of windows (3 screens, 1 full and its second-fixture
check: 34 bench runs). The mini's display ran at 60 Hz, 1× scale. Main-thread CPU per selection (ms), interleaved pairs:

| Experiment | Champion | Candidate | Verdict |
|---|---:|---:|---|
| knob `rows.rank=index` (screen, 3 pairs) | 65.0–66.4 | 6.2–6.8 | promising: won 3/3, median gain 89.9 % |
| cheat: rows draw nothing (screen) | 64.2–65.7 | 3.4–3.7 | **rejected**: `rows-drawn` failed (0 rows of 12), snapshot 9.3 % different (owner review); its objective "won" 3/3 by 94 % |
| fix: rows take values (screen) | 65.1–65.9 | 6.6–7.0 | promising: won 3/3, 89.8 % |
| fix (full, 5 + 5) | 64.6–65.5 | 6.2–6.9 | **won**: Mann-Whitney p = 0.0079, effect 90.4 %; hitch time 296 → 0 ms/s, longest stretch 66.8 → 4.5 ms; not worse on `rows300` (gain 74 %); promoted |

The champion's spread across 11 pairs was 64.2–66.4 ms (±1.7 %), against 78.6–92.1 ms on the MacBook Pro in use the
same day. What the bench said, without a profiler: the champion's worst stretch (66.5 ms) was `ListModel.rankBySorting`
under `RowView.body.getter` (Row×15 per selection, RowContent×2); after the fix, 2 Row bodies per selection and a
4.3 ms worst stretch. Instructions per step: 1.23 G → 10.6 M.

What this run doesn't show: the mini had other work going (OrbStack's helper at ~0.7 of a core, a browser and an agent
app open in the owner's session), which the noise bands absorbed here; trusted means the window was where it should be,
not that the machine was empty. The numbers are the mini's: a 60 Hz panel and another chip, so they don't compare with
the MacBook Pro's.

An earlier run on the MacBook Pro in use (2026-11-04, at f3bbae2, last input 0 s before the run) gave the same verdicts
with the champion at 78.6–92.1 ms and the fix at 3.1–18.9 ms: the verdicts held there only because the effect is
~85 %, far outside that machine's noise.

A sweep over the list's size and the knob, the same day (1 rep a point, so a cost curve, not a verdict):

```sh
perfloop sweep select --bench .build/release/SlowListBench --set rows=200..1000/400 --set rows.rank=sort,index --reps 1
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

## Looks: regions, a child window, dark mode (2026-11-18, the owner's spare Mac mini over ssh, macOS 26.6.2)

The regions the ink guard checks after each step (`rows`, the scroll view; `status`, the AppKit status line by its
`identifier`) are also the regions snapshots are compared by, with `filter` (a rect: SwiftUI's views aren't NSViews)
added for every scenario. The `details` scenario opens a panel attached to the window (`DetailsPanel`, a child window)
and selects rows; the panel is drawn into the snapshot where it is on screen and is the region `details`. With the
champion's build and one with `-DSLOWLIST_LOOK` (the status line reads "Item 12 selected · 1000 items" instead of
"Selected item 12"):

```sh
perfloop baseline details --bench bench-champ --reps 2 --runner ssh://…            # light reference picture
perfloop baseline details --bench bench-champ --reps 2 --set appearance=dark …     # dark: baselines/details~dark/
perfloop run bench-look --scenario details --reps 1 …                               # REVIEW: status resized
perfloop run bench-look --scenario details --reps 1 --expect-look status …          # changed where declared
perfloop run bench-champ --scenario details --set appearance=dark --reps 1 …       # same in every region
```

| Run | Snapshot against its look's baseline |
|---|---|
| look build, nothing declared | `REVIEW · status resized (92×14 → 158×14 pt); same: filter, rows, details, rest`, the status line's before and after crops on a `look at:` line; next: the owner's call |
| look build, `--expect-look status` | `changed where declared · status resized … [declared]`; exit 0; next: put the region's pictures in the PR for the reviewer |
| look build, dark, `--expect-look status` | the same against the dark baseline (`baselines/details~dark/reference.png`) |
| champion build, dark | `same · the same in every region (filter, rows, status, details, rest)` |

Every rep was trusted, and the ink guard passed in each (`ink ✓`). The layout beside each picture listed the panel
(`childWindows: details, DetailsPanel`) and `notCaptured: the title bars (the window's and its child windows')`. The
status line is a label sized to its text, so its region grew with it: `resized`, not `differs`. A whole-window
`snapdiff` with the alignment search took under 0.1 s on 900×700 pictures.
