import Foundation

// Recorded gestures (CAPABILITIES.md C9): a trackpad swipe recorded once in the app and replayed in-process into the
// same scroll view, so a candidate is judged on the hand's own deltas and timing rather than a made-up curve.
//
// A gesture file (`perfloop.gesture/1`, SCHEMAS.md §8) holds scroll deltas, phases and times and nothing else: no text,
// no window contents, no identifiers. The app's scroll view hands each scroll-wheel event's numbers to a
// `GestureRecorder` (only when recording was asked for; otherwise there is no recorder and the hook is a nil check),
// which cuts them into gestures (fingers down → up → the system's momentum) and hands each finished one back.

public let gestureSchema = "perfloop.gesture/1"

/// One recorded gesture: the scroll-wheel events from the fingers touching to the momentum's end.
public struct Gesture: Codable, Sendable, Equatable {
  public var schema = gestureSchema
  public var name: String
  /// When it was recorded (ISO 8601); nil for a generated one.
  public var recordedAt: String?
  /// "trackpad" (precise deltas with phases), "mouse" (a wheel: no phases), or what the recorder was told.
  public var device: String
  /// The events' rate: 1000 / the median interval between events that moved, rounded to 0.1.
  public var hz: Double?
  /// true for a gesture a program made (the bench's from its fling curve): no hand was involved.
  public var synthetic: Bool?
  /// How a synthetic gesture was made, in words.
  public var source: String?
  public var events: [Event]

  public init(name: String, recordedAt: String? = nil, device: String, hz: Double? = nil, synthetic: Bool? = nil, source: String? = nil, events: [Event]) {
    self.name = name; self.recordedAt = recordedAt; self.device = device; self.hz = hz; self.synthetic = synthetic; self.source = source; self.events = events
  }

  /// NSEvent's phases as words (`NSEvent.Phase` raw bits: began 1, stationary 2, changed 4, ended 8, cancelled 16,
  /// mayBegin 32). The momentum phase uses the same words (`none` when the event isn't momentum).
  public enum Phase: String, Codable, Sendable, CaseIterable {
    case none, mayBegin, began, stationary, changed, ended, cancelled
    /// From an `NSEvent.Phase` raw value; several bits (never seen in practice) read as the first that matters.
    public init(rawBits b: UInt) {
      if b & 1 != 0 { self = .began } else if b & 32 != 0 { self = .mayBegin } else if b & 4 != 0 { self = .changed }
      else if b & 2 != 0 { self = .stationary } else if b & 8 != 0 { self = .ended } else if b & 16 != 0 { self = .cancelled } else { self = .none }
    }
    public var rawBits: UInt {
      switch self { case .none: 0; case .began: 1; case .stationary: 2; case .changed: 4; case .ended: 8; case .cancelled: 16; case .mayBegin: 32 }
    }
    public var ends: Bool { self == .ended || self == .cancelled }
  }

  public struct Event: Codable, Sendable, Equatable {
    /// ms since the gesture's first event.
    public var t: Double
    /// `scrollingDeltaX` / `scrollingDeltaY`: points when `precise`, lines otherwise.
    public var dx: Double
    public var dy: Double
    public var phase: Phase
    public var momentum: Phase
    /// `hasPreciseScrollingDeltas`.
    public var precise: Bool
    public init(t: Double, dx: Double, dy: Double = 0, phase: Phase, momentum: Phase = .none, precise: Bool = true) {
      self.t = t; self.dx = dx; self.dy = dy; self.phase = phase; self.momentum = momentum; self.precise = precise
    }
    /// The fingers are on the surface (a phase other than none), as opposed to momentum or a wheel.
    public var finger: Bool { phase != .none }
  }

  /// From the first event to the last, in ms.
  public var durationMs: Double { (events.last?.t ?? 0) - (events.first?.t ?? 0) }
  /// Σ dx, Σ dy while the fingers were down, and during the momentum after.
  public var fingerTravel: (dx: Double, dy: Double) { travel { $0.finger } }
  public var momentumTravel: (dx: Double, dy: Double) { travel { $0.momentum != .none } }
  private func travel(_ f: (Event) -> Bool) -> (dx: Double, dy: Double) {
    events.filter(f).reduce((0, 0)) { ($0.0 + $1.dx, $0.1 + $1.dy) }
  }

  /// What is wrong with the file as a gesture to replay; empty when it can be replayed.
  public var problems: [String] {
    var p: [String] = []
    if schema != gestureSchema { p.append("schema is \(schema), not \(gestureSchema)") }
    if events.isEmpty { p.append("no events") }
    if zip(events.dropFirst(), events).contains(where: { $0.t < $1.t }) { p.append("event times go backwards") }
    if events.allSatisfy({ $0.dx == 0 && $0.dy == 0 }) { p.append("nothing moved (every delta is 0)") }
    if events.contains(where: { !$0.t.isFinite || !$0.dx.isFinite || !$0.dy.isFinite }) { p.append("a time or delta is not a number") }
    return p
  }

