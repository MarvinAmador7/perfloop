import Foundation

// How closely content followed a replayed gesture (CAPABILITIES.md C9), from what was on screen at each display tick.
//
// The host replays a gesture's events at their recorded times and, at every display tick, reads where the content
// shows (the document layer's `presentation()`, so a render-server animation counts) along the gesture's axis. The
// meter compares that with where the fingers put it: the start plus every finger delta that could be on screen by
// then, `latencyFrames` ticks back.
//
// - At 0 frames: every delta delivered before the last Core Animation commit ahead of the tick (one delivered since
//   can't be on screen yet).
// - At n ≥ 1 frames: every delta delivered before the tick n ticks earlier. AppKit's scroll view doesn't move its clip
//   view inside `scrollWheel(with:)`: it queues the delta and applies it on the next display refresh, so on the
//   reel the content shows a frame behind the fingers (as it does under a real hand).
// - Either way, a delta due more than `lagSlackS` before that point but not delivered by then counts too: the main
//   thread was busy, and under a real hand the content would lag the fingers by that much.
//
// The latency is the whole number of frames (0–3) at which the content followed the fingers best (the smallest p95
// error; the shorter one on a tie): a pipeline delay is reported as `latencyFrames`, not as error. Then, per gesture:
// - `positionErrorP95Pt`: |shown − expected| at the ticks while the fingers were down, p95. After the fingers lift the
//   app owns the motion (momentum, or a snap like the reel's), so there's no expected position to hold it to.
// - `stalls`: frames while the fingers were down where they moved ≥ 1 pt since the previous tick and the content
//   didn't: a tick where it moved < 0.5 pt, and every display frame that had no tick at all (the main thread was busy
//   past the vsync, so the screen kept the old frame while the fingers moved on).
// - `jerkP95`: |third derivative of the shown position|, p95, from the first finger tick to the settle, in pt per
//   frame³ at the display's own rate (pt/s³ × frame³): a frame that sticks or jumps, a hand-off at release that
//   changes the acceleration at once. Noisy by nature (it differentiates three times), so it informs and doesn't gate.

public struct Smoothness: Codable, Sendable, Equatable {
  /// nil when no tick fell inside the finger phase (a wheel, or nothing was read).
  public var positionErrorP95Pt: Double?
  public var stalls: Int
  /// nil with fewer than four ticks to differentiate.
  public var jerkP95: Double?
  /// The largest error while the fingers were down.
  public var positionErrorMaxPt: Double?
  /// How many display frames the content showed behind the fingers (the alignment the error was taken at).
  public var latencyFrames: Int?
  /// Ticks the error and stalls were judged on (fingers down), and all ticks the jerk was taken over.
  public var trackingTicks: Int
  public var ticks: Int
  public init(positionErrorP95Pt: Double?, stalls: Int, jerkP95: Double?, positionErrorMaxPt: Double? = nil, latencyFrames: Int? = nil, trackingTicks: Int = 0, ticks: Int = 0) {
    self.positionErrorP95Pt = positionErrorP95Pt; self.stalls = stalls; self.jerkP95 = jerkP95
    self.positionErrorMaxPt = positionErrorMaxPt; self.latencyFrames = latencyFrames; self.trackingTicks = trackingTicks; self.ticks = ticks
  }
}

public enum SmoothnessMeter {
  /// One display tick: when it was read and when the last commit before it went out (seconds, one clock), and where
  /// the content showed along the axis (pt, growing as the delta's sign says).
  public struct Tick: Sendable, Equatable {
    public var t: Double
    public var committed: Double
    public var shown: Double
    public init(t: Double, committed: Double, shown: Double) { self.t = t; self.committed = committed; self.shown = shown }
  }
  /// One replayed event: when it was due (its recorded time on the replay's clock) and delivered (nil: never), how far
  /// it should move the content (pt, same sign convention as `Tick.shown`), and whether the fingers were down.
  public struct Delta: Sendable, Equatable {
    public var due: Double
    public var delivered: Double?
    public var d: Double
    public var finger: Bool
    public init(due: Double, delivered: Double?, d: Double, finger: Bool) { self.due = due; self.delivered = delivered; self.d = d; self.finger = finger }
  }

  public static let stallFingerPt = 1.0
  public static let stallContentPt = 0.5
  /// Half a 120 Hz frame: an event this late is a lag the eye could catch.
  public static let lagSlackS = 0.004
  public static let maxLatencyFrames = 3

