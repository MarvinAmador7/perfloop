import Foundation
import PerfLoopKit

/// `exp replay plan.json` (SPEC §6.1): imports the plan's builds, sets its champion, and runs its steps in order
/// with the same verbs an agent uses, then says for each step whether the loop did what the plan expects.
extension Loop {
  public struct ReplayOutcome {
    public var lines: [String]
    public var mismatches: Int
  }

  public func replay(_ plan: ReplayPlan) throws -> ReplayOutcome {
    var lines: [String] = [], mismatches = 0
    var hash: [String: String] = [:]
    for b in plan.builds {
      let e = try store.importBench(plan.path(b.dir), commit: b.commit, dirty: b.dirty, note: b.note)
      hash[b.name] = e.build.hash
      lines.append("import \(b.name): \(e.build.line)")
    }
    guard let base = hash[plan.champion] else { throw PLError.usage("the plan's champion \(plan.champion) is not one of its builds") }
    let firstScenario = plan.steps.first { $0.do == "exp" }?.scenario
    try setChampion(build: base, merged: true, scenario: firstScenario, fixture: plan.fixture, note: "replay baseline: \(plan.champion)")
    var expOf: [String: [String: String]] = [:]                 // build → scenario → experiment id
    for (i, s) in plan.steps.enumerated() {
      var got: String
      switch s.do {
      case "exp":
        guard let name = s.build, let h = hash[name] else { throw PLError.usage("step \(i + 1) names no known build") }
        var o = NewOptions(hypothesis: s.hypothesis ?? name)
        o.build = h; o.scenario = s.scenario; o.fixture = plan.fixture; o.via = plan.via
        // A second scenario of a build just promoted is measured against the champion it replaced.
        if let c = store.champion(), c.build.hash == h { o.against = c.parents.first }
        do {
          var e = try new(o)
          expOf[name, default: [:]][e.scenario] = e.id
          if e.state == .promising && s.screenOnly != true { e = try full(e.id) }
          if e.state == .won && s.screenOnly != true { e = try promote(e.id, { var p = PromoteOptions(); p.allowDirty = true; return p }()) }
          got = e.state.rawValue
          if let w = (e.full ?? e.screen).flatMap({ $0.pairs.compactMap(\.b.worstStretch).max { $0.durationMs < $1.durationMs } }), let top = w.topFramework.first ?? w.topOurs.first {
            lines.append("     worst stretch \(Int(w.durationMs)) ms: \(top)")
          }
        } catch let err as PLError { got = "error: \(err)" }
      case "diff":
        let a = s.a.map { $0.hasPrefix("trace:") ? plan.path(String($0.dropFirst(6))) : $0 } ?? "", b = s.b ?? "champion"
        if let name = s.build, let h = hash[name], FileManager.default.fileExists(atPath: a) { try register(trace: a, build: h) }
        do { _ = try diff(a, b == "champion" ? "champion" : b, exp: nil, allowStale: false); got = "compared" }
        catch let err as PLError { got = err.code == 6 ? "refused: \(err)" : "error: \(err)" }
      default:
        got = check(s, expOf: expOf)
      }
      // A won experiment is promoted by the replay, so "won" is met by "promoted".
      let ok = s.do == "check" ? !got.hasPrefix("cannot") : s.expect.split(separator: "|").contains { got.hasPrefix($0) || ($0 == "won" && got == "promoted") }
      if !ok { mismatches += 1 }
      lines.append("\(i + 1). \(s.do) \(s.build ?? s.a ?? "") \(s.scenario ?? ""): \(got) · expected \(s.expect) \(ok ? "✓" : "✗")")
    }
    if let c = store.champion() { lines.append("champion: \(c.experiment) [\(c.build.line)], chain \(c.chain)") }
    return ReplayOutcome(lines: lines, mismatches: mismatches)
  }

  /// A check on results already in the store: did the frame rate change between two builds' candidate sides, and
  /// did the late-frame count therefore move without deciding anything (H5)?
  func check(_ s: ReplayStep, expOf: [String: [String: String]]) -> String {
    guard let sc = s.scenario, let ia = s.a.flatMap({ expOf[$0]?[sc] }), let ib = s.b.flatMap({ expOf[$0]?[sc] }),
          let ea = try? store.experiment(ia), let eb = try? store.experiment(ib) else { return "cannot check: no experiments for \(s.a ?? "?") and \(s.b ?? "?") on \(s.scenario ?? "?")" }
    func sides(_ e: Experiment) -> [Side] { (e.full ?? e.screen)?.pairs.filter { Acceptance.unusable($0) == nil }.map(\.b) ?? [] }
    func med(_ xs: [Double]) -> String { xs.isEmpty ? "-" : String(Stats.median(xs)) }
    let a = sides(ea), b = sides(eb)
    return "steadyHz \(med(a.compactMap(\.steadyHz))) → \(med(b.compactMap(\.steadyHz))), lateFrames \(med(a.compactMap(\.lateFrames))) → \(med(b.compactMap(\.lateFrames))) (information), \(ea.screen?.metric ?? "objective") decided: \(ea.state.rawValue) then \(eb.state.rawValue)"
  }
}
