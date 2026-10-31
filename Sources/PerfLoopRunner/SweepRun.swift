import Foundation
import PerfLoopKit

/// `perfloop sweep` (C8): runs a grid of fixture parameters, knobs and scenario params through the adapter's
/// `run`, one child per point, and fits cost curves through the objective. Every point is written before the next
/// starts (`points/<key>.point.json`), so a stopped sweep resumes at the first missing point when the same command
/// runs again. A point that opens a window can hold a lock directory for its duration (`--lock DIR`), so several
/// agents sharing one Mac take turns at the window between points.
public final class SweepRun {
  public struct Options {
    public var scenario: String
    public var fixture: String?
    /// `name=values` (SweepAxis.parse); one value is fixed, several are an axis.
    public var sets: [String] = []
    public var reps = 3
    public var objective: String?
    public var out: String?
    /// Stop starting points once this many minutes are spent (a resumed run counts afresh).
    public var budgetMin: Double?
    /// mkdir-style lock held while a point runs (other agents' window runs wait for it, and it for them).
    public var lock: String?
    /// Points per lock hold.
    public var lockEvery = 1
    /// shuffle (default: drift spreads over the curve) or grid (first axis slowest).
    public var order = "shuffle"
    /// Measure every point again, ignoring finished ones.
    public var fresh = false
    /// Point keys (`agents=16,items=100`) to measure again.
    public var redo: [String] = []
    /// Seconds a rep and a point's fixed cost take, for the estimate before any point is measured.
    public var repS: Double?
    public var startupS: Double?
    public init(scenario: String) { self.scenario = scenario }
  }

  public struct Plan {
    public var exe: String
    public var manifest: Manifest?
    public var scenario: String
    public var fixture: String
    public var metric: String
    public var axes: [SweepAxis]
    public var fixed: [String: String]
    var fixedRoles: [String: String]
    /// In measuring order.
    public var points: [[String: String]]
    public var dir: URL
    /// Finished points already in `dir`, by key.
    public var done: [String: SweepPoint]
    public var reps: Int
    public var perPointS: Double
    public var estimated: Bool
    public var todo: [[String: String]] { points.filter { done[Sweep.key($0, axes: axes)]?.usable != true } }
    public var estimateS: Double { Double(todo.count) * perPointS }
  }

  public var log: (String) -> Void = { FileHandle.standardError.write(Data(("perfloop: " + $0 + "\n").utf8)) }
  public var env = ProcessInfo.processInfo.environment
  /// Seconds between tries at a held lock.
  public var lockPollS: Double = 5
  public init() {}

  // MARK: plan

