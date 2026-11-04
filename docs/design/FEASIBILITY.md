# Feasibility: probes, verified vs assumed, references

All probes ran headless on 2026-10-30 on the owner's MacBookPro18,3 (M1 Pro, 6P+2E, 16 GB, macOS 27.0.1, Xcode 27.1,
xctrace 27.1) while the owner was using the machine. No window was opened, no GUI process was recorded, no input
was synthesised. Source in `probes/`; binaries are not committed.

# 1. Probes

## 1.1 Main-thread sampling from a background thread (`probes/sampler`)

`thread_suspend` → `thread_get_state(ARM_THREAD_STATE64)` → frame-pointer walk within the main thread's stack bounds →
`thread_resume`, at 1 kHz, against a main thread running a known 90/10 mix.

```
sampler probe: 3.0 s at 1000 Hz on arm64
samples 3000  failures 0  stack depth median 6  max 8
suspend+get_state+walk+resume per sample: p50 7333 ns  p95 14833 ns  max 78125 ns
main-thread throughput: 31722 iterations unsampled vs 31491 sampled → overhead 0.73 %
inclusive shares (expected: hotA ≈ 90 %, coldA ≈ 10 %, spin ≈ 100 %):
   99.9 %  spin(_:)   90.5 %  hotA(_:)   90.5 %  hotB(_:)   9.4 %  coldA(_:)
```

Conclusions: safe and accurate enough for stretch attribution; cost ≈ 7 µs per sample, so a 231 ms stretch costs
≈ 1.7 ms of its own time to sample at 1 kHz. Lesson from the first run: `mach_absolute_time` ticks at 24 MHz here,
not 1 GHz; the probe converts with `mach_timebase_info`. The probe allocates while the target is suspended (it
appends to arrays); the real component must not (C1).

## 1.2 Instructions retired without root (`probes/rusage`)

`proc_pid_rusage(getpid(), RUSAGE_INFO_V4, …)`; the struct pointer is passed as the `rusage_info_t *` (passing a
pointer to a pointer overruns the stack, which the first version did).

```
proc_pid_rusage(RUSAGE_INFO_V4) as uid 501: instructions 27259814 cycles 20842626
10 identical runs:
  wall ms       mean     30.02  cv 14.73 %
  cpu ms        mean     30.02  cv 14.72 %
  M instr       mean    150.04  cv  0.01 %
  M cycles      mean     90.35  cv  0.09 %
```

Conclusions: readable as a normal user; three orders of magnitude less noisy than time on a busy machine; per
process, not per thread (`ri_user_time` is in mach ticks). This is the low-noise objective of C3.

## 1.3 Symbolication (`probes/symbolicate`)

`dladdr` on an address 0x4000 past `NSApplicationMain` returned
`__105-[NSApplication(NSPersistentUISupport) _disableRelaunchOnLoginIfNotLaunchedByLaunchServicesOrBlacklisted]_block_invoke+0x28`,
a local symbol. `scan.swift` walked 400 addresses inside AttributeGraph: 296 distinct names, 7 unnamed, including
locals (`GCC_except_table8`, `__swift_closure_destructor.2`). `atos -p <pid>` symbolised the first address and
printed nothing for the second in one try (not investigated). Conclusion: `dladdr` is enough for the first version;
agreement with xctrace's names is measured in Phase 1.

## 1.4 xctrace: templates, CPU Counters without root, export cost

`xcrun xctrace list templates` includes Animation Hitches, CPU Counters, CPU Profiler, Processor Trace, SwiftUI,
System Trace, Time Profiler. `xctrace record --template 'CPU Counters' --launch -- /bin/sleep 2` recorded as uid 501
with no prompt; the trace holds `MetricTable` (95 rows for a sleeping process: `pmi-event`, `metric-value`,
`metric-display-name`, `core`), `CounterMetricByThread`, `CountingModeSamples` (with backtraces),
`kdebug-counters-with-time-sample`, `CoreTypeByThread`. Whether the counters are meaningful for a real run was not
tested (no GUI recording allowed); kpc is documented as root-or-entitlement with recent permission regressions
(refs 3, 4), so counters stay off the critical path.

Export: `xctrace export --xpath …table[@schema="time-profile"]` of a 12 s, 10 088-sample recording took 3.0 s and
produced 6.2 MB of XML. The Time Profiler trace's tables: `time-profile`, `time-sample` (1 ms), `potential-hangs`,
`hang-risks`, `runloop-events`, `os-signpost` (PointsOfInterest), `life-cycle-period`, `dyld-library-load`. The
Animation Hitches trace adds `hitches`, `hitches-updates`, `hitches-renders`, `hitches-gpu`, `hitches-framewait`,
`hitches-frame-lifetimes`, `display-vsyncs-interval`, `displayed-surfaces-interval`, `cpu-state`, `thread-state`,
`context-switch`, `syscall`, `virtual-memory`.

## 1.5 SwiftUI template tables (Instruments 27.1)

Recorded against `/bin/sleep` to read the schemas (no rows). Tables and columns:

