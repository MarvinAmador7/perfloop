import Foundation

// Correctness guards (docs/design/CAPABILITIES.md C6), as the runner sees them: names in the champion's manifest
// (never the candidate's), results the adapter reports per rep (`reps[].guards[]`), and one the runner judges itself
// per pair from the two sides' snapshots (`snapshot-diff`, through the champion adapter's `snapdiff`). A guard that
// fails on the candidate while it passes on the champion vetoes a win; a snapshot over tolerance sends the experiment
// to the owner (`needsReview`), never a win.

/// One guard's outcome (`reps[].guards[]`, SCHEMAS.md §3), read loosely: an adapter may add fields.
public struct GuardResult: Codable, Sendable, Equatable {
  public var name: String
  public var pass: Bool
  public var detail: String
  /// Files the guard wrote (PNGs, layouts): absolute, or relative to the store once the runner has them.
  public var artifacts: [String]
  /// The guard's measured number (built-within: ms after settle; snapshot-diff: the share of pixels that differ).
  public var value: Double?
  public var limit: Double?
  /// A failure that asks the owner (needsReview) instead of vetoing outright.
  public var review: Bool?
  /// The `ink` guard's regions, one per region and step it judged (VERIFICATION.md v3).
  public var inkRegions: [InkRegionResult]?
  /// snapshot-diff: the comparison region by region (Looks.swift), with each changed region's pictures.
  public var looks: [RegionLook]?
  public init(name: String, pass: Bool, detail: String, artifacts: [String] = [], value: Double? = nil, limit: Double? = nil, review: Bool? = nil, looks: [RegionLook]? = nil) {
    self.name = name; self.pass = pass; self.detail = detail; self.artifacts = artifacts; self.value = value; self.limit = limit; self.review = review; self.looks = looks
  }
  enum CodingKeys: String, CodingKey { case name, pass, detail, artifacts, value, limit, review, inkRegions, looks }
  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name); pass = try c.decodeIfPresent(Bool.self, forKey: .pass) ?? false
    detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""; artifacts = (try? c.decodeIfPresent([String].self, forKey: .artifacts)) ?? []
    value = try? c.decodeIfPresent(Double.self, forKey: .value); limit = try? c.decodeIfPresent(Double.self, forKey: .limit)
    review = try? c.decodeIfPresent(Bool.self, forKey: .review)
    inkRegions = try? c.decodeIfPresent([InkRegionResult].self, forKey: .inkRegions)
    looks = try? c.decodeIfPresent([RegionLook].self, forKey: .looks)
  }
  public init?(json v: JSONValue?) {
    guard let v, v.object != nil, let g = try? v.decode(GuardResult.self) else { return nil }
    self = g
  }
}

/// One region the `ink` guard judged after a step: how much of it is drawn content, against its floor, and the crop
/// it judged (a PNG an agent can look at, pass or fail).
public struct InkRegionResult: Codable, Sendable, Equatable {
  public var region: String
  /// The step it was judged after (`select#0`), or where the scenario asked (`run.ink(…, after:)`).
  public var after: String
  public var pass: Bool
  /// The share of the region's pixels that differ from its own background (its most common colour), 0…1; nil when
  /// nothing could be captured (no such view, zero size, outside the window).
  public var ink: Double?
  public var min: Double
  /// Where it was, in points from the top-left of the window's content: x, y, width, height.
  public var rect: [Double]?
  public var detail: String
  /// The crop it judged (the region as drawn), absolute, or store-relative once the runner has it.
  public var picture: String?
  /// The region was its view drawn by itself (`InkRegion.drawnAlone()`): what is behind the view didn't count.
  public var alone: Bool?
  public init(region: String, after: String, pass: Bool, ink: Double?, min: Double, rect: [Double]?, detail: String, picture: String?) {
    self.region = region; self.after = after; self.pass = pass; self.ink = ink; self.min = min; self.rect = rect; self.detail = detail; self.picture = picture
  }
}

