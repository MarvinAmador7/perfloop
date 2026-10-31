// swift-tools-version:5.9
import PackageDescription

// PerfLoop (design/perf-loop/SPEC.md §3.1): the generic performance loop. No capcomd imports.
let package = Package(
  name: "PerfLoop",
  platforms: [.macOS(.v14)],
  products: [
    // Linked by the app itself: tiny, Foundation only.
    .library(name: "PerfLoopProbe", targets: ["PerfLoopProbe"]),
  ],
  targets: [
    // Runtime knobs (C4) and, later, the probe seam, the stretch sampler and the build stamp reader.
    .target(name: "PerfLoopProbe"),
    .testTarget(name: "PerfLoopProbeTests", dependencies: ["PerfLoopProbe"]),
  ])