  /// The rate of the events that moved: 1000 / their median interval.
  public static func rate(_ events: [Event]) -> Double? {
    let moving = events.filter { $0.dx != 0 || $0.dy != 0 }
    let gaps = zip(moving.dropFirst(), moving).map { $0.t - $1.t }.filter { $0 > 0 }.sorted()
    guard !gaps.isEmpty else { return nil }
    let m = gaps.count % 2 == 1 ? gaps[gaps.count / 2] : (gaps[gaps.count / 2 - 1] + gaps[gaps.count / 2]) / 2
    return m > 0 ? (10000 / m).rounded() / 10 : nil
  }

  public static func read(_ url: URL) throws -> Gesture { try JSONDecoder().decode(Gesture.self, from: Data(contentsOf: url)) }

  public func encoded() -> Data {
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? e.encode(self)) ?? Data()
  }
}

/// Cuts a stream of scroll-wheel events into gestures. A gesture starts at the first event after the previous one
/// ended and ends at its momentum's end, or `quietS` after the fingers lifted with no momentum following (a slow drag),
/// or `quietS` after the last event of a wheel (no phases). A new touch (`mayBegin`, `began`) ends the gesture before it.
/// Gestures where nothing moved (fingers resting, then lifted) are dropped.
///
/// Times are seconds on any monotonic clock (`NSEvent.timestamp`). The host calls `idle(at:)` once `deadline` has
/// passed (a timer), since nothing else arrives to end a gesture whose momentum never came.
public final class GestureRecorder {
  public let name: String
  public let device: String?
  public var quietS: Double
  /// Called with each finished gesture, numbered from 1.
  public var finished: (Gesture, Int) -> Void
  public private(set) var count = 0
  private var events: [(t: Double, e: Gesture.Event)] = []
  private var fingerUp = false, momentum = false
  /// When `idle(at:)` should be called to end the open gesture, if it can end without another event.
  public private(set) var deadline: Double?

  public init(name: String, device: String? = nil, quietS: Double = 0.3, finished: @escaping (Gesture, Int) -> Void) {
    self.name = name; self.device = device; self.quietS = quietS; self.finished = finished
  }

  public var recording: Bool { !events.isEmpty }

  /// One scroll-wheel event's numbers. `phase` and `momentum` are `NSEvent.Phase` raw values.
  public func record(t: Double, dx: Double, dy: Double, phase: UInt, momentum m: UInt, precise: Bool) {
    let p = Gesture.Phase(rawBits: phase), mp = Gesture.Phase(rawBits: m)
    if let d = deadline, t >= d { finish() }
    if !events.isEmpty {
      let touch = p == .mayBegin || p == .began
      let wheelAfterGesture = p == .none && mp == .none && (fingerUp || momentum || events.contains { $0.e.finger })
      let phasedAfterWheel = (p != .none || mp != .none) && events.allSatisfy { !$0.e.finger && $0.e.momentum == .none }
      // A touch ends the gesture before it, unless it only rested the fingers so far (mayBegin, then began).
      let restingOnly = events.allSatisfy { $0.e.phase == .mayBegin }
      if (touch && !restingOnly && (fingerUp || momentum || p == .mayBegin)) || wheelAfterGesture || phasedAfterWheel { finish() }
    }
    events.append((t, Gesture.Event(t: 0, dx: dx, dy: dy, phase: p, momentum: mp, precise: precise)))
    if p.ends { fingerUp = true }
    if mp != .none { momentum = true }
    if mp.ends { finish(); return }
    deadline = p.ends || (p == .none && mp == .none) || p == .mayBegin ? t + quietS : nil
  }

  /// Ends the open gesture if its deadline has passed.
  public func idle(at t: Double) { if let d = deadline, t >= d { finish() } }

  /// Ends the open gesture now (the recording is stopping).
  public func finish() {
    defer { events = []; fingerUp = false; momentum = false; deadline = nil }
    guard let t0 = events.first?.t else { return }
    let es = events.map { x in var e = x.e; e.t = ((x.t - t0) * 1000 * 1000).rounded() / 1000; return e }
    guard es.contains(where: { $0.dx != 0 || $0.dy != 0 }) else { return }
    count += 1
    let phased = es.contains { $0.finger || $0.momentum != .none }
    let dev = device ?? (phased && es.contains(where: \.precise) ? "trackpad" : "mouse")
    let iso = ISO8601DateFormatter().string(from: Date())
    finished(Gesture(name: count == 1 ? name : "\(name)-\(count)", recordedAt: iso, device: dev, hz: Gesture.rate(es), events: es), count)
  }
}
