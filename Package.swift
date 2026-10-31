// swift-tools-version:5.9
import PackageDescription

// PerfLoop: an agent-first performance loop for native macOS apps (design/perf-loop/SPEC.md). Generic: nothing here
// knows what capcomd is. An app's adapter (capcomd's is `deskbench`) describes its scenarios, knobs and guards in a
// manifest; the `perfloop` runner drives it as a child process and never links it. scripts/check-imports.sh (and
// ImportGuardTests) fail on any capcomd import under Sources/.
let package = Package(
  name: "PerfLoop",
  platforms: [.macOS(.v14)],
  products: [
    // Pure: schemas, statistics, the acceptance and stopping rules, explain. Builds and tests on Linux.
    .library(name: "PerfLoopKit", targets: ["PerfLoopKit"]),
    // Linked by the app itself (macOS): knobs, probe seam, stamp reader. Tiny, Foundation only.
    .library(name: "PerfLoopProbe", targets: ["PerfLoopProbe"]),
    .executable(name: "perfloop", targets: ["perfloop"]),
  ],
  targets: [
    .target(name: "PerfLoopKit"),
    // Runtime knobs (C4) and, later, the probe seam, the stretch sampler and the build stamp reader.
    .target(name: "PerfLoopProbe"),
    // The runner's file and process plumbing: the content-addressed store, the adapter as a child, the experiment
    // verbs. Foundation only (Process, FileManager), so it builds on Linux too; `perfloop` is a thin main over it.
    .target(name: "PerfLoopRunner", dependencies: ["PerfLoopKit"]),
    .executableTarget(name: "perfloop", dependencies: ["PerfLoopKit", "PerfLoopRunner"]),
    .testTarget(name: "PerfLoopKitTests", dependencies: ["PerfLoopKit"]),
    .testTarget(name: "PerfLoopProbeTests", dependencies: ["PerfLoopProbe"]),
    // Drives the runner against a fake adapter (a shell script with canned `list`/`ab`/`run` output): no window.
    .testTarget(name: "PerfLoopRunnerTests", dependencies: ["PerfLoopKit", "PerfLoopRunner"], exclude: ["Fixtures"]),
  ])
