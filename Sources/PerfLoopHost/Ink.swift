#if os(macOS)
import AppKit
import PerfLoopKit

/// A region of the window that must show drawn content after a step: the `ink` guard (VERIFICATION.md v3). Name it
/// for the agent reading the result ("sidebar", "rows"), and place it by a view, an identifier, a rect or a closure.
///
///     await run.step("open", ink: [.view("sidebar", sidebar), .identifier("pane"), .rect("header", CGRect(x: 0, y: 0, width: 900, height: 44))]) {
///       model.sidebarOpen = true
///     }
public struct InkRegion {
  public enum Place {
    /// Points from the top-left of the window's content.
    case rect(CGRect)
    case view(NSView)
    /// An `NSView.identifier` in the window or a child window; else an accessibility identifier (SwiftUI's
    /// `.accessibilityIdentifier`), which makes SwiftUI build its accessibility tree once: prefer a view or a rect
    /// where later steps' numbers matter.
    case identifier(String)
    /// A view to resolve when the guard runs (it may not exist before the step).
    case find(@MainActor () -> NSView?)
  }
  public var name: String
  public var place: Place
  /// The least share of the region's pixels that must differ from its background (its most common colour).
  /// nil: the scenario's `ink.min` guard parameter, else `Ink.defaultMin`.
  public var min: Double?
  public init(_ name: String, _ place: Place, min: Double? = nil) { self.name = name; self.place = place; self.min = min }

  public static func rect(_ name: String, _ r: CGRect, min: Double? = nil) -> InkRegion { InkRegion(name, .rect(r), min: min) }
  public static func view(_ name: String, _ v: NSView, min: Double? = nil) -> InkRegion { InkRegion(name, .view(v), min: min) }
  public static func identifier(_ id: String, name: String? = nil, min: Double? = nil) -> InkRegion { InkRegion(name ?? id, .identifier(id), min: min) }
  public static func find(_ name: String, min: Double? = nil, _ f: @escaping @MainActor () -> NSView?) -> InkRegion { InkRegion(name, .find(f), min: min) }
}

/// The ink guard's arithmetic and capture. A region's ink is the share of its pixels that differ from its own
/// background, taken as the most common colour: a blank pane, a solid fill or an all-background region has ~0 % ink
/// whatever its colour; text, icons and rows have a few % or more. The pixels come from the views drawing themselves
/// (`cacheDisplay`, as the snapshots do): proof the view tree draws content there now, not only that a view exists.
public enum Ink {
  /// 0.5 % of the region: a line of text in a large region is about that; a separator or a border alone is less.
  public static let defaultMin = 0.005
  /// A pixel is ink when a channel differs from the background by more than this (of 255).
  public static let threshold = 24

  /// The share of `p`'s pixels that differ from its most common colour (colours bucketed to 4 bits a channel to find
  /// it, so antialiasing noise doesn't split the background), and that colour. 0 for an empty picture.
  public static func share(_ p: Snapshot.Pixels, threshold: Int = threshold) -> (share: Double, background: [UInt8]) {
    let n = p.width * p.height
    guard n > 0 else { return (0, [0, 0, 0, 0]) }
    var buckets: [UInt32: Int] = [:]
    for i in 0..<n {
      let k = i * 4
      let key = UInt32(p.bytes[k] >> 4) << 12 | UInt32(p.bytes[k + 1] >> 4) << 8 | UInt32(p.bytes[k + 2] >> 4) << 4 | UInt32(p.bytes[k + 3] >> 4)
      buckets[key, default: 0] += 1
    }
    let mode = buckets.max { ($0.value, $1.key) < ($1.value, $0.key) }!.key
    // The background: the mean of the pixels in the most common bucket.
    var sum = [Int](repeating: 0, count: 4), cnt = 0
    for i in 0..<n {
      let k = i * 4
      let key = UInt32(p.bytes[k] >> 4) << 12 | UInt32(p.bytes[k + 1] >> 4) << 8 | UInt32(p.bytes[k + 2] >> 4) << 4 | UInt32(p.bytes[k + 3] >> 4)
      if key == mode { for c in 0..<4 { sum[c] += Int(p.bytes[k + c]) }; cnt += 1 }
    }
    let bg = sum.map { UInt8($0 / max(cnt, 1)) }
    var ink = 0
    for i in 0..<n {
      let k = i * 4
      for c in 0..<4 where abs(Int(p.bytes[k + c]) - Int(bg[c])) > threshold { ink += 1; break }
    }
    return (Double(ink) / Double(n), bg)
  }

