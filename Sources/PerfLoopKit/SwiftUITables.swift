import Foundation

// The SwiftUI template's cause and effect tables (CAPABILITIES.md C7, confirmation side; ported from capcomd's
// deskbench), summarised: which root cause led to how many updates of which views, and the longest updates.
//
// The rows' content has not been seen yet: on the Mac this was written on, every swiftui-* table came out with zero
// rows ("Trace file had no SwiftUI data"), whether xctrace attached or launched the bench, bare or as an .app bundle. So
// cells are read loosely: a cell's `fmt` (what Instruments shows), else its text, else its children's `fmt`s joined.
// `rows` says how many rows each table had, so an empty recording is visible as such.

/// `profile.swiftUI` (`perfloop.profile/2`).
public struct SwiftUIProfile: Codable, Sendable, Equatable {
  public struct RootCause: Codable, Sendable, Equatable {
    /// The update's root cause as the template words it; `(none)` when the row had none.
    public var cause: String
    public var updates: Int
    /// Updates by view name.
    public var views: [String: Int]
    /// Their summed duration.
    public var ms: Double
    public init(cause: String, updates: Int, views: [String: Int], ms: Double) { self.cause = cause; self.updates = updates; self.views = views; self.ms = ms }
  }
  public struct LongUpdate: Codable, Sendable, Equatable {
    public var view: String
    public var ms: Double
    public var cause: String?
    public var severity: String?
    public var updateType: String?
  }
  /// Body counts by view (the older summary), one per table that has a view column.
  public var tables: [SwiftUISummary]
  /// Rows per table, every table asked for (0 = recorded nothing).
  public var rows: [String: Int]
  /// From `swiftui-updates`: heaviest first (updates, then ms).
  public var rootCauses: [RootCause]
  /// From `swiftui-updates`: the longest 20 at or over 1 ms.
  public var longUpdates: [LongUpdate]
  /// From `swiftui-causes`: `label: changed-properties` of the cause graph's edges, counted (top 30).
  public var edges: [String: Int]
  /// From `swiftui-changes`: `description`, counted (top 30).
  public var changes: [String: Int]
  /// From `swiftui-update-groups`: `label`, counted.
  public var groups: [String: Int]

  public static let tableNames = ["swiftui-updates", "swiftui-causes", "swiftui-update-groups", "swiftui-changes"]

  /// `tables`: the exports by schema name (a missing one counts as absent, not as zero rows). `process` keeps rows of
  /// that process only, where the table has a process column.
  public init(tables t: [String: XCTable], process: String? = nil) {
    func ours(_ name: String) -> [[String: XNode]] {
      guard let table = t[name] else { return [] }
      guard let p = process, table.columns.contains("process") else { return table.rows }
      return table.rows.filter { ($0["process"].map(Self.text) ?? "").contains(p) }
    }
    rows = Dictionary(uniqueKeysWithValues: t.map { ($0.key, ours($0.key).count) })
    tables = t.keys.sorted().compactMap { k in t[k].map { var s = SwiftUISummary(table: $0); s.rows = ours(k).count; return s } }.filter { $0.rows > 0 }

    var by: [String: RootCause] = [:]
    var long: [LongUpdate] = []
    for r in ours("swiftui-updates") {
      let view = r["view-name"].map(Self.text).flatMap { $0.isEmpty ? nil : $0 } ?? r["description"].map(Self.text) ?? "?"
      let cause = r["root-causes"].map(Self.text).flatMap { $0.isEmpty ? nil : $0 } ?? "(none)"
      let ms = r["duration"].flatMap(Self.ms) ?? 0
      var c = by[cause] ?? RootCause(cause: String(cause.prefix(160)), updates: 0, views: [:], ms: 0)
      c.updates += 1; c.views[String(view.prefix(80)), default: 0] += 1; c.ms += ms
      by[cause] = c
      if ms >= 1 { long.append(LongUpdate(view: String(view.prefix(80)), ms: Stats.round(ms, 2), cause: cause == "(none)" ? nil : String(cause.prefix(160)),
                                          severity: r["severity"].map(Self.text), updateType: r["update-type"].map(Self.text))) }
    }
    rootCauses = by.values.map { var c = $0; c.ms = Stats.round(c.ms, 2); return c }.sorted { ($0.updates, $0.ms, $1.cause) > ($1.updates, $1.ms, $0.cause) }
    longUpdates = Array(long.sorted { ($0.ms, $1.view) > ($1.ms, $0.view) }.prefix(20))

    func count(_ rows: [[String: XNode]], limit: Int = 30, _ key: ([String: XNode]) -> String?) -> [String: Int] {
      var c: [String: Int] = [:]
      for r in rows { if let k = key(r), !k.isEmpty { c[String(k.prefix(160)), default: 0] += 1 } }
      return Dictionary(uniqueKeysWithValues: c.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(limit).map { ($0.key, $0.value) })
    }
    edges = count(ours("swiftui-causes")) { r in
      let label = r["label"].map(Self.text) ?? "", props = r["changed-properties"].map(Self.text) ?? ""
      return props.isEmpty ? label : label.isEmpty ? props : "\(label): \(props)"
    }
    changes = count(ours("swiftui-changes")) { $0["description"].map(Self.text) }
    groups = count(ours("swiftui-update-groups")) { $0["label"].map(Self.text) }
  }

