import Foundation

// Checks and guards counted per trusted rep (VERIFICATION.md v9): a check that passes in some reps and fails in others
// raced something (the first commit after a structural change, a stale frame) and proves nothing. It is `flaky N/M`,
// and a failure in every verdict path: `run` and `baseline` (exit 3), and a screen, a full or an expect-same stage
// (a veto, when the champion passed it). Untrusted reps are left out before anything is counted.

/// One check or guard over a set of trusted reps: in how many it passed.
public struct CheckTally: Codable, Sendable, Equatable {
  public var name: String
  /// check | guard
  public var kind: String
  public var passed: Int
  public var of: Int
  public init(name: String, kind: String, passed: Int, of: Int) { self.name = name; self.kind = kind; self.passed = passed; self.of = of }

  public var pass: Bool { passed == of }
  /// pass · flaky (some reps) · failed (none).
  public var status: String { pass ? "pass" : passed == 0 ? "failed" : "flaky" }
  /// `landed ✓ 3/3` · `drawn flaky 2/3` · `ink ✗ 0/3`.
  public var text: String { "\(name) " + (pass ? "✓" : passed == 0 ? "✗" : "flaky") + " \(passed)/\(of)" }
}

extension Acceptance {
  /// Every check and guard the reps reported, counted over them (pass them trusted reps only). A check a rep didn't
  /// report while another rep did counts as not passed there (when the rep lists its passing checks; an `ab` summary
  /// lists only the failed ones, so there an unlisted check passed). `snapshot-diff` (a capture, judged per pair
  /// against the champion's) and guards that ask for a review (a look, not a failure) aren't counted.
  public static func tally(_ sides: [Side]) -> [CheckTally] {
    var out: [CheckTally] = []
    var checks: [String] = [], guards: [String] = []
    for s in sides {
      for c in (s.checksPassed ?? []) + s.checksFailed where !checks.contains(c) { checks.append(c) }
      for g in s.guards ?? [] where g.name != GuardNames.snapshotDiff && g.review != true && !guards.contains(g.name) { guards.append(g.name) }
    }
    for c in checks {
      let passed = sides.filter { s in !s.checksFailed.contains(c) && (s.checksPassed.map { $0.contains(c) } ?? true) }.count
      out.append(CheckTally(name: c, kind: "check", passed: passed, of: sides.count))
    }
    for g in guards {
      out.append(CheckTally(name: g, kind: "guard", passed: sides.filter { $0.guards?.first { $0.name == g }?.pass == true }.count, of: sides.count))
    }
    return out
  }

  /// "pair 2", "pairs 1, 3".
  static func pairList(_ ps: [Pair]) -> String {
    (ps.count == 1 ? "pair " : "pairs ") + ps.map { String($0.index + 1) }.joined(separator: ", ")
  }

  /// Whether the candidate failed check `c` in a pair: it said so, or it didn't report a check the champion passed
  /// there (a candidate can't drop a check).
  static func candidateFailed(_ c: String, _ p: Pair) -> Bool {
    p.b.checksFailed.contains(c) || (p.b.checksPassed.map { !$0.contains(c) } == true && p.a.checksPassed?.contains(c) == true)
  }

  /// The candidate's count over the pairs, after a failure: `· the candidate passed 2/3 (flaky: a failure)`; nothing
  /// for one pair.
  static func candidateTally(_ passed: Int, _ of: Int) -> String {
    of < 2 ? "" : " · the candidate passed \(passed)/\(of)" + (passed > 0 ? " (flaky: a failure)" : "")
  }

  /// Checks and guards the candidate failed in some pairs, but only where the champion failed them too: they can't
  /// judge this candidate (the check is flaky or broken on the champion as well), and say so instead of vetoing.
  public static func flakyOnBothSides(_ pairs: [Pair], guards: [String]) -> [String] {
    let ran = pairs.filter { $0.failure == nil }
    guard ran.count > 1 else { return [] }
    var out: [String] = []
    let a = tally(ran.map(\.a)), b = tally(ran.map(\.b))
    for t in b where !t.pass {
      let gated = t.kind == "check" ? (guards.isEmpty || guards.contains(GuardNames.checks) || guards.contains(t.name)) : (guards.contains(t.name) || GuardNames.builtIn.contains(t.name))
      guard gated, let c = a.first(where: { $0.name == t.name && $0.kind == t.kind }), !c.pass else { continue }
      let vetoed = t.kind == "check" ? ran.contains { candidateFailed(t.name, $0) && !$0.a.checksFailed.contains(t.name) }
        : ran.contains { p in p.b.guards?.first { $0.name == t.name }?.pass == false && p.a.guards?.first { $0.name == t.name }?.pass != false }
      if vetoed { continue }
      out.append("\(t.kind) \(t.name) fails on the champion too (champion \(c.passed)/\(c.of), candidate \(t.passed)/\(t.of)): it can't judge this candidate. "
                 + "A check that passes in some reps races something (the first commit after a structural change: ADAPTER.md §3b); it is the bench's to fix: ask the owner")
    }
    return out
  }
}
