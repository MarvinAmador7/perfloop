import Foundation

/// A gesture file as `perfloop gestures list` sees it (`perfloop.gesture/1`, SCHEMAS.md §8; written by an adapter's
/// recorder, PerfLoopProbe's Gestures.swift). Read loosely, like an adapter's results: what a list needs and what is
/// wrong with the file, never a schema that breaks on an added field.
public struct GestureFile: Codable, Sendable, Equatable {
  public static let schema = "perfloop.gesture/1"
  public var path: String
  public var name: String?
  public var device: String?
  public var recordedAt: String?
  public var synthetic: Bool
  public var events: Int
  public var durationMs: Double
  /// Σ dx, Σ dy while the fingers were down (phase other than "none"), and during the momentum.
  public var finger: [Double]
  public var momentum: [Double]
  public var hz: Double?
  /// Empty when an adapter can replay it.
  public var problems: [String]

  public init(path: String, json v: JSONValue) {
    self.path = path
    name = v["name"]?.string; device = v["device"]?.string; recordedAt = v["recordedAt"]?.string
    synthetic = v["synthetic"]?.bool ?? false; hz = v["hz"]?.double
    let es = v["events"]?.array ?? []
    events = es.count
    let ts = es.compactMap { $0["t"]?.double }
    durationMs = Stats.round((ts.last ?? 0) - (ts.first ?? 0), 1)
    func sum(_ f: (JSONValue) -> Bool) -> [Double] {
      let xs = es.filter(f)
      return [Stats.round(xs.reduce(0) { $0 + ($1["dx"]?.double ?? 0) }, 1), Stats.round(xs.reduce(0) { $0 + ($1["dy"]?.double ?? 0) }, 1)]
    }
    finger = sum { ($0["phase"]?.string ?? "none") != "none" }
    momentum = sum { ($0["momentum"]?.string ?? "none") != "none" }
    var p: [String] = []
    if v["schema"]?.string != Self.schema { p.append("schema is \(v["schema"]?.string ?? "missing"), not \(Self.schema)") }
    if es.isEmpty { p.append("no events") }
    if ts.count != es.count { p.append("an event has no time") }
    if zip(ts.dropFirst(), ts).contains(where: { $0 < $1 }) { p.append("event times go backwards") }
    if !es.isEmpty, finger == [0, 0], momentum == [0, 0], es.allSatisfy({ ($0["dx"]?.double ?? 0) == 0 && ($0["dy"]?.double ?? 0) == 0 }) { p.append("nothing moved") }
    problems = p
  }

  public static func read(_ path: String) -> GestureFile {
    do { return GestureFile(path: path, json: try PLJSON.read(JSONValue.self, path: path)) }
    catch {
      var g = GestureFile(path: path, json: .object([:])); g.problems = ["not JSON: \(error.localizedDescription)"]
      return g
    }
  }

  /// Every `*.json` in the folders that is a gesture file, by folder then name. A JSON file of another schema is
  /// skipped, not listed as broken (a folder may hold results too); `explicit` files are always listed.
  public static func scan(dirs: [String], files explicit: [String] = []) -> [GestureFile] {
    var out = explicit.map(read)
    var seen = Set(explicit.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    for d in dirs {
      let names = ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
      for n in names {
        let p = URL(fileURLWithPath: d).appendingPathComponent(n).standardizedFileURL.path
        guard seen.insert(p).inserted, let v = try? PLJSON.read(JSONValue.self, path: p), v["schema"]?.string == schema else { continue }
        out.append(GestureFile(path: p, json: v))
      }
    }
    return out
  }

  public var line: String {
    guard problems.isEmpty else { return "\(path): " + problems.joined(separator: "; ") }
    var s = "\((name ?? "?").padding(toLength: 28, withPad: " ", startingAt: 0)) \(device ?? "?") · \(events) events · \(Int(durationMs)) ms"
    if let hz { s += " at \(hz == hz.rounded() ? String(Int(hz)) : String(hz)) Hz" }
    s += " · fingers \(finger[0]), \(finger[1]) pt · momentum \(momentum[0]), \(momentum[1]) pt"
    if synthetic { s += " · synthetic" }
    return s + "\n  " + path
  }
}
