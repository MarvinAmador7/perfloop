#if os(macOS)
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PerfLoopKit

/// The `snapshot-diff` guard (CAPABILITIES.md C6): the window as a PNG after the rep settles, and a second one half a
/// second later (`.later.png`) so what moves by itself (a caret, a spinner) is left out of the comparison. The runner
/// hands the champion's and the candidate's pictures to the champion's `snapdiff`, so a candidate can't judge itself.
///
/// The picture is the content view drawn by itself (no screen-recording permission), with the window's visible child
/// windows (palettes, popovers, sheets, panels) drawn in where they are on screen (v7). Beside it, `X.layout.json`
/// (`perfloop.snapshot/1`) says where the scenario's named regions and the child windows are, and in which appearance it
/// was drawn, so `snapdiff` compares region by region (v5). What this can't show: the title bar, and materials
/// (vibrancy, blur), which draw flat; ScreenCaptureKit can (v8, opt-in).
public enum Snapshot {
  /// The window's content (and its child windows) drawn into a bitmap over the window's background colour, which
  /// `cacheDisplay` leaves out (text would be drawn on transparency).
  @MainActor public static func png(of window: NSWindow) -> Data? { capture(window)?.png }

  /// A picture and its layout.
  public struct Capture {
    public var png: Data
    public var layout: SnapshotLayout
  }

  /// The window as `png(of:)` draws it, with its named regions located and its child windows drawn in. `children` nil:
  /// the window's visible child windows and sheets, at any depth (a test passes its own).
  @MainActor public static func capture(_ window: NSWindow, regions: [LookRegion] = [], appearance: String? = nil, textSize: String? = nil,
                                        children: [NSWindow]? = nil) -> Capture? {
    guard let v = window.contentView, let content = image(of: v) else { return nil }
    let w = content.width, h = content.height
    let scale = v.bounds.width > 0 ? Double(w) / Double(v.bounds.width) : window.backingScaleFactor
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(background(window)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(content, in: CGRect(x: 0, y: 0, width: w, height: h))
    // Where the content is on screen: child windows and regions are placed from their screen rects.
    let origin = window.convertToScreen(v.convert(v.bounds, to: nil))
    var layout = SnapshotLayout(size: [w, h], scale: scale, appearance: appearance, textSize: textSize)
    var notCaptured = ["the title bar"]
    var flat = visualEffectViews(in: v)
    var kids: [SnapshotLayout.ChildWindow] = []
    for (i, c) in (children ?? childWindows(of: window)).enumerated() {
      guard let cv = c.contentView, let img = image(of: cv) else { continue }
      let r = pixels(c.convertToScreen(cv.convert(cv.bounds, to: nil)), in: origin, scale: scale, height: h)
      ctx.saveGState()
      ctx.clip(to: r.cg)
      ctx.setFillColor(background(c)); ctx.fill(r.cg)
      ctx.draw(img, in: r.cg)
      ctx.restoreGState()
      let effects = visualEffectViews(in: cv)
      flat += effects
      let name = [c.identifier?.rawValue, c.title].compactMap { $0 }.first { !$0.isEmpty } ?? "\(String(describing: type(of: c)))-\(i + 1)"
      kids.append(SnapshotLayout.ChildWindow(name: name, kind: String(describing: type(of: c)), rect: r.topLeft, clipped: r.clipped ? true : nil,
                                             material: !c.isOpaque || effects > 0 ? true : nil, sheet: c.sheetParent != nil ? true : nil))
    }
    if flat > 0 { notCaptured.append("materials: \(flat) visual-effect view(s) drawn flat (no vibrancy or blur)") }
    if kids.contains(where: { $0.material == true }) { notCaptured.append("child windows' materials and shapes: drawn as their content over the window background colour") }
    if kids.contains(where: { $0.clipped == true }) { notCaptured.append("child windows outside the bench window's content are cut off at its edge") }
    if !kids.isEmpty { notCaptured[0] = "the title bars (the window's and its child windows')" }
    layout.childWindows = kids.isEmpty ? nil : kids
    layout.notCaptured = notCaptured
    // Named regions, then each child window as one (unless a named region has its name).
    var missing: [String] = []
    for region in regions {
      guard let (rect, source) = region.locate(window), let r = Optional(pixels(rect, in: origin, scale: scale, height: h)), let inside = r.inside(w, h) else {
        missing.append(region.name); continue
      }
      layout.regions.append(SnapshotLayout.Region(name: region.name, rect: inside, source: source))
    }
    for k in kids where !layout.regions.contains(where: { $0.name == k.name }) {
      let r = PixelRect(x: k.rect[0], y: k.rect[1], w: k.rect[2], h: k.rect[3], height: h)
      if let inside = r.inside(w, h) { layout.regions.append(SnapshotLayout.Region(name: k.name, rect: inside, source: "child window")) }
    }
    layout.missing = missing.isEmpty ? nil : missing
    guard let img = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return nil }
    return Capture(png: png, layout: layout)
  }

