#if os(macOS)
import XCTest
import AppKit
@testable import PerfLoopHost
import PerfLoopKit
import PerfLoopProbe

/// Gesture replay and recording without a window: a rep's smoothness from its steps, read back the way the runner reads
/// it, the built-in gestures in the manifest, and the recorder cutting NSEvents into a file.
@MainActor final class GestureHostTests: XCTestCase {
  func step(_ name: String, _ s: Smoothness?) -> StepRecord {
    var t = Timeline(nominalHz: 120); t.ticks = stride(from: 0.0, through: 200, by: 1000 / 120).map { $0 }
    var r = t.step(name: name, at: 0, end: 100, latencyMs: nil, settleMs: 10, settled: true, cpuMs: 10, instructions: nil)
    r.smoothness = s
    return r
  }

  func testARepsSmoothnessIsItsWorstGestureAndTheRunnerReadsIt() throws {
    let a = Smoothness(positionErrorP95Pt: 0.4, stalls: 1, jerkP95: 3, positionErrorMaxPt: 2, latencyFrames: 1, trackingTicks: 40, ticks: 90)
    let b = Smoothness(positionErrorP95Pt: 1.6, stalls: 2, jerkP95: 9, positionErrorMaxPt: 5, latencyFrames: 2, trackingTicks: 30, ticks: 80)
    let t = Timeline(nominalHz: 120)
    let rep = t.rep(index: 0, steps: [step("swipe#0", a), step("swipe#1", b)], checks: [], guards: nil, window: nil)
    XCTAssertEqual(rep.smoothness?.positionErrorP95Pt, 1.6); XCTAssertEqual(rep.smoothness?.stalls, 3); XCTAssertEqual(rep.smoothness?.jerkP95, Stats.median([3, 9]))
    XCTAssertEqual(rep.smoothness?.latencyFrames, 2)
    XCTAssertNil(t.rep(index: 0, steps: [step("select#0", nil)], checks: [], guards: nil, window: nil).smoothness, "no gesture, no smoothness")
    let summary = ResultSummary(reps: [rep], metric: "mainThreadCpuMsPerStep")
    XCTAssertEqual(summary.smoothness?.stalls.median, 3)
    let r = HostResult(tool: ToolInfo(name: "x", version: "1", configuration: "release", commit: nil, build: Build(hash: nil, commit: nil, dirty: true, stamp: false)),
                       app: "x", adapter: "x", scenario: "scroll", fixture: "f", params: [:], startedAt: Clock.now(), reps: [rep], summary: summary, verdict: "pass", exitCode: 0, notes: [])
    let v = try PLJSON.decode(JSONValue.self, from: Data(PLJSON.encode(r).utf8))
    let side = Readings.sides(run: v, metric: "mainThreadCpuMsPerStep")[0]
    XCTAssertEqual(side.positionErrorP95Pt, 1.6); XCTAssertEqual(side.stalls, 3)
    XCTAssertNil(v["reps"]?[0]?["steps"]?[0]?["smoothness"]?["absent"])
  }

  func testBuiltInGesturesAreListedAndLoad() throws {
    let b = Bench(app: "g", stamp: "commit=abc\ndirty=0")
    b.gestures = SyntheticGestures.specs
    b.scenario("scroll", summary: "s") { _ in }
    XCTAssertEqual(b.manifest().gestures, SyntheticGestures.specs)
    XCTAssertTrue(b.handle(["gestures"]).1.contains("synthetic:scroll-down"))
    let all = try PLJSON.decode([Gesture].self, from: Data(b.handle(["gestures", "--json"]).1.utf8))
    XCTAssertEqual(all.count, SyntheticGestures.all.count)
  }

  /// A replay stamps each event with its recorded time, not the time it went out: AppKit reads the release velocity from
  /// the timestamps, and a late timer must not change it. Windowless: a scroll view in a window that is never shown.
  func testAReplayStampsEventsWithTheirRecordedTimes() async throws {
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    // Overriding scrollWheel keeps AppKit's scrolling on the main thread: its concurrent scrolling needs a screen.
    final class Scroll: NSScrollView { override func scrollWheel(with e: NSEvent) { super.scrollWheel(with: e) } }
    let sv = Scroll(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    sv.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 4000))
    window.contentView = sv
    let g = try SyntheticGestures.load("synthetic:scroll-down")
    let replay = GestureReplay(sv: sv, window: window, gesture: g, timestamps: true)
    replay.start()
    let limit = Date().addingTimeInterval(10)
    while !replay.done, Date() < limit { try await Task.sleep(nanoseconds: 5_000_000) }
    replay.stop()
    XCTAssertEqual(replay.sent.count, g.events.count)
    let first = try XCTUnwrap(replay.sent.first)
    for (s, e) in zip(replay.sent, g.events) {
      XCTAssertEqual((s.timestamp - first.timestamp) * 1000, e.t - g.events[0].t, accuracy: 0.001, "event at \(e.t) ms")
      XCTAssertEqual(s.timestamp, s.due, accuracy: 1e-6)
    }
    let zero = GestureReplay(sv: sv, window: window, gesture: g, timestamps: false)
    zero.start()
    while !zero.done, Date() < limit { try await Task.sleep(nanoseconds: 5_000_000) }
    zero.stop()
    XCTAssertTrue(zero.sent.allSatisfy { $0.timestamp == 0 }, "timestamps: false stamps every event 0")
  }

  /// The recorder's tap, fed NSEvents made from a synthetic gesture's numbers: one file, the same deltas and phases.
  func testTheRecorderCutsEventsIntoAFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perfloop-rec-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("hand.json")
    let tap = GestureTap(to: url, name: "hand", device: nil)
    let g = try SyntheticGestures.load("synthetic:drag-down")
    let t0 = ProcessInfo.processInfo.systemUptime
    for e in g.events {
      let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(e.dy), wheel2: Int32(e.dx), wheel3: 0))
      cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: e.dy)
      let sp: Int64 = switch e.phase { case .began: 1; case .changed: 2; case .ended: 4; case .mayBegin: 128; default: 0 }
      cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: sp)
      cg.timestamp = CGEventTimestamp((t0 + e.t / 1000) * 1e9)
      tap.handle(try XCTUnwrap(NSEvent(cgEvent: cg)))
    }
    tap.stop(keepOpen: true)   // the lifted drag ends 0.3 s later; out of time, the one in flight is written
    XCTAssertEqual(tap.written.count, 1)
    let back = try Gesture.read(url)
    XCTAssertEqual(back.events.count, g.events.count)
    XCTAssertEqual(back.events.map(\.phase), g.events.map(\.phase))
    XCTAssertEqual(back.events.reduce(0) { $0 + $1.dy }, g.events.reduce(0) { $0 + $1.dy })
    XCTAssertEqual(back.device, "trackpad"); XCTAssertEqual(back.problems, [])
    XCTAssertEqual(back.events.last!.t, g.events.last!.t, accuracy: 1, "the times are the events' own")
  }
}
#endif
