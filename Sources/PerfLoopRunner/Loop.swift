import Foundation
import PerfLoopKit

/// The experiment verbs (SPEC §3.4, C5) over a store: `exp new`, `screen`, `full`, `promote`, `status`, and the
/// champion. Every step writes its file before the next starts, so an interrupted run resumes at the first missing
/// pair; every state change is a ledger line and a fresh `exp/<id>/explain.txt`.
public final class Loop {
  public let store: Store
  /// Progress for the person or agent watching (stderr in the CLI).
  public var log: (String) -> Void = { FileHandle.standardError.write(Data(("perfloop: " + $0 + "\n").utf8)) }
  /// Whether the champion runs first in pair `i` of a stage (`"<id>/<stage>"`). Counterbalanced: the stage's first
  /// side is drawn from a hash of its key (random across experiments, the same on resume), then the sides alternate,
  /// so order effects (warm caches, a machine settling) fall on both sides equally (SPEC §5.1). Tests pin it.
  public var championFirst: (_ stage: String, _ i: Int) -> Bool = { key, i in
    let start = key.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 } >> 17 & 1 == 0
    return start != (i % 2 == 1)
  }
  public var cwd = FileManager.default.currentDirectoryPath
  public var env = ProcessInfo.processInfo.environment
  /// Who is acting, for the ledger: agent unless the owner said so (`--owner`).
  public var by = "agent"
  /// Guard parameters on top of the champion manifest's: only `perfloop guards --guard-tolerance` (the owner's) sets one.
  var guardOverride: [String: JSONValue] = [:]
  /// Where windowed reps run (C10, Runner.swift): this Mac, ungated, unless `--runner` / the queue says otherwise.
  public var runner: Runner = LocalRunner()
  /// An interrupted rep is redone at most this many times in a row before the pair is given up (resume redoes it).
  public var maxRedo = 50

  public init(store: Store) { self.store = store }

  // MARK: champion

  public func requireChampion() throws -> (Champion, Store.Entry) {
    guard let c = store.champion() else { throw PLError.usage("no champion yet: perfloop champion set BUILD --merged (a build already in the store; see perfloop store list)") }
    return (c, try store.entry(c.build.hash ?? ""))
  }

  /// `champion set BUILD`: the first champion (or an owner's reset), recorded as a baseline experiment that holds
  /// the default scenario and fixture later experiments inherit.
  @discardableResult
  public func setChampion(build key: String, merged: Bool, scenario: String?, fixture: String?, note: String? = nil) throws -> Champion {
    let entry = try store.entry(key)
    let m = entry.manifest
    guard let sc = scenario ?? m?.scenarios.first?.name else { throw PLError.usage("pass --scenario: the build's manifest names none") }
    guard let fx = fixture ?? m?.fixtureNames.first else { throw PLError.usage("pass --fixture: the build's manifest names none") }
    var e = Experiment(id: store.nextID(), hypothesis: note ?? "baseline", kind: "baseline", scenario: sc, fixture: fx, parent: nil, build: entry.build.embedded)
    e.state = .promoted; e.promotedAt = Clock.now()
    if store.champion() != nil { e.notes.append("set by hand over champion \(store.champion()!.experiment): the chain restarts here") }
    let c = Champion.baseline(experiment: e.id, build: entry.build.embedded, merged: merged)
    try store.save(e); try store.setChampion(c)
    try store.ledger.append(LedgerEntry(experiment: e.id, state: ExpState.promoted.rawValue, build: entry.build.hash, by: "owner", note: "champion set by hand" + (merged ? " (merged)" : "")))
    _ = explain(e)
    return c
  }

  /// `champion merged SHA`: the champion's PR landed; the chain restarts at that commit.
  @discardableResult
  public func markMerged(commit: String) throws -> Champion {
    let (c, _) = try requireChampion()
    let m = c.markMerged(at: commit)
    try store.setChampion(m)
    try store.ledger.append(LedgerEntry(experiment: c.experiment, state: "merged", build: c.build.hash, by: "owner", note: "merged at \(commit)"))
    return m
  }

  // MARK: exp new

  public struct NewOptions {
    public var hypothesis: String
    /// A stamped bench (file or directory) to add to the store.
    public var bench: String?
    public var exe: String?
    /// Run this first (in `cwd`, through /bin/sh) to build `bench` from the working tree; records the patch.
    public var buildCmd: String?
    /// A build already in the store (hash or prefix): imported pre-stamp builds enter experiments this way.
    public var build: String?
    public var scenario: String?
    public var fixture: String?
    public var secondFixture: String?
    public var kind: String = "code"
    public var knobs: [String: String] = [:]
    public var behaviourChange = false
    public var via: String?
    public var params: [String: String] = [:]
    public var patch: String?
    public var screen = true
    /// Measure against this earlier champion (an experiment in the champion's chain) instead of the current one: a
    /// second scenario's screen of a build that has just been promoted. Such an experiment is never promoted itself.
    public var against: String?
    public init(hypothesis: String) { self.hypothesis = hypothesis }
  }

  public func new(_ o: NewOptions) throws -> Experiment {
    let (c, cEntry) = try requireChampion()
    let m = cEntry.manifest
    let parentExp = try? store.experiment(c.experiment)
    guard let sc = o.scenario ?? env["PERFLOOP_SCENARIO"] ?? parentExp?.scenario ?? m?.scenarios.first?.name else { throw PLError.usage("pass --scenario") }
    if let m, m.scenario(sc) == nil { throw PLError.usage("unknown scenario '\(sc)'; the champion's manifest has \(m.scenarios.map(\.name).joined(separator: ", "))") }
    guard let fx = o.fixture ?? env["PERFLOOP_FIXTURE"] ?? parentExp?.fixture ?? m?.fixtureNames.first else { throw PLError.usage("pass --fixture") }
    let kind = o.knobs.isEmpty ? o.kind : "knob"
    if kind == "knob", o.knobs.isEmpty { throw PLError.usage("a knob experiment needs --knobs k=v[,k=v]") }
    if let ks = m?.knobs, !ks.isEmpty || kind == "knob" {
      for (k, v) in o.knobs {
        guard let knob = ks.first(where: { $0.name == k }) else { throw PLError.usage("unknown knob '\(k)'; the manifest has \(ks.map(\.name).joined(separator: ", "))") }
        guard knob.accepts(v) else { throw PLError.usage("knob \(k) doesn't take '\(v)' (\(knob.choices?.joined(separator: "|") ?? knob.range.map { "\($0)" } ?? "?"))") }
      }
    }
    let id = store.nextID()
    var patch: String?, notes: [String] = []
    let entry: Store.Entry
    if let key = o.build { entry = try store.entry(key) }
    else if let bench = o.bench ?? (o.buildCmd != nil ? env["PERFLOOP_BENCH"] : nil) {
      if let cmd = o.buildCmd {
        log("building: \(cmd)")
        let r = try Adapter.spawn("/bin/sh", ["-c", cmd], cwd: cwd)
        guard r.status == 0 else { throw PLError.harness("the build command failed (exit \(r.status))") }
        (patch, notes) = try capturePatch(id: id, base: c.build.commit)
      }
      entry = try store.add(bench, exe: o.exe)
    } else if kind == "knob" { entry = cEntry }
    else { throw PLError.usage("give it a build: --bench PATH (stamped), --build-cmd CMD --bench PATH, or --build HASH (a build in the store)") }
    if let p = o.patch { patch = try copyPatch(p, id: id) }
    var parent = ParentRef(experiment: c.experiment, build: c.build)
    if let a = o.against {
      let x = try store.experiment(a)
      guard ([c.experiment] + c.parents).contains(x.id), let xb = x.build else { throw PLError.usage("--against \(a): not a champion in the chain \(c.chain)") }
      parent = ParentRef(experiment: x.id, build: xb)
    }
    if entry.build.hash == parent.build.hash && o.knobs.isEmpty { throw PLError.refused("the candidate is the champion's own build (\(Build.short(parent.build.hash ?? ""))): nothing to compare") }

    var e = Experiment(id: id, hypothesis: o.hypothesis, kind: kind, scenario: sc, fixture: fx, parent: parent, build: entry.build.embedded)
    e.knobs = o.knobs.isEmpty ? nil : o.knobs
    e.behaviourChange = o.behaviourChange
    e.secondFixture = o.secondFixture ?? m?.scenario(sc)?.secondFixture
    e.params = o.params.isEmpty ? nil : o.params
    e.via = kind == "knob" ? "run" : (o.via ?? env["PERFLOOP_VIA"] ?? m?.defaultVia ?? "ab")
    e.patch = patch; e.notes = notes
    if !entry.build.stamp { e.notes.append("the build predates the stamp: imported as \(entry.build.commit ?? "?")\(entry.build.note.map { " (\($0))" } ?? "")") }
    try store.save(e)
    try store.ledger.append(LedgerEntry(experiment: id, state: ExpState.built.rawValue, build: entry.build.hash, by: by, note: o.hypothesis))
    _ = explain(e)
    log("exp \(id): \(o.hypothesis) [\(entry.build.line)]")
    return o.screen ? try screen(id) : e
  }

  /// The working tree's diff against the champion's commit, refused when it touches what must never be published.
  func capturePatch(id: String, base: String?) throws -> (String?, [String]) {
    guard let base else { return (nil, ["no patch: the champion has no commit"]) }
    guard let r = try? Adapter.spawn("/usr/bin/env", ["git", "-C", cwd, "diff", base], quiet: true), r.status == 0 else { return (nil, ["no patch: git diff \(base) failed in \(cwd)"]) }
    try checkPatch(r.stdout)
    let p = store.expDir(id).appendingPathComponent("patch.diff")
    try FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
    try r.stdout.write(to: p, atomically: true, encoding: .utf8)
    return (store.rel(p), [])
  }
  func copyPatch(_ path: String, id: String) throws -> String {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    try checkPatch(text)
    let p = store.expDir(id).appendingPathComponent("patch.diff")
    try FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: p, atomically: true, encoding: .utf8)
    return store.rel(p)
  }
  /// The repo's rule (AGENTS.md): never .relay/, .traces/, ~/.capcomd, nor a trace.
  public func checkPatch(_ text: String) throws {
    let bad = text.split(separator: "\n").filter { $0.hasPrefix("diff --git ") }.filter { l in
      [".relay/", ".traces/", ".capcomd"].contains { l.contains($0) } || l.hasSuffix(".trace")
    }
    if !bad.isEmpty { throw PLError.refused("the patch touches paths that are never recorded: " + bad.joined(separator: "; ")) }
  }

  // MARK: measuring pairs

  struct Sides { var champion: Store.Entry; var candidate: Store.Entry; var championKnobs: [String: String]; var candidateKnobs: [String: String] }

  func sides(_ e: Experiment) throws -> Sides {
    guard let b = e.build, let pb = e.parent?.build else { throw PLError.usage("exp \(e.id) has no build or no champion to compare with") }
    let ck = store.champion().flatMap { $0.experiment == e.parent?.experiment ? $0.knobs : nil } ?? [:]
    return Sides(champion: try store.entry(pb.hash ?? ""), candidate: try store.entry(b.hash ?? ""), championKnobs: ck, candidateKnobs: ck.merging(e.knobs ?? [:]) { $1 })
  }

  /// The champion manifest's view of the scenario: the objective and the guards. Never the candidate's (SPEC §5.5).
  func rule(_ e: Experiment, _ s: Sides) -> (metric: String, guards: [String]) {
    let sc = s.champion.manifest?.scenario(e.scenario)
    return (sc?.objective ?? "mainThreadCpuMsPerStep", GuardNames.correctness(sc))
  }

  /// Pairs `0..<count` of a stage, measuring only the ones without a usable record (resume).
  func pairs(_ e: Experiment, stage: String, fixture: String, count: Int, sides s: Sides, metric: String, scenario: String? = nil) throws -> [Pair] {
    let dir = store.expDir(e.id).appendingPathComponent(stage)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var out: [Pair] = []
    let here = try runner.identity()
    for i in 0..<count {
      let rec = dir.appendingPathComponent("p\(i + 1).pair.json")
      if let p = try? PLJSON.read(Pair.self, path: rec.path), Acceptance.unusable(p) == nil {
        // A stage's pairs come from one runner (C10): finish it where it started.
        let there = p.runner ?? .legacy
        guard there.sameMachine(as: here) else {
          throw PLError.refused("exp \(e.id) \(stage): pair \(i + 1) ran on \(there.line), this runner is \(here.line): results never mix runners; finish the stage on \(there.runner), or measure the build again in a new experiment (perfloop exp new --build \(Build.short(e.build?.hash ?? "")))")
        }
        out.append(p); continue
      }
      var p = try measureRedoingInterrupts(e, index: i, stage: stage, fixture: fixture, dir: dir, sides: s, metric: metric, scenario: scenario)
      if Acceptance.unusable(p) != nil, p.failure != nil, p.interrupted != true {
        log("exp \(e.id) \(stage) pair \(i + 1): \(p.failure!); once more")
        let n = p.interruptions
        p = try measureRedoingInterrupts(e, index: i, stage: stage, fixture: fixture, dir: dir, sides: s, metric: metric, scenario: scenario)
        if let n { p.interruptions = (p.interruptions ?? 0) + n }
      }
      p.runner = here
      try PLJSON.write(p, path: rec.path)
      out.append(p)
    }
    return out
  }

  /// A pair, redone while the runner aborts it on input (the local runner's idle gate): an interrupted rep never counts.
  func measureRedoingInterrupts(_ e: Experiment, index i: Int, stage: String, fixture: String, dir: URL, sides s: Sides, metric: String, scenario: String? = nil) throws -> Pair {
    var n = 0
    while true {
      var p = try measure(e, index: i, stage: stage, fixture: fixture, dir: dir, sides: s, metric: metric, scenario: scenario)
      guard p.interrupted == true, n < maxRedo else { if n > 0 { p.interruptions = n }; return p }
      n += 1
      log("exp \(e.id) \(stage) pair \(i + 1): interrupted by input; redoing it (\(n))")
    }
  }

  func measure(_ e: Experiment, index i: Int, stage: String, fixture: String, dir: URL, sides s: Sides, metric: String, scenario: String? = nil) throws -> Pair {
    let first = championFirst("\(e.id)/\(stage)", i), order = first ? "AB" : "BA"
    let raw = dir.appendingPathComponent("p\(i + 1).json")
    let sc = scenario ?? e.scenario
    // The champion's guards, asked of both sides; their artifacts under the pair's directory (Guards.swift).
    let g = guardRule(e, s, scenario: sc), pdir = dir.appendingPathComponent("p\(i + 1)")
    log("exp \(e.id) \(stage) pair \(i + 1) (\(first ? "champion first" : "candidate first")) on \(fixture)\(sc == e.scenario ? "" : ", scenario \(sc)")")
    let ok: Set<Int32> = [0, 3, 4, 5]                      // pass, budget failed, regression, untrusted: all carry numbers
    let params = e.params ?? [:]
    try runner.prepare(s.champion); try runner.prepare(s.candidate)
    func interrupted() -> Pair {
      var p = Pair(index: i, order: order, result: nil, a: Side(objective: nil), b: Side(objective: nil), failure: "interrupted: input during the rep")
      p.interrupted = true
      return p
    }
    if e.via == "run" {
      var got: [String: JSONValue] = ["order": .string(order)]
      var failure: String?
      for (label, entry, knobs) in first ? [("a", s.champion, s.championKnobs), ("b", s.candidate, s.candidateKnobs)] : [("b", s.candidate, s.candidateKnobs), ("a", s.champion, s.championKnobs)] {
        let o = try Adapter(exe: entry.executable, runner: runner, workDir: dir).run(scenario: sc, fixture: fixture, params: sc == e.scenario ? params : [:], knobs: knobs, env: guardEnv(g, dir: pdir.appendingPathComponent(label)))
        if o.status == interruptedStatus { return interrupted() }
        if let v = o.json, ok.contains(o.status) { got[label] = v } else { failure = "\(label == "a" ? "champion" : "candidate") run exited \(o.status)"; break }
      }
      try PLJSON.write(JSONValue.object(got), path: raw.path)
      let a = got["a"].flatMap { Readings.sides(run: $0, metric: metric).first }, b = got["b"].flatMap { Readings.sides(run: $0, metric: metric).first }
      var p = Pair(index: i, order: order, result: store.rel(raw), a: a ?? Side(objective: nil), b: b ?? Side(objective: nil), failure: failure ?? (a == nil || b == nil ? "no result" : nil))
      judgeSnapshots(&p, g, dir: pdir, sides: s)
      return p
    }
    let firstExe = first ? s.champion.executable : s.candidate.executable, secondExe = first ? s.candidate.executable : s.champion.executable
    let o = try Adapter(exe: s.champion.executable, runner: runner, workDir: dir).ab(first: firstExe, second: secondExe, scenario: sc, fixture: fixture, params: sc == e.scenario ? params : [:], out: raw.path,
                                                      env: guardEnv(g, dir: pdir))
    if o.status == interruptedStatus { return interrupted() }
    let v = o.json ?? (try? PLJSON.read(JSONValue.self, path: raw.path))
    guard let v, ok.contains(o.status) else { return Pair(index: i, order: order, result: store.rel(raw), a: Side(objective: nil), b: Side(objective: nil), failure: "ab exited \(o.status)") }
    if !FileManager.default.fileExists(atPath: raw.path) { try PLJSON.write(v, path: raw.path) }
    let cl = first ? "A" : "B", dl = first ? "B" : "A"
    let a = Readings.sides(ab: v, label: cl, metric: metric).first, b = Readings.sides(ab: v, label: dl, metric: metric).first
    var failure: String? = Readings.failures(ab: v).first.map { "ab: \($0)" }
    // The adapter says which binaries it ran: they must be the store's.
    for (label, want) in [(cl, s.champion.build.hash), (dl, s.candidate.build.hash)] {
      if let got = Readings.build(ab: v, label: label)?.hash, let want, got != want { failure = "ab ran \(Build.short(got)) as \(label), the store has \(Build.short(want))" }
    }
    if a?.objective == nil || b?.objective == nil, failure == nil { failure = "the ab output has no \(metric) (an adapter older than the objective: use --via run)" }
    var p = Pair(index: i, order: order, result: store.rel(raw), a: a ?? Side(objective: nil), b: b ?? Side(objective: nil), failure: failure)
    judgeSnapshots(&p, g, dir: pdir, sides: s)
    return p
  }

  // MARK: screen, full, promote

  public func screen(_ id: String) throws -> Experiment {
    var e = try store.experiment(id)
    guard e.kind != "baseline" else { throw PLError.usage("exp \(e.id) is the baseline") }
    if let s = e.screen, s.verdict != "error" { log("exp \(e.id) is already screened (\(s.verdict))"); return e }
    let s = try sides(e), r = rule(e, s)
    let ps = try pairs(e, stage: "screen", fixture: e.fixture, count: Acceptance.screenPairs, sides: s, metric: r.metric)
    let st = Acceptance.screen(ps, metric: r.metric, guards: r.guards)
    e.screen = st
    if st.verdict == "error" { e.notes.append("screen: no usable pair; rerun perfloop exp screen \(e.id)") }
    else { e.state = st.verdict == "promising" ? .promising : st.verdict == "needsReview" ? .needsReview : .rejected }
    try record(e, st)
    return e
  }

  public func full(_ id: String, force: Bool = false) throws -> Experiment {
    var e = try store.experiment(id)
    if e.state == .rejected && !force { throw PLError.refused("exp \(e.id) was rejected by its screen; --force to run a full anyway") }
    // A screen the owner cleared of its snapshot review goes back to promising (perfloop guards --owner); the owner may
    // also run the full on a screen that still asks for review.
    guard [.promising, .full, .rejected].contains(e.state) || (e.state == .lost && force) || (e.state == .needsReview && e.full == nil && by == "owner") else {
      if e.full != nil { log("exp \(e.id) already has a full (\(e.full!.verdict))"); return e }
      throw PLError.usage("exp \(e.id) is \(e.state.rawValue): screen it first")
    }
    let s = try sides(e), r = rule(e, s)
    if e.state != .full { e.state = .full; try store.save(e); try store.ledger.append(LedgerEntry(experiment: e.id, state: ExpState.full.rawValue, build: e.build?.hash, by: by)) }
    var st = Stage(metric: r.metric, pairs: [], verdict: "pending")
    for look in Acceptance.fullLooks {
      let ps = try pairs(e, stage: "full", fixture: e.fixture, count: look, sides: s, metric: r.metric)
      st = Acceptance.full(ps, metric: r.metric, guards: r.guards, lastLook: look == Acceptance.fullLooks.last)
      if look > Acceptance.fullLooks[0] { st.extendedTo = look }
      if st.verdict != "unknown" { break }
      log("exp \(e.id): unknown at \(look) + \(look) (p = \(st.mwuP ?? 1)): extending")
    }
    e.full = st
    switch st.verdict {
    case "won":
      e.state = .won
      if let sf = e.secondFixture, sf != e.fixture {
        let ps = try pairs(e, stage: "second", fixture: sf, count: Acceptance.screenPairs, sides: s, metric: r.metric)
        let (s2, ok) = Acceptance.notWorse(ps, metric: r.metric, guards: r.guards)
        e.secondScreen = SecondFixture(fixture: sf, stage: s2, notWorse: ok)
        if !ok { e.state = (s2.guardReviews ?? []).isEmpty || !s2.guardsPassed ? .lost : .needsReview; e.notes.append("won on \(e.fixture) but worse on \(sf) (or a guard there): over-fitting one fixture (SPEC §5.5)") }
      }
      // The isolation scenarios' checks hold on the candidate too, whatever this experiment climbs (C6).
      if e.state == .won {
        e.isolation = try isolation(e, sides: s)
        if let bad = e.isolation?.first(where: { !$0.pass }) { e.state = .lost; e.notes.append("isolation broken in \(bad.scenario): " + bad.failures.joined(separator: "; ")) }
      }
    case "noDecision", "needsReview": e.state = .needsReview
    case "error": e.state = .promising; e.notes.append("full: no usable pairs; rerun perfloop exp full \(e.id)")
    default: e.state = .lost
    }
    try record(e, st)
    return e
  }

  public struct PromoteOptions {
    public var owner = false
    /// Promote a dirty build (SPEC §5.1 refuses one): the replay's imported working trees, with the owner's say.
    public var allowDirty = false
    public var pr: String?
    public init() {}
  }

  /// Moves the champion to the experiment's build (SPEC §5.4, §7.5–7.6). Refuses unless the full won (or the owner
  /// decides a needsReview), the build is clean, it was measured against the current champion, its manifest keeps
  /// the champion's objectives, guards and fixtures, and the second fixture is not worse. A behaviour change or a
  /// changed contract needs `--owner`.
  public func promote(_ id: String, _ o: PromoteOptions = PromoteOptions()) throws -> Experiment {
    var e = try store.experiment(id)
    let (c, cEntry) = try requireChampion()
    var refusals: [String] = [], ownerNeeded: [String] = []
    switch e.state {
    case .won: break
    case .needsReview: ownerNeeded.append("no decision at 10 + 10")
    default: refusals.append("exp \(e.id) is \(e.state.rawValue), not won")
    }
    if e.parent?.experiment != c.experiment { refusals.append("measured against champion \(e.parent?.experiment ?? "?"), but the champion is now \(c.experiment): screen it again as a new experiment") }
    if e.build?.dirty != false && !o.allowDirty { refusals.append("the build is dirty (or its state unknown): commit, rebuild, and run it again") }
    if let s = e.secondScreen, !s.notWorse { refusals.append("worse on the second fixture \(s.fixture)") }
    if e.secondFixture != nil && e.secondFixture != e.fixture && e.secondScreen == nil { refusals.append("no screen on the second fixture \(e.secondFixture!)") }
    if e.behaviourChange { ownerNeeded.append("a declared behaviour change") }
    // Guards (C6): a full stage, the isolation scenarios holding (run now if the full predates them), the latest
    // guards re-run passing.
    if e.full == nil && e.kind != "baseline" { refusals.append("no full stage: perfloop exp full \(e.id)") }
    if refusals.isEmpty, e.isolation == nil, !(cEntry.manifest?.isolationGuards ?? []).isEmpty, let s = try? sides(e) {
      e.isolation = try isolation(e, sides: s); try store.save(e)
    }
    for i in e.isolation ?? [] where !i.pass { refusals.append("isolation broken in \(i.scenario): " + i.failures.joined(separator: "; ")) }
    if let r = e.guardRuns?.last, !r.pass {
      if r.failures.isEmpty { ownerNeeded.append("the last guards re-run asks for review") } else { refusals.append("the last guards re-run failed: " + r.failures.joined(separator: "; ")) }
    }
    if let cand = try? store.entry(e.build?.hash ?? ""), let cm = cand.manifest, let km = cEntry.manifest, cm.contract != km.contract {
      ownerNeeded.append("the candidate's manifest changes scenarios, objectives, guards or fixtures (they are their own PR)")
    }
    if !ownerNeeded.isEmpty && !o.owner { refusals.append("needs the owner (--owner): " + ownerNeeded.joined(separator: "; ")) }
    guard refusals.isEmpty else { throw PLError.refused("not promoted: " + refusals.joined(separator: "; ")) }
    guard let b = e.build else { throw PLError.usage("exp \(e.id) has no build") }
    let after = e.full.flatMap { $0.objective["b"] }.map(Stats.median)
    let next = c.succeeded(by: e.id, build: b, objectives: after.map { [e.scenario: $0] } ?? [:], knobs: e.knobs)
    try store.setChampion(next)
    e.state = .promoted; e.promotedAt = Clock.now(); e.pr = o.pr
    if o.allowDirty && b.dirty { e.notes.append("promoted dirty (--allow-dirty)") }
    if let k = e.knobs, !k.isEmpty { e.notes.append("knob debt (SPEC §7.6): bake \(Adapter.knobString(k)) in as the default and delete the knob in a follow-up, this phase") }
    e.notes.append("confirmation traces (profile --template hitches|time) are not recorded yet: run them on an idle Mac for the ledger")
    let before = e.full.flatMap { $0.objective["a"] }.map(Stats.median)
    try store.save(e)
    try store.ledger.append(LedgerEntry(experiment: e.id, state: ExpState.promoted.rawValue, objective: .init(before: before, after: after), build: b.hash, by: o.owner ? "owner" : by,
                                        note: "champion \(c.experiment) → \(e.id); chain \(next.chain)"))
    _ = explain(e)
    return e
  }

  public func abandon(_ id: String, note: String?) throws -> Experiment {
    var e = try store.experiment(id)
    guard e.state != .promoted else { throw PLError.refused("exp \(e.id) is the champion's or was promoted") }
    e.state = .abandoned
    if let n = note { e.notes.append(n) }
    try store.save(e)
    try store.ledger.append(LedgerEntry(experiment: e.id, state: ExpState.abandoned.rawValue, build: e.build?.hash, by: by, note: note))
    _ = explain(e)
    return e
  }

  func record(_ e: Experiment, _ st: Stage) throws {
    var e = e
    let a = st.objective["a"] ?? [], b = st.objective["b"] ?? []
    e.explain = store.rel(store.expDir(e.id).appendingPathComponent("explain.txt"))
    try store.save(e)
    try store.ledger.append(LedgerEntry(experiment: e.id, state: e.state.rawValue, objective: .init(before: a.isEmpty ? nil : Stats.median(a), after: b.isEmpty ? nil : Stats.median(b)),
                                        build: e.build?.hash, by: by, note: "\(st.verdict): " + (st.reasons.first ?? ""), runner: st.runner))
    _ = explain(e)
  }

  // MARK: reading

  /// Writes and returns `exp/<id>/explain.txt`.
  @discardableResult
  public func explain(_ e: Experiment) -> String {
    let text = Explain.experiment(e, champion: store.champion(), stop: Stopping.reasons(StopInput(session: store.ledger.currentSession())))
    let p = store.expDir(e.id).appendingPathComponent("explain.txt")
    try? FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: p, atomically: true, encoding: .utf8)
    return text
  }

  /// The loop at a glance: the champion, the open experiments and what each needs next, the stopping rules.
  public func status() -> String {
    var o: [String] = []
    if let c = store.champion() {
      o.append("champion \(c.experiment) [\(c.build.line)] \(c.merged ? "merged" : "unmerged"), chain \(c.chain)")
      if !c.objectives.isEmpty { o.append("  objectives: " + c.objectives.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) }
      if let k = c.knobs { o.append("  knob debt: " + Adapter.knobString(k)) }
    } else { o.append("no champion: perfloop champion set BUILD --merged") }
    let open = store.experiments().filter { !$0.state.terminal }
    o.append(open.isEmpty ? "no open experiments" : "open experiments:")
    for e in open { o.append("  \(e.id) \(e.state.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(e.scenario)/\(e.fixture) \(e.hypothesis)\n      next: \(Explain.next(e))") }
    for s in Stopping.reasons(StopInput(session: store.ledger.currentSession())) { o.append("stop: " + s) }
    return o.joined(separator: "\n")
  }

  // MARK: diff

  /// Where a profile or trace came from: the build it records, a `<file>.build.json` beside it, or the store's
  /// trace index (`traces/index.jsonl`, written by `trace register`).
  public func provenance(of path: String) -> String? {
    let abs = URL(fileURLWithPath: path).standardizedFileURL.path
    for l in ((try? String(contentsOfFile: store.root.appendingPathComponent("traces/index.jsonl").path, encoding: .utf8)) ?? "").split(separator: "\n").reversed() {
      if let v = try? PLJSON.decode(JSONValue.self, from: Data(l.utf8)), v["path"]?.string == abs, let h = v["build"]?.string { return h }
    }
    if let b = try? PLJSON.read(Build.self, path: abs + ".build.json"), let h = b.hash { return h }
    if !abs.hasSuffix(".trace"), let v = try? PLJSON.read(JSONValue.self, path: abs) { return v.at("build.hash")?.string ?? v.at("tool.build.hash")?.string }
    return nil
  }

  /// Records which build a trace was recorded on (paths only: the trace stays where it is, out of any repo).
  public func register(trace path: String, build key: String) throws {
    let e = try store.entry(key)
    let abs = URL(fileURLWithPath: path).standardizedFileURL.path
    let idx = store.root.appendingPathComponent("traces/index.jsonl")
    try FileManager.default.createDirectory(at: idx.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: idx.path) { FileManager.default.createFile(atPath: idx.path, contents: nil) }
    let h = try FileHandle(forWritingTo: idx); try h.seekToEnd()
    try h.write(contentsOf: Data((PLJSON.line(JSONValue.object(["path": .string(abs), "build": .string(e.build.hash ?? ""), "at": .string(Clock.now())])) + "\n").utf8)); try h.close()
  }

  /// `diff A B`: refuses inputs recorded on any build but the champion's or the experiment's (SPEC §5.5, stale
  /// trace) unless `allowStale`, then runs the champion adapter's `diff`. Returns its JSON text.
  public func diff(_ a: String, _ b: String, exp: String?, allowStale: Bool) throws -> String {
    let (c, cEntry) = try requireChampion()
    let ex = try exp.map { try store.experiment($0) }
    var allowed: [String: String] = [:]
    if let h = c.build.hash { allowed[h] = "champion \(c.experiment)" }
    if let h = ex?.build?.hash { allowed[h] = "exp \(ex!.id)" }
    var problems: [String] = [], files: [String] = []
    for x in [a, b] {
      if x == "champion" || x.hasPrefix("exp/") { problems.append("\(x) has no recorded profile yet (confirmation traces come with the profile step); pass a profile or trace file"); continue }
      files.append(x)
      guard let h = provenance(of: x) else { problems.append("\(x): unknown provenance (no build recorded for it; perfloop trace register \(x) --build HASH)"); continue }
      if allowed[h] == nil {
        let commit = (try? store.entry(h))?.build.commit ?? Build.short(h)
        problems.append("\(x): trace build \(commit) ≠ champion \(c.build.commit ?? Build.short(c.build.hash ?? ""))\(ex.map { " or exp \($0.id)" } ?? "")")
      }
    }
    if !problems.isEmpty && (!allowStale || files.count < 2) { throw PLError.refused("diff refused: " + problems.joined(separator: "; ") + (files.count == 2 ? " (--allow-stale to compare anyway)" : "")) }
    for f in files where TracePrivacy.inCheckout(f) { log("warning: \(f) is inside a git checkout; a trace holds the recorded process's environment: move it out") }
    let o = try Adapter(exe: cEntry.executable).diff(files[0], files[1])
    guard o.status == 0 else { throw PLError.harness("diff exited \(o.status)") }
    if var e = ex {
      let p = store.expDir(e.id).appendingPathComponent("diff.json")
      try o.stdout.write(to: p, atomically: true, encoding: .utf8)
      e.diff = store.rel(p); if allowStale && !problems.isEmpty { e.notes.append("diff with --allow-stale: " + problems.joined(separator: "; ")) }
      try store.save(e); _ = explain(e)
    }
    return o.stdout
  }
}

/// A trace inside a git checkout is one `git add .` from being published (SPEC §4.3).
public enum TracePrivacy {
  public static func inCheckout(_ path: String) -> Bool {
    var u = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent()
    while u.path != "/" && !u.path.isEmpty {
      if FileManager.default.fileExists(atPath: u.appendingPathComponent(".git").path) { return true }
      u = u.deletingLastPathComponent()
    }
    return false
  }
}
