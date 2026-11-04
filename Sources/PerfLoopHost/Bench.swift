#if os(macOS)
import AppKit
import PerfLoopKit
import PerfLoopProbe

/// A fixture: the data a scenario runs on, by name. `params` are its defaults; `parametric` names the ones a sweep may
/// vary (`--fixture rows@rows=2000`), with their accepted range.
public struct Fixture: Sendable, Equatable {
  public var name: String
  public var summary: String?
  public var params: [String: String]
  public var parametric: [String: ClosedRange<Double>]?
  public init(_ name: String, summary: String? = nil, params: [String: String] = [:], parametric: [String: ClosedRange<Double>]? = nil) {
    self.name = name; self.summary = summary; self.params = params; self.parametric = parametric
  }
  public func param(_ k: String) -> String? { params[k] }
  public func int(_ k: String, _ d: Int) -> Int { params[k].flatMap { Int($0) } ?? d }
  public func double(_ k: String, _ d: Double) -> Double { params[k].flatMap { Double($0) } ?? d }

  var json: JSONValue {
    var o: [String: JSONValue] = ["name": .string(name), "params": .object(params.mapValues { .string($0) })]
    if let s = summary { o["summary"] = .string(s) }
    if let p = parametric { o["parametric"] = .object(p.mapValues { .array([.number($0.lowerBound), .number($0.upperBound)]) }) }
    return .object(o)
  }
}

/// How a scenario is judged (SPEC §5.1): `smooth` and `isolation` climb on main-thread CPU per step, `latency` on
/// the time to the first frame that shows the change.
public enum ScenarioKind: String, Sendable { case smooth, latency, isolation }

/// The number a scenario climbs on (lower is better).
public enum Metric: String, Sendable { case mainThreadCpuMsPerStep, instructionsPerStep, latencyMs }

/// A registered scenario: what `describe` lists and `run` drives.
public struct ScenarioSpec: Sendable {
  public var name: String
  public var summary: String
  public var kind: ScenarioKind
  public var objective: Metric
  /// Correctness guards that gate acceptance: `checks` (the scenario's own `run.check`s), `snapshot-diff`, and any the
  /// bench registered with `bench.guard`.
  public var guards: [String]
  public var guardParams: [String: Double]
  public var frameGuards: [String]
  public var params: [String: String]
  public var budget: String?
  public var latencyBudgetMs: Double?
  /// Promotion needs not-worse here (over-fitting one fixture).
  public var secondFixture: String?
}

/// A guard's outcome, as the runner reads it (PerfLoopKit's `GuardResult`, named here so a bench needs only this import).
public typealias GuardResult = PerfLoopKit.GuardResult

public typealias ScenarioBody = @MainActor (Run) async throws -> Void
/// A correctness guard of the bench's own, judged after a rep with the window still up.
public typealias GuardBody = @MainActor (Run, [String: Double]) async -> GuardResult

/// An app's bench: register fixtures, scenarios, knobs and guards, then `bench.main()`. The library answers the
/// runner's whole contract (ADAPTER.md in the PerfLoop repository): `list`, `describe`, `run`, `snapdiff`, `knobs`, `help`.
///
///     let bench = Bench(app: "slowlist", stamp: perfLoopBuildStamp)   // the PerfLoopStamp plugin writes the stamp
///     bench.fixture("rows500", params: ["rows": "500"])
///     bench.knobs { [ListView.rank] }
///     bench.scenario("select", summary: "Select rows one after another", params: ["steps": "8"]) { run in … }
///     bench.main()
public final class Bench: @unchecked Sendable {
  public let app: String
  public let adapter: String
  public let version: String
  let stamp: String?
  public private(set) var fixtures: [Fixture] = []
  public private(set) var scenarios: [ScenarioSpec] = []
  var bodies: [String: ScenarioBody] = [:]
  var guardBodies: [String: GuardBody] = [:]
  var knobList: @MainActor () -> [any AnyKnob] = { [] }
  /// Scenarios whose checks run on every promotion, whatever an experiment climbs on (C6: isolation).
  public var isolationScenarios: [String] = []
  /// View names the app's `Probe.body` calls use, for the manifest.
  public var probes: [String] = []
  /// Paths a patch may never record (secrets, private state); see `Manifest.privatePaths`.
  public var privatePaths: [String] = []
  /// Name prefixes of the app's modules: their qualifier is dropped from sampled symbols, and their frames are "ours".
  public var appModules: [String] = []
  public var defaultFixture: String?
  public var windowSize = CGSize(width: 900, height: 700)
  /// The bench window's appearance (light by default), whatever the Mac's setting: snapshots compare across machines.
  /// nil follows the system.
  public var appearance: NSAppearance.Name? = .aqua

