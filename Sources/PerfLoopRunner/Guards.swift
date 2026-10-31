import Foundation
import PerfLoopKit

/// Correctness guards in the loop (CAPABILITIES.md C6). The champion's manifest says which guards gate a scenario and
/// with which parameters; both sides of every pair are asked for them (`PERFLOOP_GUARDS`, `PERFLOOP_GUARD_PARAMS`)
/// and write their artifacts under the pair's directory (`PERFLOOP_ARTIFACTS`); the snapshots are compared by the
/// champion's adapter (`snapdiff`), so a candidate can neither drop a guard nor judge itself.
extension Loop {
  /// The champion manifest's correctness guards for a scenario and their parameters, with the owner's (this
  /// experiment's, then this command's) on top.
  func guardRule(_ e: Experiment, _ s: Sides, scenario: String) -> (guards: [String], params: [String: JSONValue]) {
    let sc = s.champion.manifest?.scenario(scenario)
    return (GuardNames.correctness(sc), (sc?.guardParams ?? [:]).merging(e.guardParams ?? [:]) { $1 }.merging(guardOverride) { $1 })
  }

  /// What a side's run gets in its environment: the guards it runs itself, their parameters, where to write.
  func guardEnv(_ g: (guards: [String], params: [String: JSONValue]), dir: URL) -> [String: String] {
    let run = GuardNames.adapterRun(g.guards)
    guard !run.isEmpty else { return [:] }
    return ["PERFLOOP_GUARDS": run.joined(separator: ","), "PERFLOOP_GUARD_PARAMS": GuardNames.params(g.params), "PERFLOOP_ARTIFACTS": dir.path]
  }

  /// After a pair: the candidate's snapshot against the champion's, judged by the champion's adapter. The candidate's
  /// own `snapshot-diff` record (its capture) is replaced by the comparison. Passing pictures are deleted (they are a
  /// few MB a side); failing ones stay, with the diff picture, for the owner. Artifacts become store-relative.
  func judgeSnapshots(_ p: inout Pair, _ g: (guards: [String], params: [String: JSONValue]), dir: URL, sides s: Sides) {
    guard g.guards.contains(GuardNames.snapshotDiff), p.failure == nil else { relativise(&p); return }
    func png(_ side: Side) -> String? {
      side.guards?.first { $0.name == GuardNames.snapshotDiff && $0.pass }?.artifacts.first { $0.hasSuffix(".png") && !$0.hasSuffix(".later.png") }
    }
    let fm = FileManager.default
    guard let bi = p.b.guards?.firstIndex(where: { $0.name == GuardNames.snapshotDiff }) else { relativise(&p); return }   // dropped: guardResultFailures says so
    guard let pb = png(p.b) else { relativise(&p); return }                    // its capture failed: a failure of its own
    guard let pa = png(p.a), fm.fileExists(atPath: pa) else {
      p.b.guards![bi] = GuardResult(name: GuardNames.snapshotDiff, pass: false, detail: "the champion's snapshot is missing: nothing to compare the candidate's with", artifacts: [pb], review: true)
      relativise(&p); return
    }
    let diffOut = dir.appendingPathComponent("diff.png").path
    var r: GuardResult
    if let o = try? Adapter(exe: s.champion.executable).snapdiff(pa, pb, params: GuardNames.params(g.params), diffOut: diffOut), let v = o.json?["guard"], let x = GuardResult(json: v), [0, 3].contains(o.status) {
      r = x
    } else {
      r = GuardResult(name: GuardNames.snapshotDiff, pass: false, detail: "the champion's snapdiff couldn't compare \(pa) with \(pb)", artifacts: [pa, pb], review: true)
    }
    p.b.guards![bi] = r
    // Keep what the owner needs to look at, nothing else.
    let later = [pa, pb].map { $0.replacingOccurrences(of: ".png", with: ".later.png") }
    for f in later { try? fm.removeItem(atPath: f) }
    if r.pass { for f in [pa, pb, diffOut] { try? fm.removeItem(atPath: f) }; p.b.guards![bi].artifacts = [] }
    relativise(&p)
  }

  /// Artifact paths relative to the store, and only those that still exist.
  func relativise(_ p: inout Pair) {
    for side in [\Pair.a, \Pair.b] {
      guard var gs = p[keyPath: side].guards else { continue }
      for i in gs.indices { gs[i].artifacts = gs[i].artifacts.filter { FileManager.default.fileExists(atPath: store.abs($0)) }.map { store.rel(URL(fileURLWithPath: store.abs($0))) } }
      p[keyPath: side].guards = gs
    }
  }

