import Foundation
import PerfLoopKit

// `perfloop run` and `perfloop baseline` (F5): one build's scenario measured on its own, with no champion on the other
// side and so no verdict. The reps go through the same runner as a pair's sides (the screen-lock wait, the idle and
// quiet gates, the window lock) and are judged for trust the same way, so a feature's own scenario, one the
// champion doesn't have yet, is measured through PerfLoop and lands in the ledger instead of being run by hand.
// Only the adapter's `run` verb is used: every protocol-1 adapter answers it (ADAPTER.md §3), `ab`-only or not.

extension Store {
  public func measureDir(_ id: String) -> URL { root.appendingPathComponent("runs").appendingPathComponent(id) }
  public func save(_ m: ScenarioRun) throws { try PLJSON.write(m, path: measureDir(m.id).appendingPathComponent("run.json").path) }

  /// "m0003", "run/m0003", "3" → the measurement.
  public func measurement(_ id: String) throws -> ScenarioRun {
    var t = id.hasPrefix("run/") ? String(id.dropFirst(4)) : id
    if let n = Int(t.hasPrefix("m") ? String(t.dropFirst()) : t) { t = String(format: "m%04d", n) }
    let p = measureDir(t).appendingPathComponent("run.json").path
    guard FileManager.default.fileExists(atPath: p) else { throw PLError.usage("no measurement \(t) in \(root.path) (perfloop ledger lists them: state measure)") }
    return try PLJSON.read(ScenarioRun.self, path: p)
  }

  public func measurements() -> [ScenarioRun] {
    let ids = ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("runs").path)) ?? []).sorted()
    return ids.compactMap { try? measurement($0) }
  }

  public func nextMeasureID() -> String {
    let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("runs").path)) ?? []
    let n = ids.compactMap { $0.hasPrefix("m") ? Int($0.dropFirst()) : nil }.max().map { $0 + 1 } ?? 1
    return String(format: "m%04d", n)
  }

  public func baselineDir(_ scenario: String) -> URL { root.appendingPathComponent("baselines").appendingPathComponent(Sweep.fileName(scenario)) }
  public func baseline(_ scenario: String) -> BaselineRecord? {
    try? PLJSON.read(BaselineRecord.self, path: baselineDir(scenario).appendingPathComponent("baseline.json").path)
  }
  public func baselines() -> [BaselineRecord] {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("baselines").path)) ?? []).sorted()
    return names.compactMap { try? PLJSON.read(BaselineRecord.self, path: root.appendingPathComponent("baselines/\($0)/baseline.json").path) }
  }
}

extension Loop {
  public struct MeasureOptions {
    /// champion, exp/ID, a build in the store (hash or prefix), or a stamped bench's path (added to the store).
    public var target: String
    /// run | baseline.
    public var kind = "run"
    public var scenario: String?
    public var fixture: String?
    public var reps = 3
    public var params: [String: String] = [:]
    public var knobs: [String: String] = [:]
    /// A scenario of the champion's, run on the champion interleaved with these reps (one of it per rep).
    public var reference: String?
    public var exe: String?
    public init(target: String, kind: String = "run") { self.target = target; self.kind = kind; reps = kind == "baseline" ? 5 : 3 }
  }

  /// What a `run` target stands for: the build, the knobs it runs with, and its own scenario and fixture, if any.
  public struct MeasureTarget {
    public var label: String
    public var entry: Store.Entry
    public var knobs: [String: String]
    public var scenario: String?
    public var fixture: String?
  }

  public func measureTarget(_ x: String, exe: String? = nil) throws -> MeasureTarget {
    if Self.isProfileTarget(x) {
      let t = try profileTarget(x)
      return MeasureTarget(label: x, entry: try store.entry(t.build), knobs: t.knobs, scenario: t.scenario == "-" ? nil : t.scenario, fixture: t.fixture == "-" ? nil : t.fixture)
    }
    if FileManager.default.fileExists(atPath: Store.tilde(x)) {
      let e = try store.add(x, exe: exe)
      return MeasureTarget(label: "build \(Build.short(e.build.hash ?? ""))", entry: e, knobs: [:])
    }
    do {
      let e = try store.entry(x)
      return MeasureTarget(label: "build \(Build.short(e.build.hash ?? ""))", entry: e, knobs: [:])
    } catch {
      throw PLError.usage("\(x): not champion, exp/ID, a build in the store (perfloop store list) or a bench path (\(error))")
    }
  }

