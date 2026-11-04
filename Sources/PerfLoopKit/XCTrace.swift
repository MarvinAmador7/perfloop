import Foundation

// Reading what `xctrace export --xpath` prints (CAPABILITIES.md C2; ported from capcomd's deskbench), so no one
// hand-parses it again. The export is a table: a <schema> with <col><mnemonic> names, then <row>s whose cells either
// carry an id (first occurrence) or a ref to an earlier cell. Backtraces are the same: a <backtrace> or
// <tagged-backtrace> whose <frame>s have a `name` attribute, by id or ref. Pure: the export is text, so this parses on
// Linux too; recording and exporting (`xcrun xctrace`) are PerfLoopHost's.

/// A light DOM for the export, built by `XMLLite`.
public final class XNode {
  public let name: String
  public var attrs: [String: String]
  public var text = ""
  public var children: [XNode] = []
  public init(_ n: String, _ a: [String: String]) { name = n; attrs = a }
  public func first(_ n: String) -> XNode? { children.first { $0.name == n } }
  public func all(_ n: String) -> [XNode] { children.filter { $0.name == n } }
}

/// One exported table, with ids resolved.
public struct XCTable {
  public var schema: String
  public var columns: [String]
  /// Each row: column mnemonic → the resolved cell.
  public var rows: [[String: XNode]]
  /// Every cell with an id, for resolving refs inside backtraces.
  public var ids: [String: XNode]

  /// Every `<node>` of the export: one table can come in several (a schema-only node, then the rows; or one per
  /// matching table, as `table[@schema="os-signpost"]` matches four). Ids are global to the document, so refs cross
  /// nodes. A `<sentinel/>` is an empty cell: it keeps its column's place and is absent from the row.
  public init(xml: Data) throws {
    let root = try XMLLite.parse(xml)
    let nodes = root.first("trace-query-result")?.all("node") ?? []
    guard !nodes.isEmpty else { throw XCTraceError.badXML("no <node>") }
    var schema: String?, columns: [String] = []
    var ids: [String: XNode] = [:]
    func register(_ n: XNode) { if let id = n.attrs["id"] { ids[id] = n }; n.children.forEach(register) }
    var rows: [[String: XNode]] = []
    for node in nodes {
      if let s = node.first("schema") {
        if schema == nil { schema = s.attrs["name"] }
        columns = s.all("col").compactMap { $0.first("mnemonic")?.text }
      }
      for r in node.all("row") {
        register(r)
        var out: [String: XNode] = [:]
        for (c, cell) in zip(columns, r.children) where cell.name != "sentinel" { out[c] = cell.attrs["ref"].flatMap { ids[$0] } ?? cell }
        rows.append(out)
      }
    }
    self.schema = schema ?? "?"; self.columns = columns
    self.rows = rows; self.ids = ids
  }

  /// Resolves refs inside a cell's subtree (a backtrace's frames).
  public static func frames(_ bt: XNode, ids: [String: XNode]) -> [String] { bt.all("frame").map { ($0.attrs["ref"].flatMap { ids[$0] } ?? $0).attrs["name"] ?? "?" } }
}

public enum XCTraceError: Error, CustomStringConvertible {
  case badXML(String), noTable(String)
  public var description: String { switch self { case .badXML(let s): "xctrace export: \(s)"; case .noTable(let s): "no \(s) table in the trace" } }
}

/// Animation Hitches: the compositor's hitch list (frames shown late), and Instruments' potential hangs.
public struct HitchSummary: Codable, Sendable, Equatable {
  public var process: String
  public var hitches: Int
  public var totalMs: Double
  public var maxMs: Double
  public var over16Ms: Int
  /// Instruments' "Potential Issue" per hitch, counted.
  public var causes: [String: Int]
  public var durationsMs: [Double]
  public var potentialHangsMs: [Double]

  public init(hitches: XCTable, hangs: XCTable?, process: String) {
    self.process = process
    let ours = hitches.rows.filter { ($0["process"]?.attrs["fmt"] ?? "").contains(process) }
    let ms = ours.compactMap { $0["duration"]?.text }.compactMap(Double.init).map { $0 / 1e6 }
    self.hitches = ours.count; totalMs = Stats.round(ms.reduce(0, +), 1); maxMs = Stats.round(ms.max() ?? 0, 2)
    over16Ms = ms.filter { $0 >= 16 }.count
    var c: [String: Int] = [:]
    for r in ours { c[r["narrative-description"]?.attrs["fmt"] ?? r["narrative-description"]?.text ?? "unspecified", default: 0] += 1 }
    causes = c; durationsMs = ms.map { Stats.round($0, 2) }
    potentialHangsMs = (hangs?.rows ?? []).filter { ($0["process"]?.attrs["fmt"] ?? "").contains(process) || hangs?.columns.contains("process") == false }
      .compactMap { $0["duration"]?.text }.compactMap(Double.init).map { Stats.round($0 / 1e6, 1) }.sorted()
  }
}

extension XCTable {
  /// A table with no rows, for summaries that only have hangs.
  public static var empty: XCTable { try! XCTable(xml: Data("<trace-query-result><node><schema name=\"hitches\"></schema></node></trace-query-result>".utf8)) }
}

/// SwiftUI template: view body evaluations by view type, from the SwiftUI instruments' tables when present.
public struct SwiftUISummary: Codable, Sendable, Equatable {
  public var table: String
  public var rows: Int
  public var byView: [String: Int]
  public init(table t: XCTable) {
    table = t.schema; rows = t.rows.count
    var c: [String: Int] = [:]
    for r in t.rows {
      let name = r["view-name"]?.attrs["fmt"] ?? r["name"]?.attrs["fmt"] ?? r["view-type"]?.attrs["fmt"] ?? r.values.first { $0.name == "string" }?.attrs["fmt"] ?? "?"
      c[String(name.prefix(80)), default: 0] += 1
    }
    byView = c
  }
}

