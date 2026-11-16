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
    window(r["window"], into: &s)
    machine(r, into: &s)
    s.steadyHz = r.at("frames.steadyHz")?.double; s.lateFrames = r.at("frames.late")?.double
    s.worstStretch = worst(r["worstStretches"]?.array ?? [])
    s.guards = r["guards"]?.array.map { $0.compactMap(GuardResult.init(json:)) }
    s.positionErrorP95Pt = r.at("smoothness.positionErrorP95Pt")?.double; s.stalls = r.at("smoothness.stalls")?.double; s.jerkP95 = r.at("smoothness.jerkP95")?.double
    if let f = r["frames"], f.object != nil, drewNothing(ticks: f["ticks"]?.double, p95: f["p95Ms"]?.double) { noFrames(&s, metric: metric) }
    return s
  }

  /// A rep that presented no frame (the screen locked, the window off-screen or never shown) has no frame metrics: a
  /// hitch ratio of 0 there is nothing drawing, not a perfect run. Known by the display-link tick count, or, from an
  /// adapter that doesn't report it, a frame p95 of 0 ms (no real frame takes 0 ms). This was PerfLoopHost's "the
  /// window drew no frame" rule; here it holds for every adapter.
  static func drewNothing(ticks: Double?, p95: Double?) -> Bool {
    if let t = ticks { return t == 0 }
    if let p = p95 { return p == 0 }
    return false
  }

  static func noFrames(_ s: inout Side, metric: String) {
    s.noFrames = true
    s.hitchTimeRatioMsPerS = nil; s.lateFrames = nil; s.steadyHz = nil
    if ["hitchTimeRatioMsPerS", "lateFrames", "steadyHz"].contains(metric) { s.objective = nil }
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
    // deskbench's summary has no tick count, only the frame p95 (`frameP95Ms`); the summary of a side with one rep.
    if v["frameP95Ms"] != nil || v["frameTicks"] != nil, drewNothing(ticks: med("frameTicks"), p95: med("frameP95Ms")) { noFrames(&s, metric: metric) }
    return s
  }

  /// A whole `run --json` result: its reps, or its summary when it has none. What the result says once for every rep
  /// (a top-level `window`, `quiet`, deskbench's `noise.quiet`, `exitCode`) fills in what a rep doesn't say itself.
  public static func sides(run v: JSONValue, metric: String) -> [Side] {
    var out = (v["reps"]?.array ?? []).map { side(rep: $0, metric: metric) }
    if out.isEmpty, let s = v["summary"] { out = [side(summary: s, metric: metric)] }
    if v["profiled"]?.bool == true { for i in out.indices { out[i].profiled = true } }
    var top = Side(objective: nil)
    window(v["window"], into: &top); machine(v, into: &top)
    if top.quiet == nil, let q = v.at("noise.quiet")?.bool { top.quiet = q; if !q { top.busy = v.at("noise.reasons")?.strings } }
    for i in out.indices {
      if out[i].trustworthy == nil { out[i].trustworthy = top.trustworthy; out[i].windowFailed = top.windowFailed }
      if out[i].quiet == nil { out[i].quiet = top.quiet; out[i].busyPct = out[i].busyPct ?? top.busyPct; out[i].busy = out[i].busy ?? top.busy }
      out[i].exit = out[i].exit ?? v["exitCode"]?.double.map { Int($0) }
    }
    return out
  }

  /// `ab --json`: the sides for one label ("A" or "B"). Per-rep records when the adapter includes them (`repsA`,
  /// `reps[]` with `variant`), else the label's summary.
  public static func sides(ab v: JSONValue, label: String, metric: String) -> [Side] {
    let ran = runs(ab: v, label: label)
    // Per-rep records, each with its own run's exit and quiet when `runs[]` lines up with them.
    func withRuns(_ rs: [JSONValue]) -> [Side] {
      rs.enumerated().map { i, r in trust(of: ran.count == rs.count ? [ran[i]] : ran, into: side(rep: r, metric: metric)) }
    }
    if let rs = v["reps" + label]?.array, !rs.isEmpty { return withRuns(rs) }
    if let rs = v["reps"]?.array?.filter({ $0["variant"]?.string == label }), !rs.isEmpty { return withRuns(rs) }
    guard let s = v["summary" + label] else { return [] }
    if (s["reps"]?.double ?? 1) == 0 { return [] }
    var one = side(summary: s, metric: metric)
    // The side's guards, every rep's (deskbench `guardsA`/`guardsB`).
    one.guards = v["guards" + label]?.array.map { $0.compactMap(GuardResult.init(json:)) }
    return [trust(of: ran, into: one)]
  }

  /// The label's processes as `ab` ran them (`runs[]` with `side`: deskbench's `pair`, `exit`, `quiet`, `busyPct`,
  /// `builds`, and `window` when the adapter adds it).
  static func runs(ab v: JSONValue, label: String) -> [JSONValue] { (v["runs"]?.array ?? []).filter { $0["side"]?.string == label } }

  /// A summary side and the runs it summarises: untrusted when any of them was. Their exit code (5 wins: the bench's
  /// own "untrusted"), quiet when all were, the busiest share and every busy process, the window fields any got wrong.
  static func trust(of runs: [JSONValue], into s: Side) -> Side {
    var s = s
    guard !runs.isEmpty else { return s }
    var each: [Side] = runs.map { r in
      var x = Side(objective: nil)
      window(r["window"], into: &x); machine(r, into: &x)
      x.exit = (r["exit"] ?? r["exitCode"])?.double.map { Int($0) }
      return x
    }
    if each.contains(where: { $0.exit != nil }) { s.exit = each.compactMap(\.exit).contains(5) ? 5 : each.compactMap(\.exit).max() }
    let qs = each.compactMap(\.quiet)
    if !qs.isEmpty { s.quiet = !qs.contains(false) }
    let busy = each.compactMap(\.busyPct)
    if !busy.isEmpty { s.busyPct = busy.max() }
    let names = each.flatMap { $0.busy ?? [] }
    if !names.isEmpty { s.busy = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
    each = each.filter { $0.trustworthy != nil }
    if !each.isEmpty {
      let failed = ((s.windowFailed ?? []) + each.flatMap { $0.windowFailed ?? [] }).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
      s.trustworthy = failed.isEmpty; s.windowFailed = failed.isEmpty ? nil : failed
    }
    return s
  }

  /// The window fields a rep needs right (`window { appActive, keyWindow, visible, occluded }`): any that isn't makes
  /// the rep untrusted, and the field names say which.
  static func window(_ w: JSONValue?, into s: inout Side) {
    guard let w, w.object != nil else { return }
    var failed: [String] = []
    if w["appActive"]?.bool != true { failed.append("appActive") }
    if w["keyWindow"]?.bool != true { failed.append("keyWindow") }
    if w["visible"]?.bool != true { failed.append("visible") }
    if w["occluded"]?.bool != false { failed.append("occluded") }
    s.trustworthy = failed.isEmpty; s.windowFailed = failed.isEmpty ? nil : failed
  }

  /// Whether the machine was quiet when the rep started: `quiet`, `busyPct`, and what kept it busy (`busy`, deskbench's
  /// `builds`).
  static func machine(_ r: JSONValue, into s: inout Side) {
    if let q = r["quiet"]?.bool { s.quiet = q }
    if let b = r["busyPct"]?.double { s.busyPct = b }
    if let n = (r["busy"] ?? r["builds"])?.strings, !n.isEmpty { s.busy = n }
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