public enum GuardNames {
  /// The scenario's own checks: one the candidate fails while the champion passes vetoes it.
  public static let checks = "checks"
  /// PerfLoopHost's own guard (VERIFICATION.md v3): the regions a step names have drawn content.
  public static let ink = "ink"
  /// Guards that are PerfLoop's code, not a bench's: they judge whenever a side reports them, whether or not the
  /// champion's manifest lists them (a scenario declares its ink regions in its steps), and an adapter is never asked
  /// for them in `PERFLOOP_GUARDS`.
  public static let builtIn: Set<String> = [ink]
  public static let builtWithin = "built-within"
  /// Pairwise: the runner compares the two sides' snapshots with the champion adapter's `snapdiff`.
  public static let snapshotDiff = "snapshot-diff"
  /// Metrics Acceptance judges as frame guards (bands), whatever a manifest calls them.
  public static let frameMetrics: Set<String> = ["hitchTimeRatioMsPerS", "longestStretchMs"]

  /// The correctness guards of a scenario entry: its `guards` minus frame metrics (adapters before Phase 3 listed
  /// those there), and the scenario's checks when nothing else is left, so checks always veto.
  public static func correctness(_ e: ScenarioEntry?) -> [String] {
    let g = (e?.guards ?? []).filter { !frameMetrics.contains($0) }
    return g.isEmpty ? [checks] : g
  }

  /// Guards the adapter runs itself after a rep, to ask for in `PERFLOOP_GUARDS` (checks always run).
  public static func adapterRun(_ guards: [String]) -> [String] { guards.filter { $0 != checks && !builtIn.contains($0) } }

  /// `k=v,k=v` for `PERFLOOP_GUARD_PARAMS`, numbers as numbers.
  public static func params(_ p: [String: JSONValue]?) -> String {
    (p ?? [:]).sorted { $0.key < $1.key }.compactMap { k, v in
      if let d = v.double { return "\(k)=\(d == d.rounded() && abs(d) < 1e12 ? String(Int(d)) : String(d))" }
      return v.string.map { "\(k)=\($0)" }
    }.joined(separator: ",")
  }
}

extension Acceptance {
  /// Guard results the candidate fails while the champion passes them (or the champion doesn't run them: a pairwise
  /// guard), plus guards the champion reported that the candidate didn't (a candidate can't drop a guard). Reviews
  /// (`review: true`) are left to `guardReviews`.
  /// Built-in guards (`GuardNames.builtIn`) count whatever the manifest lists.
  public static func guardResultFailures(_ p: Pair, guards: [String]) -> [String] { guardResultFailures([p], guards: guards) }

  /// The same over pairs, one line per guard: the pairs it failed in (and the first one's detail), the candidate's
  /// count when there are several (flaky is a failure), and the pairs that dropped it.
  public static func guardResultFailures(_ ps: [Pair], guards: [String]) -> [String] {
    func gated(_ n: String) -> Bool { guards.contains(n) || GuardNames.builtIn.contains(n) }
    var names: [String] = []
    for p in ps { for g in (p.b.guards ?? []) + (p.a.guards ?? []) where gated(g.name) && !names.contains(g.name) { names.append(g.name) } }
    var out: [String] = []
    for n in names {
      func res(_ s: Side) -> GuardResult? { s.guards?.first { $0.name == n } }
      let failed = ps.filter { p in res(p.b).map { !$0.pass && $0.review != true } == true && res(p.a).map { !$0.pass } != true }
      if let first = failed.first, let g = res(first.b) {
        out.append("\(n) failed on the candidate in \(pairList(failed)): \(g.detail)" + candidateTally(ps.filter { res($0.b)?.pass == true }.count, ps.count))
      }
      let dropped = ps.filter { res($0.a) != nil && res($0.b) == nil }
      if !dropped.isEmpty { out.append("\(n) not reported by the candidate in \(pairList(dropped)) (the champion's manifest asks for it)") }
    }
    return out
  }

  /// Guards over their tolerance that ask the owner: a snapshot that differs from the champion's.
  public static func guardReviews(_ pairs: [Pair], guards: [String]) -> [String] {
    pairs.filter { $0.failure == nil }.flatMap { p in
      (p.b.guards ?? []).filter { !$0.pass && $0.review == true && (guards.contains($0.name) || GuardNames.builtIn.contains($0.name)) }.map { "\($0.name) in pair \(p.index + 1): \($0.detail)" }
    }
  }
}

