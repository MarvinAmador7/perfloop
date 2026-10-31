import Foundation

/// Any JSON document, for reading what an adapter prints without a schema that breaks on the next field it adds
/// (`deskbench.ab/1` grows while the hardening work lands). Readers pick paths; unknown keys are kept and ignored.
public enum JSONValue: Codable, Sendable, Equatable {
  case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let b = try? c.decode(Bool.self) { self = .bool(b) }
    else if let n = try? c.decode(Double.self) { self = .number(n) }
    else if let s = try? c.decode(String.self) { self = .string(s) }
    else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
    else { self = .object(try c.decode([String: JSONValue].self)) }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let n): try c.encode(n)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }

  public subscript(_ k: String) -> JSONValue? { if case .object(let o) = self { return o[k] }; return nil }
  public subscript(_ i: Int) -> JSONValue? { if case .array(let a) = self, a.indices.contains(i) { return a[i] }; return nil }
  /// `v.at("summaryA.objective.value")`.
  public func at(_ path: String) -> JSONValue? {
    path.split(separator: ".").reduce(Optional(self)) { $0?[String($1)] }
  }
  public var double: Double? { if case .number(let n) = self { return n }; return nil }
  public var string: String? { if case .string(let s) = self { return s }; return nil }
  public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
  public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
  public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
  public var strings: [String] { array?.compactMap(\.string) ?? [] }

  /// Re-decodes this value as a typed document.
  public func decode<T: Decodable>(_ t: T.Type) throws -> T { try PLJSON.decode(t, from: Data(PLJSON.encode(self).utf8)) }
}

/// Pretty-printed with sorted keys, as `deskbench` writes (diffs of results stay readable).
public enum PLJSON {
  public static func encode<T: Encodable>(_ v: T) -> String {
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try! e.encode(v), as: UTF8.self)
  }
  /// One line, for JSONL (the ledger).
  public static func line<T: Encodable>(_ v: T) -> String {
    let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try! e.encode(v), as: UTF8.self)
  }
  public static func decode<T: Decodable>(_ t: T.Type, from d: Data) throws -> T { try JSONDecoder().decode(t, from: d) }
  public static func read<T: Decodable>(_ t: T.Type, path: String) throws -> T { try decode(t, from: Data(contentsOf: URL(fileURLWithPath: path))) }
  public static func write<T: Encodable>(_ v: T, path: String) throws {
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    try (encode(v) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
  }
  /// The first JSON object in a child's stdout: adapters may print a line of progress before it.
  public static func firstObject(in text: String) -> JSONValue? {
    if let v = try? decode(JSONValue.self, from: Data(text.utf8)), v.object != nil { return v }
    guard let i = text.firstIndex(of: "{"), let j = text.lastIndex(of: "}"), i < j else { return nil }
    return try? decode(JSONValue.self, from: Data(text[i...j].utf8))
  }
}

/// ISO 8601 timestamps (`*At` fields).
public enum Clock {
  public static func now() -> String { iso(Date()) }
  public static func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d) }
  public static func date(_ s: String) -> Date? { ISO8601DateFormatter().date(from: s) }
}