  /// `perfloop run` (and the measuring half of `perfloop baseline`): `reps` reps of the scenario on the target's build,
  /// each through the runner and judged for trust, interleaved with the champion's `reference` scenario when asked;
  /// stored under `runs/<id>/`, one ledger line (`measure`), and no verdict.
  public func runScenario(_ o: MeasureOptions) throws -> ScenarioRun {
    guard o.reps >= 1 else { throw PLError.usage("--reps takes a count ≥ 1") }
    let t = try measureTarget(o.target, exe: o.exe)
    let m = t.entry.manifest
    let champ = store.champion()
    let cEntry = champ.flatMap { try? store.entry($0.build.hash ?? "") }
    // The build's own manifest says what it can run: the scenario may be one only it has (a feature's own). No verdict
    // comes of it, so there is nothing for the build to judge itself by.
    guard let sc = o.scenario ?? t.scenario ?? m?.scenarios.first?.name else { throw PLError.usage("pass --scenario: the build's manifest names none") }
    if let m, m.scenario(sc) == nil { throw PLError.usage("unknown scenario '\(sc)'; \(t.label)'s manifest has \(m.scenarios.map(\.name).joined(separator: ", "))") }
    if o.kind == "baseline", let cm = cEntry?.manifest, cm.scenario(sc) != nil {
      throw PLError.usage("the champion has \(sc) already, so it is the baseline: perfloop run champion --scenario \(sc) measures it, and perfloop exp new … --scenario \(sc) judges a change against it")
    }
    guard let fx = o.fixture ?? (t.scenario == sc ? t.fixture : nil) ?? m?.fixture(for: sc) else { throw PLError.usage("pass --fixture: the build's manifest names none") }
    if let m, let why = m.unknownFixture(fx, whose: "\(t.label)'s manifest") { throw PLError.usage(why) }
    if let ks = m?.knobs {
      for (k, v) in o.knobs {
        guard let knob = ks.first(where: { $0.name == k }) else { throw PLError.usage("unknown knob '\(k)'; the manifest has \(ks.map(\.name).joined(separator: ", ").ifEmpty("none"))") }
        guard knob.accepts(v) else { throw PLError.usage("knob \(k) doesn't take '\(v)' (\(knob.choices?.joined(separator: "|") ?? knob.range.map { "\($0)" } ?? "?"))") }
      }
    }
    var ref: (scenario: String, fixture: String, entry: Store.Entry, champion: Champion)?
    if let r = o.reference {
      guard let c = champ, let ce = cEntry else { throw PLError.usage("--reference runs a champion's scenario: there is no champion yet (perfloop champion set BUILD --merged)") }
      if let cm = ce.manifest, cm.scenario(r) == nil { throw PLError.usage("unknown reference scenario '\(r)'; the champion's manifest has \(cm.scenarios.map(\.name).joined(separator: ", "))") }
      let base = try? store.experiment(c.experiment)
      guard let rf = (base?.scenario == r ? base?.fixture : nil) ?? ce.manifest?.fixture(for: r) else { throw PLError.usage("the champion's manifest names no fixture for \(r)") }
      ref = (r, rf, ce, c)
    }
    let metric = m?.scenario(sc)?.objective ?? "mainThreadCpuMsPerStep"
    let id = store.nextMeasureID(), dir = store.measureDir(id)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var x = ScenarioRun(id: id, kind: o.kind, target: t.label, build: t.entry.build.embedded, scenario: sc, fixture: fx, metric: metric, by: by)
    x.expectedFixture = m?.scenario(sc)?.fixture
    let knobs = t.knobs.merging(o.knobs) { $1 }
    x.knobs = knobs.isEmpty ? nil : knobs
    x.params = o.params.isEmpty ? nil : o.params
    x.runner = try runner.identity()
    try runner.prepare(t.entry)
    if let r = ref { try runner.prepare(r.entry) }
    log("\(o.kind) \(id): \(sc) on \(fx), \(o.reps) rep(s) of \(t.label)" + (ref.map { ", each beside one of \($0.scenario) on the champion" } ?? ""))

    // The build's own guards for its scenario (its snapshot among them), asked of every rep.
    let sEntry = m?.scenario(sc)
    let g = (guards: GuardNames.correctness(sEntry), params: sEntry?.guardParams ?? [:])
    var reps: [MeasureRep] = []
    var reference: MeasureReference?
    if let r = ref {
      reference = MeasureReference(scenario: r.scenario, fixture: r.fixture, experiment: r.champion.experiment, build: r.entry.build.embedded,
                                   metric: r.entry.manifest?.scenario(r.scenario)?.objective ?? "mainThreadCpuMsPerStep")
      reference?.championObjective = r.champion.objectives[r.scenario]
    }
    for i in 0..<o.reps {
      let refFirst = ref != nil && championFirst("\(id)/run", i)
      if refFirst, let r = ref, var rr = reference {
        rr.reps.append(try measureRep(id, index: i, name: "ref\(i + 1)", entry: r.entry, scenario: r.scenario, fixture: r.fixture, params: [:], knobs: r.champion.knobs ?? [:],
                                      metric: rr.metric, env: [:], dir: dir, earlier: rr.reps))
        reference = rr
      }
      var rep = try measureRep(id, index: i, name: "r\(i + 1)", entry: t.entry, scenario: sc, fixture: fx, params: o.params, knobs: knobs, metric: metric,
                               env: guardEnv(g, dir: dir.appendingPathComponent("r\(i + 1)")), dir: dir, earlier: reps)
      if ref != nil { rep.order = refFirst ? "after" : "before" }
      reps.append(rep)
      if !refFirst, let r = ref, var rr = reference {
        rr.reps.append(try measureRep(id, index: i, name: "ref\(i + 1)", entry: r.entry, scenario: r.scenario, fixture: r.fixture, params: [:], knobs: r.champion.knobs ?? [:],
                                      metric: rr.metric, env: [:], dir: dir, earlier: rr.reps))
        reference = rr
      }
    }
    x.reps = reps
    x.summary = Measure.summary(reps)
    if var r = reference { r.summary = Measure.summary(r.reps); x.reference = r }

    let capture = reps.filter(\.trusted).lazy.compactMap { r in
      r.side.guards?.first { $0.name == GuardNames.snapshotDiff && $0.pass }?.artifacts.first { $0.hasSuffix(".png") && !$0.hasSuffix(".later.png") }
    }.first { FileManager.default.fileExists(atPath: $0) }
    var record: BaselineRecord?
    if o.kind == "baseline" {
      record = try writeBaseline(x, capture: capture)
    } else if let b = store.baseline(sc), b.measurement != id {
      x.againstBaseline = Measure.compare(x.summary, fixture: fx, reference: x.reference, with: b)
      if let shot = b.snapshot.map(store.abs), FileManager.default.fileExists(atPath: shot), let c = capture {
        x.snapshot = compareSnapshot(shot, c, scenario: sc, params: g.params, build: t.entry, champion: cEntry, dir: dir)
      }
    }
    // Pictures are a few MB each: the reps' are deleted; what a person has to look at is in the run's own folder.
    for p in Self.pictures(under: dir) { try? FileManager.default.removeItem(at: p) }

    x.next = measureNext(x, recorded: record, championHas: cEntry?.manifest?.scenario(sc) != nil || (cEntry != nil && cEntry?.manifest == nil))
    try store.save(x)
    let text = Measure.text(x, store: store.rel(dir.appendingPathComponent("run.json")))
    try? text.write(to: dir.appendingPathComponent("run.txt"), atomically: true, encoding: .utf8)
    var note = "\(o.kind) \(sc) on \(fx): " + (x.summary.median.map { "\(metric) \(Measure.number($0)) median, \(x.summary.trusted)/\(x.summary.ran) reps trusted" }
      ?? "UNTRUSTED (\(x.summary.untrusted ?? "\(x.summary.failed) rep(s) failed"))")
    if o.kind == "baseline" { note += record == nil ? "; no baseline recorded" : "; recorded as the baseline of \(sc)" }
    try store.ledger.append(LedgerEntry(experiment: id, state: "measure", objective: x.summary.median.map { .init(before: nil, after: $0) }, build: t.entry.build.hash, by: by,
                                        note: note, runner: x.runner))
    return x
  }

