import Foundation

// Scaling sweeps (CAPABILITIES.md C8, SCHEMAS.md §7): a grid over fixture parameters, knobs and scenario params, the
// objective measured at every point, and cost curves fitted through them ("ms/step grows 0.9 ms per agent, r² 0.98").
// Pure: the grid, the fits and the text. The runner (PerfLoopRunner/SweepRun.swift) measures the points.

public struct SweepError: Error, CustomStringConvertible {
  public var description: String
  public init(_ s: String) { description = s }
}

/// One dimension of a sweep: `--set agents=4..64/4`.
public struct SweepAxis: Codable, Sendable, Equatable {
  public var name: String
  /// How the value reaches the adapter: `fixture` (a parametric fixture's parameter, `--fixture NAME@k=v,…`), `knob`
  /// (`PERFLOOP_KNOBS`) or `param` (a scenario parameter, `--set k=v`).
  public var role: String
  /// As given, in order. Numbers when every value parses as one.
  public var values: [String]

  public init(name: String, role: String, values: [String]) { self.name = name; self.role = role; self.values = values }
  public var numeric: Bool { !values.isEmpty && values.allSatisfy { Double($0) != nil } }

  enum CodingKeys: String, CodingKey { case name, role, values }
  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name); role = try c.decodeIfPresent(String.self, forKey: .role) ?? "param"
    values = try c.decode([JSONValue].self, forKey: .values).map(Sweep.text)
  }
  public func encode(to e: Encoder) throws {
    var c = e.container(keyedBy: CodingKeys.self)
    try c.encode(name, forKey: .name); try c.encode(role, forKey: .role)
    try c.encode(values.map(Sweep.json), forKey: .values)
  }

  /// `name=4..64/4` (inclusive, step 4), `name=4..64` (step 1), `name=4,8,16` (a list, numbers or words) or `name=8`.
  /// Returns the name and the values; the role is decided by whoever knows the manifest.
  public static func parse(_ text: String) throws -> (name: String, values: [String]) {
    let kv = text.split(separator: "=", maxSplits: 1).map(String.init)
    guard kv.count == 2, !kv[0].isEmpty, !kv[1].isEmpty else { throw SweepError("--set wants name=values (4..64/4, 4,8,16 or 8), not '\(text)'") }
    let name = kv[0], spec = kv[1]
    if let r = spec.range(of: "..") {
      let lo = String(spec[..<r.lowerBound])
      let rest = String(spec[r.upperBound...]).split(separator: "/", maxSplits: 1).map(String.init)
      guard let a = Double(lo), let hiText = rest.first, let b = Double(hiText) else { throw SweepError("\(name): '\(spec)' is not a range (lo..hi or lo..hi/step)") }
      let step = rest.count == 2 ? Double(rest[1]) : 1
      guard let s = step, s > 0 else { throw SweepError("\(name): the step in '\(spec)' must be a positive number") }
      guard b >= a else { throw SweepError("\(name): '\(spec)' runs backwards") }
      let n = Int(((b - a) / s + 1e-9).rounded(.down)) + 1
      guard n <= 1000 else { throw SweepError("\(name): '\(spec)' has \(n) values; a sweep that long is a mistake") }
      let integral = [a, b, s].allSatisfy { $0 == $0.rounded() }
      return (name, (0..<n).map { i in let v = a + Double(i) * s; return integral ? String(Int(v.rounded())) : String(Stats.round(v, 6)) })
    }
    let values = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !values.isEmpty else { throw SweepError("\(name): no values in '\(spec)'") }
    return (name, values)
  }
}

/// One grid point's measurement.
public struct SweepPoint: Sendable, Equatable {
  /// Axis name → value.
  public var values: [String: String]
  /// The objective's median across the point's reps (lower is better).
  public var objective: Double?
  public var dist: Dist?
  public var hitchTimeRatioMsPerS: Double?
  public var longestStretchMs: Double?
  /// Every rep's checks passed and its window was trustworthy.
  public var guardsPassed: Bool?
  public var checksFailed: [String] = []
  public var reps: Int = 0
  /// The adapter's result for the point, relative to the sweep's directory.
  public var result: String?
  /// Wall time the point took, adapter start to exit.
  public var wallS: Double?
  /// The adapter said the machine was not quiet: the point's number may be inflated.
  public var busy: Bool?
  public var noise: [String]?
  public var failure: String?
  public var finishedAt: String?

