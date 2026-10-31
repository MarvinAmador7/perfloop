import Foundation

// "Why did this body run" (CAPABILITIES.md C7): the app records which observed model property it set, a bench
// charges the view bodies SwiftUI evaluates next to those records, and each long stretch and step says which
// mutations its bodies followed.
//
// The app calls `Mutations.record` where a property that drives bodies is set (a `didSet`, or the equality-guarded
// setter that assigns it):
//
//     package private(set) var onScreen = false { didSet { Mutations.record("AgentSlice.onScreen", id: id) } }
//
// With no sink attached (the app as it ships) a call is one load of a nil and a branch, so behaviour and cost are as
// before. A bench attaches a `CauseRecorder` before it shows the window.
//
// Attribution is coarse on purpose: per update, not per dependency edge. `@Observable` says nothing about which key
// path invalidated which view, so bodies in an update are charged to every mutation since the previous update (the
// update being the bodies evaluated in one run-loop turn). That answers "a tab click re-evaluated Column×17 because
// `onScreen` and `focused` changed"; changes SwiftUI tracks through the environment or preferences are not recorded
// and their bodies show as `(unrecorded)`.

/// Where `Mutations.record` goes. Main thread: the models whose changes drive bodies are main-actor models.
@MainActor public protocol MutationSink: AnyObject {
  func mutation(_ keyPath: StaticString)
  /// The same, for a property of one of many objects (`id` names it: an agent's slice).
  func mutation(_ keyPath: StaticString, id: String)
}

@MainActor public enum Mutations {
  public static var sink: (any MutationSink)?
  /// `keyPath` names the property as `Type.property` ("DeskModel.focusedAgent").
  @inline(__always) public static func record(_ keyPath: StaticString) { if let s = sink { s.mutation(keyPath) } }
  @inline(__always) public static func record(_ keyPath: StaticString, id: String) { if let s = sink { s.mutation(keyPath, id: id) } }
}

/// One key path's share of a window's bodies (`steps[].causes[]`, `worstStretches[].causes[]`).
public struct Cause: Codable, Sendable, Equatable {
  /// `Type.property`; `(unrecorded)` for bodies evaluated with no recorded mutation since the previous update.
  public var keyPath: String
  /// How many times it was set in the updates whose bodies fell in the window (0 for `(unrecorded)`).
  public var count: Int
  /// How many distinct objects it was set on, when recorded with ids (agents, for a per-agent slice).
  public var ids: Int?
  /// The bodies evaluated in those updates, by view type. A body is charged to every key path of its update, so
  /// two key paths set together list the same bodies.
  public var bodies: [String: Int]
  /// For views probed with an id (one per agent): how many distinct ones those bodies were, by view type. `Column×34`
  /// with `Column: 17` is every one of 17 columns, twice.
  public var objects: [String: Int]?
  public init(keyPath: String, count: Int, ids: Int? = nil, bodies: [String: Int], objects: [String: Int]? = nil) {
    self.keyPath = keyPath; self.count = count; self.ids = ids; self.bodies = bodies; self.objects = objects
  }

  public static let unrecorded = "(unrecorded)"
  public var bodyTotal: Int { bodies.values.reduce(0, +) }
}

/// The bench's sink: mutations grouped into updates, and bodies charged to them, with times so any window (a step, a
/// stretch) can be asked for its causes afterwards.
///
/// The rule: mutations collect in an open update. A body is charged to the open update (or to `(unrecorded)` when
/// there is none). A mutation after bodies were charged starts a new update (a body's side effect, or the next
/// event). At the end of a run-loop turn (`turnEnded`, from the bench's `beforeWaiting` observer), an update that
/// has bodies is closed; one without bodies stays open, so mutations whose update SwiftUI defers to a later turn
/// still own its bodies.
@MainActor public final class CauseRecorder: MutationSink {
  struct Update { var keys: [String: Int] = [:]; var ids: [String: Set<String>] = [:] }
  struct Charge { var t: Double; var update: Int32; var view: String; var id: String? }

  private let clock: () -> Double
  private var updates: [Update] = []
  private var charges: [Charge] = []
  private var open: Int?
  private var charged = false

  /// `clock`: the bench's time base (the same ms its stretches and steps use).
  public init(clock: @escaping () -> Double) { self.clock = clock }

  public func mutation(_ keyPath: StaticString) { record(keyPath.description, id: nil) }
  public func mutation(_ keyPath: StaticString, id: String) { record(keyPath.description, id: id) }

  public func record(_ keyPath: String, id: String?) {
    if open == nil || charged { updates.append(Update()); open = updates.count - 1; charged = false }
    updates[open!].keys[keyPath, default: 0] += 1
    if let id { updates[open!].ids[keyPath, default: []].insert(id) }
  }

  /// A body was evaluated (the bench's body probe calls this); `id` for a view that belongs to one object.
  public func body(_ view: String, id: String? = nil, at t: Double? = nil) {
    charges.append(Charge(t: t ?? clock(), update: open.map { Int32($0) } ?? -1, view: view, id: id))
    if open != nil { charged = true }
  }

  /// The run loop is about to sleep: the update that ran in this turn is over.
  public func turnEnded() { if charged { open = nil; charged = false } }

  public var bodyCount: Int { charges.count }
  public var mutationCount: Int { updates.reduce(0) { $0 + $1.keys.values.reduce(0, +) } }

  /// The causes of the bodies evaluated in `from...to`, heaviest first (bodies charged, then sets, then name).
  public func causes(from a: Double, to b: Double) -> [Cause] {
    // Charges are appended in time order: find the first at or after `a`.
    var lo = 0, hi = charges.count
    while lo < hi { let mid = (lo + hi) / 2; if charges[mid].t < a { lo = mid + 1 } else { hi = mid } }
    var byUpdate: [Int32: [String: Int]] = [:], idsByUpdate: [Int32: [String: Set<String>]] = [:]
    var i = lo
    while i < charges.count, charges[i].t <= b {
      let c = charges[i]
      byUpdate[c.update, default: [:]][c.view, default: 0] += 1
      if let id = c.id { idsByUpdate[c.update, default: [:]][c.view, default: []].insert(id) }
      i += 1
    }
    var out: [String: Cause] = [:]
    var seen: [String: Set<String>] = [:], withIds: Set<String> = []
    var objects: [String: [String: Set<String>]] = [:]
    func charge(_ k: String, _ n: Int, _ u: Int32, _ bodies: [String: Int]) {
      var c = out[k] ?? Cause(keyPath: k, count: 0, bodies: [:])
      c.count += n
      c.bodies.merge(bodies, uniquingKeysWith: +)
      out[k] = c
      for (view, ids) in idsByUpdate[u] ?? [:] { objects[k, default: [:]][view, default: []].formUnion(ids) }
    }
    for (u, bodies) in byUpdate {
      guard u >= 0 else { charge(Cause.unrecorded, 0, u, bodies); continue }
      let up = updates[Int(u)]
      for (k, n) in up.keys {
        charge(k, n, u, bodies)
        if let ids = up.ids[k] { seen[k, default: []].formUnion(ids); withIds.insert(k) }
      }
    }
    for k in withIds { out[k]?.ids = seen[k]?.count }
    for (k, o) in objects { out[k]?.objects = o.mapValues(\.count) }
    return out.values.sorted { ($0.bodyTotal, $0.count, $1.keyPath) > ($1.bodyTotal, $1.count, $0.keyPath) }
  }
}