  /// One rep, redone while the runner aborts it on input, and once more when it failed or was untrusted and a redo
  /// could come out differently.
  func measureRep(_ id: String, index i: Int, name: String, entry: Store.Entry, scenario: String, fixture: String, params: [String: String], knobs: [String: String],
                  metric: String, env: [String: String], dir: URL, earlier: [MeasureRep]) throws -> MeasureRep {
    var r = try measureAttempt(index: i, name: name, entry: entry, scenario: scenario, fixture: fixture, params: params, knobs: knobs, metric: metric, env: env, dir: dir)
    if let why = r.failure ?? r.untrusted, Measure.worthRedoing(r, after: earlier) {
      log("\(id) \(name): \(why); once more")
      let n = r.interruptions
      r = try measureAttempt(index: i, name: name + "-redo", entry: entry, scenario: scenario, fixture: fixture, params: params, knobs: knobs, metric: metric, env: env, dir: dir)
      if let n { r.interruptions = (r.interruptions ?? 0) + n }
      r.redone = why
    }
    return r
  }

  func measureAttempt(index i: Int, name: String, entry: Store.Entry, scenario: String, fixture: String, params: [String: String], knobs: [String: String],
                      metric: String, env: [String: String], dir: URL) throws -> MeasureRep {
    let raw = dir.appendingPathComponent("\(name).json")
    var n = 0
    while true {
      let o = try Adapter(exe: entry.executable, runner: runner, workDir: dir).run(scenario: scenario, fixture: fixture, params: params, knobs: knobs, env: env)
      if o.status == interruptedStatus {
        n += 1
        guard n <= maxRedo else { return MeasureRep(index: i, result: nil, side: Side(objective: nil), failure: "interrupted \(n) times in a row (input, or the screen locked)") }
        log("\(name): interrupted (input, or the screen locked); redoing it (\(n))")
        continue
      }
      // Pass, budget failed, regression, untrusted: all carry numbers (ADAPTER.md §3).
      guard let v = o.json, [0, 3, 4, 5].contains(o.status) else {
        var r = MeasureRep(index: i, result: nil, side: Side(objective: nil), failure: "the run exited \(o.status)\(o.json == nil ? " without a result" : "")")
        r.interruptions = n > 0 ? n : nil
        return r
      }
      try PLJSON.write(v, path: raw.path)
      var s = Readings.sides(run: v, metric: metric).first
      s?.exit = Int(o.status)
      Self.stamp(&s, o.machine)
      let side = s ?? Side(objective: nil)
      var failure = Measure.fixtureMismatch(side, asked: fixture)
      if failure == nil, side.objective == nil, side.noFrames != true { failure = "the result has no \(metric)" }
      var r = MeasureRep(index: i, result: store.rel(raw), side: side, failure: failure)
      r.interruptions = n > 0 ? n : nil
      return r
    }
  }

