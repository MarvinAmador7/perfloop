// swift-tools-version:5.9
import PackageDescription

// SlowList: a small AppKit + SwiftUI app with a deliberately slow path, and its PerfLoop bench. It depends on PerfLoop
// the way an outside app would (here by path; from a tag once PerfLoop has its own repo), and shows what an app adds:
// `Probe.body` in the views worth counting, a knob where an idea varies, and a bench target of ~150 lines.
let package = Package(
  name: "SlowList",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "SlowList", targets: ["SlowList"]),
    .executable(name: "SlowListBench", targets: ["SlowListBench"]),
  ],
  dependencies: [.package(path: "../..")],
  targets: [
    // The app's model and views: what both the app and the bench show.
    .target(name: "SlowListKit", dependencies: [.product(name: "PerfLoopProbe", package: "perfloop")]),
    // The app: one window with the list.
    .executableTarget(name: "SlowList", dependencies: ["SlowListKit"]),
    // The bench (the adapter): hosts the app's views on fixture data; PerfLoopHost answers the runner's contract.
    .executableTarget(name: "SlowListBench",
                      dependencies: ["SlowListKit", .product(name: "PerfLoopHost", package: "perfloop"), .product(name: "PerfLoopProbe", package: "perfloop")],
                      plugins: [.plugin(name: "PerfLoopStamp", package: "perfloop")]),
    .testTarget(name: "SlowListKitTests", dependencies: ["SlowListKit"]),
  ])