  public init(values: [String: String]) { self.values = values }
  /// Has a number a fit can use.
  public var usable: Bool { objective != nil && failure == nil }
}

extension SweepPoint: Codable {
  struct Key: CodingKey {
    var stringValue: String; var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue s: String) { stringValue = s }
    init?(intValue: Int) { nil }
  }
  static let fields = ["values", "objective", "dist", "hitchTimeRatioMsPerS", "longestStretchMs", "guardsPassed", "checksFailed", "reps", "result", "wallS", "busy",
                       "noise", "failure", "finishedAt"]
  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: Key.self)
    if let v = try c.decodeIfPresent([String: JSONValue].self, forKey: Key("values")) { values = v.mapValues(Sweep.text) }
    else {
      // A point written as SCHEMAS.md §7 shows it (axis values flat beside the fields).
      var v: [String: String] = [:]
      for k in c.allKeys where !Self.fields.contains(k.stringValue) { if let x = try? c.decode(JSONValue.self, forKey: k), x.object == nil, x.array == nil { v[k.stringValue] = Sweep.text(x) } }
      values = v
    }
    objective = try c.decodeIfPresent(Double.self, forKey: Key("objective")); dist = try c.decodeIfPresent(Dist.self, forKey: Key("dist"))
    hitchTimeRatioMsPerS = try c.decodeIfPresent(Double.self, forKey: Key("hitchTimeRatioMsPerS"))
    longestStretchMs = try c.decodeIfPresent(Double.self, forKey: Key("longestStretchMs"))
    guardsPassed = try c.decodeIfPresent(Bool.self, forKey: Key("guardsPassed"))
    checksFailed = try c.decodeIfPresent([String].self, forKey: Key("checksFailed")) ?? []
    reps = try c.decodeIfPresent(Int.self, forKey: Key("reps")) ?? 0
    result = try c.decodeIfPresent(String.self, forKey: Key("result")); wallS = try c.decodeIfPresent(Double.self, forKey: Key("wallS"))
    busy = try c.decodeIfPresent(Bool.self, forKey: Key("busy")); noise = try c.decodeIfPresent([String].self, forKey: Key("noise"))
    failure = try c.decodeIfPresent(String.self, forKey: Key("failure")); finishedAt = try c.decodeIfPresent(String.self, forKey: Key("finishedAt"))
  }
  /// The axis values twice: flat, as SCHEMAS.md §7 shows them (`"agents": 4`), unless a name collides with a field,
  /// and under `values`, which is what a reader should use.
  public func encode(to e: Encoder) throws {
    var c = e.container(keyedBy: Key.self)
    for (k, v) in values where !Self.fields.contains(k) { try c.encode(Sweep.json(v), forKey: Key(k)) }
    try c.encode(values.mapValues(Sweep.json), forKey: Key("values"))
    try c.encodeIfPresent(objective, forKey: Key("objective")); try c.encodeIfPresent(dist, forKey: Key("dist"))
    try c.encodeIfPresent(hitchTimeRatioMsPerS, forKey: Key("hitchTimeRatioMsPerS")); try c.encodeIfPresent(longestStretchMs, forKey: Key("longestStretchMs"))
    try c.encodeIfPresent(guardsPassed, forKey: Key("guardsPassed")); try c.encode(checksFailed, forKey: Key("checksFailed"))
    try c.encode(reps, forKey: Key("reps")); try c.encodeIfPresent(result, forKey: Key("result")); try c.encodeIfPresent(wallS, forKey: Key("wallS"))
    try c.encodeIfPresent(busy, forKey: Key("busy")); try c.encodeIfPresent(noise, forKey: Key("noise"))
    try c.encodeIfPresent(failure, forKey: Key("failure")); try c.encodeIfPresent(finishedAt, forKey: Key("finishedAt"))
  }
}