  /// `perfloop baseline`: the scenario's first numbers, from trusted reps only, with the reference picture. A run with
  /// no trusted rep records nothing (a baseline that only looks fine would mislead every later comparison).
  func writeBaseline(_ x: ScenarioRun, capture: String?) throws -> BaselineRecord? {
    let s = x.summary
    guard let med = s.median, let lo = s.min, let hi = s.max else { return nil }
    var b = BaselineRecord(scenario: x.scenario, fixture: x.fixture, metric: x.metric, measurement: x.id, build: x.build, trusted: s.trusted, reps: s.ran, median: med, min: lo, max: hi)
    b.referenceScenario = x.reference?.scenario; b.referenceMedian = x.reference?.summary.median
    b.replaces = store.baseline(x.scenario)?.measurement
    let dir = store.baselineDir(x.scenario)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fm = FileManager.default
    for f in ["reference.png", "reference.later.png"] { try? fm.removeItem(at: dir.appendingPathComponent(f)) }
    if let c = capture {
      let png = dir.appendingPathComponent("reference.png")
      try fm.copyItem(atPath: c, toPath: png.path)
      let later = String(c.dropLast(4)) + ".later.png"
      if fm.fileExists(atPath: later) { try fm.copyItem(atPath: later, toPath: dir.appendingPathComponent("reference.later.png").path) }
      b.snapshot = store.rel(png)
    }
    try PLJSON.write(b, path: dir.appendingPathComponent("baseline.json").path)
    return b
  }

