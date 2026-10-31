import Foundation

/// `perfloop.manifest/1` (SCHEMAS.md §2): what an adapter's `describe --json` prints, and all the runner knows of an
/// app: its scenarios, which metric each climbs on, which guards gate acceptance, its knobs. Decoded leniently: a
/// missing optional field is nil, an unknown one ignored.
public struct Manifest: Codable, Sendable, Equatable {
  public var schema: String
  public var `protocol`: Int
  public var app: String
  public var adapter: String
  public var build: Build?
  public var scenarios: [ScenarioEntry]
  /// Fixtures as the adapter describes them; the runner only needs their names.
  public var fixtures: [JSONValue]
  public var knobs: [KnobEntry]
  public var hosts: [String]?
  public var defaultHost: String?
  public var probes: [String]?
  public var exitCodes: [String: Int]?
  /// Scenarios whose checks run on every promotion, whatever the experiment climbs (C6: isolation).
  public var isolationGuards: [String]?
  /// "describe" when the adapter printed it; "list" when the runner derived it from an older adapter's `list --json`.
  public var source: String?
  /// The fixture the adapter runs when none is named (a sweep varies this one unless told otherwise).
  public var defaultFixture: String?

  public init(app: String, adapter: String, build: Build?, scenarios: [ScenarioEntry], fixtures: [JSONValue] = [], knobs: [KnobEntry] = [], source: String? = "describe") {
    schema = "perfloop.manifest/1"; self.protocol = 1; self.app = app; self.adapter = adapter; self.build = build
    self.scenarios = scenarios; self.fixtures = fixtures; self.knobs = knobs; self.source = source
  }

  enum CodingKeys: String, CodingKey { case schema, `protocol`, app, adapter, build, scenarios, fixtures, knobs, hosts, defaultHost, probes, exitCodes, source, defaultFixture, isolationGuards }
  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? "perfloop.manifest/1"
    self.protocol = try c.decodeIfPresent(Int.self, forKey: .protocol) ?? 1
    app = try c.decode(String.self, forKey: .app)
    adapter = try c.decodeIfPresent(String.self, forKey: .adapter) ?? app
    build = try? c.decodeIfPresent(Build.self, forKey: .build)
    scenarios = try c.decodeIfPresent([ScenarioEntry].self, forKey: .scenarios) ?? []
    fixtures = try c.decodeIfPresent([JSONValue].self, forKey: .fixtures) ?? []
    knobs = try c.decodeIfPresent([KnobEntry].self, forKey: .knobs) ?? []
    hosts = try c.decodeIfPresent([String].self, forKey: .hosts); defaultHost = try c.decodeIfPresent(String.self, forKey: .defaultHost)
    probes = try c.decodeIfPresent([String].self, forKey: .probes); exitCodes = try c.decodeIfPresent([String: Int].self, forKey: .exitCodes)
    source = try c.decodeIfPresent(String.self, forKey: .source)
    defaultFixture = try c.decodeIfPresent(String.self, forKey: .defaultFixture)
    isolationGuards = try? c.decodeIfPresent([String].self, forKey: .isolationGuards)
  }

  public func scenario(_ name: String) -> ScenarioEntry? { scenarios.first { $0.name == name } }
  public var fixtureNames: [String] { fixtures.compactMap { $0["name"]?.string } }

  /// For adapters without `describe` (deskbench before Phase 2): the manifest implied by `list --json`. Objectives
  /// follow SPEC §5.1 (latency scenarios keep latency, the rest climb on main-thread CPU); the guards are the
  /// scenario's own checks.
  public static func derived(fromList v: JSONValue, app: String? = nil) -> Manifest? {
    guard let scs = v["scenarios"]?.array else { return nil }
    let tool = v["tool"]
    let scenarios = scs.compactMap { s -> ScenarioEntry? in
      guard let name = s["name"]?.string else { return nil }
      let kind = s["kind"]?.string ?? "smooth"
      var e = ScenarioEntry(name: name, kind: kind, objective: kind == "latency" ? "latencyMs" : "mainThreadCpuMsPerStep", guards: ["checks"])
      e.summary = s["summary"]?.string; e.budget = s["budget"]?.string; e.rule = s["rule"]?.string; e.latencyBudgetMs = s["latencyBudgetMs"]?.double
      e.params = (s["params"]?.object ?? [:]).compactMapValues(\.string)
      return e
    }
    let name = tool?["name"]?.string ?? "adapter"
    var m = Manifest(app: app ?? name, adapter: name, build: Build(json: tool?["build"]), scenarios: scenarios, fixtures: v["fixtures"]?.array ?? [], source: "list")
    m.exitCodes = (v["exitCodes"]?.object ?? [:]).compactMapValues { $0.double.map(Int.init) }
    return m
  }

  /// What an experiment may not change (SPEC §5.4–5.5, anti-Goodhart): scenarios' objectives and guards, the
  /// fixtures. Two manifests with equal contracts judge builds the same way.
  public var contract: String {
    let s = scenarios.sorted { $0.name < $1.name }.map { e in
      "\(e.name):\(e.objective ?? "-"):\(e.guards.sorted().joined(separator: "+")):\(PLJSON.line(e.guardParams ?? [:])):\(e.secondFixture ?? "-")"
    }
    return (s + ["fixtures:" + fixtureNames.sorted().joined(separator: ",")] + (isolationGuards.map { ["isolation:" + $0.joined(separator: ",")] } ?? [])).joined(separator: "\n")
  }
}

