import XCTest
@testable import PerfLoopProbe

/// Recorded gestures and the smoothness meter (CAPABILITIES.md C9), without a window: the recorder is fed the numbers
/// a scroll view's events carry, the meter the ticks and deltas a replay would give it.
final class GesturesTests: XCTestCase {
  // NSEvent.Phase raw bits.
  let mayBegin: UInt = 32, began: UInt = 1, changed: UInt = 4, ended: UInt = 8, cancelled: UInt = 16

  func testPhasesRoundTripNSEventBits() {
    for p in Gesture.Phase.allCases { XCTAssertEqual(Gesture.Phase(rawBits: p.rawBits), p) }
    XCTAssertEqual(Gesture.Phase(rawBits: 0), .none)
  }

  /// A swipe as a trackpad sends it: fingers rest, move, lift, then the system's momentum. One gesture, times from its
  /// first event, the device inferred.
  func testAFlickWithMomentumIsOneGesture() throws {
    var got: [Gesture] = []
    let r = GestureRecorder(name: "flick") { g, _ in got.append(g) }
    var t = 100.0
    r.record(t: t, dx: 0, dy: 0, phase: mayBegin, momentum: 0, precise: true)
    for (i, d) in [0.0, -4, -9, -15].enumerated() { t += 1.0 / 120; r.record(t: t, dx: d, dy: 0, phase: i == 0 ? began : changed, momentum: 0, precise: true) }
    t += 1.0 / 120; r.record(t: t, dx: 0, dy: 0, phase: ended, momentum: 0, precise: true)
    XCTAssertNotNil(r.deadline, "a lifted finger may still get momentum: wait")
    for (i, d) in [-14.0, -12, -10].enumerated() { t += 1.0 / 120; r.record(t: t, dx: d, dy: 0, phase: 0, momentum: i == 0 ? began : changed, precise: true) }
    XCTAssertTrue(got.isEmpty)
    t += 1.0 / 120; r.record(t: t, dx: 0, dy: 0, phase: 0, momentum: ended, precise: true)
    let g = try XCTUnwrap(got.first)
    XCTAssertEqual(got.count, 1)
    XCTAssertEqual(g.name, "flick"); XCTAssertEqual(g.device, "trackpad"); XCTAssertEqual(g.schema, gestureSchema)
    XCTAssertEqual(g.events.count, 10)
    XCTAssertEqual(g.events.first?.t, 0); XCTAssertEqual(g.events.last?.t ?? 0, 9000.0 / 120, accuracy: 0.01)
    XCTAssertEqual(g.events.map(\.phase).prefix(6), [.mayBegin, .began, .changed, .changed, .changed, .ended])
    XCTAssertEqual(g.events.last?.momentum, .ended)
    XCTAssertEqual(g.fingerTravel.dx, -28); XCTAssertEqual(g.momentumTravel.dx, -36)
    XCTAssertEqual(g.hz ?? 0, 120, accuracy: 0.5)
    XCTAssertEqual(g.problems, [])
    XCTAssertFalse(r.recording)
  }

  func testADragWithoutMomentumEndsAtItsDeadline() {
    var got: [Gesture] = []
    let r = GestureRecorder(name: "drag", quietS: 0.3) { g, _ in got.append(g) }
    r.record(t: 1, dx: 0, dy: 0, phase: began, momentum: 0, precise: true)
    r.record(t: 1.01, dx: -3, dy: 1, phase: changed, momentum: 0, precise: true)
    r.record(t: 1.02, dx: 0, dy: 0, phase: ended, momentum: 0, precise: true)
    r.idle(at: 1.2); XCTAssertTrue(got.isEmpty, "momentum may still come")
    r.idle(at: 1.33)
    XCTAssertEqual(got.count, 1); XCTAssertEqual(got.first?.fingerTravel.dy, 1)
  }