  /// The isolation scenarios (the champion manifest's `isolationGuards`) on one pair each: every check and guard the
  /// champion passes, the candidate must pass (C6: on every promotion, whatever the experiment climbs). Resumes from
  /// the pairs already on disk.
  func isolation(_ e: Experiment, sides s: Sides, stagePrefix: String = "isolation") throws -> [IsolationGuard] {
    let m = s.champion.manifest
    var out: [IsolationGuard] = []
    for sc in m?.isolationGuards ?? [] where sc != e.scenario && m?.scenario(sc) != nil {
      let metric = m?.scenario(sc)?.objective ?? "mainThreadCpuMsPerStep"
      let g = guardRule(e, s, scenario: sc)
      let p = try pairs(e, stage: "\(stagePrefix)-\(sc)", fixture: e.fixture, count: 1, sides: s, metric: metric, scenario: sc)[0]
      var why = Acceptance.guardFailures([p], guards: g.guards) + Acceptance.guardReviews([p], guards: g.guards)
      if let u = Acceptance.unusable(p), p.failure != nil { why.append("couldn't run: \(u)") }
      out.append(IsolationGuard(scenario: sc, pair: p, pass: why.isEmpty, failures: why))
      log("exp \(e.id) isolation \(sc): \(why.isEmpty ? "holds" : why.joined(separator: "; "))")
    }
    return out
  }

  /// `perfloop guards --exp ID`: the guards alone, re-run on a fresh pair of the experiment's scenario and the isolation
  /// scenarios; recorded in `guardRuns`. A failure demotes a promising or won experiment (rejected/lost), a snapshot
  /// over tolerance sends it to the owner; only the owner (`--owner`, with or without `--guard-tolerance`) clears a
  /// review, back to what the objective said.
  public func guards(_ id: String, tolerance: Double? = nil) throws -> (Experiment, GuardRun) {
    var e = try store.experiment(id)
    guard e.kind != "baseline" else { throw PLError.usage("exp \(e.id) is the baseline") }
    if tolerance != nil && by != "owner" { throw PLError.refused("--guard-tolerance is the owner's (--owner): the tolerance comes from the champion's manifest") }
    let s = try sides(e)
    if let t = tolerance { guardOverride["snapshot-diff.tolerance"] = .number(t) }
    defer { guardOverride = [:] }
    let n = (e.guardRuns?.count ?? 0) + 1
    let g = guardRule(e, s, scenario: e.scenario)
    let metric = rule(e, s).metric
    let p = try pairs(e, stage: "guards-\(n)", fixture: e.fixture, count: 1, sides: s, metric: metric)[0]
    var failures = Acceptance.guardFailures([p], guards: g.guards)
    if let u = Acceptance.unusable(p), p.failure != nil { failures.append("couldn't run: \(u)") }
    let iso = try isolation(e, sides: s, stagePrefix: "guards-\(n)-isolation")
    failures += iso.filter { !$0.pass }.flatMap { i in i.failures.map { "isolation \(i.scenario): \($0)" } }
    let run = GuardRun(pair: p, isolation: iso, params: g.params, override: tolerance.map { "snapshot-diff.tolerance \($0) by the owner" },
                       failures: failures, reviews: Acceptance.guardReviews([p], guards: g.guards))
    e.guardRuns = (e.guardRuns ?? []) + [run]
    let before = e.state
    if !run.failures.isEmpty, [.promising, .won, .needsReview].contains(e.state) { e.state = e.full == nil ? .rejected : .lost }
    else if !run.reviews.isEmpty, [.promising, .won].contains(e.state) { e.state = .needsReview }
    else if run.pass, e.state == .needsReview, by == "owner", let last = e.full ?? e.screen, last.verdict == "needsReview" {
      e.state = e.full == nil ? .promising : .won
      e.notes.append("the owner cleared the snapshot review with guards re-run \(n)" + (tolerance.map { " at tolerance \($0)" } ?? ""))
    }
    // The owner's tolerance holds for the rest of this experiment's pairs (a full after a cleared screen).
    if let t = tolerance, by == "owner" { e.guardParams = (e.guardParams ?? [:]).merging(["snapshot-diff.tolerance": .number(t)]) { $1 } }
    if e.state != before { e.notes.append("guards re-run \(n): \(before.rawValue) → \(e.state.rawValue)") }
    try store.save(e)
    try store.ledger.append(LedgerEntry(experiment: e.id, state: e.state.rawValue, build: e.build?.hash, by: by,
                                        note: "guards re-run \(n): \(run.pass ? "pass" : (run.failures + run.reviews).joined(separator: "; "))"))
    _ = explain(e)
    return (e, run)
  }
}
