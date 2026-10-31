import Foundation

// Runtime knobs (CAPABILITIES.md C4): named, typed switches read at the use site, so one binary holds several
// variants and a bench can sweep them without rebuilding. The runner sets them for a run in the environment,
// `PERFLOOP_KNOBS=reel.slide=clip,build.perFrame=2`; without it every knob reads its default, so the app behaves
// exactly as it would without knobs.
//
// A knob is a `static let` at the site that varies:
//
//     static let slide = Knob("reel.slide", default: "ca", choices: ["ca", "clip"])
//     … if Self.slide.value == "clip" { … }
//
// Its value is resolved once, when the static is first touched, and stored in the knob: a read after that is one
// static load, no dictionary and no lock (a knob read every frame must cost no more than a constant would).
// Registration is part of making the knob, so an adapter's `describe` can list every knob with its default and
// choices once it has touched the statics. Knobs are for experiments: a knob that wins is made the default in a
// follow-up change and deleted (SPEC.md §7.6).

/// A value a knob can take. It is written as text in `PERFLOOP_KNOBS`, in results and in the manifest.
public protocol KnobValue: Sendable, Equatable {
  init?(knobText: String)
  var knobText: String { get }
  /// The manifest's `type`: "int", "double", "bool" or "string". A knob with choices is always "choice".
  static var knobType: String { get }
}

extension String: KnobValue {
  public init?(knobText s: String) { self = s }
  public var knobText: String { self }
  public static var knobType: String { "string" }
}

extension Int: KnobValue {
  public init?(knobText s: String) { self.init(s.trimmingCharacters(in: .whitespaces)) }
  public var knobText: String { String(self) }
  public static var knobType: String { "int" }
}

extension Double: KnobValue {
  public init?(knobText s: String) { self.init(s.trimmingCharacters(in: .whitespaces)) }
  public var knobText: String { String(self) }
  public static var knobType: String { "double" }
}

extension Bool: KnobValue {
  public init?(knobText s: String) {
    switch s.trimmingCharacters(in: .whitespaces).lowercased() {
    case "1", "true", "on", "yes": self = true
    case "0", "false", "off", "no": self = false
    default: return nil
    }
  }
  public var knobText: String { self ? "true" : "false" }
  public static var knobType: String { "bool" }
}

/// An enum with string raw values is a knob value as it is: `enum Slide: String, KnobValue { case ca, clip }`.
extension KnobValue where Self: RawRepresentable, RawValue == String {
  public init?(knobText s: String) { self.init(rawValue: s) }
  public var knobText: String { rawValue }
  public static var knobType: String { "choice" }
}

/// What the manifest says about a knob (SCHEMAS.md `perfloop.manifest/1` → `knobs[]`). `default` and `range` are
/// numbers in JSON for numeric knobs, strings otherwise.
public struct KnobInfo: Codable, Sendable, Equatable {
  public var name: String
  /// "choice", "int", "double", "bool" or "string".
  public var type: String
  public var `default`: String
  public var choices: [String]?
  /// Lower and upper bound, inclusive.
  public var range: [String]?
  public var summary: String?
  /// The version or phase the knob appeared in: the ledger flags knobs older than one phase.
  public var since: String?

  public init(name: String, type: String, default d: String, choices: [String]? = nil, range: [String]? = nil, summary: String? = nil, since: String? = nil) {
    self.name = name; self.type = type; self.default = d; self.choices = choices; self.range = range; self.summary = summary; self.since = since
  }