public struct ScenarioEntry: Codable, Sendable, Equatable {
  public var name: String
  public var summary: String?
  /// latency | smooth | isolation.
  public var kind: String
  public var budget: String?
  public var rule: String?
  public var latencyBudgetMs: Double?
  public var params: [String: String]
  /// The metric this scenario climbs on (lower is better): mainThreadCpuMsPerStep | instructionsPerStep | latencyMs.
  public var objective: String?
  /// Guards that gate acceptance; "checks" means every check the scenario makes.
  public var guards: [String]
  public var guardParams: [String: JSONValue]?
  /// Promotion needs not-worse here (SPEC §5.5, over-fitting one fixture).
  public var secondFixture: String?
  /// Metrics that may not get worse beyond their band (Acceptance judges them as frame guards).
  public var frameGuards: [String]?

  public init(name: String, kind: String, objective: String?, guards: [String] = [], params: [String: String] = [:], secondFixture: String? = nil) {
    self.name = name; self.kind = kind; self.objective = objective; self.guards = guards; self.params = params; self.secondFixture = secondFixture
  }
  enum CodingKeys: String, CodingKey { case name, summary, kind, budget, rule, latencyBudgetMs, params, objective, guards, guardParams, secondFixture, frameGuards }
  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    summary = try c.decodeIfPresent(String.self, forKey: .summary); kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "smooth"
    budget = try c.decodeIfPresent(String.self, forKey: .budget); rule = try c.decodeIfPresent(String.self, forKey: .rule)
    latencyBudgetMs = try c.decodeIfPresent(Double.self, forKey: .latencyBudgetMs)
    params = (try? c.decodeIfPresent([String: String].self, forKey: .params)) ?? [:]
    objective = try c.decodeIfPresent(String.self, forKey: .objective); guards = try c.decodeIfPresent([String].self, forKey: .guards) ?? []
    guardParams = try c.decodeIfPresent([String: JSONValue].self, forKey: .guardParams); secondFixture = try c.decodeIfPresent(String.self, forKey: .secondFixture)
    frameGuards = try? c.decodeIfPresent([String].self, forKey: .frameGuards)
  }
}

/// A runtime knob (C4) as the manifest lists it. Values travel as strings (`PERFLOOP_KNOBS=k=v,k=v`).
public struct KnobEntry: Codable, Sendable, Equatable {
  public var name: String
  public var type: String?
  public var `default`: String?
  public var choices: [String]?
  public var range: [Double]?
  public var since: String?
  public init(name: String, type: String? = nil, default d: String? = nil, choices: [String]? = nil, range: [Double]? = nil) {
    self.name = name; self.type = type; self.default = d; self.choices = choices; self.range = range
  }
  enum CodingKeys: String, CodingKey { case name, type, `default`, choices, range, since }
  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name); type = try c.decodeIfPresent(String.self, forKey: .type)
    // An int knob's default may come as a number.
    let v = try c.decodeIfPresent(JSONValue.self, forKey: .default)
    self.default = v?.string ?? v?.double.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? v?.bool.map(String.init)
    choices = try? c.decodeIfPresent([String].self, forKey: .choices); range = try? c.decodeIfPresent([Double].self, forKey: .range)
    since = try c.decodeIfPresent(String.self, forKey: .since)
  }

  /// Whether `value` is one this knob accepts.
  public func accepts(_ value: String) -> Bool {
    if let cs = choices { return cs.contains(value) }
    if let r = range, r.count == 2, let x = Double(value) { return x >= r[0] && x <= r[1] }
    return true
  }
}