  /// `stamp` is `perfLoopBuildStamp` from the PerfLoopStamp plugin; nil leaves the bench unstamped, which
  /// `perfloop store add` refuses.
  public init(app: String, adapter: String? = nil, version: String = "1", stamp: String?) {
    self.app = app; self.adapter = adapter ?? "\(app)-bench"; self.version = version; self.stamp = stamp
  }

  // MARK: registration

  public func fixture(_ name: String, summary: String? = nil, params: [String: String] = [:], parametric: [String: ClosedRange<Double>]? = nil) {
    fixtures.append(Fixture(name, summary: summary, params: params, parametric: parametric))
  }

  /// The app's knobs (C4). A closure, so the statics are first touched after `PERFLOOP_KNOBS` is final.
  public func knobs(_ list: @escaping @MainActor () -> [any AnyKnob]) { knobList = list }

  public func scenario(_ name: String, summary: String, kind: ScenarioKind = .smooth, objective: Metric? = nil, guards: [String] = ["checks"],
                       guardParams: [String: Double] = [:], frameGuards: [String] = ["hitchTimeRatioMsPerS", "longestStretchMs"], params: [String: String] = [:],
                       budget: String? = nil, latencyBudgetMs: Double? = nil, secondFixture: String? = nil, _ body: @escaping ScenarioBody) {
    precondition(bodies[name] == nil, "scenario \(name) registered twice")
    scenarios.append(ScenarioSpec(name: name, summary: summary, kind: kind, objective: objective ?? (kind == .latency ? .latencyMs : .mainThreadCpuMsPerStep),
                                  guards: guards, guardParams: guardParams, frameGuards: frameGuards, params: params, budget: budget,
                                  latencyBudgetMs: latencyBudgetMs, secondFixture: secondFixture))
    bodies[name] = body
  }

  /// A guard of the bench's own (`built-within`-like checks of what is on screen), by name: a scenario lists it in
  /// `guards`, the runner asks for it, and it is judged after each rep with the window up.
  public func `guard`(_ name: String, _ body: @escaping GuardBody) { guardBodies[name] = body }

  // MARK: what the runner reads

  public var build: Build {
    let exe = Bundle.main.executablePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ?? CommandLine.arguments[0]
    return Self.build(stamp: stamp, hash: FileHash.sha256(file: exe))
  }

  static var configuration: String {
    #if DEBUG
    return "debug"
    #else
    return "release"
    #endif
  }

  /// The stamp's `key=value` lines as a `perfloop.build/1`. Empty values are unknown; a missing `dirty` is dirty.
  public static func build(stamp text: String?, hash: String?) -> Build {
    var kv: [String: String] = [:]
    for line in (text ?? "").split(whereSeparator: \.isNewline) {
      let p = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      if p.count == 2, !p[1].isEmpty { kv[p[0]] = p[1] }
    }
    return Build(hash: hash, commit: kv["commit"], dirty: kv["dirty"].map { $0 != "0" && $0 != "false" } ?? true, sourceHash: kv["sourceHash"],
                 builtAt: kv["builtAt"], configuration: configuration, toolchain: kv["toolchain"], stamp: !kv.isEmpty)
  }

  var tool: ToolInfo { let b = build; return ToolInfo(name: adapter, version: version, configuration: Self.configuration, commit: b.commit, build: b) }