/// A least-squares cost curve through the points: the objective against one axis (the others held at `at`), or a
/// plane through every numeric axis at once.
public struct SweepFit: Codable, Sendable, Equatable {
  /// linear | quadratic | plane.
  public var model: String
  /// The axis on x (for a plane, the first axis; every coefficient is in `coefficients`).
  public var axis: String
  /// The other axes' values for a slice of a grid; nil when the fit uses every point.
  public var at: [String: String]?
  public var n: Int
  /// Objective per unit of `axis` (linear and plane), or the linear term (quadratic).
  public var slope: Double
  public var intercept: Double
  /// The x² coefficient (quadratic).
  public var quadratic: Double?
  /// Every axis's coefficient (plane).
  public var coefficients: [String: Double]?
  public var r2: Double
  /// r² penalised for the model's parameters, to compare a quadratic with a line on few points.
  public var adjustedR2: Double?
  /// Measured − fitted, in point order (x ascending).
  public var residuals: [Double]
  public var rmse: Double
  /// "ms per step per agent".
  public var unit: String
}

/// `perfloop.sweep/1` (SCHEMAS.md §7).
public struct SweepDoc: Codable, Sendable, Equatable {
  public var schema = "perfloop.sweep/1"
  public var scenario: String
  public var fixture: String
  /// The metric measured at every point (the scenario's objective unless `--objective`).
  public var objective: String
  public var build: Build?
  public var axis: [SweepAxis]
  /// `--set` values that are not swept (one value): the same at every point.
  public var fixed: [String: String] = [:]
  public var reps: Int
  public var points: [SweepPoint]
  /// The headline fit: a line through the first numeric axis (one axis), or a plane (several).
  public var fit: SweepFit?
  /// Every fit: per numeric axis, linear and (with ≥ 4 distinct x) quadratic, per slice of the other axes; the plane.
  public var fits: [SweepFit] = []
  public var notes: [String] = []
  public var startedAt: String?
  public var finishedAt: String?
  /// Every point has a usable number (false after a budget stop or failures: rerun the same command to resume).
  public var complete: Bool = false

  public init(scenario: String, fixture: String, objective: String, build: Build?, axis: [SweepAxis], reps: Int, points: [SweepPoint]) {
    self.scenario = scenario; self.fixture = fixture; self.objective = objective; self.build = build; self.axis = axis; self.reps = reps; self.points = points
  }
}

public enum Sweep {
  // MARK: grid

  /// Every combination of the axes' values, the first axis varying slowest.
  public static func grid(_ axes: [SweepAxis]) -> [[String: String]] {
    axes.reduce([[:]]) { acc, a in acc.flatMap { p in a.values.map { v in p.merging([a.name: v]) { $1 } } } }
  }

  /// The order points are measured in. `shuffle` (the default) is a fixed permutation drawn from `seed`: a machine that
  /// warms up or gets busy during the sweep then spreads its drift over the curve instead of tilting it (an ascending
  /// sweep turns drift into slope). The same seed gives the same order, so a resumed sweep keeps it.
  public static func order(_ points: [[String: String]], _ how: String, seed: String) -> [[String: String]] {
    guard how == "shuffle", points.count > 2 else { return points }
    var state = seed.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state; z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9; z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    var out = points
    for i in stride(from: out.count - 1, to: 0, by: -1) { out.swapAt(i, Int(next() % UInt64(i + 1))) }
    return out
  }

  /// A point's name, in axis order: `agents=4,items=50` (also its file name, made safe).
  public static func key(_ values: [String: String], axes: [SweepAxis]) -> String {
    axes.map { "\($0.name)=\(values[$0.name] ?? "-")" }.joined(separator: ",")
  }
  public static func fileName(_ key: String) -> String {
    String(key.map { $0.isLetter || $0.isNumber || "._=,-".contains($0) ? $0 : "_" })
  }

