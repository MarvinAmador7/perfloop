import Foundation

/// Reads the numbers acceptance needs out of what an adapter prints: `ab --json` (`deskbench.ab/1`) and `run --json`
/// (`deskbench.result/1`, `perfloop.result/2`). Loose on purpose: paths are looked up, never a full schema decoded, so a
/// field the adapter adds changes nothing and a field it lacks (an older bench) falls back to what can be derived.
public enum Readings {
  /// One rep (`reps[]` of a result): the objective from its raw parts, so results from benches older than the
  /// objective (the session's v1–v5) still give CPU ms per step.
  public static func side(rep r: JSONValue, metric: String) -> Side {
    let steps = r["steps"]?.array ?? []
    func perStep(_ total: Double?) -> Double? { guard let t = total, !steps.isEmpty else { return nil }; return Stats.round(t / Double(steps.count), 2) }
    var value: Double?
    switch metric {
    case "mainThreadCpuMsPerStep": value = r["cpuMsPerStep"]?.double ?? perStep(r.at("mainThread.cpuMs")?.double)
    case "instructionsPerStep":
      let xs = steps.compactMap { $0["instructions"]?.double }
      value = !steps.isEmpty && xs.count == steps.count && xs.reduce(0, +) > 0 ? (xs.reduce(0, +) / Double(steps.count)).rounded() : nil
    case "latencyMs":
      let xs = steps.compactMap { $0["latencyMs"]?.double }
      value = xs.isEmpty ? nil : Stats.median(xs)
    case "hitchTimeRatioMsPerS": value = r.at("frames.hitchTimeRatioMsPerS")?.double
    default: value = r[metric]?.double ?? r.at(metric)?.double
    }
    var s = Side(objective: value, hitch: r.at("frames.hitchTimeRatioMsPerS")?.double, longest: r.at("mainThread.longestMs")?.double,
                 checksFailed: (r["checks"]?.array ?? []).filter { $0["pass"]?.bool == false }.compactMap { $0["name"]?.string })
    if let w = r["window"], w.object != nil {
      s.trustworthy = (w["appActive"]?.bool ?? false) && (w["keyWindow"]?.bool ?? false) && (w["visible"]?.bool ?? false) && !(w["occluded"]?.bool ?? true)
    }
    s.steadyHz = r.at("frames.steadyHz")?.double; s.lateFrames = r.at("frames.late")?.double
    s.worstStretch = worst(r["worstStretches"]?.array ?? [])
    s.guards = r["guards"]?.array.map { $0.compactMap(GuardResult.init(json:)) }
    s.positionErrorP95Pt = r.at("smoothness.positionErrorP95Pt")?.double; s.stalls = r.at("smoothness.stalls")?.double; s.jerkP95 = r.at("smoothness.jerkP95")?.double
    return s
  }

  /// A summary (`summary`, `summaryA`): medians only. With one rep a side (how the runner calls `ab`) they are the
  /// rep's own values.
  public static func side(summary v: JSONValue, metric: String) -> Side {
    func med(_ k: String) -> Double? { v[k]?["median"]?.double ?? v[k]?.double }
    var value: Double?
    if let o = v["objective"], o["name"]?.string == metric { value = o["value"]?.double }
    value = value ?? med(metric)
    var s = Side(objective: value, hitch: med("hitchTimeRatioMsPerS"), longest: med("longestStretchMs"), checksFailed: v["checksFailed"]?.strings ?? [])
    s.steadyHz = med("steadyHz"); s.lateFrames = med("lateFrames")
    func smooth(_ k: String) -> Double? { v["smoothness"]?[k]?["median"]?.double }
    s.positionErrorP95Pt = smooth("positionErrorP95Pt"); s.stalls = smooth("stalls"); s.jerkP95 = smooth("jerkP95")
    return s
  }

  /// A whole `run --json` result: its reps, or its summary when it has none.
  public static func sides(run v: JSONValue, metric: String) -> [Side] {
    var out = (v["reps"]?.array ?? []).map { side(rep: $0, metric: metric) }
    if out.isEmpty, let s = v["summary"] { out = [side(summary: s, metric: metric)] }
    if v["profiled"]?.bool == true { for i in out.indices { out[i].profiled = true } }
    return out
  }

  /// `ab --json`: the sides for one label ("A" or "B"). Per-rep records when the adapter includes them (`repsA`,
  /// `reps[]` with `variant`), else the label's summary.
  public static func sides(ab v: JSONValue, label: String, metric: String) -> [Side] {
    if let rs = v["reps" + label]?.array, !rs.isEmpty { return rs.map { side(rep: $0, metric: metric) } }
    if let rs = v["reps"]?.array?.filter({ $0["variant"]?.string == label }), !rs.isEmpty { return rs.map { side(rep: $0, metric: metric) } }
    guard let s = v["summary" + label] else { return [] }
    if (s["reps"]?.double ?? 1) == 0 { return [] }
    var one = side(summary: s, metric: metric)
    // The side's guards, every rep's (deskbench `guardsA`/`guardsB`).
    one.guards = v["guards" + label]?.array.map { $0.compactMap(GuardResult.init(json:)) }
    return [one]
  }

  /// What went wrong in an `ab`, if anything (its `failures[]`).
  public static func failures(ab v: JSONValue) -> [String] { v["failures"]?.strings ?? [] }

  /// The build an `ab` reports for a label (`buildA`), to check it ran what the store says it did.
  public static func build(ab v: JSONValue, label: String) -> Build? { Build(json: v["build" + label]) }

  static func worst(_ ss: [JSONValue]) -> StretchNote? {
    guard let w = ss.max(by: { ($0["durationMs"]?.double ?? 0) < ($1["durationMs"]?.double ?? 0) }), let d = w["durationMs"]?.double else { return nil }
    func names(_ k: String) -> [String] {
      (w[k]?.array ?? []).prefix(5).compactMap { e in
        guard let sym = e["symbol"]?.string else { return nil }
        var s = sym
        if let n = e["samples"]?.double { s += " ×\(Int(n))" }
        if let u = e["under"]?.string { s += " under \(u)" }
        return s
      }
    }
    var n = StretchNote(durationMs: d, step: w["step"]?.string, topOurs: names("topOurs"), topFramework: names("topFramework"))
    n.causes = CauseTable.rows(w["causes"]).map { CauseTable.line($0, groups: 3) }
    return n
  }
}
