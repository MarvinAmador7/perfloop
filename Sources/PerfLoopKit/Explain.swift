import Foundation

/// An experiment as text for an agent: verdict, numbers, what to look at, the next command. Written to
/// `exp/<id>/explain.txt` after every state change, so one file is enough to decide the next step (C5).
public enum Explain {
  public static func experiment(_ e: Experiment, champion: Champion?, stop: [String] = []) -> String {
    var o: [String] = []
    o.append("exp \(e.id) · \(e.state.rawValue) · \(e.kind) · \(e.scenario) on \(e.fixture)" + (e.secondFixture.map { " (second fixture \($0))" } ?? ""))
    o.append("hypothesis: \(e.hypothesis)")
    if let p = e.parent { o.append("measured against: champion \(p.experiment) [\(p.build.line)]") }
    if let c = champion, c.experiment != e.parent?.experiment { o.append("current champion: \(c.experiment) [\(c.build.line)], chain \(c.chain)") }
    if let b = e.build { o.append("candidate: [\(b.line)]") }
    if let k = e.knobs, !k.isEmpty { o.append("knobs: " + k.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")) }
    if e.behaviourChange { o.append("behaviour change: declared; the owner approves it before promotion") }
    if let s = e.screen { o += stage("screen", s) }
    if let f = e.full { o += stage("full", f) }
    if let s = e.secondScreen { o.append("second fixture \(s.fixture): \(s.notWorse ? "not worse" : "WORSE") (median gain \(s.stage.medianGainPct.map { "\($0) %" } ?? "-"), band \(s.stage.band.map { "\($0) %" } ?? "-"))") }
    o += guardSections(e)
    if let last = e.full ?? e.screen { o += look(last) }
    for n in e.notes { o.append("note: " + n) }
    for s in stop { o.append("stop: " + s) }
    o.append("next: " + next(e))
    return o.joined(separator: "\n") + "\n"
  }

  static func stage(_ name: String, _ s: Stage) -> [String] {
    var o: [String] = []
    let use = s.pairs.filter { Acceptance.unusable($0) == nil }
    var head = "\(name): \(s.verdict.uppercased()) on \(s.metric), \(use.count) pair(s) (orders \(s.pairs.map(\.order).joined(separator: " ")))"
    if name == "screen" { head += ", candidate won \(s.wins)/\(use.count)" }
    if let g = s.medianGainPct { head += ", gain \(g) %" }
    if let b = s.band { head += ", band ±\(b) %" }
    if let p = s.mwuP { head += ", MWU p=\(p)" }
    if let p = s.signP { head += ", sign p=\(p)" }
    o.append(head)
    for p in s.pairs {
      if let why = Acceptance.unusable(p) { o.append("  pair \(p.index + 1) \(p.order): unusable: \(why)"); continue }
      o.append("  pair \(p.index + 1) \(p.order): champion \(fmt(p.a.objective)) · candidate \(fmt(p.b.objective)) (\(Stats.round(-Acceptance.gainPct(p.a.objective!, p.b.objective!), 1)) %)")
    }
    for (k, g) in (s.frameGuards ?? [:]).sorted(by: { $0.key < $1.key }) { o.append("  guard \(k): \(g.a) → \(g.b) (band ±\(g.bandPct) %) \(g.pass ? "pass" : "FAIL")") }
    o += guardLines(s)
    for r in s.reasons { o.append("  · " + r) }
    return o
  }

  /// What the numbers can't say on their own: a changed frame rate (H5) and where the candidate's time went.
  static func look(_ s: Stage) -> [String] {
    var o: [String] = []
    let use = s.pairs.filter { Acceptance.unusable($0) == nil }
    let ha = use.compactMap(\.a.steadyHz), hb = use.compactMap(\.b.steadyHz)
    if !ha.isEmpty, !hb.isEmpty, Stats.median(ha) != Stats.median(hb) {
      let la = use.compactMap(\.a.lateFrames), lb = use.compactMap(\.b.lateFrames)
      var line = "rate changed \(fmt(Stats.median(ha))) → \(fmt(Stats.median(hb))) Hz: late-frame counts are not comparable"
      if !la.isEmpty, !lb.isEmpty { line += " (lateFrames \(fmt(Stats.median(la))) → \(fmt(Stats.median(lb))) is information, not a verdict)" }
      o.append(line + "; hitch time ratio and \(s.metric) decide")
    }
    if let w = use.compactMap(\.b.worstStretch).max(by: { $0.durationMs < $1.durationMs }) {
      o.append("candidate's worst stretch: \(fmt(w.durationMs)) ms" + (w.step.map { " in \($0)" } ?? ""))
      if !w.topOurs.isEmpty { o.append("  ours: " + w.topOurs.joined(separator: "; ")) }
      if !w.topFramework.isEmpty { o.append("  framework: " + w.topFramework.joined(separator: "; ")) }
    }
    return o
  }

  public static func next(_ e: Experiment) -> String {
    switch e.state {
    case .new: return "give it a build: perfloop exp new … --bench PATH (or --build-cmd CMD --bench PATH)"
    case .built, .screened: return "perfloop exp screen \(e.id)"
    case .promising: return "perfloop exp full \(e.id)"
    case .full: return "perfloop exp full \(e.id) (resumes at the first missing pair)"
    case .rejected: return "drop it and try the next idea; the worst stretch above is where the time went"
    case .lost: return e.full?.regression == true ? "drop it: the candidate is slower" : "drop it, or narrow the hypothesis and try again"
    case .needsReview:
      if let r = (e.full ?? e.screen)?.guardReviews, !r.isEmpty {
        return "the owner looks at the snapshots (the guards lines above list both PNGs and the diff): perfloop guards --exp \(e.id) --guard-tolerance X --owner to accept the look, or abandon it"
      }
      return "the owner decides (no decision at 10 + 10, or a guard asks for review); perfloop exp promote \(e.id) --owner, or abandon it"
    case .won:
      var s = "perfloop exp promote \(e.id)"
      if e.behaviourChange { s += " --owner (behaviour change: the owner approves)" }
      if e.build?.dirty == true { s += " (the build is dirty: commit and rebuild, or --allow-dirty with the owner's say)" }
      return s
    case .promoted: return "open a PR with exp/\(e.id)/explain.txt and the diff; after the merge: perfloop champion merged <sha>. The loop may climb on it meanwhile"
    case .abandoned: return "nothing"
    }
  }

  static func fmt(_ x: Double?) -> String {
    guard let x else { return "-" }
    return x == x.rounded() && abs(x) < 1e12 ? String(Int(x)) : String(Stats.round(x, 2))
  }
}
