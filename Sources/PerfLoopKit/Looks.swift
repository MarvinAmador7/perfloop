import Foundation

// Looks (VERIFICATION.md v5, v7, v11): what a snapshot shows, region by region. The bench writes each snapshot with a
// sidecar (`perfloop.snapshot/1`: where its named regions and child windows are, in which appearance); the champion's
// `snapdiff` compares two snapshots per region (`same`, `moved` by dx,dy, `differs`, `missing`, `resized`) and writes
// each changed region's pictures; the runner then judges the looks against the regions the agent declared with
// `--expect-look`: a change inside them is `expected` (the PR's reviewer accepts it by looking, decision 5), one
// outside them stays `REVIEW` for the owner.

/// One region of a snapshot comparison (`guards[].looks[]`, SCHEMAS.md §3).
public struct RegionLook: Codable, Sendable, Equatable {
  public var name: String
  /// same | moved | differs | missing | resized.
  public var look: String
  /// Share of the region's compared pixels that differ where it was (no shift), 0…1.
  public var share: Double?
  /// moved: by how much, in points: [dx, dy], right and down positive.
  public var movedPt: [Double]?
  /// The agent declared this region's change (`--expect-look`): for the PR's reviewer, not the owner.
  public var expected: Bool?
  public var detail: String?
  /// The region in the champion's (before) and the candidate's (after) picture, and the differing pixels in red; absolute,
  /// or relative to the store once the runner has them. Written only for a region that changed.
  public var before: String?
  public var after: String?
  public var diff: String?
  public init(name: String, look: String, share: Double? = nil, movedPt: [Double]? = nil, detail: String? = nil, before: String? = nil, after: String? = nil, diff: String? = nil) {
    self.name = name; self.look = look; self.share = share; self.movedPt = movedPt; self.detail = detail; self.before = before; self.after = after; self.diff = diff
  }

  public var changed: Bool { look != "same" }
  public var pictures: [String] { [before, after, diff].compactMap { $0 } }

  /// "footer differs 3.2 %", "list moved 60,0 pt", "details missing in the candidate's picture".
  public var line: String {
    var s: String
    switch look {
    case "moved": s = "\(name) moved " + (movedPt ?? []).map { Explain.fmt(Stats.round($0, 1)) }.joined(separator: ",") + " pt"
    case "differs": s = "\(name) differs" + (share.map { " \(Stats.round($0 * 100, 2)) %" } ?? "")
    default: s = "\(name) \(look)"
    }
    if let d = detail, look != "same" { s += " (\(d))" }
    if expected == true { s += " [declared]" }
    return s
  }
}

/// `perfloop.snapshot/1`: the sidecar of a snapshot PNG (`X.png` → `X.layout.json`). Rects are in the picture's pixels,
/// from its top-left corner: `[x, y, width, height]`.
public struct SnapshotLayout: Codable, Sendable, Equatable {
  public var schema = "perfloop.snapshot/1"
  /// The picture's size in pixels, and pixels per point.
  public var size: [Int]
  public var scale: Double
  /// light | dark | system: the appearance the window and its child windows drew in.
  public var appearance: String?
  /// The text size the bench applied (`--set textSize=…`), when it applied one.
  public var textSize: String?
  public var regions: [Region]
  /// Regions the scenario named that weren't found when the snapshot was taken.
  public var missing: [String]?
  /// Visible child windows (palettes, popovers, sheets, panels) drawn into the picture where they are on screen.
  public var childWindows: [ChildWindow]?
  /// What this picture can't show (the title bar, materials drawn flat): ScreenCaptureKit's, later (v8).
  public var notCaptured: [String]?

  public struct Region: Codable, Sendable, Equatable {
    public var name: String
    public var rect: [Int]
    /// identifier | view | rect | child window.
    public var source: String?
    public init(name: String, rect: [Int], source: String? = nil) { self.name = name; self.rect = rect; self.source = source }
  }

  public struct ChildWindow: Codable, Sendable, Equatable {
    public var name: String
    /// The window's class (NSPanel, _NSPopoverWindow, …).
    public var kind: String
    public var rect: [Int]
    /// Part of it is outside the bench window's content: cut off in the picture.
    public var clipped: Bool?
    /// It draws a material (a visual effect view, or a window that isn't opaque): drawn flat here.
    public var material: Bool?
    public var sheet: Bool?
    public init(name: String, kind: String, rect: [Int], clipped: Bool? = nil, material: Bool? = nil, sheet: Bool? = nil) {
      self.name = name; self.kind = kind; self.rect = rect; self.clipped = clipped; self.material = material; self.sheet = sheet
    }
  }

  public init(size: [Int], scale: Double, appearance: String?, textSize: String? = nil, regions: [Region] = []) {
    self.size = size; self.scale = scale; self.appearance = appearance; self.textSize = textSize; self.regions = regions
  }

  /// The look key it was taken in (`Looks.key`): nil for light at the default text size.
  public var key: String? { Looks.key(appearance: appearance, textSize: textSize) }
}