| table | columns |
|---|---|
| `swiftui-causes`, `swiftui-full-causes` | `timestamp`, `source-node`, `source-node-event-id`, `destination-node`, `destination-node-event-id`, `changed-properties`, `label`, `layout-info`, `value-type`, `process` |
| `swiftui-updates` | `view-name`, `view-hierarchy`, `module`, `update-type`, `category`, `start`, `duration`, `severity`, `root-causes`, `cause-graph-node`, `full-cause-graph-node`, `downstream-events`, `downstream-cost`, `allocations`, `description`, `thread`, `id` |
| `swiftui-update-groups` | `start`, `duration`, `label`, `backtrace`, `cause-backtrace`, `thread` |
| `swiftui-changes` | `timestamp`, `description`, `backtrace`, `thread`, `id` |
| `swiftui-layout-updates` | `view-name`, `view-hierarchy`, `start`, `duration`, `self-duration`, `cached`, `severity`, `full-cause-graph-node`, `description` |

Also in the template: `time-profile` at 100 µs (`high-frequency-sampling="1"`), `hitches*`, `runloop-events`,
`potential-hangs`. Conclusion: the Cause & Effect data of WWDC25 (ref 2) is exportable in principle; the content of
the rows on a real run is still to be seen (Phase 3).

## 1.6 Traces carry the environment

`xctrace export --toc` of a session trace lists the attached process's environment variables, including
`CLAUDE_CODE_MESSAGING_TOKEN`, `PATH`, `HOME`. Traces must never be committed, published or attached to issues; the
ledger stores paths and summaries (SPEC §4.3).

# 2. Verified vs assumed

| Claim | Status |
|---|---|
| Suspending and walking the main thread from another thread at 1 kHz: safe, < 1 % overhead, accurate shares | Verified (1.1), on a synthetic workload; not yet on the real window |
| `dladdr` names local shared-cache symbols | Verified (1.3) |
| `proc_pid_rusage` instructions/cycles without root, CV 0.01 % | Verified (1.2) |
| CPU Counters template records without root on this Mac | Verified for a plain process (1.4); meaningfulness and stability across OS updates assumed fragile (refs 3, 4) |
| SwiftUI template exports cause/effect tables | Schemas verified (1.5); rows: none yet. Phase 3 recorded `step` attached and launched (bare, with get-task-allow, as an .app): every swiftui-* table empty, "Trace file had no SwiftUI data" (Developer Mode was off; cause unconfirmed) |
| xctrace stops cleanly on SIGINT and saves | Assumed from "Ctrl-C to stop the recording" in its output and the man page (ref 1); verify in Phase 0 |
| Signpost `step` intervals land in the `os-signpost` table | Mixed: the harness emits them, but two session recordings showed `signposts:` empty; fallback designed (C2) |
| Compositor hitch time ratio from the `hitches` table | Verified data path (today's `HitchSummary`); the ratio is arithmetic |
| Knobs cost one static load after first read | Assumed (ordinary Swift) |
| Snapshot PNG comparison is stable across builds for a deterministic fixture | Assumed; relative timestamps need a mask |
| `@Observable` mutation hook via registrar wrapper | Assumed; coarse per-turn attribution designed instead of per-edge |
| Tart VM renders via paravirtualised Metal; PMU counters unavailable in guests | From sources (refs 14, 15), not run here |
| Display-link cadence and hitch numbers inside a VM | Unverified; treated as untrusted (C10) |
| A second login session cannot host measured runs | Assumed, not verified, not pursued |
| MWU at 5 v 5 can reach p < 0.05 (min 0.0079); 3 pairs cannot | Arithmetic (ref 19) |
| Idle detection via IOKit `HIDIdleTime` | Assumed (standard API) |

# 3. References

1. `xctrace(1)` man page: `record --attach/--template/--time-limit/--launch`, `export --toc/--xpath`, `--har`.
   https://keith.github.io/xcode-man-pages/xctrace.1.html
2. WWDC25 session 306, "Optimize SwiftUI performance with Instruments": Update Groups, Long View Body Updates, Long
   Representable Updates, Cause & Effect Graph. https://developer.apple.com/videos/play/wwdc2025/306/
3. ibireme, KPC/kperf notes: counters need root or a blessed process.
   https://gist.github.com/ibireme/173517c208c7dc333ba962c1f0d67d12 ; Rust `darwin-kperf` README (root or
   `com.apple.private.kernel.kpc`). https://docs.rs/crate/darwin-kperf/latest/source/README.md
4. Apple Developer Forums: "Failed set kpc configuration: Operation not permitted" on macOS 15.3.1 (fixed 15.4) and
   again on 27.0.1. https://developer.apple.com/forums/thread/775833 ; https://developer.apple.com/forums/thread/849179
5. XNU `bsd/sys/resource.h`: `rusage_info_v4.ri_instructions`, `ri_cycles`.
   https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/sys/resource.h ; Swift Benchmark reads
   instruction counts via rusage on macOS and warns they may be empty in a VM.
   https://forums.swift.org/t/benchmark-support-for-cpu-instruction-counts/71423 ; Lemire, counting cycles and
   instructions on M1 (under sudo). https://lemire.me/blog/2021/03/24/counting-cycles-and-instructions-on-the-apple-m1-processor/