  enum CodingKeys: String, CodingKey { case name, type, `default`, choices, range, summary, since }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(name, forKey: .name); try c.encode(type, forKey: .type)
    try c.encode(Scalar(self.default, type: type), forKey: .default)
    try c.encodeIfPresent(choices, forKey: .choices)
    try c.encodeIfPresent(range?.map { Scalar($0, type: type) }, forKey: .range)
    try c.encodeIfPresent(summary, forKey: .summary); try c.encodeIfPresent(since, forKey: .since)
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name); type = try c.decode(String.self, forKey: .type)
    self.default = try c.decode(Scalar.self, forKey: .default).text
    choices = try c.decodeIfPresent([String].self, forKey: .choices)
    range = try c.decodeIfPresent([Scalar].self, forKey: .range)?.map(\.text)
    summary = try c.decodeIfPresent(String.self, forKey: .summary); since = try c.decodeIfPresent(String.self, forKey: .since)
  }

  /// A knob value in JSON: a number for numeric knobs, a bool for bool knobs, else a string. Decodes any of them.
  struct Scalar: Codable {
    var text: String
    var type = "string"
    init(_ text: String, type: String) { self.text = text; self.type = type }
    init(from decoder: Decoder) throws {
      let c = try decoder.singleValueContainer()
      if let s = try? c.decode(String.self) { text = s }
      else if let i = try? c.decode(Int.self) { text = String(i) }
      else if let d = try? c.decode(Double.self) { text = String(d) }
      else { text = try c.decode(Bool.self).knobText }
    }
    func encode(to encoder: Encoder) throws {
      var c = encoder.singleValueContainer()
      switch type {
      case "int": if let i = Int(knobText: text) { return try c.encode(i) }
      case "double": if let d = Double(knobText: text) { return try c.encode(d) }
      case "bool": if let b = Bool(knobText: text) { return try c.encode(b) }
      default: break
      }
      try c.encode(text)
    }
  }
}

/// A runtime knob. Make it a `static let` where it is read; `value` is fixed for the life of the process.
public struct Knob<Value: KnobValue>: Sendable {
  public let name: String
  public let defaultValue: Value
  /// The value this process runs with: the setting's, when it has a valid one, else the default.
  public let value: Value
  public let info: KnobInfo
  @inline(__always) public func callAsFunction() -> Value { value }
  public var isDefault: Bool { value == defaultValue }

  /// A knob that takes one of `choices`.
  public init(_ name: String, default d: Value, choices: [Value], summary: String? = nil, since: String? = nil, settings: [String: String] = Knobs.settings) {
    let texts = choices.map(\.knobText)
    self.init(name, default: d, info: KnobInfo(name: name, type: "choice", default: d.knobText, choices: texts, summary: summary, since: since), settings: settings) { v in
      choices.contains(v) ? nil : "not one of \(texts.joined(separator: ", "))"
    }
  }

  /// A knob that takes any value in `range`.
  public init(_ name: String, default d: Value, range: ClosedRange<Value>, summary: String? = nil, since: String? = nil, settings: [String: String] = Knobs.settings) where Value: Comparable {
    let lo = range.lowerBound.knobText, hi = range.upperBound.knobText
    self.init(name, default: d, info: KnobInfo(name: name, type: Value.knobType, default: d.knobText, range: [lo, hi], summary: summary, since: since), settings: settings) { v in
      range.contains(v) ? nil : "outside \(lo)…\(hi)"
    }
  }

  /// A knob that takes any value of its type (a bool, or an enum whose cases are its choices).
  public init(_ name: String, default d: Value, summary: String? = nil, since: String? = nil, settings: [String: String] = Knobs.settings) {
    self.init(name, default: d, info: KnobInfo(name: name, type: Value.knobType, default: d.knobText, summary: summary, since: since), settings: settings) { _ in nil }
  }

  private init(_ name: String, default d: Value, info: KnobInfo, settings: [String: String], check: @escaping @Sendable (Value) -> String?) {
    let validate: @Sendable (String) -> String? = { text in
      guard let v = Value(knobText: text) else { return info.choices.map { "not one of \($0.joined(separator: ", "))" } ?? "'\(text)' is not a valid \(info.type)" }
      return check(v)
    }
    var resolved = d, problem: String?
    if let text = settings[name] {
      if let p = validate(text) { problem = "\(name)=\(text): \(p); using the default \(d.knobText)" }
      else if let v = Value(knobText: text) { resolved = v }
    }
    self.name = name; defaultValue = d; value = resolved; self.info = info
    Knobs.registry.add(.init(info: info, value: resolved.knobText, problem: problem, validate: validate))
  }
}