  /// Decides each `--set`'s role from the manifest (a knob, a parameter of the fixture, a scenario param; `knob:`,
  /// `fixture:` and `param:` prefixes force one), the grid, its order and the directory, and reads what is done.
  public func plan(exe: String, manifest m: Manifest?, _ o: Options, home: URL) throws -> Plan {
    if let m, m.scenario(o.scenario) == nil { throw PLError.usage("unknown scenario '\(o.scenario)'; the bench has \(m.scenarios.map(\.name).joined(separator: ", "))") }
    let sc = m?.scenario(o.scenario)
    let metric = o.objective ?? sc?.objective ?? "mainThreadCpuMsPerStep"
    var parsed: [(name: String, role: String, values: [String])] = []
    for s in o.sets {
      let (raw, values): (String, [String])
      do { (raw, values) = try SweepAxis.parse(s) } catch let e as SweepError { throw PLError.usage(e.description) }
      parsed.append((raw, "", values))
    }
    // The fixture: given, else the default (or the first parametric one) when a fixture parameter is swept, else the
    // default, else the first.
    let fixtures = m?.fixtures ?? []
    func entry(_ name: String) -> JSONValue? { fixtures.first { $0["name"]?.string == String(name.split(separator: "@").first ?? "") } }
    func params(_ f: String?) -> [String: JSONValue] { f.flatMap { entry($0)?["parametric"]?.object } ?? [:] }
    let isParametric = { (n: String?) in n.map { entry($0)?["parametric"]?.object?.isEmpty == false } ?? false }
    let parametric = isParametric(m?.defaultFixture) ? m?.defaultFixture : fixtures.first { $0["parametric"]?.object?.isEmpty == false }?["name"]?.string
    let wantsFixtureParam = parsed.contains { p in p.name.hasPrefix("fixture:") || (m?.knobs.contains { $0.name == p.name } != true && fixtures.contains { $0["parametric"]?[p.name] != nil }) }
    guard let fixture = o.fixture ?? (wantsFixtureParam ? parametric : nil) ?? m?.defaultFixture ?? fixtures.first?["name"]?.string else { throw PLError.usage("pass --fixture: the bench's manifest names none") }
    if let m, !m.fixtures.isEmpty, entry(fixture) == nil { throw PLError.usage("unknown fixture '\(fixture)'; the bench has \(m.fixtureNames.joined(separator: ", "))") }
    let fp = params(fixture)
    for i in parsed.indices {
      var n = parsed[i].name
      var role = ""
      for (p, r) in [("knob:", "knob"), ("fixture:", "fixture"), ("param:", "param")] where n.hasPrefix(p) { n = String(n.dropFirst(p.count)); role = r }
      if role.isEmpty {
        if m?.knobs.contains(where: { $0.name == n }) == true { role = "knob" }
        else if fp[n] != nil { role = "fixture" }
        else if sc?.params[n] != nil || m == nil { role = "param" }
        else {
          throw PLError.usage("--set \(n): not a knob (\((m?.knobs.map(\.name) ?? []).joined(separator: ", "))), a parameter of fixture \(fixture) (\(fp.keys.sorted().joined(separator: ", ").ifEmpty("none"))) " +
                              "nor a parameter of \(o.scenario) (\((sc?.params.keys.sorted() ?? []).joined(separator: ", ").ifEmpty("none"))); prefix it with param: to pass it anyway")
        }
      }
      parsed[i].name = n; parsed[i].role = role
      // Values the manifest says the adapter refuses fail here, not after an hour of points.
      if role == "knob", let k = m?.knobs.first(where: { $0.name == n }) {
        for v in parsed[i].values where !k.accepts(v) { throw PLError.usage("knob \(n) doesn't take '\(v)' (\(k.choices?.joined(separator: "|") ?? k.range.map { "\($0)" } ?? "?"))") }
      }
      if role == "fixture", let r = fp[n]?.array?.compactMap(\.double), r.count == 2 {
        for v in parsed[i].values { guard let x = Double(v), x >= r[0], x <= r[1] else { throw PLError.usage("fixture \(fixture)'s \(n) is \(Sweep.fmt(r[0]))…\(Sweep.fmt(r[1])); '\(v)' is outside it") } }
      }
    }
    let names = parsed.map(\.name)
    if Set(names).count != names.count { throw PLError.usage("a --set name appears twice") }
    let axes = parsed.filter { $0.values.count > 1 }.map { SweepAxis(name: $0.name, role: $0.role, values: $0.values) }
    guard !axes.isEmpty else { throw PLError.usage("nothing to sweep: give at least one --set with several values (agents=4..64/4)") }
    var fixed: [String: String] = [:], fixedRoles: [String: String] = [:]
    for p in parsed where p.values.count == 1 { fixed[p.name] = p.values[0]; fixedRoles[p.name] = p.role }

    let benchHash = m?.build?.hash ?? FileHash.sha256(file: exe) ?? exe
    let identity = PLJSON.line(JSONValue.object([
      "bench": .string(benchHash), "scenario": .string(o.scenario), "fixture": .string(fixture), "metric": .string(metric), "reps": .number(Double(o.reps)),
      "axes": .array(axes.map { .string("\($0.role):\($0.name)=\($0.values.joined(separator: ","))") }),
      "fixed": .object(fixed.mapValues(JSONValue.string)),
    ]))
    let id = String(FileHash.sha256(Data(identity.utf8)).prefix(8))
    let dir = o.out.map { URL(fileURLWithPath: Store.tilde($0)) }
      ?? home.appendingPathComponent("sweeps").appendingPathComponent(Sweep.fileName("\(o.scenario)-\(fixture.split(separator: "@").first ?? "")-\(id)"))
    let points = Sweep.order(Sweep.grid(axes), o.order, seed: identity)
    var done: [String: SweepPoint] = [:]
    if !o.fresh {
      for p in points {
        let k = Sweep.key(p, axes: axes)
        if o.redo.contains(k) { continue }
        if let sp = try? PLJSON.read(SweepPoint.self, path: pointFile(dir, k).path) { done[k] = sp }
      }
    }
    let walls = done.values.filter(\.usable).compactMap(\.wallS)
    let perPoint = walls.isEmpty ? (o.startupS ?? 6) + Double(o.reps) * (o.repS ?? 7) : walls.reduce(0, +) / Double(walls.count)
    return Plan(exe: exe, manifest: m, scenario: o.scenario, fixture: fixture, metric: metric, axes: axes, fixed: fixed, fixedRoles: fixedRoles, points: points, dir: dir,
                done: done, reps: o.reps, perPointS: perPoint, estimated: walls.isEmpty)
  }

