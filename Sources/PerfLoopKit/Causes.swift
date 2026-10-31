import Foundation

/// "Why did this body run" (CAPABILITIES.md C7), read out of a run result: the causes an adapter wrote on its steps
/// (`reps[].steps[].causes[]`) and long stretches (`reps[].worstStretches[].causes[]`), each `{ keyPath, count, ids?,
/// bodies }`. Read loosely, like `Readings`: any adapter that records mutations gets the table, one that doesn't gets
/// a sentence saying so.
public enum CauseTable {
  /// One key path's share, summed over windows.
  public struct Row: Codable, Sendable, Equatable {
    public var keyPath: String
    public var count: Int
    public var ids: Int?
    public var bodies: [String: Int]
    /// Distinct objects among the bodies, by view (views probed with an id).
    public var objects: [String: Int]?
    public var bodyTotal: Int { bodies.values.reduce(0, +) }
  }
  /// One window (a step or a stretch) and its causes.
  public struct Window: Codable, Sendable, Equatable {
    public var rep: Int
    public var name: String
    public var durationMs: Double?
    public var causes: [Row]
  }
  public struct Table: Codable, Sendable, Equatable {
    public var schema = "perfloop.causes/1"
    public var scenario: String?
    public var fixture: String?
    public var reps: Int
    /// Every step's causes, summed per key path.
    public var steps: [Row]
    public var perStep: [Window]
    /// The worst stretches, longest first.
    public var stretches: [Window]
  }

  static let unrecorded = "(unrecorded)"

  public static func rows(_ v: JSONValue?) -> [Row]? {
    guard let a = v?.array else { return nil }
    return a.compactMap { c in
      guard let k = c["keyPath"]?.string else { return nil }
      var b: [String: Int] = [:]
      for (view, n) in c["bodies"]?.object ?? [:] { b[view] = Int(n.double ?? 0) }
      let o = c["objects"]?.object.map { $0.compactMapValues { $0.double.map { Int($0) } } }
      return Row(keyPath: k, count: Int(c["count"]?.double ?? 0), ids: c["ids"]?.double.map { Int($0) }, bodies: b, objects: o)
    }
  }

  /// Rows summed per key path (ids: the most in any one window), heaviest first.
  public static func merge(_ lists: [[Row]]) -> [Row] {
    var by: [String: Row] = [:]
    for l in lists {
      for r in l {
        var m = by[r.keyPath] ?? Row(keyPath: r.keyPath, count: 0, ids: nil, bodies: [:])
        m.count += r.count
        if let n = r.ids { m.ids = max(m.ids ?? 0, n) }
        m.bodies.merge(r.bodies, uniquingKeysWith: +)
        if let o = r.objects { m.objects = (m.objects ?? [:]).merging(o, uniquingKeysWith: max) }
        by[r.keyPath] = m
      }
    }
    return by.values.sorted { ($0.bodyTotal, $0.count, $1.keyPath) > ($1.bodyTotal, $1.count, $0.keyPath) }
  }

  /// nil when the result carries no causes at all (the adapter doesn't record mutations, or predates them).
  public static func table(_ v: JSONValue) -> Table? {
    let reps = v["reps"]?.array ?? []
    var perStep: [Window] = [], stretches: [Window] = []
    var any = false
    for (i, r) in reps.enumerated() {
      let rep = Int(r["index"]?.double ?? Double(i))
      for s in r["steps"]?.array ?? [] {
        guard let c = rows(s["causes"]) else { continue }
        any = true
        perStep.append(Window(rep: rep, name: s["name"]?.string ?? "?", durationMs: s["durationMs"]?.double, causes: c))
      }
      for w in r["worstStretches"]?.array ?? [] {
        guard let c = rows(w["causes"]) else { continue }
        any = true
        stretches.append(Window(rep: rep, name: w["step"]?.string ?? "?", durationMs: w["durationMs"]?.double, causes: c))
      }
    }
    guard any else { return nil }
    stretches.sort { ($0.durationMs ?? 0) > ($1.durationMs ?? 0) }
    return Table(scenario: v["scenario"]?.string, fixture: v["fixture"]?.string, reps: reps.count, steps: merge(perStep.map(\.causes)), perStep: perStep, stretches: stretches)
  }

