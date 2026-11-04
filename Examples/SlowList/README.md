# SlowList: PerfLoop on an app that isn't capcomd

A small AppKit + SwiftUI app (an AppKit window, a SwiftUI list of 1,000 items over an AppKit status line) with a
deliberately slow path, and its PerfLoop bench. It is the second app PerfLoop runs on, and the template for yours.

| File | What it shows |
|---|---|
| `Sources/SlowListKit/Model.swift` | a knob (`ListKnobs.rank`) where an idea varies, and `Mutations.record` on the state that drives bodies |
| `Sources/SlowListKit/Views.swift` | `Probe.body("Row", id:)` in the bodies worth counting; the slow path; the fix (`SLOWLIST_ROW_VALUES`); a cheat (`SLOWLIST_CHEAT`) |
| `Sources/SlowListBench/main.swift` | the whole adapter: fixtures, two scenarios, a knob, a guard of its own, `bench.main()` |
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
../../.build/release/perfloop doctor --bench $B   # (build the runner first: swift build -c release in tools/perfloop)
$B run select --reps 1                       # opens a window for ~3 s; prints where the time went
PERFLOOP_KNOBS=rows.rank=index $B run select --reps 1
./walkthrough.sh --dry-run                   # the whole loop, printed
./walkthrough.sh --lock /tmp/window.lock     # …and run (~5 min of windows: when nobody is using the Mac)
```
