import XCTest
@testable import PerfLoopKit

/// The quiet gate's rule and record, and frames that never drew (F2): missing, never a perfect 0.
final class QuietTests: XCTestCase {
  func json(_ s: String) throws -> JSONValue { try PLJSON.decode(JSONValue.self, from: Data(s.utf8)) }

  // MARK: the quiet gate

  func testTheGateNamesWhatIsBusy() {
    let g = QuietGate()
    XCTAssertNil(g.busy(LoadReading(busyPct: 12, processes: [BusyProcess(name: "Safari", pct: 20)])))
    XCTAssertNil(g.busy(LoadReading(busyPct: nil)))                                   // unknown: no wait
    let busy = g.busy(LoadReading(busyPct: 99.8, processes: [BusyProcess(name: "swift-frontend", pct: 380), BusyProcess(name: "Safari", pct: 20)]))
    XCTAssertEqual(busy, "100 % of the cores busy (> 30 %); building: swift-frontend; busiest: swift-frontend 380 %, Safari 20 %")
    // A build running is noise even while the cores are mostly free (a link step, a test run starting).
    XCTAssertEqual(g.busy(LoadReading(busyPct: 8, processes: [BusyProcess(name: "ld", pct: 0)])), "building: ld; busiest: ld 0 %")
    XCTAssertNil(QuietGate(maxLoadPct: 90).busy(LoadReading(busyPct: 60)))
    let st = g.state(LoadReading(busyPct: 64.04, processes: [BusyProcess(name: "clang", pct: 120)]), waited: 60.04)
    XCTAssertEqual(st, MachineState(quiet: false, busyPct: 64, busy: ["clang 120 %"], waitedS: 60, why: "64 % of the cores busy (> 30 %); building: clang; busiest: clang 120 %"))
    XCTAssertTrue(g.state(LoadReading(busyPct: 5), waited: 0.5).quiet)
  }

  func testPsIsSummedByNameWithoutOurselves() {
    let ps = """
      101  95.0 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend
      102  80.5 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend
      103   0.0 /usr/bin/ld
      104   3.0 /Applications/Safari.app/Contents/MacOS/Safari
      105  40.0 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
      106  99.0 /usr/local/bin/perfloop
      107  50.0 ps
    """
    XCTAssertEqual(HostLoad.parse(ps, exclude: [106]), [BusyProcess(name: "swift-frontend", pct: 175.5), BusyProcess(name: "Google Chrome", pct: 40), BusyProcess(name: "ld", pct: 0)])
  }

  func testTheTestingHookReadsLoadAndBusy() {
    let r = LoadReading(text: "idle=500 locked=0 load=72.5 busy=swift-frontend:300,Google_Chrome:40")
    XCTAssertEqual(r.busyPct, 72.5)
    XCTAssertEqual(r.processes, [BusyProcess(name: "swift-frontend", pct: 300), BusyProcess(name: "Google Chrome", pct: 40)])
    XCTAssertEqual(r.builds, ["swift-frontend"])
    XCTAssertTrue(LoadReading(text: "idle=500 locked=0").unknown)                    // an idle file from before the gate
    XCTAssertTrue(LoadReading(text: "130").unknown)
  }

  func testNotQuietRepsAreSaidInExplain() {
    var a = Side(objective: 40), b = Side(objective: 20)
    b.quiet = false; b.machine = MachineState(quiet: false, busyPct: 99.8, busy: ["swift-frontend 380 %"], waitedS: 60, why: "100 % of the cores busy (> 30 %)")
    a.quiet = true
    var st = Stage(metric: "mainThreadCpuMsPerStep", pairs: [Pair(index: 0, order: "AB", result: nil, a: a, b: b)], verdict: "rejected")
    st.runner = RunnerIdentity(runner: "local", model: "Mac16,1")
    let text = Explain.stage("screen", st).joined(separator: "\n")
    XCTAssertTrue(text.contains("1 of 2 rep(s) started on a machine that wasn't quiet (100 % of the cores busy (> 30 %)): quiet: false in the pair records"), text)
    // A record round-trips with its machine state.
    let back = try? PLJSON.decode(Side.self, from: Data(PLJSON.encode(b).utf8))
    XCTAssertEqual(back, b)
  }

  // MARK: frames that never drew