  /// Resting the fingers and lifting them moves nothing: no file. A new touch during momentum starts a new gesture;
  /// the second is named NAME-2.
  func testRestsAreDroppedAndATouchStartsANewGesture() {
    var got: [(Gesture, Int)] = []
    let r = GestureRecorder(name: "g") { got.append(($0, $1)) }
    r.record(t: 0, dx: 0, dy: 0, phase: mayBegin, momentum: 0, precise: true)
    r.record(t: 0.05, dx: 0, dy: 0, phase: cancelled, momentum: 0, precise: true)
    r.idle(at: 1)
    XCTAssertTrue(got.isEmpty)
    r.record(t: 2, dx: 0, dy: 0, phase: began, momentum: 0, precise: true)
    r.record(t: 2.01, dx: 5, dy: 0, phase: changed, momentum: 0, precise: true)
    r.record(t: 2.02, dx: 0, dy: 0, phase: ended, momentum: 0, precise: true)
    r.record(t: 2.03, dx: 4, dy: 0, phase: 0, momentum: began, precise: true)
    r.record(t: 2.04, dx: 0, dy: 0, phase: mayBegin, momentum: 0, precise: true)   // caught the momentum
    XCTAssertEqual(got.count, 1)
    r.record(t: 2.05, dx: 0, dy: 0, phase: began, momentum: 0, precise: true)
    r.record(t: 2.06, dx: -6, dy: 0, phase: changed, momentum: 0, precise: true)
    r.finish()
    XCTAssertEqual(got.map(\.1), [1, 2]); XCTAssertEqual(got.map(\.0.name), ["g", "g-2"])
    XCTAssertEqual(got[1].0.events.first?.phase, .mayBegin)
  }

  func testAWheelIsAMouseGestureCutByQuiet() {
    var got: [Gesture] = []
    let r = GestureRecorder(name: "w") { g, _ in got.append(g) }
    r.record(t: 0, dx: 0, dy: 1, phase: 0, momentum: 0, precise: false)
    r.record(t: 0.1, dx: 0, dy: 1, phase: 0, momentum: 0, precise: false)
    r.record(t: 0.6, dx: 0, dy: 2, phase: 0, momentum: 0, precise: false)   // after the quiet: a new one
    r.finish()
    XCTAssertEqual(got.count, 2); XCTAssertEqual(got.first?.device, "mouse"); XCTAssertEqual(got.first?.events.count, 2)
  }

  func testTheFileRoundTripsAndSaysWhatIsWrong() throws {
    let g = Gesture(name: "x", device: "trackpad", hz: 120, synthetic: true, source: "test",
                    events: [.init(t: 0, dx: 0, phase: .began), .init(t: 8.333, dx: -3.5, dy: 0.5, phase: .changed), .init(t: 16.667, dx: 0, phase: .ended)])
    let back = try JSONDecoder().decode(Gesture.self, from: g.encoded())
    XCTAssertEqual(back, g)
    let text = String(decoding: g.encoded(), as: UTF8.self)
    XCTAssertTrue(text.contains("\"schema\" : \"perfloop.gesture\\/1\"") || text.contains("\"schema\" : \"perfloop.gesture/1\""))
    var bad = g; bad.events = [.init(t: 5, dx: 0, phase: .began), .init(t: 1, dx: 0, phase: .changed)]
    XCTAssertEqual(bad.problems, ["event times go backwards", "nothing moved (every delta is 0)"])
  }

  // MARK: the meter

