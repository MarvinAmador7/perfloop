#if os(macOS)
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PerfLoopKit

/// The `snapshot-diff` guard (CAPABILITIES.md C6): the window as a PNG after the rep settles, and a second one half a
/// second later (`.later.png`) so what moves by itself (a caret, a spinner) is left out of the comparison. The runner
/// hands the champion's and the candidate's pictures to the champion's `snapdiff`, so a candidate can't judge itself.
public enum Snapshot {
  /// The window's content view drawn into a bitmap (no screen-recording permission: the view draws itself), over the
  /// window's background colour, which `cacheDisplay` leaves out (text would be drawn on transparency).
  @MainActor public static func png(of window: NSWindow) -> Data? {
    guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
    v.cacheDisplay(in: v.bounds, to: rep)
    guard let content = rep.cgImage else { return rep.representation(using: .png, properties: [:]) }
    let w = content.width, h = content.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    var bg = NSColor.windowBackgroundColor.cgColor
    window.effectiveAppearance.performAsCurrentDrawingAppearance { bg = (window.backgroundColor ?? .windowBackgroundColor).cgColor }
    ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(content, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let img = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
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

  /// `snapdiff A.png B.png`: the guard record the runner reads (`{ "guard": … }`) and the exit code (0 within
  /// tolerance, 3 over it: the owner reviews).
  public static func snapdiff(a: String, b: String, tolerance: Double, threshold: Int = 16, diffOut: String?) -> (GuardResult, Int32) {
    func later(_ p: String) -> String { p.hasSuffix(".png") ? String(p.dropLast(4)) + ".later.png" : p + ".later" }
    guard let pa = Pixels(path: a) else { return (GuardResult(name: "snapshot-diff", pass: false, detail: "can't read \(a)", artifacts: [a, b], review: true), 2) }
    guard let pb = Pixels(path: b) else { return (GuardResult(name: "snapshot-diff", pass: false, detail: "can't read \(b)", artifacts: [a, b], review: true), 2) }
    let c = compare(pa, pb, aLater: Pixels(path: later(a)), bLater: Pixels(path: later(b)), threshold: threshold, diffPicture: diffOut != nil)
    var artifacts = [a, b]
    if let o = diffOut, let d = c.diff?.png() { try? d.write(to: URL(fileURLWithPath: o)); artifacts.append(o) }
    let pass = c.share <= tolerance
    let pct = Stats.round(c.share * 100, 2)
    let detail = c.sizeMismatch ? "the snapshots differ in size (\(pa.width)×\(pa.height) vs \(pb.width)×\(pb.height))"
      : "\(pct) % of the pixels differ (\(c.differing) of \(c.compared); \(c.moving) moving by themselves left out), tolerance \(Stats.round(tolerance * 100, 2)) %"
    return (GuardResult(name: "snapshot-diff", pass: pass, detail: detail, artifacts: artifacts, value: Stats.round(c.share, 5), limit: tolerance, review: pass ? nil : true), pass ? 0 : 3)
  }
}
#endif