  func testARepThatPresentedNoFrameHasNoFrameMetrics() throws {
    // PerfLoopHost's rep: a tick count of 0 (the screen locked; every number in frames reads 0).
    let locked = try json(#"{ "steps": [{ "cpuMs": 3 }], "cpuMsPerStep": 3, "frames": { "ticks": 0, "p95Ms": 0, "late": 0, "steadyHz": 120, "hitchTimeRatioMsPerS": 0 }, "mainThread": { "longestMs": 4 } }"#)
    let s = Readings.side(rep: locked, metric: "mainThreadCpuMsPerStep")
    XCTAssertEqual(s.noFrames, true)
    XCTAssertNil(s.hitchTimeRatioMsPerS); XCTAssertNil(s.lateFrames); XCTAssertNil(s.steadyHz)
    XCTAssertEqual(s.objective, 3); XCTAssertEqual(s.longestStretchMs, 4)            // the main thread still ran
    XCTAssertNil(Readings.side(rep: locked, metric: "hitchTimeRatioMsPerS").objective)   // never a perfect 0
    // An adapter without a tick count: a frame p95 of 0 ms.
    XCTAssertEqual(Readings.side(rep: try json(#"{ "steps": [{}], "frames": { "p95Ms": 0, "hitchTimeRatioMsPerS": 0 } }"#), metric: "latencyMs").noFrames, true)
    // Frames that drew, and an adapter that reports neither field: nothing changes.
    let drew = Readings.side(rep: try json(#"{ "steps": [{}], "frames": { "ticks": 90, "p95Ms": 8.3, "hitchTimeRatioMsPerS": 0 } }"#), metric: "hitchTimeRatioMsPerS")
    XCTAssertNil(drew.noFrames); XCTAssertEqual(drew.objective, 0); XCTAssertEqual(drew.hitchTimeRatioMsPerS, 0)
    XCTAssertNil(Readings.side(rep: try json(#"{ "steps": [{}], "frames": { "steadyHz": 120, "hitchTimeRatioMsPerS": 0 } }"#), metric: "mainThreadCpuMsPerStep").noFrames)
    // deskbench's `ab` summary: frameP95Ms 0.
    let sum = Readings.side(summary: try json(#"{ "mainThreadCpuMsPerStep": { "median": 3 }, "frameP95Ms": { "median": 0 }, "hitchTimeRatioMsPerS": { "median": 0 }, "lateFrames": { "median": 0 } }"#), metric: "mainThreadCpuMsPerStep")
    XCTAssertEqual(sum.noFrames, true); XCTAssertNil(sum.hitchTimeRatioMsPerS); XCTAssertNil(sum.lateFrames)
    XCTAssertNil(Readings.side(summary: try json(#"{ "mainThreadCpuMsPerStep": { "median": 3 }, "frameP95Ms": { "median": 9.1 } }"#), metric: "mainThreadCpuMsPerStep").noFrames)
    // The adapter's own quiet flag on a rep.
    XCTAssertEqual(Readings.side(rep: try json(#"{ "steps": [{}], "quiet": false }"#), metric: "mainThreadCpuMsPerStep").quiet, false)
  }

  func testAPairWithoutFramesNeverDecides() {
    var nf = Side(objective: 20); nf.noFrames = true
    let p = Pair(index: 0, order: "AB", result: nil, a: Side(objective: 40), b: nf)
    XCTAssertEqual(Acceptance.unusable(p), "no frames on the candidate: screen locked or window off-screen (its frame metrics are missing, not 0)")
    // A screen whose every pair drew nothing says so, and promises nothing (it was "promising" at 2× before).
    let s = Acceptance.screen([p, p, p].enumerated().map { var x = $1; x.index = $0; return x }, metric: "mainThreadCpuMsPerStep", guards: [])
    XCTAssertEqual(s.verdict, "error")
    XCTAssertTrue(s.reasons.contains { $0.contains("screen locked or window off-screen") }, "\(s.reasons)")
    // A frame metric as the objective: missing, so "no frames" is the reason, not "the objective is missing".
    var nh = Side(objective: nil); nh.noFrames = true
    XCTAssertTrue(Acceptance.unusable(Pair(index: 0, order: "AB", result: nil, a: nh, b: Side(objective: 1)))?.hasPrefix("no frames on the champion") == true)
  }
}