  /// Where a region is: its window's content view and the rect in it (AppKit's coordinates), or why it can't be judged.
  @MainActor static func resolve(_ r: InkRegion, in window: NSWindow) -> (NSView, NSRect)? {
    guard let content = window.contentView else { return nil }
    func place(_ v: NSView) -> (NSView, NSRect)? {
      guard let w = v.window, let c = w.contentView else { return nil }
      return (c, c.convert(v.bounds, from: v))
    }
    switch r.place {
    case .rect(let x):
      // Top-left origin, as people measure a window.
      let y = content.isFlipped ? x.minY : content.bounds.height - x.maxY
      return (content, NSRect(x: x.minX, y: y, width: x.width, height: x.height))
    case .view(let v): return place(v)
    case .find(let f): return f().flatMap(place)
    case .identifier(let id):
      for w in windows(window) {
        if let c = w.contentView, let v = find(id, in: c) { return place(v) }
      }
      for w in windows(window) {
        guard let c = w.contentView, let f = accessibilityFrame(id, in: c) else { continue }
        let inWindow = w.convertFromScreen(f)
        return (c, c.convert(inWindow, from: nil))
      }
      return nil
    }
  }

  @MainActor static func windows(_ w: NSWindow) -> [NSWindow] { [w] + (w.childWindows ?? []).flatMap(windows) }

  @MainActor static func find(_ id: String, in v: NSView) -> NSView? {
    if v.identifier?.rawValue == id { return v }
    for s in v.subviews { if let f = find(id, in: s) { return f } }
    return nil
  }

  /// The screen frame of the accessibility element with `id` under `root` (SwiftUI's views are elements, not NSViews).
  @MainActor static func accessibilityFrame(_ id: String, in root: NSView) -> NSRect? {
    var budget = 5000
    func walk(_ e: Any, _ depth: Int) -> NSRect? {
      budget -= 1
      guard budget > 0, depth < 64, let el = e as? NSAccessibilityProtocol else { return nil }
      if el.accessibilityIdentifier() == id { return el.accessibilityFrame() }
      for c in el.accessibilityChildren() ?? [] { if let f = walk(c, depth + 1) { return f } }
      return nil
    }
    return walk(root, 0)
  }

  /// `rect` of `content` as its views draw it, over the window's background colour (as the snapshots are).
  @MainActor static func capture(_ content: NSView, _ rect: NSRect) -> Snapshot.Pixels? {
    guard let rep = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
    content.cacheDisplay(in: rect, to: rep)
    guard let img = rep.cgImage, img.width > 0, img.height > 0 else { return nil }
    guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    var bg = NSColor.windowBackgroundColor.cgColor
    if let w = content.window { w.effectiveAppearance.performAsCurrentDrawingAppearance { bg = (w.backgroundColor ?? .windowBackgroundColor).cgColor } }
    ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return ctx.makeImage().flatMap { Snapshot.Pixels(image: $0) }
  }