  public static let verbs = ["help", "list", "describe", "knobs", "run", "snapdiff"]
  public static let exitCodes = ["ok": 0, "usage": 1, "harness": 2, "budget": 3, "regression": 4, "untrusted": 5]

  /// `describe --json`: the `perfloop.manifest/1` the runner does everything from.
  @MainActor
  public func manifest() -> Manifest {
    let entries = scenarios.map { s -> ScenarioEntry in
      var e = ScenarioEntry(name: s.name, kind: s.kind.rawValue, objective: s.objective.rawValue, guards: s.guards, params: s.params, secondFixture: s.secondFixture)
      e.summary = s.summary; e.budget = s.budget; e.latencyBudgetMs = s.latencyBudgetMs
      e.guardParams = s.guardParams.isEmpty ? nil : s.guardParams.mapValues { .number($0) }
      e.frameGuards = s.frameGuards
      return e
    }
    let ks = knobList().map { k -> KnobEntry in
      let i = k.info
      var e = KnobEntry(name: i.name, type: i.type, default: i.default, choices: i.choices, range: i.range?.compactMap(Double.init))
      e.since = i.since
      return e
    }
    var m = Manifest(app: app, adapter: adapter, build: build, scenarios: entries, fixtures: fixtures.map(\.json), knobs: ks, source: nil)
    m.hosts = ["window"]; m.defaultHost = "window"; m.defaultFixture = defaultFixture ?? fixtures.first?.name
    m.probes = probes.isEmpty ? nil : probes; m.exitCodes = Self.exitCodes
    m.isolationGuards = isolationScenarios.isEmpty ? nil : isolationScenarios
    m.verbs = Self.verbs; m.privatePaths = privatePaths.isEmpty ? nil : privatePaths
    return m
  }

  /// `list --json`: `tool.build` (the stamp `store add` requires), scenarios and fixtures.
  @MainActor
  public func listJSON() -> JSONValue {
    let m = manifest()
    let scs = (try? PLJSON.decode([JSONValue].self, from: Data(PLJSON.encode(m.scenarios).utf8))) ?? []
    let toolJSON = (try? PLJSON.decode(JSONValue.self, from: Data(PLJSON.encode(tool).utf8))) ?? .null
    return .object(["tool": toolJSON, "scenarios": .array(scs), "fixtures": .array(m.fixtures), "suite": .array(scenarios.map { .string($0.name) }),
                    "exitCodes": .object(Self.exitCodes.mapValues { .number(Double($0)) })])
  }

  // MARK: the command line

  @MainActor
  public var help: String {
    """
    \(adapter): the PerfLoop bench of \(app) (PerfLoopHost; the contract is ADAPTER.md in the PerfLoop repository)

      list [--json]                         scenarios, fixtures and the build stamp
      describe [--json]                     the perfloop.manifest/1 a runner reads
      knobs [--json]                        the runtime knobs this process runs with (PERFLOOP_KNOBS)
      run SCENARIO [--fixture F] [--reps N] [--set k=v] [--json] [--out FILE] [--artifacts DIR]
          [--knob k=v] [--guards LIST] [--guard-param k=v] [--sampler on|off] [--no-activate]
                                            drive a scenario in a window of this process; the result is perfloop.result/2
      snapdiff A.png B.png [--diff-out D.png] [--guard-param snapshot-diff.tolerance=X] [--json]
                                            the snapshot-diff guard, headless (exit 3 over tolerance)

    scenarios: \(scenarios.map(\.name).joined(separator: ", "))
    fixtures: \(fixtures.map(\.name).joined(separator: ", "))
    environment: PERFLOOP_KNOBS=k=v,… PERFLOOP_GUARDS=a,b PERFLOOP_GUARD_PARAMS=k=v,… PERFLOOP_ARTIFACTS=DIR PERFLOOP_SAMPLER=off
    exit codes: 0 pass · 1 usage · 2 harness error · 3 budget, check or guard failed · 5 untrusted (window not active: rerun)
    """
  }

