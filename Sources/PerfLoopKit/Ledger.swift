import Foundation

/// One line of `ledger.jsonl` (`perfloop.ledger/1`): a state change of one experiment. Append-only: the ledger is the
/// loop's memory across agent sessions (SPEC §5.5, agent drift), so nothing rewrites it.
public struct LedgerEntry: Codable, Sendable, Equatable {
  public var schema = "perfloop.ledger/1"
  public var at: String
  public var experiment: String
  /// An `ExpState`, or "session" (a session started: the stopping rules count from the newest one).
  public var state: String
  public var objective: Before?
  /// The experiment's build hash.
  public var build: String?
  /// agent | owner.
  public var by: String
  public var note: String?
  /// Where a stage's numbers came from (C10): the runner and the machine model. Results are keyed by both.
  public var runner: String?
  public var machine: String?

  public struct Before: Codable, Sendable, Equatable {
    public var before: Double?
    public var after: Double?
    public init(before: Double?, after: Double?) { self.before = before; self.after = after }
  }

  public init(experiment: String, state: String, objective: Before? = nil, build: String? = nil, by: String = "agent", note: String? = nil, at: String = Clock.now(),
              runner: RunnerIdentity? = nil) {
    self.at = at; self.experiment = experiment; self.state = state; self.objective = objective; self.build = build; self.by = by; self.note = note
    self.runner = runner?.runner; machine = runner?.model
  }
}

public struct Ledger: Sendable {
  public let path: String
  public init(path: String) { self.path = path }

  /// Appends one line, as one write. A torn last line (a crash mid-write) is closed with a newline first, so it costs
  /// itself and never the entry after it.
  public func append(_ e: LedgerEntry) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
    guard let h = FileHandle(forWritingAtPath: path) else { throw CocoaError(.fileWriteUnknown) }
    defer { try? h.close() }
    let end = try h.seekToEnd()
    var torn = false
    if end > 0, let r = FileHandle(forReadingAtPath: path) {
      try r.seek(toOffset: end - 1); torn = try r.read(upToCount: 1) != Data("\n".utf8); try r.close()
    }
    try h.write(contentsOf: Data(((torn ? "\n" : "") + PLJSON.line(e) + "\n").utf8))
  }

  /// Every readable line, in order. A torn last line (a crash mid-write) is skipped, not fatal: resume carries on.
  public func entries() -> [LedgerEntry] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: \.isNewline).compactMap { try? PLJSON.decode(LedgerEntry.self, from: Data($0.utf8)) }
  }

  /// The newest state of each experiment.
  public func latest() -> [String: LedgerEntry] {
    var d: [String: LedgerEntry] = [:]
    for e in entries() where e.state != "session" { d[e.experiment] = e }
    return d
  }

  /// Entries from the newest `session` line on (all of them when there is none).
  public func currentSession() -> [LedgerEntry] {
    let all = entries()
    guard let i = all.lastIndex(where: { $0.state == "session" }) else { return all }
    return Array(all[i...])
  }
}

/// `champion.json` (`perfloop.champion/1`): the build every candidate is measured against. The loop may climb on an
/// unmerged champion (owner, SPEC §7.5); `parents` is the chain of earlier champions back to the newest merged one
/// and `mergedAncestor` that merged commit, so any champion traces back to `main`.
public struct Champion: Codable, Sendable, Equatable {
  public var schema = "perfloop.champion/1"
  public var experiment: String
  public var build: Build
  public var merged: Bool
  /// Newest first: the champion this one replaced, then the one before, … up to and including the newest merged one.
  public var parents: [String]
  /// The commit of the newest merged champion in the chain (this one's own commit when it is merged).
  public var mergedAncestor: String?
  /// Scenario → the champion's objective median there, from its own full stage.
  public var objectives: [String: Double]
  public var since: String
  /// Knob values this champion was promoted with: knob debt until a follow-up bakes them in (SPEC §7.6).
  public var knobs: [String: String]?

  public init(experiment: String, build: Build, merged: Bool, parents: [String] = [], mergedAncestor: String?, objectives: [String: Double] = [:], since: String = Clock.now()) {
    self.experiment = experiment; self.build = build; self.merged = merged; self.parents = parents; self.mergedAncestor = mergedAncestor
    self.objectives = objectives; self.since = since
  }

  /// The first champion, set by hand from a build already on `main` (or not: then it has no merged ancestor yet).
  public static func baseline(experiment: String = "0000", build: Build, merged: Bool) -> Champion {
    Champion(experiment: experiment, build: build, merged: merged, mergedAncestor: merged ? build.commit : nil)
  }

  /// The champion after `experiment` wins and is promoted. A merged champion ends the chain: its successor's
  /// parents are just it.
  public func succeeded(by experiment: String, build: Build, objectives new: [String: Double], knobs: [String: String]? = nil, at: String = Clock.now()) -> Champion {
    var c = Champion(experiment: experiment, build: build, merged: false, parents: merged ? [self.experiment] : [self.experiment] + parents,
                     mergedAncestor: merged ? (mergedAncestor ?? self.build.commit) : mergedAncestor,
                     objectives: objectives.merging(new) { $1 }, since: at)
    let k = (self.knobs ?? [:]).merging(knobs ?? [:]) { $1 }
    c.knobs = k.isEmpty ? nil : k
    return c
  }

  /// The owner merged this champion's PR at `commit`: the chain restarts here.
  public func markMerged(at commit: String) -> Champion {
    var c = self; c.merged = true; c.parents = []; c.mergedAncestor = commit
    return c
  }

  /// "0007 ← 0005 ← 0002 (merged 9bcd41a)".
  public var chain: String {
    let ids = [experiment] + parents
    var s = ids.joined(separator: " ← ")
    if merged { s += " (merged \(mergedAncestor ?? build.commit ?? "?"))" }
    else if let m = mergedAncestor { s += " ← main@\(m)" }
    else { s += " (no merged ancestor)" }
    return s
  }
}
