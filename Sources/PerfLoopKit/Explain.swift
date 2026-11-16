import Foundation

/// An experiment as text for an agent: verdict, numbers, what to look at, the next command. Written to
/// `exp/<id>/explain.txt` after every state change, so one file is enough to decide the next step (C5).
public enum Explain {
  public static func experiment(_ e: Experiment, champion: Champion?, stop: [String] = []) -> String {
    var o: [String] = []
    o.append("exp \(e.id) · \(e.state.rawValue) · \(e.kind) · \(e.scenario) on \(e.fixture)" + (e.secondFixture.map { " (second fixture \($0))" } ?? "")
             + (e.forced == true ? " · FORCED (owner flag)" : ""))
    o.append("hypothesis: \(e.hypothesis)")
    // An owner flag changed this experiment's course: say so where a PR quotes from (AGENTS.md: owner flags).
    for u in e.ownerFlags ?? [] { o.append("owner flag: " + u.line) }
    if let p = e.parent { o.append("measured against: champion \(p.experiment) [\(p.build.line)]") }
    if let c = champion, c.experiment != e.parent?.experiment { o.append("current champion: \(c.experiment) [\(c.build.line)], chain \(c.chain)") }
    if let b = e.build { o.append("candidate: [\(b.line)]") }
    if let k = e.knobs, !k.isEmpty { o.append("knobs: " + k.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")) }
    if e.behaviourChange { o.append("behaviour change: declared; the owner approves it before promotion") }
    if let s = e.screen { o += stage("screen", s) }
    if let f = e.full { o += stage("full", f) }
    if let s = e.secondScreen, s.stage.verdict == "untrusted" { o.append("second fixture \(s.fixture): UNTRUSTED (\(s.stage.untrusted ?? "untrusted reps")): not judged") }
    else if let s = e.secondScreen { o.append("second fixture \(s.fixture): \(s.notWorse ? "not worse" : "WORSE") (median gain \(s.stage.medianGainPct.map { "\($0) %" } ?? "-"), band \(s.stage.band.map { "\($0) %" } ?? "-"))") }
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
    var head = "\(name): \(s.verdict.uppercased())" + (s.verdict == "untrusted" ? " (\(s.untrusted ?? "untrusted reps"))" : "")
    head += " on \(s.metric), \(use.count) pair(s) (orders \(s.pairs.map(\.order).joined(separator: " ")))"
    if name == "screen" && s.verdict != "untrusted" { head += ", candidate won \(s.wins)/\(use.count)" }
    if let g = s.medianGainPct { head += ", gain \(g) %" }
    if let b = s.band { head += ", band ±\(b) %" }
    if let p = s.mwuP { head += ", MWU p=\(p)" }
    if let p = s.signP { head += ", sign p=\(p)" }
    o.append(head)
    if let r = s.runner {
      let n = s.pairs.compactMap(\.interruptions).reduce(0, +)
      o.append("  ran on \(r.line)" + (n > 0 ? "; \(n) rep(s) interrupted by input and redone" : ""))
    }
    // An adapter that reports no exit code, window or quiet state for a rep can't have an untrusted one told apart.
    let ran = s.pairs.filter { $0.failure == nil }
    if !ran.isEmpty, !ran.contains(where: { p in [p.a, p.b].contains { $0.exit != nil || $0.trustworthy != nil || $0.quiet != nil } }) {
      o.append("  trust: not checked: the adapter reports no exit code, window or quiet state per rep (ADAPTER.md §4), so an untrusted rep would count")
    }
    for p in s.pairs {
      let why = Acceptance.unusable(p)
      let redone = p.redone.map { $0 == why ? " (the same on its redo)" : " (redone once: \($0))" } ?? ""
      if let why { o.append("  pair \(p.index + 1) \(p.order): unusable: \(why)" + redone); continue }
      o.append("  pair \(p.index + 1) \(p.order): champion \(fmt(p.a.objective)) · candidate \(fmt(p.b.objective)) (\(Stats.round(-Acceptance.gainPct(p.a.objective!, p.b.objective!), 1)) %)" + redone)
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
      if let c = w.causes { o.append("  causes: " + c) }
    }
    return o
  }

  public static func next(_ e: Experiment) -> String {
    switch e.state {
    case .new: return "give it a build: perfloop exp new … --bench PATH (or --build-cmd CMD --bench PATH)"
    case .built, .screened:
      if let s = e.screen, s.verdict == "untrusted" { return untrustedNext(s, "perfloop exp screen \(e.id)", e) }
      return "perfloop exp screen \(e.id)"
    case .promising: return "perfloop exp full \(e.id)"
    case .full:
      if let s = [e.secondScreen?.stage, e.full].compactMap({ $0 }).first(where: { $0.verdict == "untrusted" }) { return untrustedNext(s, "perfloop exp full \(e.id)", e) }
      return "perfloop exp full \(e.id) (resumes at the first missing pair)"
    case .rejected: return "drop it and try the next idea; the worst stretch above is where the time went"
    case .lost: return e.full?.regression == true ? "drop it: the candidate is slower" : "drop it, or narrow the hypothesis and try again"
    // What waits for the owner says so and gives the agent its own step; the owner's flags are in `perfloop help`.
    case .needsReview:
      if let r = (e.full ?? e.screen)?.guardReviews, !r.isEmpty {
        return "stop and ask the owner to look at the snapshots (the guards lines above list both PNGs and the diff): accepting the look is theirs; meanwhile, the next idea"
      }
      return "stop and ask the owner to decide (no decision at 10 + 10, or a guard asks for review): report it with this explain.txt; meanwhile, the next idea"
    case .won:
      if e.build?.dirty == true { return "the build is dirty: commit, rebuild, and measure it again in a new experiment (promotion refuses a dirty build)" }
      if e.behaviourChange { return "ask the owner to approve the declared behaviour change and promote it: report it with this explain.txt" }
      return "perfloop exp promote \(e.id)"
    case .promoted: return "open a PR with exp/\(e.id)/explain.txt and the diff; after the merge: perfloop champion merged <sha>. The loop may climb on it meanwhile"
    case .abandoned: return "nothing"
    }
  }

  /// After an untrusted stage: never "drop it" (it decided nothing). Rerun it when the Mac is fit to measure, unless a
  /// rerun can't help: one side's window is wrong the same way every time.
  static func untrustedNext(_ s: Stage, _ rerun: String, _ e: Experiment) -> String {
    guard Acceptance.deterministic(s.pairs) != nil else {
      return "\(rerun) once the Mac is quiet and unlocked (perfloop doctor says what isn't): only the untrusted pairs run again"
    }
    let bad = s.pairs.filter(Acceptance.distrusted)
    guard bad.contains(where: { $0.b.trustworthy == false }) else {
      return "a rerun won't help: the champion's bench window is wrong the same way every time while the candidate's isn't: ask the owner (the bench, not your change)"
    }
    var t = "a rerun won't help: the candidate's bench window is wrong the same way every time."
    if bad.contains(where: { $0.b.windowFailed?.contains("keyWindow") == true }) {
      t += " If the change moves the keyboard into a window of its own on purpose (a panel, sheet or popover), the bench must count a key child window of its window as key (ADAPTER.md §3; PerfLoopHost does): that is the owner's bench change, ask for it. Otherwise"
    } else { t += " So" }
    return t + " the change broke the window's state: fix it, or perfloop exp abandon \(e.id)"
  }

  static func fmt(_ x: Double?) -> String {
    guard let x else { return "-" }
    return x == x.rounded() && abs(x) < 1e12 ? String(Int(x)) : String(Stats.round(x, 2))
  }
}