  /// A replay of `n` finger deltas of `d` pt, one per 120 Hz frame, events and ticks half a frame apart; the content
  /// shows each delta `lag` ticks after the tick that follows its delivery (0: by the next tick).
  func replay(n: Int = 12, d: Double = 5, lag: Int, hold: Set<Int> = [], skip: Set<Int> = []) -> (ticks: [SmoothnessMeter.Tick], deltas: [SmoothnessMeter.Delta], until: Double) {
    let f = 1.0 / 120
    let deltas = (0..<n).map { SmoothnessMeter.Delta(due: Double($0) * f, delivered: Double($0) * f + 0.0001, d: d, finger: true) }
    var ticks: [SmoothnessMeter.Tick] = [], shown = 0.0
    for k in 0..<(n + 6) {
      let t = (Double(k) + 0.5) * f
      // Deltas delivered before tick k − lag, committed before the tick: what the content shows at tick k.
      let ref = (Double(k - lag) + 0.5) * f
      if !hold.contains(k) { shown = deltas.filter { $0.delivered! < ref - 0.001 }.reduce(0) { $0 + $1.d } }
      if !skip.contains(k) { ticks.append(SmoothnessMeter.Tick(t: t, committed: t - 0.001, shown: shown)) }
    }
    return (ticks, deltas, Double(n - 1) * f)
  }

  func testContentAFrameBehindTheFingersFollowsThem() {
    for lag in 0...2 {
      let r = replay(lag: lag)
      let s = SmoothnessMeter.measure(ticks: r.ticks, deltas: r.deltas, start: 0, fingerFrom: 0, fingerUntil: r.until, settled: nil)
      XCTAssertEqual(s.positionErrorP95Pt, 0, "lag \(lag)"); XCTAssertEqual(s.stalls, 0, "lag \(lag)")
      XCTAssertEqual(s.latencyFrames, lag)
      XCTAssertEqual(s.trackingTicks, 11)
    }
  }

  func testContentThatStopsFollowingIsErrorAndStalls() {
    // Frozen for three ticks while the fingers move on, then it catches up.
    let r = replay(lag: 1, hold: [5, 6, 7])
    let s = SmoothnessMeter.measure(ticks: r.ticks, deltas: r.deltas, start: 0, fingerFrom: 0, fingerUntil: r.until, settled: nil)
    XCTAssertEqual(s.stalls, 3)
    XCTAssertGreaterThan(s.positionErrorP95Pt ?? 0, 1)
    XCTAssertGreaterThanOrEqual(s.positionErrorMaxPt ?? 0, 10)   // at the alignment that fits best
  }

  func testFramesThatNeverCameAreStalls() {
    // The main thread missed three vsyncs while the fingers moved: the screen kept the old frame.
    let r = replay(lag: 1, skip: [5, 6, 7])
    let s = SmoothnessMeter.measure(ticks: r.ticks, deltas: r.deltas, start: 0, fingerFrom: 0, fingerUntil: r.until, settled: nil)
    XCTAssertEqual(s.stalls, 3)
  }

  func testOverdueDeltasCountAsLag() {
    // Due, but held back 30 ms by a busy main thread: the fingers were ahead of the content by then.
    var r = replay(lag: 0)
    for i in 4..<8 { r.deltas[i].delivered = 0.07 }
    let s = SmoothnessMeter.measure(ticks: r.ticks, deltas: r.deltas, start: 0, fingerFrom: 0, fingerUntil: r.until, settled: nil)
    XCTAssertGreaterThan(s.positionErrorP95Pt ?? 0, 1)
  }

  func testJerkIsZeroAtASteadyVelocityAndSeesAJump() {
    let f = 1.0 / 120
    let steady = (0..<20).map { SmoothnessMeter.Tick(t: Double($0) * f, committed: Double($0) * f, shown: Double($0) * 4) }
    let s = SmoothnessMeter.measure(ticks: steady, deltas: [], start: 0, fingerFrom: 0, fingerUntil: 0, settled: nil)
    XCTAssertEqual(s.jerkP95 ?? -1, 0, accuracy: 1e-6)
    XCTAssertNil(s.positionErrorP95Pt, "no finger delta: nothing to follow")
    var jumpy = steady; for i in 10..<20 { jumpy[i].shown += 20 }
    XCTAssertGreaterThan(SmoothnessMeter.measure(ticks: jumpy, deltas: [], start: 0, fingerFrom: 0, fingerUntil: 0, settled: nil).jerkP95 ?? 0, 10)
  }
}
