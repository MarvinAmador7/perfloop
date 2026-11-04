import Foundation

// Synthetic gestures (CAPABILITIES.md C9): trackpad swipes a program made, for a bench to replay when no recording of a
// hand exists yet, and to check the replay pipeline itself. Made from deskbench's fling curves, on either axis: fingers
// down for 6 frames of growing motion then lifted, the system's momentum decaying 4 % a frame to 20 pt/s; or a slow
// drag with no momentum. 120 Hz, whole points (what a CGEvent carries). No hand made them: they test the pipeline and
// what a frame costs while content moves, not feel.

public enum SyntheticGestures {
  /// `synthetic:NAME` names one of `all`; anything else is a file.
  public static let prefix = "synthetic:"

  public enum Axis: String, Sendable { case x, y }

  /// Forward is what the fingers do to move on through the content (left on x, up on y, with natural scrolling): the
  /// deltas are negative, and a flipped document's offset grows.
  public static let all: [Gesture] = [
    flick(name: "synthetic-flick-forward", axis: .x, sign: -1, velocity: 2400),
    flick(name: "synthetic-flick-back", axis: .x, sign: 1, velocity: 2400),
    drag(name: "synthetic-drag-forward", axis: .x, sign: -1, ptPerFrame: 4, frames: 48),
    flick(name: "synthetic-scroll-down", axis: .y, sign: -1, velocity: 2400),
    flick(name: "synthetic-scroll-up", axis: .y, sign: 1, velocity: 2400),
    drag(name: "synthetic-drag-down", axis: .y, sign: -1, ptPerFrame: 4, frames: 48),
  ]

  /// How a scenario's `gesture` parameter names one: `synthetic:scroll-down`.
  public static func spec(_ g: Gesture) -> String { prefix + (g.name.hasPrefix("synthetic-") ? String(g.name.dropFirst("synthetic-".count)) : g.name) }
  public static var specs: [String] { all.map(spec) }

  public static func named(_ s: String) -> Gesture? {
    let n = s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : s
    return all.first { $0.name == n || $0.name == "synthetic-" + n }
  }

  /// A gesture from `synthetic:NAME` or a `perfloop.gesture/1` file (`~` expanded); the error says what was wrong.
  public static func load(_ spec: String) throws -> Gesture {
    if spec.hasPrefix(prefix) {
      guard let g = named(spec) else { throw GestureLoadError("no synthetic gesture '\(spec)'; there are: " + specs.joined(separator: ", ")) }
      return g
    }
    let path = spec == "~" || spec.hasPrefix("~/") ? FileManager.default.homeDirectoryForCurrentUser.path + spec.dropFirst() : spec
    let g: Gesture
    do { g = try Gesture.read(URL(fileURLWithPath: path)) } catch { throw GestureLoadError("\(spec): not a perfloop.gesture/1 file (\(error))") }
    let p = g.problems
    if !p.isEmpty { throw GestureLoadError("\(spec): " + p.joined(separator: "; ")) }
    return g
  }

  static let frameMs = 1000.0 / 120

  /// Whole points out of a fractional curve, the rounding carried over so the sum stays within half a point.
  static func whole(_ xs: [Double]) -> [Double] {
    var acc = 0.0, sent = 0.0
    return xs.map { x in acc += x; let d = acc.rounded() - sent; sent += d; return d }
  }

  static func event(_ t: Double, _ d: Double, _ axis: Axis, phase: Gesture.Phase, momentum: Gesture.Phase = .none) -> Gesture.Event {
    Gesture.Event(t: (t * 1000).rounded() / 1000, dx: axis == .x ? d : 0, dy: axis == .y ? d : 0, phase: phase, momentum: momentum)
  }

  /// A flick: began, 6 frames growing to v/120 a frame, ended, then momentum from v decaying 4 % a frame to 20 pt/s.
  public static func flick(name: String, axis: Axis, sign: Double, velocity v0: Double) -> Gesture {
    let finger = whole((1...6).map { k in sign * v0 / 120 * Double(k) / 6 })
    var vs: [Double] = [v0], v = v0
    while v > 20 { v *= 0.96; vs.append(v) }
    let momentum = whole(vs.map { sign * $0 / 120 })
    var es = [event(0, 0, axis, phase: .mayBegin), event(frameMs, 0, axis, phase: .began)]
    for (k, d) in finger.enumerated() { es.append(event(Double(k + 2) * frameMs, d, axis, phase: .changed)) }
    var t = Double(finger.count + 2) * frameMs
    es.append(event(t, 0, axis, phase: .ended))
    for (k, d) in momentum.enumerated() { t += frameMs; es.append(event(t, d, axis, phase: .none, momentum: k == 0 ? .began : .changed)) }
    t += frameMs; es.append(event(t, 0, axis, phase: .none, momentum: .ended))
    return Gesture(name: name, device: "trackpad", hz: 120, synthetic: true,
                   source: "flick on \(axis.rawValue): 6 frames to \(Int(v0)) pt/s \(sign < 0 ? "forward" : "back"), momentum −4 %/frame to 20 pt/s, 120 Hz", events: es)
  }

  /// A slow, steady drag: ramps up over 6 frames, holds `ptPerFrame`, ramps down over 6, lifted without momentum.
  public static func drag(name: String, axis: Axis, sign: Double, ptPerFrame p: Double, frames n: Int) -> Gesture {
    let ramp = 6
    let curve = (0..<n).map { k -> Double in
      let up = min(1, Double(k + 1) / Double(ramp)), down = min(1, Double(n - k) / Double(ramp))
      return sign * p * min(up, down)
    }
    var es = [event(0, 0, axis, phase: .mayBegin), event(frameMs, 0, axis, phase: .began)]
    for (k, d) in whole(curve).enumerated() { es.append(event(Double(k + 2) * frameMs, d, axis, phase: .changed)) }
    es.append(event(Double(n + 2) * frameMs, 0, axis, phase: .ended))
    return Gesture(name: name, device: "trackpad", hz: 120, synthetic: true,
                   source: "drag on \(axis.rawValue): \(Int(p * 120)) pt/s \(sign < 0 ? "forward" : "back") for \(n) frames, ramped over 6 at each end, no momentum, 120 Hz", events: es)
  }
}

public struct GestureLoadError: Error, CustomStringConvertible, Sendable {
  public var description: String
  public init(_ s: String) { description = s }
}