  /// Writes a capture to `X.png` and its layout to `X.layout.json`; false when either couldn't be written.
  public static func write(_ c: Capture, to png: URL) -> Bool {
    guard (try? c.png.write(to: png)) != nil else { return false }
    return (try? PLJSON.encode(c.layout).write(toFile: Looks.layoutPath(png.path), atomically: true, encoding: .utf8)) != nil
  }

  /// A view drawn by itself into a bitmap of its backing scale.
  @MainActor static func image(of v: NSView) -> CGImage? {
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
    v.cacheDisplay(in: v.bounds, to: rep)
    return rep.cgImage
  }

  /// A window's background colour as it draws in its own appearance: what shows behind its content. A window that
  /// isn't opaque (a popover, a panel over a material) gets the window background colour, a flat stand-in for its material.
  @MainActor static func background(_ w: NSWindow) -> CGColor {
    var bg = NSColor.windowBackgroundColor.cgColor
    w.effectiveAppearance.performAsCurrentDrawingAppearance {
      let c = w.backgroundColor ?? .windowBackgroundColor
      bg = (w.isOpaque && c.alphaComponent > 0 ? c : .windowBackgroundColor).cgColor
    }
    return bg
  }

  /// The window's visible child windows and sheets, at any depth, in the order they were added.
  @MainActor public static func childWindows(of w: NSWindow, visibleOnly: Bool = true) -> [NSWindow] {
    var out: [NSWindow] = [], seen: Set<ObjectIdentifier> = [ObjectIdentifier(w)]
    func walk(_ x: NSWindow) {
      for c in (x.childWindows ?? []) + x.sheets where !seen.contains(ObjectIdentifier(c)) {
        seen.insert(ObjectIdentifier(c))
        if !visibleOnly || c.isVisible { out.append(c) }
        walk(c)
      }
    }
    walk(w)
    return out
  }

  @MainActor static func visualEffectViews(in v: NSView) -> Int {
    (v is NSVisualEffectView ? 1 : 0) + v.subviews.reduce(0) { $0 + visualEffectViews(in: $1) }
  }

  /// A screen rect in the picture's pixels: `cg` for drawing (bottom-left origin), `topLeft` for the layout.
  struct PixelRect {
    var x: Int, y: Int, w: Int, h: Int
    /// The picture's height, to flip y.
    var height: Int
    var topLeft: [Int] { [x, y, w, h] }
    var cg: CGRect { CGRect(x: x, y: height - y - h, width: w, height: h) }
    var clipped: Bool { x < 0 || y < 0 || x + w > widthLimit || y + h > height }
    var widthLimit = Int.max
    /// The part inside a w×h picture, or nil when none is.
    func inside(_ pw: Int, _ ph: Int) -> [Int]? {
      let x0 = max(0, x), y0 = max(0, y), x1 = min(pw, x + w), y1 = min(ph, y + h)
      return x1 > x0 && y1 > y0 ? [x0, y0, x1 - x0, y1 - y0] : nil
    }
  }

  static func pixels(_ r: CGRect, in origin: CGRect, scale: Double, height: Int) -> PixelRect {
    let x = Int(((r.minX - origin.minX) * scale).rounded()), y = Int(((origin.maxY - r.maxY) * scale).rounded())
    var p = PixelRect(x: x, y: y, w: Int((r.width * scale).rounded()), h: Int((r.height * scale).rounded()), height: height)
    p.widthLimit = Int((origin.width * scale).rounded())
    return p
  }

  /// RGBA8 pixels of a PNG (or any image ImageIO reads), drawn at its own size.
  public struct Pixels: Equatable {
    public var width: Int, height: Int
    public var bytes: [UInt8]
    public init(width: Int, height: Int, bytes: [UInt8]) { self.width = width; self.height = height; self.bytes = bytes }
    public init?(path: String) {
      guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
      self.init(image: img)
    }
    public init?(image img: CGImage) {
      let w = img.width, h = img.height
      var buf = [UInt8](repeating: 0, count: w * h * 4)
      let ok = buf.withUnsafeMutableBytes { p -> Bool in
        guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
      }
      guard ok else { return nil }
      width = w; height = h; bytes = buf
    }
    /// Whether pixel `i` differs from the same pixel of `o` by more than `threshold` in any channel.
    func differs(_ o: Pixels, _ i: Int, threshold: Int) -> Bool {
      let k = i * 4
      for c in 0..<4 where abs(Int(bytes[k + c]) - Int(o.bytes[k + c])) > threshold { return true }
      return false
    }
    public func png() -> Data? {
      var b = bytes
      return b.withUnsafeMutableBytes { p -> Data? in
        guard let ctx = CGContext(data: p.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let img = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, nil)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
      }
    }
  }