  /// The run's picture against the baseline's, judged by the champion's adapter when it has the scenario (the judge
  /// the loop uses), else by the measured build's own; nil when neither answers `snapdiff`.
  func compareSnapshot(_ reference: String, _ capture: String, scenario: String, params: [String: JSONValue], build: Store.Entry, champion: Store.Entry?, dir: URL) -> GuardResult? {
    let judge = [champion].compactMap { $0 }.first { $0.manifest?.scenario(scenario) != nil && $0.manifest?.has(verb: "snapdiff") != false }
      ?? (build.manifest?.has(verb: "snapdiff") != false ? build : nil)
    guard let j = judge else { return nil }
    let fm = FileManager.default
    // The run's picture is kept beside the diff while it needs a look (the rep folders are cleaned up).
    let mine = dir.appendingPathComponent("snapshot.png").path, diffOut = dir.appendingPathComponent("snapshot-diff.png").path
    try? fm.copyItem(atPath: capture, toPath: mine)
    let later = String(capture.dropLast(4)) + ".later.png"
    if fm.fileExists(atPath: later) { try? fm.copyItem(atPath: later, toPath: String(mine.dropLast(4)) + ".later.png") }
    var r: GuardResult
    if let o = try? Adapter(exe: j.executable).snapdiff(reference, mine, params: GuardNames.params(params), diffOut: diffOut), let v = o.json?["guard"], let g = GuardResult(json: v), [0, 3].contains(o.status) {
      r = g
    } else {
      r = GuardResult(name: GuardNames.snapshotDiff, pass: false, detail: "snapdiff couldn't compare the baseline's picture with this run's", artifacts: [reference, mine], review: true)
    }
    try? fm.removeItem(atPath: String(mine.dropLast(4)) + ".later.png")
    if r.pass { for f in [mine, diffOut] { try? fm.removeItem(atPath: f) }; r.artifacts = [] }
    else { r.artifacts = [reference, mine, diffOut].filter { fm.fileExists(atPath: $0) }.map { store.rel(URL(fileURLWithPath: $0)) } }
    return r
  }

  /// The step after a measurement, for the agent: never "looks fine" when nothing could be trusted.
  func measureNext(_ x: ScenarioRun, recorded: BaselineRecord?, championHas: Bool) -> String {
    let s = x.summary, again = "perfloop \(x.kind == "baseline" ? "baseline \(x.scenario) --build \(Build.short(x.build.hash ?? ""))" : "run \(x.target.hasPrefix("build ") ? String(x.target.dropFirst(6)) : x.target) --scenario \(x.scenario)")"
    if s.ran == 0 { return "every rep failed (the reps above say how): fix that, then \(again)" }
    if s.trusted == 0 {
      if let d = s.deterministic { return "a rerun won't help (\(d)): the build's window isn't active and key where the bench looks (ADAPTER.md §3: a key child window counts as key); fix that first. These numbers are not to be quoted" }
      return "\(again) once the Mac is quiet and unlocked (perfloop doctor says what isn't); no number above is to be quoted" + (x.kind == "baseline" ? ", and no baseline was recorded" : "")
    }
    if !s.checksFailed.isEmpty || !s.guardsFailed.isEmpty { return "the scenario's own checks failed (\((s.checksFailed + s.guardsFailed).joined(separator: ", "))): fix the feature before reading its numbers" }
    if let g = x.snapshot, !g.pass { return "look at the two pictures and the diff above: a change from the baseline's look is the owner's call (say so in your PR)" }
    if x.kind == "baseline" {
      return "quote this baseline in your PR and commit the scenario with the feature; once the champion has \(x.scenario), perfloop run champion --scenario \(x.scenario) compares it with this baseline"
    }
    if championHas {
      if x.target == "champion" { return "numbers, not a verdict: to judge a change on \(x.scenario), perfloop exp new \"<hypothesis>\" … --scenario \(x.scenario)" }
      return "numbers, not a verdict: perfloop exp new \"<hypothesis>\" --build \(Build.short(x.build.hash ?? "")) --scenario \(x.scenario) judges this build against the champion on it"
    }
    return "numbers, not a verdict: the champion has no \(x.scenario) yet, so nothing judges it; perfloop baseline \(x.scenario) --build \(Build.short(x.build.hash ?? "")) records first numbers and a reference snapshot that later champions are compared with" + (x.reference == nil ? " (--reference SCENARIO adds a champion scenario in the same minutes as a yardstick)" : "")
  }