  /// Key paths charged with the same bodies (set in the same updates) as one group, heaviest first:
  /// `AgentSlice.onScreen×6 + AgentSlice.focused×2 → CrewTab×6, Column×2`.
  public static func groups(_ rs: [Row]) -> [(keys: [Row], bodies: [String: Int], objects: [String: Int]?)] {
    var out: [(keys: [Row], bodies: [String: Int], objects: [String: Int]?)] = []
    for r in rs { if let i = out.firstIndex(where: { $0.bodies == r.bodies }) { out[i].keys.append(r) } else { out.append(([r], r.bodies, r.objects)) } }
    for i in out.indices { out[i].keys.sort { ($0.count, $1.keyPath) > ($1.count, $0.keyPath) } }
    return out.sorted { ($0.bodies.values.reduce(0, +), $0.keys.count) > ($1.bodies.values.reduce(0, +), $1.keys.count) }
  }

  /// `Column×34 (17 distinct), CrewTab×4`.
  static func bodies(_ b: [String: Int], objects: [String: Int]? = nil, limit: Int = 6) -> String {
    let xs = b.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
    return xs.prefix(limit).map { x in "\(x.key)×\(x.value)" + (objects?[x.key].flatMap { $0 < x.value ? " (\($0) distinct)" : nil } ?? "") }
      .joined(separator: ", ") + (xs.count > limit ? ", …" : "")
  }

  /// `keys → bodies` groups on one line.
  public static func line(_ rs: [Row], groups limit: Int = 4) -> String {
    if rs.isEmpty { return "no bodies" }
    let gs = groups(rs)
    var parts = gs.prefix(limit).map { g in
      g.keys.map { $0.keyPath == unrecorded ? $0.keyPath : "\($0.keyPath)×\($0.count)" }.joined(separator: " + ") + " → " + bodies(g.bodies, objects: g.objects, limit: 5)
    }
    if gs.count > limit { parts.append("+\(gs.count - limit) more") }
    return parts.joined(separator: " · ")
  }

  /// The whole table as text, for `perfloop causes`.
  public static func text(_ v: JSONValue, stretches limit: Int = 12) -> String {
    let title = [v["scenario"]?.string, v["fixture"]?.string.map { "on \($0)" }].compactMap { $0 }.joined(separator: " ")
    guard let t = table(v) else {
      return "\(title.isEmpty ? "this result" : title): no causes recorded (the adapter records no model mutations, or predates them; CAPABILITIES.md C7)"
    }
    var o = ["causes\(title.isEmpty ? "" : " in \(title)"), \(t.reps) rep\(t.reps == 1 ? "" : "s"): each update's bodies are charged to the model mutations recorded since the previous update (coarse: a run-loop turn, not a dependency edge); \(unrecorded) = bodies with no mutation recorded before them (environment, layout, an unrecorded property)"]
    o.append("")
    o.append("steps, all reps (sets · objects · bodies charged):")
    let w = max(24, t.steps.map(\.keyPath.count).max() ?? 0)
    for r in t.steps {
      o.append("  " + r.keyPath.padding(toLength: w, withPad: " ", startingAt: 0) + " " + left(String(r.count), 5) + "  " + left(r.ids.map(String.init) ?? "-", 5) + "  " + bodies(r.bodies, limit: 8))
    }
    if t.steps.isEmpty { o.append("  no bodies in the steps") }
    o.append("")
    o.append("by step:")
    for s in t.perStep { o.append("  rep \(s.rep) \(s.name)\(s.durationMs.map { " (\(fmt($0)) ms)" } ?? ""): " + line(s.causes)) }
    if !t.stretches.isEmpty {
      o.append("")
      o.append("longest stretches:")
      for s in t.stretches.prefix(limit) { o.append("  \(s.durationMs.map { fmt($0) } ?? "?") ms  rep \(s.rep) \(s.name.hasPrefix("before ") || s.name.hasPrefix("after ") ? s.name : "during \(s.name)"): " + line(s.causes)) }
    }
    return o.joined(separator: "\n")
  }

  static func left(_ s: String, _ n: Int) -> String { String(repeating: " ", count: max(0, n - s.count)) + s }
  static func fmt(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(Stats.round(x, 1)) }
}