/// The isolation scenarios' checks on one promotion (C6): one pair each, champion and candidate.
public struct IsolationGuard: Codable, Sendable, Equatable {
  public var scenario: String
  public var pair: Pair
  public var pass: Bool
  public var failures: [String]
  public init(scenario: String, pair: Pair, pass: Bool, failures: [String]) { self.scenario = scenario; self.pair = pair; self.pass = pass; self.failures = failures }
}

/// `perfloop guards --exp ID`: the guards re-run on their own, one pair of the experiment's scenario plus the isolation
/// scenarios, with the parameters used (an owner's `--guard-tolerance` shows here).
public struct GuardRun: Codable, Sendable, Equatable {
  public var at: String
  public var pair: Pair
  public var isolation: [IsolationGuard]
  public var params: [String: JSONValue]
  public var override: String?
  public var failures: [String]
  public var reviews: [String]
  public var pass: Bool { failures.isEmpty && reviews.isEmpty }
  public init(at: String = Clock.now(), pair: Pair, isolation: [IsolationGuard], params: [String: JSONValue], override: String?, failures: [String], reviews: [String]) {
    self.at = at; self.pair = pair; self.isolation = isolation; self.params = params; self.override = override; self.failures = failures; self.reviews = reviews
  }
}

extension Explain {
  /// One line per pair with guards: each guard's outcome on the candidate (and the champion's when it failed there).
  public static func guardLines(_ s: Stage) -> [String] {
    var o: [String] = []
    for p in s.pairs where !(p.b.guards ?? []).isEmpty || !(p.a.guards ?? []).isEmpty {
      let b = (p.b.guards ?? []).map { g in
        "\(g.name) \(g.pass ? ((g.looks ?? []).contains { $0.expected == true } ? "✓ declared look" : "✓") : g.review == true ? "REVIEW" : "✗")\(g.value.map { " " + guardValue(g.name, $0) } ?? "")"
      }
      let aFailed = (p.a.guards ?? []).filter { !$0.pass }.map(\.name)
      o.append("  guards pair \(p.index + 1): " + b.joined(separator: ", ") + (aFailed.isEmpty ? "" : " (champion failed: \(aFailed.joined(separator: ", ")))"))
      for g in p.b.guards ?? [] where !g.pass && !g.artifacts.isEmpty && g.name != GuardNames.ink { o.append("    \(g.name) artifacts: " + g.artifacts.joined(separator: " ")) }
      // The ink guard's crops, pass or fail: what it judged, to look at (the first pair's when they passed).
      if let g = p.b.guards?.first(where: { $0.name == GuardNames.ink }), !g.artifacts.isEmpty, !g.pass || p.index == s.pairs.first?.index {
        o.append("    look at (ink\(g.pass ? "" : " failed")): " + g.artifacts.joined(separator: " "))
      }
      for g in p.b.guards ?? [] { o += Looks.lines(g) }
    }
    return o
  }

  /// The promotion's isolation checks and the guard re-runs.
  public static func guardSections(_ e: Experiment) -> [String] {
    var o: [String] = []
    for i in e.isolation ?? [] { o.append("isolation \(i.scenario): \(i.pass ? "holds" : "BROKEN: " + i.failures.joined(separator: "; "))") }
    for (n, r) in (e.guardRuns ?? []).enumerated() {
      o.append("guards re-run \(n + 1) at \(r.at)\(r.override.map { " (\($0))" } ?? ""): \(r.pass ? "pass" : "FAIL")")
      for f in r.failures + r.reviews { o.append("  · " + f) }
      o += guardLines(Stage(metric: "-", pairs: [r.pair], verdict: "-"))
    }
    return o
  }

  static func guardValue(_ name: String, _ v: Double) -> String {
    name == GuardNames.snapshotDiff ? "\(Stats.round(v * 100, 3)) %" : name == GuardNames.ink ? "\(fmt(Stats.round(v * 100, 2))) % ink" : name == GuardNames.builtWithin ? "\(fmt(v)) ms" : fmt(v)
  }
}