  /// Older profiles wrote `swiftUI` as the list of table summaries: read that as `tables`, the rest empty.
  public init(from decoder: Decoder) throws {
    if let list = try? decoder.singleValueContainer().decode([SwiftUISummary].self) {
      tables = list; rows = Dictionary(list.map { ($0.table, $0.rows) }, uniquingKeysWith: +)
      rootCauses = []; longUpdates = []; edges = [:]; changes = [:]; groups = [:]
      return
    }
    let c = try decoder.container(keyedBy: CodingKeys.self)
    tables = try c.decodeIfPresent([SwiftUISummary].self, forKey: .tables) ?? []
    rows = try c.decodeIfPresent([String: Int].self, forKey: .rows) ?? [:]
    rootCauses = try c.decodeIfPresent([RootCause].self, forKey: .rootCauses) ?? []
    longUpdates = try c.decodeIfPresent([LongUpdate].self, forKey: .longUpdates) ?? []
    edges = try c.decodeIfPresent([String: Int].self, forKey: .edges) ?? [:]
    changes = try c.decodeIfPresent([String: Int].self, forKey: .changes) ?? [:]
    groups = try c.decodeIfPresent([String: Int].self, forKey: .groups) ?? [:]
  }

  /// Whether the recording had any SwiftUI rows at all.
  public var empty: Bool { rows.values.reduce(0, +) == 0 }

  /// What a cell says: its `fmt`, else its text, else its children's `fmt`s.
  static func text(_ n: XNode) -> String {
    if let f = n.attrs["fmt"], !f.isEmpty { return f }
    let t = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !t.isEmpty { return t }
    return n.children.compactMap { $0.attrs["fmt"] ?? ($0.text.isEmpty ? nil : $0.text) }.joined(separator: ", ")
  }

  /// A duration cell (ns) in ms.
  static func ms(_ n: XNode) -> Double? { Double(n.text.trimmingCharacters(in: .whitespaces)).map { $0 / 1e6 } }

  public var lines: [String] {
    var o: [String] = []
    o.append("swiftui: rows " + Self.tableNames.map { "\($0) \(rows[$0].map(String.init) ?? "absent")" }.joined(separator: " · "))
    if empty { o.append("  the template recorded no SwiftUI rows (xctrace says so as \"Trace file had no SwiftUI data\"); the in-process causes are the record") }
    if !rootCauses.isEmpty {
      o.append("  root causes (updates · views):")
      for c in rootCauses.prefix(12) {
        let v = c.views.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5).map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
        o.append("    \(c.updates)× \(c.cause) (\(c.ms) ms): \(v)")
      }
    }
    if !longUpdates.isEmpty { o.append("  longest updates: " + longUpdates.prefix(8).map { "\($0.view) \($0.ms) ms" + ($0.cause.map { " ← \($0)" } ?? "") }.joined(separator: " · ")) }
    if !edges.isEmpty { o.append("  cause edges: " + edges.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(8).map { "\($0.key) ×\($0.value)" }.joined(separator: " · ")) }
    if !changes.isEmpty { o.append("  changes: " + changes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(8).map { "\($0.key) ×\($0.value)" }.joined(separator: " · ")) }
    return o
  }
}