  /// For `exp status`: baselines whose scenario the champion has now and that no run of the champion has been
  /// compared with yet, and those still waiting for a champion with their scenario.
  func baselineLines() -> [String] {
    let bs = store.baselines()
    guard !bs.isEmpty, let c = store.champion(), let cm = try? store.entry(c.build.hash ?? "").manifest else { return [] }
    var o: [String] = [], waiting: [String] = []
    let runs = store.measurements()
    for b in bs {
      guard cm.scenario(b.scenario) != nil else { waiting.append("\(b.scenario) (\(b.measurement))"); continue }
      if runs.contains(where: { $0.build.hash == c.build.hash && $0.againstBaseline?.measurement == b.measurement }) { continue }
      o.append("baseline \(b.scenario) (\(b.measurement), \(b.metric) \(Measure.number(b.median)) on \(b.fixture)): the champion has \(b.scenario) now; perfloop run champion --scenario \(b.scenario) compares it with the baseline")
    }
    if !waiting.isEmpty { o.append("baselines waiting for a champion with their scenario: " + waiting.joined(separator: ", ")) }
    return o
  }

  /// The reps' pictures: every `.png` in a measurement's subfolders (`r1/`, `ref2/`, …).
  static func pictures(under dir: URL) -> [URL] {
    guard let e = FileManager.default.enumerator(atPath: dir.path) else { return [] }
    return e.compactMap { $0 as? String }.filter { $0.contains("/") && $0.hasSuffix(".png") }.map { dir.appendingPathComponent($0) }
  }

  /// `perfloop run`'s exit code: 2 every rep failed, 5 nothing could be trusted (or, for a baseline, none was
  /// recorded), 3 a check or guard failed in a trusted rep, else 0.
  public static func exitCode(_ m: ScenarioRun) -> Int32 {
    if m.summary.ran == 0 { return 2 }
    if m.summary.trusted == 0 { return 5 }
    return m.summary.checksFailed.isEmpty && m.summary.guardsFailed.isEmpty ? 0 : 3
  }
}

extension Loop {
  /// `exp new` on a scenario the champion doesn't have: a feature's own scenario can't be judged against it yet, but it
  /// can be measured (`run`) and given first numbers (`baseline`).
  static func unknownScenario(_ sc: String, _ m: Manifest) -> String {
    "unknown scenario '\(sc)'; the champion's manifest has \(m.scenarios.map(\.name).joined(separator: ", ")). A scenario only your build has (a feature's own) "
      + "can't be judged against the champion until the champion has it: measure it with perfloop run BUILD --scenario \(sc) (numbers, no verdict), "
      + "or record its first numbers with perfloop baseline \(sc) --bench PATH"
  }

  /// A pair whose side ran another fixture than the one asked for has numbers of the wrong data: it can't decide.
  static func fixtureMismatch(p a: Side?, _ b: Side?, asked: String) -> String? {
    if let a, let why = Measure.fixtureMismatch(a, asked: asked) { return "the champion " + why }
    if let b, let why = Measure.fixtureMismatch(b, asked: asked) { return "the candidate " + why }
    return nil
  }
}