  func pointFile(_ dir: URL, _ key: String) -> URL { dir.appendingPathComponent("points").appendingPathComponent(Sweep.fileName(key) + ".point.json") }
  func rawFile(_ dir: URL, _ key: String) -> URL { dir.appendingPathComponent("points").appendingPathComponent(Sweep.fileName(key) + ".json") }

  /// What a sweep would do: the grid in order, what's done, and how long the rest should take.
  public func dryRun(_ p: Plan, budgetMin: Double? = nil) -> String {
    var o: [String] = []
    o.append("sweep \(p.scenario) on \(p.fixture) · \(p.metric) · \(p.reps) rep(s) a point · \(p.points.count) point(s), \(p.done.values.filter(\.usable).count) done")
    for a in p.axes { o.append("  axis \(a.name) (\(a.role)): \(a.values.joined(separator: " "))") }
    if !p.fixed.isEmpty { o.append("  fixed: " + p.fixed.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value) (\(p.fixedRoles[$0.key] ?? "param"))" }.joined(separator: ", ")) }
    for (i, v) in p.points.enumerated() {
      let k = Sweep.key(v, axes: p.axes)
      o.append("  \(String(i + 1).padding(toLength: 4, withPad: " ", startingAt: 0)) \(k)  →  \(command(p, v).joined(separator: " "))" + (p.done[k]?.usable == true ? "  (done)" : ""))
    }
    let est = p.estimateS
    o.append("estimate: \(p.todo.count) point(s) × \(Int(p.perPointS.rounded())) s ≈ \(minutes(est))\(p.estimated ? " (a guess: no point measured yet; --rep-s and --startup-s refine it)" : " (from the points measured)")")
    if let b = budgetMin, est > b * 60 { o.append("budget: \(Int(b)) min covers about \(max(0, Int(b * 60 / max(1, p.perPointS)))) point(s); the rest wait for the next run (it resumes)") }
    o.append("results: \(p.dir.path)")
    return o.joined(separator: "\n")
  }

  func minutes(_ s: Double) -> String { s < 90 ? "\(Int(s.rounded())) s" : "\(Stats.round(s / 60, 1)) min" }

  /// The adapter command for one point (without the knobs, which travel in PERFLOOP_KNOBS).
  func command(_ p: Plan, _ v: [String: String]) -> [String] {
    let (fx, params, _) = split(p, v)
    var args = ["run", p.scenario, "--fixture", Sweep.fixtureName(p.fixture, fx), "--reps", String(p.reps), "--json"]
    for (k, x) in params.sorted(by: { $0.key < $1.key }) { args += ["--set", "\(k)=\(x)"] }
    let knobs = knobsFor(p, v)
    if !knobs.isEmpty { args.insert("PERFLOOP_KNOBS=\(Adapter.knobString(knobs))", at: 0) }
    return args
  }

  func split(_ p: Plan, _ v: [String: String]) -> (fixture: [String: String], params: [String: String], knobs: [String: String]) {
    var f: [String: String] = [:], pa: [String: String] = [:], k: [String: String] = [:]
    let roles = p.fixedRoles.merging(Dictionary(uniqueKeysWithValues: p.axes.map { ($0.name, $0.role) })) { $1 }
    for (n, x) in p.fixed.merging(v, uniquingKeysWith: { $1 }) {
      switch roles[n] { case "fixture": f[n] = x; case "knob": k[n] = x; default: pa[n] = x }
    }
    return (f, pa, k)
  }
  func knobsFor(_ p: Plan, _ v: [String: String]) -> [String: String] { split(p, v).knobs }

  // MARK: run

  /// Measures every point not done yet, in order, writing each as it lands; then the fits. Stops early (and says so)
  /// when the budget is spent; never throws for a point that failed (it is recorded as such).
  public func run(_ p: Plan, _ o: Options) throws -> SweepDoc {
    let fm = FileManager.default
    try fm.createDirectory(at: p.dir.appendingPathComponent("points"), withIntermediateDirectories: true)
    var doc = SweepDoc(scenario: p.scenario, fixture: p.fixture, objective: p.metric, build: p.manifest?.build?.embedded, axis: p.axes, reps: p.reps, points: [])
    doc.fixed = p.fixed
    doc.startedAt = Clock.now()
    var done = p.done
    let began = Date()
    var held = 0
    var stopped: String?
    defer { Interrupts.release() }
    let todo = p.todo
    for (i, v) in todo.enumerated() {
      let k = Sweep.key(v, axes: p.axes)
      if let b = o.budgetMin, Date().timeIntervalSince(began) + p.perPointS > b * 60 {
        stopped = "budget of \(Int(b)) min spent with \(todo.count - i) point(s) left: run the same command again to resume"; break
      }
      if let l = o.lock, held == 0 { try acquire(l) }
      log("sweep point \(i + 1)/\(todo.count): \(k)")
      var sp = measure(p, v, key: k)
      if !sp.usable, sp.failure != nil {
        log("sweep point \(k): \(sp.failure!); once more")
        sp = measure(p, v, key: k)
      }
      held += 1
      if o.lock != nil, held >= max(1, o.lockEvery) || i == todo.count - 1 { Interrupts.release(); held = 0 }
      try PLJSON.write(sp, path: pointFile(p.dir, k).path)
      done[k] = sp
      if doc.build == nil, let raw = try? PLJSON.read(JSONValue.self, path: rawFile(p.dir, k).path) { doc.build = Build(json: raw.at("tool.build"))?.embedded }
      doc = finish(doc, p, done, stopped: nil)
      try PLJSON.write(doc, path: p.dir.appendingPathComponent("sweep.json").path)
      if let x = sp.objective { log("sweep point \(k): \(Sweep.metricWord(p.metric)) \(Sweep.fmt(x))\(sp.busy == true ? " (busy machine)" : "")") }
    }
    Interrupts.release()
    doc = finish(doc, p, done, stopped: stopped)
    try PLJSON.write(doc, path: p.dir.appendingPathComponent("sweep.json").path)
    return doc
  }

  func finish(_ d: SweepDoc, _ p: Plan, _ done: [String: SweepPoint], stopped: String?) -> SweepDoc {
    var doc = d
    doc.points = p.points.map { done[Sweep.key($0, axes: p.axes)] ?? SweepPoint(values: $0) }
    let (fit, all) = Sweep.fits(doc.points, axes: p.axes, objective: p.metric)
    doc.fit = fit; doc.fits = all
    doc.complete = doc.points.allSatisfy(\.usable)
    doc.finishedAt = Clock.now()
    doc.notes = []
    if let s = stopped { doc.notes.append(s) }
    let failed = doc.points.filter { $0.failure != nil }
    if !failed.isEmpty { doc.notes.append("\(failed.count) point(s) failed: " + failed.map { "\(Sweep.key($0.values, axes: p.axes)): \($0.failure!)" }.joined(separator: "; ")) }
    if doc.points.contains(where: { $0.guardsPassed == false }) { doc.notes.append("some points failed a check: their numbers are for a run that didn't do what the scenario asks") }
    return doc
  }

  /// One point: the adapter's `run` with the point's fixture, params and knobs; its reps' objective, frame guards,
  /// checks and the machine's noise.
  func measure(_ p: Plan, _ v: [String: String], key k: String) -> SweepPoint {
    var sp = SweepPoint(values: v)
    let (fx, params, knobs) = split(p, v)
    var args = ["run", p.scenario, "--fixture", Sweep.fixtureName(p.fixture, fx), "--reps", String(p.reps), "--json"]
    for (n, x) in params.sorted(by: { $0.key < $1.key }) { args += ["--set", "\(n)=\(x)"] }
    var e: [String: String] = [:]
    if !knobs.isEmpty { e["PERFLOOP_KNOBS"] = Adapter.knobString(Adapter.knobs(env["PERFLOOP_KNOBS"] ?? "").merging(knobs) { $1 }) }
    let t0 = Date()
    let out: Adapter.Output
    do { out = try Interrupts.spawn(p.exe, args, env: e, base: env) } catch { sp.failure = "\(error)"; return sp }
    sp.wallS = Stats.round(Date().timeIntervalSince(t0), 1)
    sp.finishedAt = Clock.now()
    let raw = rawFile(p.dir, k)
    try? out.stdout.write(to: raw, atomically: true, encoding: .utf8)
    sp.result = "points/" + raw.lastPathComponent
    guard let r = out.json, [0, 3, 4, 5].contains(out.status) else { sp.failure = "run exited \(out.status)\(out.json == nil ? " without a result" : "")"; return sp }
    let sides = Readings.sides(run: r, metric: p.metric)
    let xs = sides.compactMap(\.objective)
    sp.reps = sides.count
    guard !xs.isEmpty else { sp.failure = "the result has no \(p.metric)"; return sp }
    sp.dist = Dist(xs); sp.objective = Stats.round(Stats.median(xs), 4)
    let h = sides.compactMap(\.hitchTimeRatioMsPerS), l = sides.compactMap(\.longestStretchMs)
    sp.hitchTimeRatioMsPerS = h.isEmpty ? nil : Stats.round(Stats.median(h), 3)
    sp.longestStretchMs = l.isEmpty ? nil : Stats.round(Stats.median(l), 3)
    sp.checksFailed = Array(Set(sides.flatMap(\.checksFailed))).sorted()
    sp.guardsPassed = sp.checksFailed.isEmpty && !sides.contains { $0.trustworthy == false }
    if let q = r.at("noise.quiet")?.bool { sp.busy = !q; if !q { sp.noise = r.at("noise.reasons")?.strings } }
    return sp
  }

  /// Waits for the lock directory (mkdir is atomic), writes who holds it, and registers it for release on exit or a
  /// signal.
  func acquire(_ path: String) throws {
    let fm = FileManager.default
    var waited = false
    while true {
      do {
        try fm.createDirectory(atPath: path, withIntermediateDirectories: false)
        try? "perfloop sweep pid \(ProcessInfo.processInfo.processIdentifier)\n".write(toFile: path + "/owner", atomically: true, encoding: .utf8)
        Interrupts.hold(path)
        if waited { log("lock \(path): acquired") }
        return
      } catch {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { throw PLError.harness("couldn't create the lock \(path): \(error)") }
        if !waited { log("lock \(path) held by \(((try? String(contentsOfFile: path + "/owner", encoding: .utf8)) ?? "?").trimmingCharacters(in: .whitespacesAndNewlines)); waiting") }
        waited = true
        Thread.sleep(forTimeInterval: lockPollS)
      }
    }
  }
}

/// The child running now and the lock held now, so SIGINT/SIGTERM stop the child and free the lock before the
/// runner exits 7 (interrupted, SCHEMAS.md): a sweep stopped by hand never leaves the window lock behind.
public enum Interrupts {
  static let mutex = NSLock()
  static var child: Process?
  static var lock: String?
  static var sources: [DispatchSourceSignal] = []