  /// A parametric fixture's name with parameters (manifest protocol 1): `crew@agents=24,items=100`, keys sorted, on
  /// top of any the base name already carries.
  public static func fixtureName(_ base: String, _ params: [String: String]) -> String {
    guard !params.isEmpty else { return base }
    let parts = base.split(separator: "@", maxSplits: 1).map(String.init)
    var all: [String: String] = [:]
    if parts.count == 2 {
      for kv in parts[1].split(separator: ",") { let p = kv.split(separator: "=", maxSplits: 1).map(String.init); if p.count == 2 { all[p[0]] = p[1] } }
    }
    all.merge(params) { $1 }
    return parts[0] + "@" + all.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
  }

  /// Seconds a sweep should take: a fixed cost per point (process start, window, the quiet check) and the reps.
  public static func estimate(points: Int, reps: Int, repS: Double, startupS: Double) -> Double {
    Double(points) * (startupS + Double(reps) * repS)
  }

  // MARK: fits

  /// Least squares: the coefficients β minimising |Xβ − y|², by the normal equations and Gaussian elimination with
  /// partial pivoting; nil when XᵀX is singular (too few distinct x for the model).
  public static func leastSquares(_ x: [[Double]], _ y: [Double]) -> [Double]? {
    guard let k = x.first?.count, k > 0, x.count == y.count, x.count >= k else { return nil }
    var a = [[Double]](repeating: [Double](repeating: 0, count: k + 1), count: k)
    for (row, yi) in zip(x, y) {
      for i in 0..<k {
        for j in 0..<k { a[i][j] += row[i] * row[j] }
        a[i][k] += row[i] * yi
      }
    }
    for col in 0..<k {
      guard let piv = (col..<k).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }) else { return nil }
      let scale = a.map { abs($0[col]) }.max() ?? 1
      guard abs(a[piv][col]) > 1e-12 * max(1, scale) else { return nil }
      a.swapAt(col, piv)
      for r in 0..<k where r != col {
        let f = a[r][col] / a[col][col]
        if f != 0 { for c in col...k { a[r][c] -= f * a[col][c] } }
      }
    }
    return (0..<k).map { a[$0][k] / a[$0][$0] }
  }

  struct Quality { var r2: Double; var adjusted: Double?; var residuals: [Double]; var rmse: Double }
  static func quality(_ y: [Double], _ fitted: [Double], parameters p: Int) -> Quality {
    let n = Double(y.count), mean = y.reduce(0, +) / n
    let res = zip(y, fitted).map { $0 - $1 }
    let ssRes = res.reduce(0) { $0 + $1 * $1 }, ssTot = y.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
    let r2 = ssTot == 0 ? (ssRes < 1e-12 ? 1 : 0) : 1 - ssRes / ssTot
    let adj: Double? = y.count - p - 1 > 0 ? 1 - (1 - r2) * (n - 1) / (n - Double(p) - 1) : nil
    return Quality(r2: r2, adjusted: adj, residuals: res, rmse: (ssRes / n).squareRoot())
  }

  /// A line through (x, y); nil with fewer than two distinct x.
  public static func linear(_ x: [Double], _ y: [Double], axis: String, unit: String, at: [String: String]? = nil) -> SweepFit? {
    guard Set(x).count >= 2, let b = leastSquares(x.map { [1, $0] }, y) else { return nil }
    let q = quality(y, x.map { b[0] + b[1] * $0 }, parameters: 1)
    return SweepFit(model: "linear", axis: axis, at: at, n: x.count, slope: Stats.round(b[1], 6), intercept: Stats.round(b[0], 6), r2: Stats.round(q.r2, 4),
                    adjustedR2: q.adjusted.map { Stats.round($0, 4) }, residuals: q.residuals.map { Stats.round($0, 4) }, rmse: Stats.round(q.rmse, 4), unit: unit)
  }

  /// y = a + b·x + c·x²; nil with fewer than four distinct x (three fit any parabola exactly and say nothing).
  public static func quadratic(_ x: [Double], _ y: [Double], axis: String, unit: String, at: [String: String]? = nil) -> SweepFit? {
    guard Set(x).count >= 4, let b = leastSquares(x.map { [1, $0, $0 * $0] }, y) else { return nil }
    let q = quality(y, x.map { b[0] + b[1] * $0 + b[2] * $0 * $0 }, parameters: 2)
    return SweepFit(model: "quadratic", axis: axis, at: at, n: x.count, slope: Stats.round(b[1], 6), intercept: Stats.round(b[0], 6), quadratic: Stats.round(b[2], 8),
                    r2: Stats.round(q.r2, 4), adjustedR2: q.adjusted.map { Stats.round($0, 4) }, residuals: q.residuals.map { Stats.round($0, 4) }, rmse: Stats.round(q.rmse, 4), unit: unit)
  }

  /// y = a + Σ bᵢ·xᵢ over several axes.
  public static func plane(_ xs: [[Double]], _ y: [Double], axes: [String], unit: String) -> SweepFit? {
    guard axes.count >= 2, let b = leastSquares(xs.map { [1] + $0 }, y) else { return nil }
    let fitted = xs.map { row in b[0] + zip(row, b.dropFirst()).map { $0 * $1 }.reduce(0, +) }
    let q = quality(y, fitted, parameters: axes.count)
    var co: [String: Double] = [:]
    for (i, a) in axes.enumerated() { co[a] = Stats.round(b[i + 1], 6) }
    return SweepFit(model: "plane", axis: axes[0], n: y.count, slope: co[axes[0]] ?? 0, intercept: Stats.round(b[0], 6), coefficients: co, r2: Stats.round(q.r2, 4),
                    adjustedR2: q.adjusted.map { Stats.round($0, 4) }, residuals: q.residuals.map { Stats.round($0, 4) }, rmse: Stats.round(q.rmse, 4), unit: "\(unit) per unit of each axis")
  }

  /// Every fit the points allow, and the headline one. Points without a number are left out.
  public static func fits(_ points: [SweepPoint], axes: [SweepAxis], objective: String) -> (fit: SweepFit?, all: [SweepFit]) {
    let use = points.filter(\.usable)
    let numeric = axes.filter(\.numeric)
    var all: [SweepFit] = []
    for a in numeric {
      let others = axes.filter { $0.name != a.name }
      let slices = Dictionary(grouping: use) { p in others.map { p.values[$0.name] ?? "" } }
      for (_, ps) in slices.sorted(by: { $0.key.joined(separator: ",") < $1.key.joined(separator: ",") }) {
        let sorted = ps.sorted { Double($0.values[a.name] ?? "") ?? 0 < Double($1.values[a.name] ?? "") ?? 0 }
        let x = sorted.compactMap { Double($0.values[a.name] ?? "") }, y = sorted.compactMap(\.objective)
        guard x.count == y.count else { continue }
        let at: [String: String]? = others.isEmpty ? nil : Dictionary(uniqueKeysWithValues: others.map { ($0.name, sorted[0].values[$0.name] ?? "") })
        let unit = slopeUnit(objective, axis: a.name)
        if let f = linear(x, y, axis: a.name, unit: unit, at: at) { all.append(f) }
        if let f = quadratic(x, y, axis: a.name, unit: unit, at: at) { all.append(f) }
      }
    }
    var head: SweepFit?
    if numeric.count >= 2 {
      let rows = use.map { p in numeric.map { Double(p.values[$0.name] ?? "") ?? 0 } }
      if let p = plane(rows, use.compactMap(\.objective), axes: numeric.map(\.name), unit: metricUnit(objective)) { all.append(p); head = p }
    } else if let a = numeric.first {
      head = all.first { $0.model == "linear" && $0.axis == a.name }
    }
    return (head, all)
  }

  // MARK: words

  /// What the objective is called in a sentence, and its unit.
  public static func metricWord(_ m: String) -> String {
    switch m {
    case "mainThreadCpuMsPerStep": return "ms/step"
    case "instructionsPerStep": return "instructions/step"
    case "latencyMs": return "latency"
    case "hitchTimeRatioMsPerS": return "late frame time"
    default: return m
    }
  }
  public static func metricUnit(_ m: String) -> String {
    switch m {
    case "mainThreadCpuMsPerStep": return "ms per step"
    case "instructionsPerStep": return "instructions per step"
    case "latencyMs": return "ms"
    case "hitchTimeRatioMsPerS": return "ms/s"
    default: return m
    }
  }
  static func shortUnit(_ m: String) -> String {
    switch m { case "mainThreadCpuMsPerStep", "latencyMs": return "ms"; case "instructionsPerStep": return "instructions"; case "hitchTimeRatioMsPerS": return "ms/s"; default: return "" }
  }
  /// "agents" → "agent": the unit of one step along an axis.
  static func singular(_ axis: String) -> String {
    let last = axis.split(separator: ".").last.map(String.init) ?? axis
    return last.count > 3 && last.hasSuffix("s") && !last.hasSuffix("ss") ? String(last.dropLast()) : last
  }
  public static func slopeUnit(_ m: String, axis: String) -> String { "\(metricUnit(m)) per \(singular(axis))" }

  /// A number as a person reads it: two significant decimals, millions as M.
  public static func fmt(_ x: Double) -> String {
    let a = abs(x)
    if a >= 1e6 { return "\(Stats.round(x / 1e6, a >= 1e8 ? 0 : 2)) M" }
    if a >= 100 { return String(Int(x.rounded())) }
    if a >= 10 { return String(Stats.round(x, 1)) }
    if a >= 0.1 { return String(Stats.round(x, 2)) }
    if a == 0 { return "0" }
    return String(format: "%.2g", x)
  }

  /// "ms/step grows 0.9 ms per agent (r² 0.98)", for a linear or plane fit.
  public static func sentence(_ f: SweepFit, objective: String) -> String {
    let unit = shortUnit(objective)
    let verb = f.slope >= 0 ? "grows" : "falls"
    let per = singular(f.axis)
    let slice = f.at.map { at in at.isEmpty ? "" : " at " + at.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") } ?? ""
    switch f.model {
    case "plane":
      let terms = (f.coefficients ?? [:]).sorted { $0.key < $1.key }.map { "\(fmt($0.value))\(unit.isEmpty ? "" : " " + unit) per \(singular($0.key))" }
      return "\(metricWord(objective)) ≈ \(fmt(f.intercept)) + " + terms.joined(separator: " + ") + " (r² \(Stats.round(f.r2, 2)), plane through \(f.n) points)"
    case "quadratic":
      return "quadratic\(slice): \(fmt(f.intercept)) + \(fmt(f.slope))·\(per) + \(fmt(f.quadratic ?? 0))·\(per)² (r² \(Stats.round(f.r2, 2)))"
    default:
      return "\(metricWord(objective)) \(verb) \(fmt(abs(f.slope)))\(unit.isEmpty ? "" : " " + unit) per \(per)\(slice) (r² \(Stats.round(f.r2, 2)))"
    }
  }

  /// Whether the quadratic says something the line doesn't: it explains clearly more after paying for its extra term.
  public static func curves(linear l: SweepFit, quadratic q: SweepFit) -> Bool {
    guard let la = l.adjustedR2, let qa = q.adjustedR2 else { return false }
    return qa - la > 0.02 && q.r2 > l.r2
  }

  /// The sweep as text: a table of the points and the fits, the busy points, what's missing.
  public static func text(_ d: SweepDoc) -> String {
    var o: [String] = []
    let grid = d.axis.map { a in "\(a.name) \(a.values.count == 1 ? a.values[0] : a.numeric ? "\(a.values.first!)…\(a.values.last!) (\(a.values.count))" : a.values.joined(separator: "|"))" }
    o.append("sweep \(d.scenario) on \(d.fixture) · \(grid.joined(separator: " × ")) · \(d.points.count) point(s) · \(d.reps) rep(s) a point · \(d.objective)")
    if let b = d.build { o.append("build: \(b.line)") }
    if !d.fixed.isEmpty { o.append("fixed: " + d.fixed.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) }
    let names = d.axis.map(\.name)
    let w = names.map { max($0.count, 6) }
    var head = zip(names, w).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }.joined(separator: "  ")
    head += "  " + metricWord(d.objective).padding(toLength: 22, withPad: " ", startingAt: 0) + "  hitch ms/s  guards"
    o.append("  " + head)
    let sorted = d.points.sorted { a, b in
      for n in names {
        let x = a.values[n] ?? "", y = b.values[n] ?? ""
        if x == y { continue }
        if let p = Double(x), let q = Double(y) { return p < q }
        return x < y
      }
      return false
    }
    for p in sorted {
      var line = zip(names, w).map { (p.values[$0] ?? "-").padding(toLength: $1, withPad: " ", startingAt: 0) }.joined(separator: "  ")
      let obj: String
      if let v = p.objective {
        obj = fmt(v) + (p.dist.map { $0.n > 1 ? " (\(fmt($0.min))–\(fmt($0.max)))" : "" } ?? "")
      } else { obj = p.failure.map { "– \($0)" } ?? "– not measured" }
      line += "  " + obj.padding(toLength: 22, withPad: " ", startingAt: 0)
      line += "  " + (p.hitchTimeRatioMsPerS.map(fmt) ?? "-").padding(toLength: 10, withPad: " ", startingAt: 0)
      line += "  " + (p.guardsPassed.map { $0 ? "ok" : "FAIL " + p.checksFailed.joined(separator: ",") } ?? "-")
      if p.busy == true { line += "  busy" }
      o.append("  " + line)
    }
    if let f = d.fit { o.append("fit: " + sentence(f, objective: d.objective)) }
    for a in d.axis where a.numeric {
      let lines = d.fits.filter { $0.model == "linear" && $0.axis == a.name && $0 != d.fit }
      let quads = d.fits.filter { $0.model == "quadratic" && $0.axis == a.name }
      if lines.count <= 3 {
        for l in lines { o.append("  " + sentence(l, objective: d.objective)) }
      } else {
        let s = lines.map(\.slope), r = lines.map(\.r2)
        o.append("  per \(singular(a.name)), in each of \(lines.count) slices of the other axes: \(fmt(s.min()!))…\(fmt(s.max()!))\(shortUnit(d.objective).isEmpty ? "" : " " + shortUnit(d.objective)) (r² ≥ \(Stats.round(r.min()!, 2)))")
      }
      for q in quads {
        guard let l = d.fits.first(where: { $0.model == "linear" && $0.axis == q.axis && $0.at == q.at }) else { continue }
        if curves(linear: l, quadratic: q) {
          o.append("  " + sentence(q, objective: d.objective) + ": curves (adjusted r² \(Stats.round(q.adjustedR2 ?? 0, 2)) vs \(Stats.round(l.adjustedR2 ?? 0, 2)) for the line)")
        } else if quads.count == 1 { o.append("  a quadratic in \(singular(a.name)) is no better than the line (adjusted r² \(Stats.round(q.adjustedR2 ?? 0, 2)) vs \(Stats.round(l.adjustedR2 ?? 0, 2)))") }
      }
    }
    if let f = d.fit, !f.residuals.isEmpty { o.append("  residuals" + (shortUnit(d.objective).isEmpty ? "" : " (\(shortUnit(d.objective)))") + ": " + f.residuals.map(fmt).joined(separator: " ") + " · rmse \(fmt(f.rmse))") }
    let busy = d.points.filter { $0.busy == true }
    if !busy.isEmpty { o.append("busy machine at \(busy.count) point(s): " + busy.map { key($0.values, axes: d.axis) }.joined(separator: "; ") + " (their numbers may be high; rerun them with --redo KEY)") }
    let missing = d.points.filter { !$0.usable }
    if !missing.isEmpty { o.append("missing \(missing.count) point(s): rerun the same command to measure them") }
    for n in d.notes { o.append("note: " + n) }
    return o.joined(separator: "\n")
  }

  static func text(_ v: JSONValue) -> String {
    if let s = v.string { return s }
    if let d = v.double { return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d) }
    if let b = v.bool { return String(b) }
    return ""
  }
  static func json(_ s: String) -> JSONValue {
    if let i = Int(s) { return .number(Double(i)) }
    if let d = Double(s), s.contains(".") { return .number(d) }
    return .string(s)
  }
}