/// Any knob, whatever its value type: what an adapter lists its own knobs as.
public protocol AnyKnob: Sendable {
  var info: KnobInfo { get }
  /// The value this process runs with, as text.
  var valueText: String { get }
}

extension Knob: AnyKnob {
  public var valueText: String { value.knobText }
}

/// The registry and the environment.
public enum Knobs {
  /// The environment variable a bench sets for its child: `name=value,name=value`.
  public static let variable = "PERFLOOP_KNOBS"

  /// `PERFLOOP_KNOBS` as this process started with it, parsed once.
  public static let settings: [String: String] = parse(ProcessInfo.processInfo.environment[variable] ?? "")

  /// `a=1,b=two` → ["a": "1", "b": "two"]. Whitespace around names and values is dropped; an entry without `=` or
  /// with an empty name is skipped (`malformed` lists them); a later entry for a name wins.
  public static func parse(_ s: String) -> [String: String] {
    var d: [String: String] = [:]
    for e in entries(s) where !e.name.isEmpty { if let v = e.value { d[e.name] = v } }
    return d
  }

  /// The entries of a setting string that `parse` skipped.
  public static func malformed(_ s: String) -> [String] {
    entries(s).filter { $0.name.isEmpty || $0.value == nil }.map(\.text)
  }

  private static func entries(_ s: String) -> [(text: String, name: String, value: String?)] {
    s.split(separator: ",").compactMap { e in
      let t = e.trimmingCharacters(in: .whitespaces)
      guard !t.isEmpty else { return nil }
      let p = t.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
      return (t, p[0], p.count == 2 ? p[1] : nil)
    }
  }

  /// The inverse of `parse`, names sorted: what a bench exports for a child.
  public static func format(_ v: [String: String]) -> String {
    v.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
  }

  /// Every knob made so far, by name.
  public static var registered: [KnobInfo] { registry.all.map(\.info) }

  /// The full knob vector this process runs with, defaults included (a result's `knobs`).
  public static var vector: [String: String] { Dictionary(uniqueKeysWithValues: registry.all.map { ($0.info.name, $0.value) }) }

  /// What is wrong with this process's settings: values a knob refused (it runs with its default) and names no knob
  /// has. Names are only known once every knob is made, so ask after touching them all.
  public static var problems: [String] { problems(in: settings, raw: ProcessInfo.processInfo.environment[variable] ?? "") }

  static func problems(in settings: [String: String], raw: String) -> [String] {
    let all = registry.all
    var out = malformed(raw).map { "\(variable): '\($0)' is not name=value" }
    out += all.compactMap(\.problem)
    let names = Set(all.map(\.info.name))
    out += settings.keys.sorted().filter { !names.contains($0) }.map { "unknown knob '\($0)' (known: \(names.sorted().joined(separator: ", ")))" }
    return out
  }

  /// Checks a setting before it is handed to a child: one line per name that no knob has or value it refuses.
  public static func check(_ proposed: [String: String]) -> [String] {
    let all = Dictionary(registry.all.map { ($0.info.name, $0) }, uniquingKeysWith: { _, b in b })
    return proposed.sorted { $0.key < $1.key }.compactMap { k, v in
      guard let e = all[k] else { return "unknown knob '\(k)' (known: \(all.keys.sorted().joined(separator: ", ")))" }
      return e.validate(v).map { "\(k)=\(v): \($0)" }
    }
  }

  static let registry = Registry()

  final class Registry: @unchecked Sendable {
    struct Entry: Sendable {
      var info: KnobInfo
      var value: String
      var problem: String?
      var validate: @Sendable (String) -> String?
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Registration happens once per knob (a static's first touch), never on a read.
    func add(_ e: Entry) { lock.lock(); entries[e.info.name] = e; lock.unlock() }
    var all: [Entry] { lock.lock(); defer { lock.unlock() }; return entries.values.sorted { $0.info.name < $1.info.name } }
  }
}