public enum Looks {
  /// The region of everything outside the named ones (all of the window when none is named).
  public static let rest = "rest"
  public static let window = "window"
  /// What `--set appearance=` takes; light is the default (snapshots compare across machines whatever their setting).
  public static let appearances = ["light", "dark", "system"]
  public static let parameter = "appearance"
  public static let textSizeParameter = "textSize"

  /// `X.png` → `X.layout.json`, the sidecar.
  public static func layoutPath(_ png: String) -> String { (png.hasSuffix(".png") ? String(png.dropLast(4)) : png) + ".layout.json" }
  /// `X.png` → `X.later.png`, the picture half a second later.
  public static func laterPath(_ png: String) -> String { (png.hasSuffix(".png") ? String(png.dropLast(4)) : png) + ".later.png" }

  /// The appearance and text size a run asks for, as one key for file and folder names: nil for light at the default
  /// text size (what every run before v11 was), else `dark`, `light-text-xLarge`, `dark-text-xLarge`.
  public static func key(appearance: String?, textSize: String?) -> String? {
    let a = appearance ?? "light"
    if a == "light" && (textSize ?? "").isEmpty { return nil }
    return a + ((textSize ?? "").isEmpty ? "" : "-text-\(textSize!)")
  }
  public static func key(_ params: [String: String]?) -> String? { key(appearance: params?[parameter], textSize: params?[textSizeParameter]) }

  /// `--expect-look a,b --expect-look c` → [a, b, c], trimmed, in order, once each.
  public static func names(_ values: [String]) -> [String] {
    var out: [String] = []
    for v in values { for n in v.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !n.isEmpty && !out.contains(n) { out.append(n) } }
    return out
  }

  /// A name a region's pictures can carry in a file name.
  public static func fileName(_ s: String) -> String {
    String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
  }

  /// The snapshot-diff guard judged on its regions: a change in a region the agent declared is `expected` (passes:
  /// the PR's reviewer accepts it by looking at its pictures), any other change asks the owner (`review`). A guard
  /// without regions (an adapter from before v5, or two pictures that can't be compared) keeps its own verdict.
  public static func judge(_ g: GuardResult, expected: [String]) -> GuardResult {
    guard var looks = g.looks, !looks.isEmpty else { return g }
    let declared = Set(expected)
    for i in looks.indices { looks[i].expected = looks[i].changed && declared.contains(looks[i].name) ? true : nil }
    var r = g
    r.looks = looks
    let unexpected = looks.filter { $0.changed && $0.expected != true }
    r.pass = unexpected.isEmpty
    r.review = r.pass ? nil : true
    let changed = looks.filter(\.changed)
    var parts: [String] = []
    if changed.isEmpty { parts.append("the same in every region (\(looks.map(\.name).joined(separator: ", ")))") }
    else {
      parts.append(changed.map(\.line).joined(separator: " · "))
      let same = looks.filter { !$0.changed }.map(\.name)
      if !same.isEmpty { parts.append("same: " + same.joined(separator: ", ")) }
    }
    let unknown = expected.filter { n in !looks.contains { $0.name == n } }
    if !unknown.isEmpty { parts.append("declared \(unknown.joined(separator: ", ")) but no region has that name (regions: \(looks.map(\.name).joined(separator: ", ")))") }
    let unchangedDeclared = expected.filter { n in looks.contains { $0.name == n && !$0.changed } }
    if !unchangedDeclared.isEmpty { parts.append("declared \(unchangedDeclared.joined(separator: ", ")) but it looks the same") }
    if let v = g.value { parts.append("whole window \(Stats.round(v * 100, 2)) % of the pixels differ" + (g.limit.map { ", tolerance \(Stats.round($0 * 100, 2)) % per region" } ?? "")) }
    if !changed.isEmpty, unexpected.isEmpty { parts.append("only where declared: the PR's reviewer accepts it by looking at the pictures") }
    r.detail = parts.joined(separator: "; ")
    return r
  }

  /// Lines for a snapshot-diff guard's changed regions, each with what to look at: what an agent and a reviewer read.
  public static func lines(_ g: GuardResult, indent: String = "    ") -> [String] {
    (g.looks ?? []).filter(\.changed).map { l in
      let who = l.expected == true ? "declared by the agent: the PR's reviewer accepts it" : "not declared: the owner reviews it"
      return "\(indent)look \(l.line) · \(who)" + (l.pictures.isEmpty ? "" : " · look at (snapshot \(l.name)): " + l.pictures.joined(separator: " "))
    }
  }

  /// The pairs' declared look changes (`expected` regions on the candidate's snapshot-diff), one line each.
  public static func declared(_ pairs: [Pair]) -> [String] {
    pairs.filter { $0.failure == nil }.flatMap { p in
      (p.b.guards ?? []).filter { $0.name == GuardNames.snapshotDiff }.flatMap { g in
        (g.looks ?? []).filter { $0.expected == true }.map { "\(g.name) in pair \(p.index + 1): \($0.line)" }
      }
    }
  }
}