  public struct Comparison: Equatable {
    /// Share of the compared pixels that differ.
    public var share: Double
    public var differing: Int
    public var compared: Int
    /// Pixels left out because they changed by themselves in either side's `.later` picture.
    public var moving: Int
    public var sizeMismatch: Bool
    public var diff: Pixels?
  }

  /// A against B, outside the pixels that moved by themselves (A vs A.later, B vs B.later). A size mismatch is a
  /// full difference (share 1).
  public static func compare(_ a: Pixels, _ b: Pixels, aLater: Pixels? = nil, bLater: Pixels? = nil, threshold: Int = 16, diffPicture: Bool = true) -> Comparison {
    guard a.width == b.width, a.height == b.height else { return Comparison(share: 1, differing: 1, compared: 1, moving: 0, sizeMismatch: true, diff: nil) }
    let n = a.width * a.height
    var differing = 0, moving = 0
    var d = diffPicture ? Pixels(width: a.width, height: a.height, bytes: a.bytes.enumerated().map { $0.offset % 4 == 3 ? 255 : $0.element / 3 }) : nil
    let al = aLater.flatMap { $0.width == a.width && $0.height == a.height ? $0 : nil }, bl = bLater.flatMap { $0.width == b.width && $0.height == b.height ? $0 : nil }
    for i in 0..<n {
      if let x = al, a.differs(x, i, threshold: threshold) { moving += 1; continue }
      if let x = bl, b.differs(x, i, threshold: threshold) { moving += 1; continue }
      if a.differs(b, i, threshold: threshold) {
        differing += 1
        if d != nil { d!.bytes[i * 4] = 255; d!.bytes[i * 4 + 1] = 0; d!.bytes[i * 4 + 2] = 0 }
      }
    }
    let compared = n - moving
    return Comparison(share: compared > 0 ? Double(differing) / Double(compared) : 0, differing: differing, compared: compared, moving: moving, sizeMismatch: false, diff: d)
  }

  /// `snapdiff A.png B.png`: the guard record the runner reads (`{ "guard": … }`) and the exit code (0 when nothing
  /// changed outside the `expected` regions, 3 when something did: the owner reviews). Region by region when the
  /// pictures have layouts (`X.layout.json`), else the whole window as one region; two pictures drawn in different
  /// looks (appearance, text size) are not compared at all.
  public static func snapdiff(a: String, b: String, tolerance: Double, threshold: Int = 16, diffOut: String?, expected: [String] = [], maxMovePt: Double = 120) -> (GuardResult, Int32) {
    guard let pa = Pixels(path: a) else { return (GuardResult(name: "snapshot-diff", pass: false, detail: "can't read \(a)", artifacts: [a, b], review: true), 2) }
    guard let pb = Pixels(path: b) else { return (GuardResult(name: "snapshot-diff", pass: false, detail: "can't read \(b)", artifacts: [a, b], review: true), 2) }
    let la = try? PLJSON.read(SnapshotLayout.self, path: Looks.layoutPath(a)), lb = try? PLJSON.read(SnapshotLayout.self, path: Looks.layoutPath(b))
    if la?.key != lb?.key {
      return (GuardResult(name: "snapshot-diff", pass: false, detail: "not comparable: the champion's picture was drawn in \(la?.key ?? "light") and the candidate's in \(lb?.key ?? "light") "
                          + "(appearance or text size; a bench without v11 draws light only): run both in the same look", artifacts: [a, b], review: true), 3)
    }
    let aLater = Pixels(path: Looks.laterPath(a)), bLater = Pixels(path: Looks.laterPath(b))
    let c = compare(pa, pb, aLater: aLater, bLater: bLater, threshold: threshold, diffPicture: diffOut != nil)
    var artifacts = [a, b]
    if let o = diffOut, let d = c.diff?.png() { try? d.write(to: URL(fileURLWithPath: o)); artifacts.append(o) }
    let base = diffOut.map { $0.hasSuffix(".png") ? String($0.dropLast(4)) : $0 }
    let looks = regionLooks(a: pa, b: pb, aLater: aLater, bLater: bLater, la: la, lb: lb, threshold: threshold, tolerance: tolerance, maxMovePt: maxMovePt,
                            pictures: base, whole: (a, b, artifacts.count > 2 ? artifacts[2] : nil))
    let raw = GuardResult(name: "snapshot-diff", pass: c.share <= tolerance, detail: "", artifacts: artifacts, value: Stats.round(c.share, 5), limit: tolerance, looks: looks)
    let g = Looks.judge(raw, expected: expected)
    return (g, g.pass ? 0 : 3)
  }
}
#endif
