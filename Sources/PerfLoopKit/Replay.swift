import Foundation

/// `perfloop.replay/1`: a past session as a list of experiments against a moving champion (SPEC §6.1), so the loop
/// can be judged on a session whose answers are known.
public struct ReplayPlan: Codable, Sendable, Equatable {
  public var schema: String
  /// The store the replay uses (its own, never the app's real one).
  public var app: String
  /// Base for relative `dir`/`trace` paths.
  public var root: String
  public var fixture: String
  /// How pairs are measured. `run`: one child per side, which works on benches older than the objective.
  public var via: String?
  public var builds: [ReplayBuild]
  /// The build that is champion before the first step (set with `merged`).
  public var champion: String
  public var steps: [ReplayStep]
  /// The hand-run session's own cost, for the comparison.
  public var session: SessionCost
  /// Seconds per stage on this Mac (SPEC §5.3's cost model).
  public var costs: Costs
  public var notes: [String]?

  public struct SessionCost: Codable, Sendable, Equatable {
    public var abRuns: Int
    public var abMinutes: Double
    public var recordings: Int
    public var recordingMinutes: Double
    public var promotions: [String]
  }
  public struct Costs: Codable, Sendable, Equatable {
    public var screenS: Double
    public var fullS: Double
    public var confirmationS: Double
    public var diffS: Double
  }
}

public struct ReplayBuild: Codable, Sendable, Equatable {
  public var name: String
  /// The bench binary's directory (binary + resource bundles), relative to `root`.
  public var dir: String
  public var commit: String
  public var dirty: Bool
  public var note: String
  /// Whether the mapping to a hypothesis was confirmed by the agent that built it (SPEC §6.1 asks for it).
  public var confirmed: Bool?
}

public struct ReplayStep: Codable, Sendable, Equatable {
  /// exp: an experiment (screen, full when promising, promote when won) · diff: a `perfloop diff` that must behave
  /// as `expect` says · check: an assertion on results already in the store (no bench time).
  public var `do`: String
  public var build: String?
  public var hypothesis: String?
  public var scenario: String?
  /// For `exp`: screen only (a second scenario's not-worse check), no full.
  public var screenOnly: Bool?
  public var a: String?
  public var b: String?
  public var expect: String
  public var why: String?
}

public struct ReplayBudget: Sendable, Equatable {
  public var screens = 0, fulls = 0, confirmations = 0, diffs = 0
  public var seconds = 0.0
  /// With every full extended to 10 + 10.
  public var worstSeconds = 0.0
  public var sessionMinutes = 0.0
  public var withinThird: Bool { seconds / 60 <= sessionMinutes / 3 }
}

extension ReplayPlan {
  /// The plan's bench time: a screen per `exp`, a full per `exp` expected to get past its screen, a confirmation
  /// per expected promotion, a diff per `diff`.
  public var budget: ReplayBudget {
    var b = ReplayBudget()
    for s in steps {
      switch s.do {
      case "exp":
        b.screens += 1
        if s.screenOnly != true && s.expect != "rejected" { b.fulls += 1 }
        if s.expect == "won" || s.expect == "promoted" { b.confirmations += 1 }
      case "diff": b.diffs += 1
      default: break
      }
    }
    let base = Double(b.screens) * costs.screenS + Double(b.confirmations) * costs.confirmationS + Double(b.diffs) * costs.diffS
    b.seconds = base + Double(b.fulls) * costs.fullS
    b.worstSeconds = base + Double(b.fulls) * costs.fullS * Double(Acceptance.fullLooks.last!) / Double(Acceptance.fullLooks.first!)
    b.sessionMinutes = session.abMinutes + session.recordingMinutes
    return b
  }

  public func path(_ rel: String) -> String { rel.hasPrefix("/") ? rel : URL(fileURLWithPath: root).appendingPathComponent(rel).path }
  public func build(_ name: String) -> ReplayBuild? { builds.first { $0.name == name } }

  /// The `--dry-run` text: what would be imported, run and checked, and what it costs against the session.
  /// `exists` checks a path (injected so tests need no files).
  public func dryRun(exists: (String) -> Bool, size: (String) -> Int64? = { _ in nil }) -> String {
    var o: [String] = []
    let b = budget
    o.append("replay (dry run): \(builds.count) builds, \(steps.count) steps on \(fixture), via \(via ?? "ab"), store app \(app)")
    o.append("imports (perfloop store import DIR --commit SHA --note …):")
    for x in builds {
      let p = path(x.dir), ok = exists(p)
      let mb = size(p).map { String(format: " %.1f MB", Double($0) / 1e6) } ?? ""
      o.append("  \(x.name.padding(toLength: 5, withPad: " ", startingAt: 0)) \(x.commit)\(x.dirty ? " (dirty)" : "")\(mb) \(ok ? "found" : "MISSING: \(p)")\(x.confirmed == true ? "" : " · mapping unconfirmed")")
      o.append("        \(x.note)")
    }
    o.append("champion before step 1: \(champion)")
    o.append("steps:")
    for (i, s) in steps.enumerated() {
      var line = "  \(i + 1). "
      switch s.do {
      case "exp":
        let stages = s.screenOnly == true || s.expect == "rejected" ? "screen" : "screen → full → promote"
        line += "exp \(s.build ?? "?") on \(s.scenario ?? "?"): \(stages); expect \(s.expect)"
      case "diff": line += "diff \(s.a ?? "?") vs \(s.b ?? "?") on \(s.scenario ?? "?"); expect \(s.expect)"
      default: line += "check \(s.a ?? "?") → \(s.b ?? "?") on \(s.scenario ?? "?"): expect \(s.expect)"
      }
      o.append(line)
      if let h = s.hypothesis { o.append("     hypothesis: \(h)") }
      if let w = s.why { o.append("     why: \(w)") }
    }
    func m(_ s: Double) -> String { String(format: "%.1f min", s / 60) }
    o.append("budget: \(b.screens) screens (\(m(Double(b.screens) * costs.screenS))), \(b.fulls) fulls (\(m(Double(b.fulls) * costs.fullS)); up to \(m(Double(b.fulls) * costs.fullS * 2)) if all extend to 10 + 10), \(b.confirmations) confirmations (\(m(Double(b.confirmations) * costs.confirmationS))), \(b.diffs) diffs (\(m(Double(b.diffs) * costs.diffS)))")
    o.append("        ≈ \(m(b.seconds)) expected, \(m(b.worstSeconds)) worst case")
    o.append("session by hand: \(session.abRuns) ab runs ≈ \(Int(session.abMinutes)) min + \(session.recordings) recordings ≈ \(Int(session.recordingMinutes)) min = \(Int(b.sessionMinutes)) min; acceptance ≤ ⅓ = \(m(b.sessionMinutes * 60 / 3)): \(b.withinThird ? "within" : "OVER")")
    o.append("same promotions expected: \(session.promotions.joined(separator: ", "))")
    for n in notes ?? [] { o.append("note: \(n)") }
    let missing = builds.filter { !exists(path($0.dir)) }.map(\.name)
    if !missing.isEmpty { o.append("cannot run: missing builds \(missing.joined(separator: ", "))") }
    o.append("not run (--dry-run). The replay opens windows: run it when nobody is using the Mac, or on ssh://mac-mini.")
    return o.joined(separator: "\n") + "\n"
  }
}