  /// One region after a step: resolved, clipped to the window, drawn, measured, its crop written to `dir`.
  @MainActor static func judge(_ r: InkRegion, after: String, window: NSWindow, min: Double, dir: URL?, file: String) -> InkRegionResult {
    func fail(_ why: String, rect: [Double]? = nil) -> InkRegionResult {
      InkRegionResult(region: r.name, after: after, pass: false, ink: nil, min: min, rect: rect, detail: why, picture: nil)
    }
    if case .view(let v) = r.place, v.window == nil { return fail("its view isn't in a window") }
    guard let (content, raw) = resolve(r, in: window) else {
      if case .identifier(let id) = r.place { return fail("no view or accessibility element with identifier '\(id)' in the window") }
      return fail("no view to judge (the view wasn't found, or isn't in a window)")
    }
    let topLeft: (NSRect) -> [Double] = { x in
      let y = content.isFlipped ? x.minY : content.bounds.height - x.maxY
      return [x.minX, y, x.width, x.height].map { Stats.round($0, 1) }
    }
    if raw.width < 1 || raw.height < 1 { return fail("zero size (\(Int(raw.width))×\(Int(raw.height)) pt)", rect: topLeft(raw)) }
    let rect = raw.intersection(content.bounds)
    if rect.isNull || rect.width < 1 || rect.height < 1 {
      return fail("outside the window (\(topLeft(raw).map { String(Int($0)) }.joined(separator: ", ")); the content is \(Int(content.bounds.width))×\(Int(content.bounds.height)) pt)", rect: topLeft(raw))
    }
    switch r.place {
    case .view(let v) where v.isHiddenOrHasHiddenAncestor || v.alphaValue == 0: return fail("its view is hidden", rect: topLeft(rect))
    default: break
    }
    guard let px = capture(content, rect) else { return fail("couldn't draw the region", rect: topLeft(rect)) }
    let (share, _) = Ink.share(px)
    var picture: String?
    if let d = dir, let png = px.png() {
      try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
      let u = d.appendingPathComponent(file)
      if (try? png.write(to: u)) != nil { picture = u.path }
    }
    let pct = Stats.round(share * 100, 2), pass = share >= min
    let detail = pass ? "\(pct) % ink" : (share == 0 ? "blank: no pixel differs from its background" : "\(pct) % ink, under \(Stats.round(min * 100, 2)) %: next to blank")
    return InkRegionResult(region: r.name, after: after, pass: pass, ink: Stats.round(share, 5), min: min, rect: topLeft(rect), detail: detail, picture: picture)
  }

  /// The rep's `ink` guard from every region judged in it: pass when all passed. Its artifacts are every crop,
  /// failing ones first; its value the lowest share, against that region's floor.
  public static func guardResult(_ rs: [InkRegionResult]) -> GuardResult {
    let bad = rs.filter { !$0.pass }
    let detail: String
    if bad.isEmpty {
      detail = "\(rs.count) region(s) drawn: " + rs.map { "\($0.region) after \($0.after) \($0.ink.map { "\(Stats.round($0 * 100, 2)) %" } ?? "-")" }.prefix(6).joined(separator: ", ")
    } else {
      detail = bad.map { "\($0.region) after \($0.after): \($0.detail)" }.prefix(4).joined(separator: "; ") + (bad.count > 4 ? "; +\(bad.count - 4) more" : "")
        + (bad.contains { $0.picture != nil } ? " (look at: " + bad.compactMap(\.picture).prefix(3).joined(separator: " ") + ")" : "")
    }
    let lowest = rs.min { ($0.ink ?? -1) < ($1.ink ?? -1) }
    var g = GuardResult(name: GuardNames.ink, pass: bad.isEmpty, detail: detail, artifacts: (bad + rs.filter(\.pass)).compactMap(\.picture),
                        value: lowest?.ink ?? 0, limit: lowest?.min)
    g.inkRegions = rs
    return g
  }

  /// A file name from a region and its step: letters, digits, `-` and `_` only.
  static func fileName(scenario: String, rep: Int, after: String, region: String, n: Int) -> String {
    func safe(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.prefix(40)) }
    return "\(safe(scenario))-rep\(rep)-\(String(format: "%02d", n))-\(safe(after))-\(safe(region)).png"
  }
}
#endif