6. Sentry, "Building a performant iOS profiler": suspend, `thread_get_state`, walk x29.
   https://blog.sentry.io/building-a-performant-ios-profiler/
7. Chromium `base/profiler/suspendable_thread_delegate_mac.cc`: no heap allocation after `thread_suspend`.
   https://chromium.googlesource.com/chromium/src.git/+/main/base/profiler/suspendable_thread_delegate_mac.cc
8. Emerge Tools ETTrace: background thread sampling the main thread every ~4.5 ms. https://github.com/EmergeTools/ETTrace ;
   https://emergetools.com/blog/posts/ettrace-reliable-ios-profiling-with-flamecharts/
9. `OSSignposter.beginAnimationInterval(_:id:_:)`; WWDC20: use animation intervals so Instruments derives frame
   rate and hitches per interval. https://developer.apple.com/documentation/os/ossignposter/beginanimationinterval(_:id:_:)
10. WWDC20 10077, "Explore UI animation hitches and the render loop": hitch time ratio in ms/s; < 5 good, 5–10
    noticeable, ≥ 10 act. https://developer.apple.com/videos/play/wwdc2020/10077/
11. Xcode Organizer hitch scale (≤ 10 good, ≤ 25 warning, ≤ 50 critical).
    https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app
12. MetricKit `hitchTimeRatio` (macOS 27 `SignpostIntervalMetric`), `MXAnimationMetric.scrollHitchTimeRatio`
    (UIScrollView only). https://developer.apple.com/documentation/metrickit/hitchtimeratio ;
    `XCTOSSignpostMetric` (no native macOS in availability), `XCTCPUMetric` (cpu time, cycles, instructions).
    https://developer.apple.com/documentation/xctest/xctossignpostmetric ; https://developer.apple.com/documentation/xctest/xctcpumetric
13. Chromium Pinpoint compare: KS + Mann-Whitney U with Same/Different/Unknown ("collect more data"), randomised arm
    order. https://pkg.go.dev/go.skia.org/infra/pinpoint/go/compare ;
    https://chromium.googlesource.com/chromium/src/+/main/docs/speed/perf_trybots.md ; crossbench
    https://chromium.googlesource.com/crossbench
14. Tart: paravirtualised GPU, Metal in guests, no nested virtualisation. https://github.com/cirruslabs/tart ;
    https://github.com/openai/tart/discussions/344 ; macOS VM limits (two VMs, no Apple ID).
    https://eclecticlight.co/2023/09/14/current-limitations-on-macos-virtual-machines-running-on-apple-silicon-macs/
15. jmh-dev: CPU Counters fail inside macOS VMs (no PMU for virtual CPUs).
    https://mail.openjdk.org/pipermail/jmh-dev/2024-May/003891.html
16. Android Macrobenchmark `FrameTimingMetric`, `TraceSectionMetric`; Perfetto `TraceProcessor` SQL.
    https://developer.android.com/topic/performance/benchmarking/macrobenchmark-metrics ;
    https://developer.android.com/reference/androidx/benchmark/traceprocessor/TraceProcessor
17. Differential call trees: Brendan Gregg, differential flame graphs.
    https://brendangregg.com/blog/2014-11-09/differential-flame-graphs.html ; `pprof -diff_base`
    https://github.com/google/pprof/blob/main/doc/README.md ; Firefox Profiler compare mode
    https://bugzilla.mozilla.org/show_bug.cgi?id=2063430
18. Mozilla Perfherder alert sheriffing: t-test confidence, sustained over 12 points, 2 % thresholds.
    https://firefox-source-docs.mozilla.org/testing/perfdocs/perf-sheriffing.html
19. Mann-Whitney exact p for small n (min two-sided p 2/252 ≈ 0.0079 at 5 v 5; 2/20 = 0.1 at 3 v 3).
    https://graphpad.com/guides/prism/latest/statistics/how_the_mann-whitney_test_works.htm ; Kalibera & Jones,
    "Rigorous benchmarking in reasonable time". https://kar.kent.ac.uk/33611/
20. Karpathy, `autoresearch` (2026): the agent edits one file under a fixed time budget, keeps on a single metric,
    constrained by `program.md`. https://github.com/karpathy/autoresearch ; https://blog.skypilot.co/scaling-autoresearch/
21. AlphaEvolve https://arxiv.org/abs/2506.13131 ; OpenEvolve https://github.com/algorithmicsuperintelligence/openevolve ;
    ShinkaEvolve https://sakana.ai/shinka-evolve/
22. Agents gaming metrics: METR's o3 report (test and scoring edits) https://evaluations.metr.org/openai-o3-report ;
    EvilGenie (hard-coded test cases) https://arxiv.org/abs/2511.21654 ; ImpossibleBench
    https://www.greaterwrong.com/posts/qJYMbrabcQqCZ7iqm/impossiblebench-measuring-reward-hacking-in-llm-coding-1
23. Xcode performance test baselines ("Max STDDEV"; legacy 10 % relative standard deviation).
    https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests ;
    https://developer.squareup.com/blog/measureblock-how-does-performance-testing-work-in-ios/