  public static func install() {
    mutex.lock(); defer { mutex.unlock() }
    guard sources.isEmpty else { return }
    for sig in [SIGINT, SIGTERM, SIGHUP] {
      signal(sig, SIG_IGN)
      let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
      s.setEventHandler {
        mutex.lock(); let c = child; mutex.unlock()
        if let c, c.isRunning { c.terminate() }
        release()
        FileHandle.standardError.write(Data("perfloop: interrupted (signal \(sig)); finished points are kept, run the same command to resume\n".utf8))
        exit(7)
      }
      s.resume(); sources.append(s)
    }
  }
  static func hold(_ path: String) { mutex.lock(); lock = path; mutex.unlock() }
  public static func release() {
    mutex.lock(); let l = lock; lock = nil; mutex.unlock()
    if let l { try? FileManager.default.removeItem(atPath: l) }
  }

  /// Adapter.spawn, keeping the child where a signal can reach it.
  static func spawn(_ exe: String, _ args: [String], env extra: [String: String], base: [String: String]) throws -> Adapter.Output {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    var e = base; for (k, v) in extra { e[k] = v }; p.environment = e
    let out = Pipe(); p.standardOutput = out
    p.standardError = FileHandle.standardError; p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { throw PLError.harness("couldn't start \(exe): \(error)") }
    mutex.lock(); child = p; mutex.unlock()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    mutex.lock(); child = nil; mutex.unlock()
    return Adapter.Output(status: p.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
  }
}

extension String {
  func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}