  /// `start`: where the content showed before the first event. `fingerFrom`/`fingerUntil`: the due times of the first
  /// and last finger events (the fingers touched, lifted). `settled`: when the content came to rest (the jerk's window
  /// ends there; nil: the last tick).
  public static func measure(ticks raw: [Tick], deltas: [Delta], start: Double, fingerFrom: Double, fingerUntil: Double, settled: Double?) -> Smoothness {
    let ticks = raw.sorted { $0.t < $1.t }
    let finger = deltas.filter(\.finger).sorted { $0.due < $1.due }
    /// Where the fingers had put the content by `ref` (`committed`: count deliveries before it; else before `ref`).
    func expected(ref: Double, committed: Double?) -> Double {
      finger.reduce(start) { x, e in
        let shown = e.delivered.map { $0 < (committed ?? ref) } ?? false
        let overdue = (e.delivered.map { $0 > ref } ?? true) && e.due < ref - lagSlackS
        return shown || overdue ? x + e.d : x
      }
    }
    // Fingers down: ticks after the first finger event was due, up to the last one's.
    let tracking = ticks.indices.filter { ticks[$0].t > fingerFrom && ticks[$0].t <= fingerUntil }
    var best: (lag: Int, errors: [Double], expected: [Double])?
    for lag in 0...maxLatencyFrames {
      let exp = tracking.map { k -> Double in
        lag == 0 ? expected(ref: ticks[k].t, committed: ticks[k].committed) : k - lag >= 0 ? expected(ref: ticks[k - lag].t, committed: nil) : start
      }
      let errs = zip(tracking, exp).map { abs(ticks[$0].shown - $1) }
      if best == nil || (!errs.isEmpty && percentile(errs, 95) < percentile(best!.errors, 95) - 1e-9) { best = (lag, errs, exp) }
    }
    var stalls = 0
    let allGaps = zip(ticks.dropFirst(), ticks).map { $0.t - $1.t }.filter { $0 > 0.0005 }.sorted()
    let frameS = allGaps.isEmpty ? 0 : allGaps[allGaps.count / 2]
    if let b = best {
      for i in b.expected.indices.dropFirst() where abs(b.expected[i] - b.expected[i - 1]) >= stallFingerPt {
        let a = ticks[tracking[i - 1]], c = ticks[tracking[i]]
        if abs(c.shown - a.shown) < stallContentPt { stalls += 1 }
        if frameS > 0 { stalls += max(0, Int(((c.t - a.t) / frameS).rounded()) - 1) }
      }
    }
    let errors = best?.errors ?? []
    // Jerk from the first tick of the gesture to the settle, with the ticks' own times (a late tick is a longer step).
    let end = settled ?? ticks.last?.t ?? 0
    var pts = ticks.filter { $0.t >= fingerFrom && $0.t <= end + 0.0001 }
    pts = pts.reduce(into: []) { acc, x in if let l = acc.last, x.t - l.t < 0.0005 { acc[acc.count - 1] = x } else { acc.append(x) } }
    var jerk: Double?
    if pts.count >= 4 {
      let gaps = zip(pts.dropFirst(), pts).map { $0.t - $1.t }.sorted()
      let frame = gaps[gaps.count / 2]
      var v: [(t: Double, v: Double)] = [], a: [(t: Double, a: Double)] = [], j: [Double] = []
      for (p, q) in zip(pts, pts.dropFirst()) { v.append(((p.t + q.t) / 2, (q.shown - p.shown) / (q.t - p.t))) }
      for (p, q) in zip(v, v.dropFirst()) where q.t > p.t { a.append(((p.t + q.t) / 2, (q.v - p.v) / (q.t - p.t))) }
      for (p, q) in zip(a, a.dropFirst()) where q.t > p.t { j.append(abs((q.a - p.a) / (q.t - p.t)) * frame * frame * frame) }
      jerk = j.isEmpty ? nil : round(percentile(j, 95), 2)
    }
    return Smoothness(positionErrorP95Pt: errors.isEmpty ? nil : round(percentile(errors, 95), 2), stalls: stalls, jerkP95: jerk,
                      positionErrorMaxPt: errors.max().map { round($0, 2) }, latencyFrames: errors.isEmpty ? nil : best?.lag,
                      trackingTicks: tracking.count, ticks: pts.count)
  }

  /// Nearest-rank percentile (the bench's statistics live elsewhere; this stays dependency-free).
  public static func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    let rank = Int((p / 100 * Double(s.count)).rounded(.up))
    return s[min(max(rank, 1), s.count) - 1]
  }

  static func round(_ x: Double, _ places: Int) -> Double { let m = pow(10, Double(places)); return (x * m).rounded() / m }
}