  /// Runs the command line and exits. `run` starts the app's run loop; the other verbs answer without a window.
  public func main(_ argv: [String] = Array(CommandLine.arguments.dropFirst())) -> Never {
    dispatchPrecondition(condition: .onQueue(.main))
    let a = HostArgs(argv)
    // `--knob k=v` joins PERFLOOP_KNOBS before any knob is first read (knobs resolve once, from the environment).
    if a.has("knob") {
      var k = Knobs.parse(ProcessInfo.processInfo.environment[Knobs.variable] ?? "")
      for x in a.all("knob") { k.merge(Knobs.parse(x)) { $1 } }
      setenv(Knobs.variable, Knobs.format(k), 1)
    }
    if a.positional.first == "run" {
      NSApplication.shared.setActivationPolicy(a.has("no-activate") ? .accessory : .regular)
      let d = LaunchDelegate { [unowned self] in
        let (code, text) = await runCommand(a)
        if !text.isEmpty { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
        exit(code)
      }
      NSApplication.shared.delegate = d
      withExtendedLifetime(d) { NSApplication.shared.run() }
      exit(2)
    }
    let (code, text) = MainActor.assumeIsolated { handle(a) }
    if !text.isEmpty { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    exit(code)
  }

  /// The headless verbs: what `main` prints and exits with. Tests call this.
  @MainActor
  public func handle(_ argv: [String]) -> (Int32, String) { handle(HostArgs(argv)) }

  @MainActor
  func handle(_ a: HostArgs) -> (Int32, String) {
    let json = a.has("json")
    switch a.positional.first ?? "help" {
    case "help", "-h", "--help": return (0, help)
    case "list":
      if json { return (0, PLJSON.encode(listJSON())) }
      let b = build
      return (0, (["\(adapter) · \(b.line)"] + scenarios.map { "  \($0.name) (\($0.kind.rawValue), \($0.objective.rawValue)): \($0.summary)" }
                  + fixtures.map { "  fixture \($0.name)\($0.summary.map { ": \($0)" } ?? "")" }).joined(separator: "\n"))
    case "describe": return (0, PLJSON.encode(manifest()))
    case "knobs":
      let ks = knobList()
      let problems = Knobs.problems
      if json { return (0, PLJSON.encode(["knobs": .array(ks.map { .object(["name": .string($0.info.name), "value": .string($0.valueText), "default": .string($0.info.default)]) }),
                                           "problems": .array(problems.map(JSONValue.string))] as [String: JSONValue])) }
      return (0, (ks.map { "\($0.info.name) = \($0.valueText)\($0.valueText == $0.info.default ? "" : " (default \($0.info.default))")" } + problems.map { "problem: " + $0 }).joined(separator: "\n"))
    case "snapdiff":
      guard a.positional.count >= 3 else { return (1, "usage: \(adapter) snapdiff A.png B.png [--diff-out D.png] [--guard-param snapshot-diff.tolerance=X]") }
      let gp = guardParams(a)
      let (g, code) = Snapshot.snapdiff(a: a.positional[1], b: a.positional[2], tolerance: gp["snapshot-diff.tolerance"] ?? 0.005,
                                        threshold: Int(gp["snapshot-diff.threshold"] ?? 16), diffOut: a.one("diff-out"))
      if json {
        let gj = (try? PLJSON.decode(JSONValue.self, from: Data(PLJSON.encode(g).utf8))) ?? .null
        return (code, PLJSON.encode(["schema": .string("perfloop.snapdiff/1"), "guard": gj] as [String: JSONValue]))
      }
      return (code, "snapshot-diff: \(g.pass ? "PASS" : "OVER TOLERANCE") · \(g.detail)")
    case "run": return (1, "run needs the app's run loop: call bench.main()")
    case let v: return (1, "\(adapter): unknown command '\(v)'\n\n" + help)
    }
  }

  /// Guard parameters: the scenario's, then `PERFLOOP_GUARD_PARAMS`, then `--guard-param`.
  func guardParams(_ a: HostArgs, scenario: ScenarioSpec? = nil) -> [String: Double] {
    var p = scenario?.guardParams ?? [:]
    let env = ProcessInfo.processInfo.environment["PERFLOOP_GUARD_PARAMS"] ?? ""
    for kv in env.split(separator: ",").map(String.init) + a.all("guard-param") {
      let x = kv.split(separator: "=", maxSplits: 1).map(String.init)
      if x.count == 2, let d = Double(x[1]) { p[x[0]] = d }
    }
    return p
  }

  /// `name@k=v,k=v` → the named fixture with those parameters, refused outside its `parametric` ranges.
  func resolveFixture(_ spec: String?) throws -> Fixture {
    let s = spec ?? defaultFixture ?? fixtures.first?.name ?? "default"
    let parts = s.split(separator: "@", maxSplits: 1).map(String.init)
    guard var f = fixtures.first(where: { $0.name == parts[0] }) ?? (fixtures.isEmpty ? Fixture(parts[0]) : nil) else {
      throw HostError.usage("unknown fixture '\(parts[0])' (fixtures: \(fixtures.map(\.name).joined(separator: ", ")))")
    }
    if parts.count == 2 {
      for kv in parts[1].split(separator: ",") {
        let x = kv.split(separator: "=", maxSplits: 1).map(String.init)
        guard x.count == 2 else { throw HostError.usage("fixture parameter '\(kv)' is not k=v") }
        guard let r = f.parametric?[x[0]] else { throw HostError.usage("fixture \(f.name) has no parameter '\(x[0])' to vary (parametric: \((f.parametric ?? [:]).keys.sorted().joined(separator: ", ")))") }
        guard let d = Double(x[1]), r.contains(d) else { throw HostError.usage("fixture \(f.name): \(x[0])=\(x[1]) is outside \(r.lowerBound)…\(r.upperBound)") }
        f.params[x[0]] = x[1]
      }
      f.name = s
    }
    return f
  }

  // MARK: run

  @MainActor
  func runCommand(_ a: HostArgs) async -> (Int32, String) {
    do { return try await run(a) } catch let e as HostError { return (e.code, "\(adapter): \(e)") } catch { return (2, "\(adapter): \(error)") }
  }

  @MainActor
  func run(_ a: HostArgs) async throws -> (Int32, String) {
    guard let name = a.positional.dropFirst().first else { throw HostError.usage("usage: \(adapter) run SCENARIO [--fixture F] [--reps N] (scenarios: \(scenarios.map(\.name).joined(separator: ", ")))") }
    guard let spec = scenarios.first(where: { $0.name == name }), let body = bodies[name] else {
      throw HostError.usage("unknown scenario '\(name)' (scenarios: \(scenarios.map(\.name).joined(separator: ", ")))")
    }
    let fixture = try resolveFixture(a.one("fixture"))
    let reps = max(1, Int(a.one("reps") ?? "3") ?? 3)
    var params = spec.params
    for kv in a.all("set") {
      let x = kv.split(separator: "=", maxSplits: 1).map(String.init)
      guard x.count == 2 else { throw HostError.usage("--set takes k=v, not '\(kv)'") }
      params[x[0]] = x[1]
    }
    let ks = knobList()
    let problems = Knobs.problems
    if !problems.isEmpty { throw HostError.usage("knobs: " + problems.joined(separator: "; ")) }
    let env = ProcessInfo.processInfo.environment
    let fromEnv: [String] = (env["PERFLOOP_GUARDS"] ?? "").split(separator: ",").map(String.init)
    let fromFlags: [String] = a.all("guards").flatMap { $0.split(separator: ",").map(String.init) }
    let requested: Set<String> = Set((fromEnv + fromFlags).filter { !$0.isEmpty && $0 != "checks" })
    let artifacts = a.one("artifacts") ?? env["PERFLOOP_ARTIFACTS"]
    let gp = guardParams(a, scenario: spec)
    let samplerOn = !(a.one("sampler") == "off" || (a.one("sampler") == nil && env["PERFLOOP_SAMPLER"] == "off"))
    let sampler: MainThreadSampler? = samplerOn && MainThreadSampler.supported ? MainThreadSampler(config: SamplerConfig()) : nil
    Symbols.appModulePrefixes = appModules
    let activate = !a.has("no-activate")
    let startedAt = Clock.now()

    var records: [RepRecord] = []
    for i in 0..<reps {
      let recorder = Recorder(nominalHz: Double(NSScreen.main?.maximumFramesPerSecond ?? 60))
      Probe.sink = recorder; Mutations.sink = recorder.causes
      let run = Run(scenario: name, fixture: fixture, params: params, rep: i, recorder: recorder, activate: activate, sampler: sampler)
      run.appearance = appearance
      defer { run.close(); Probe.sink = nil; Mutations.sink = nil }
      try await body(run)
      // Let the stretch the last step ended in close first: the guards' own work (snapshots) never lands in a stretch
      // the steps overlap, so it is never a step's "worst stretch".
      let closed = recorder.timeline.stretches.count
      _ = await recorder.wait(timeoutMs: 1000) { recorder.timeline.stretches.count > closed }
      let window = run.windowState()
      var guards: [GuardResult]?
      if !requested.isEmpty {
        var gs: [GuardResult] = []
        for g in requested.sorted() { gs.append(await judge(g, run: run, params: gp, artifacts: artifacts)) }
        guards = gs
      } else if let dir = artifacts, let w = run.window, let png = Snapshot.png(of: w) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-rep\(i).png"))
      }
      if run.steps.isEmpty { run.note("the scenario measured no step: call run.step") }
      let rec = recorder.timeline.rep(index: i, steps: run.steps, checks: run.checks, guards: guards, window: window, notes: run.notes) { r, s in
        sampler?.annotate(&r, stretch: s.id)
      }
      records.append(rec)
      if let s = sampler, let last = recorder.timeline.stretches.last { s.discard(beforeStretch: last.id + 1) }
    }
    sampler?.stop()

    let summary = ResultSummary(reps: records, metric: spec.objective.rawValue)
    var notes: [String] = []
    var failed = !summary.checksFailed.isEmpty || !summary.guardsFailed.filter { $0 != "snapshot-diff" }.isEmpty
    if let budget = spec.latencyBudgetMs, let l = summary.latencyMs?.median, l > budget { failed = true; notes.append("latency \(l) ms is over the budget of \(budget) ms") }
    let untrusted = records.contains { $0.window?.trustworthy == false }
    if untrusted { notes.append("the window wasn't active, key, visible and unoccluded in every rep: these numbers decide nothing (rerun with nobody using the Mac)") }
    let verdict = untrusted ? "untrusted" : failed ? "fail" : "pass"
    let code: Int32 = untrusted ? 5 : failed ? 3 : 0
    var pj: [String: JSONValue] = params.mapValues { .string($0) }
    pj["knobs"] = .object(Dictionary(uniqueKeysWithValues: ks.map { ($0.info.name, JSONValue.string($0.valueText)) }))
    let result = HostResult(tool: tool, app: app, adapter: adapter, scenario: name, fixture: fixture.name, params: pj, startedAt: startedAt, reps: records,
                            summary: summary, verdict: verdict, exitCode: Int(code), notes: notes)
    let text = PLJSON.encode(result)
    if let o = a.one("out") { try text.write(toFile: o, atomically: true, encoding: .utf8) }
    return (code, a.has("json") ? text : explain(result))
  }

  /// A guard after a rep. `snapshot-diff` captures the window (the runner compares the pictures); the others are the
  /// bench's own (`bench.guard`); a guard nobody registered fails, so a manifest can't name one the bench can't judge.
  @MainActor
  func judge(_ name: String, run: Run, params: [String: Double], artifacts: String?) async -> GuardResult {
    if name == "snapshot-diff" {
      guard let dir = artifacts else { return GuardResult(name: name, pass: false, detail: "no artifacts directory (PERFLOOP_ARTIFACTS or --artifacts) to write the snapshot to") }
      guard let w = run.window else { return GuardResult(name: name, pass: false, detail: "no window to capture") }
      try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      let base = URL(fileURLWithPath: dir).appendingPathComponent("\(run.scenario)-rep\(run.rep).settled")
      guard let a = Snapshot.png(of: w), (try? a.write(to: base.appendingPathExtension("png"))) != nil else { return GuardResult(name: name, pass: false, detail: "couldn't capture the window") }
      await run.sleep(ms: params["snapshot-diff.laterMs"] ?? 500)
      let later = URL(fileURLWithPath: base.path + ".later.png")
      if let b = Snapshot.png(of: w) { try? b.write(to: later) }
      return GuardResult(name: name, pass: true, detail: "captured", artifacts: [base.appendingPathExtension("png").path, later.path])
    }
    guard let g = guardBodies[name] else { return GuardResult(name: name, pass: false, detail: "this bench has no guard '\(name)' (it has: \((["snapshot-diff"] + guardBodies.keys.sorted()).joined(separator: ", ")))") }
    return await g(run, params)
  }

  /// The text `run` prints without --json.
  @MainActor
  public func explain(_ r: HostResult) -> String {
    var out = ["\(r.scenario) on \(r.fixture): \(r.verdict.uppercased()) · \(r.reps.count) rep(s) · \(r.tool.build.line)"]
    let s = r.summary
    out.append("  objective \(s.objective.name): \(s.objective.value.map { "\($0)" } ?? "none")")
    out.append("  main-thread CPU \(s.mainThreadCpuMsPerStep.median) ms/step · hitch time \(s.hitchTimeRatioMsPerS.median) ms/s at \(s.steadyHz.median) Hz · longest stretch \(s.longestStretchMs.median) ms"
               + (s.latencyMs.map { " · latency \($0.median) ms" } ?? ""))
    if let rep = r.reps.first, let w = rep.worstStretches.first {
      var line = "  worst stretch: \(w.durationMs) ms in \(w.step)"
      if !w.bodies.isEmpty { line += " · bodies " + w.bodies.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key)×\($0.value)" }.joined(separator: " ") }
      out.append(line)
      if let o = w.topOurs, !o.isEmpty { out.append("    ours: " + o.prefix(4).map { "\($0.symbol) ×\($0.samples)" }.joined(separator: ", ")) }
      if let f = w.topFramework, !f.isEmpty { out.append("    framework: " + f.prefix(3).map { "\($0.symbol) ×\($0.samples)\($0.under.map { " under \($0)" } ?? "")" }.joined(separator: ", ")) }
    }
    for c in r.reps.flatMap(\.checks) where !c.pass { out.append("  check \(c.name) FAILED: \(c.detail)") }
    for g in r.reps.flatMap({ $0.guards ?? [] }) where !g.pass { out.append("  guard \(g.name) FAILED: \(g.detail)") }
    out += r.notes.map { "  " + $0 }
    return out.joined(separator: "\n")
  }
}

/// Starts the scenario once AppKit has finished launching (activation before that is unreliable).
final class LaunchDelegate: NSObject, NSApplicationDelegate {
  let go: @MainActor () async -> Void
  init(_ go: @escaping @MainActor () async -> Void) { self.go = go }
  func applicationDidFinishLaunching(_ n: Notification) { Task { @MainActor in await go() } }
}

struct HostArgs {
  var positional: [String] = []
  var flags: [String: [String]] = [:]
  static let valued: Set<String> = ["fixture", "reps", "set", "out", "artifacts", "guards", "guard-param", "diff-out", "sampler", "quiet-check", "knob", "host", "objective"]
  init(_ argv: [String]) {
    var i = 0
    while i < argv.count {
      let a = argv[i]
      if a.hasPrefix("--") {
        let k = String(a.dropFirst(2))
        if Self.valued.contains(k), i + 1 < argv.count { flags[k, default: []].append(argv[i + 1]); i += 2 } else { flags[k, default: []].append("1"); i += 1 }
      } else { positional.append(a); i += 1 }
    }
  }
  func has(_ k: String) -> Bool { flags[k] != nil }
  func one(_ k: String) -> String? { flags[k]?.last }
  func all(_ k: String) -> [String] { flags[k] ?? [] }
}
#endif
