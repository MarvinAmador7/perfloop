#if os(macOS)
import XCTest
import AppKit
@testable import PerfLoopHost
import PerfLoopKit

/// Looks (v5, v7, v11) without a window on screen: region-by-region snapshot diffs with the alignment search, the
/// declared regions, child windows drawn into a capture of offscreen windows, regions located by identifier, and the
/// appearance and text-size parameters.
@MainActor final class LooksHostTests: XCTestCase {
  var dir: URL!
  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("perfloop-looks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

  /// A 160×120 "window": a grey background, a list of dark stripes (rows) offset by `rowsDx`, `rowsDy`, and a footer
  /// bar with `footer` drawn as a block of that width.
  func window(rowsDx: Int = 0, rowsDy: Int = 0, footer: Int = 30, sidebar: Int = 0) -> Snapshot.Pixels {
    let w = 160, h = 120
    var b = [UInt8](repeating: 255, count: w * h * 4)
    func set(_ x: Int, _ y: Int, _ v: UInt8) { guard x >= 0, y >= 0, x < w, y < h else { return }; let k = (y * w + x) * 4; b[k] = v; b[k + 1] = v; b[k + 2] = v }
    for y in 0..<h { for x in 0..<w { set(x, y, 230) } }
    for x in 0..<sidebar { for y in 0..<100 { set(x, y, 180) } }
    // Rows: a varied pattern, so a shift is unambiguous.
    for r in 0..<6 { for y in 0..<6 { for x in 0..<(40 + r * 13) { set(sidebar + 10 + x + rowsDx, 10 + r * 14 + y + rowsDy, UInt8(40 + r * 20)) } } }
    for y in 100..<120 { for x in 0..<w { set(x, y, 200) } }
    for y in 106..<114 { for x in 6..<(6 + footer) { set(x, y, 20) } }
    return Snapshot.Pixels(width: w, height: h, bytes: b)
  }

  func layout(list: [Int] = [0, 0, 150, 100], appearance: String? = "light") -> SnapshotLayout {
    SnapshotLayout(size: [160, 120], scale: 1, appearance: appearance, regions: [.init(name: "list", rect: list, source: "rect"), .init(name: "footer", rect: [0, 100, 160, 20], source: "identifier")])
  }

  func look(_ ls: [RegionLook], _ n: String) -> RegionLook? { ls.first { $0.name == n } }

  func testSameMovedAndDiffersPerRegion() {
    let a = window()
    let same = Snapshot.regionLooks(a: a, b: a, la: layout(), lb: layout(), tolerance: 0.005)
    XCTAssertEqual(same.map(\.name), ["list", "footer", "rest"])
    XCTAssertTrue(same.allSatisfy { $0.look == "same" }, "\(same)")
    // The rows shifted 7 right and 3 down inside the list: moved, not differs; the footer changed: differs.
    let b = window(rowsDx: 7, rowsDy: 3, footer: 60)
    let ls = Snapshot.regionLooks(a: a, b: b, la: layout(), lb: layout(), tolerance: 0.005, maxMovePt: 20)
    XCTAssertEqual(look(ls, "list")?.look, "moved", "\(ls)"); XCTAssertEqual(look(ls, "list")?.movedPt, [7, 3])
    XCTAssertGreaterThan(look(ls, "list")?.share ?? 0, 0.005, "where it was, it differs")
    XCTAssertEqual(look(ls, "footer")?.look, "differs"); XCTAssertEqual(look(ls, "rest")?.look, "same")
    // No alignment search: a shift is a difference.
    XCTAssertEqual(look(Snapshot.regionLooks(a: a, b: b, la: layout(), lb: layout(), tolerance: 0.005, maxMovePt: 0), "list")?.look, "differs")
  }

  /// A sidebar takes 30 pt: the list's own rect moved, its pixels didn't change: moved by the rect's shift.
  func testARegionThatMovedWithItsRect() {
    let a = window(), b = window(sidebar: 30)
    let ls = Snapshot.regionLooks(a: a, b: b, la: layout(list: [0, 0, 130, 100]), lb: layout(list: [30, 0, 130, 100]), tolerance: 0.005)
    XCTAssertEqual(look(ls, "list")?.look, "moved", "\(ls)"); XCTAssertEqual(look(ls, "list")?.movedPt, [30, 0])
    XCTAssertEqual(look(ls, "rest")?.look, "differs", "the sidebar itself is outside every named region")
  }

  func testMissingResizedAndNoLayout() {
    let a = window()
    var lb = layout(); lb.regions.removeAll { $0.name == "footer" }; lb.missing = ["footer"]
    let ls = Snapshot.regionLooks(a: a, b: a, la: layout(), lb: lb, tolerance: 0.005)
    XCTAssertEqual(look(ls, "footer")?.look, "missing"); XCTAssertEqual(look(ls, "footer")?.detail, "only in the champion's picture")
    let r = Snapshot.regionLooks(a: a, b: a, la: layout(list: [0, 0, 100, 100]), lb: layout(list: [0, 0, 120, 100]), tolerance: 0.005)
    XCTAssertEqual(look(r, "list")?.look, "resized"); XCTAssertEqual(look(r, "list")?.detail, "100×100 → 120×100 pt")
    XCTAssertEqual(look(r, "rest")?.look, "same", "what a region that stayed put grew into is the region's, not the rest's")
    // Without layouts the whole window is one region.
    let w = Snapshot.regionLooks(a: a, b: window(footer: 70), la: nil, lb: nil, tolerance: 0.005)
    XCTAssertEqual(w.map(\.name), ["window"]); XCTAssertEqual(w.first?.look, "differs")
  }

  func testAlignmentFindsAShiftOnABiggerPicture() {
    // 600×400 with texture everywhere: a 37,−21 px shift is found through the coarse-to-fine search.
    func pic(_ dx: Int, _ dy: Int) -> Snapshot.Pixels {
      var b = [UInt8](repeating: 255, count: 600 * 400 * 4)
      // Blocks of pseudo-random grey (never periodic), as text and icons are to the search.
      func v(_ x: Int, _ y: Int) -> UInt8 { var h = UInt32(truncatingIfNeeded: (x >> 3) &* 73_856_093 ^ (y >> 3) &* 19_349_663); h ^= h >> 13; h = h &* 0x5bd1e995; return UInt8(truncatingIfNeeded: h >> 7) }
      for y in 0..<400 { for x in 0..<600 { let g = v(x - dx + 1000, y - dy + 1000); let k = (y * 600 + x) * 4; b[k] = g; b[k + 1] = g; b[k + 2] = g } }
      return Snapshot.Pixels(width: 600, height: 400, bytes: b)
    }
    let m = Snapshot.align(pic(0, 0), nil, pic(37, -21), nil, maxShift: 64, threshold: 16)
    XCTAssertEqual(m?.dx, 37); XCTAssertEqual(m?.dy, -21); XCTAssertEqual(m?.share ?? 1, 0, accuracy: 0.001)
  }

  /// `snapdiff` on files with layouts: per-region pictures written and named, declared regions pass, the rest reviews,
  /// two looks never compare.
  func testSnapdiffWithLayoutsAndDeclaredRegions() throws {
    func save(_ p: Snapshot.Pixels, _ l: SnapshotLayout, _ name: String) throws -> String {
      let path = dir.appendingPathComponent("\(name).png").path
      try XCTUnwrap(p.png()).write(to: URL(fileURLWithPath: path))
      try PLJSON.encode(l).write(toFile: Looks.layoutPath(path), atomically: true, encoding: .utf8)
      return path
    }
    let a = try save(window(), layout(), "a"), b = try save(window(footer: 60), layout(), "b")
    let diff = dir.appendingPathComponent("diff.png").path
    let (g, code) = Snapshot.snapdiff(a: a, b: b, tolerance: 0.005, diffOut: diff)
    XCTAssertEqual(code, 3); XCTAssertEqual(g.review, true)
    let footer = try XCTUnwrap(g.looks?.first { $0.name == "footer" })
    XCTAssertEqual(footer.look, "differs"); XCTAssertNil(footer.expected)
    for p in footer.pictures { XCTAssertTrue(FileManager.default.fileExists(atPath: p), p) }
    XCTAssertEqual(footer.before, dir.appendingPathComponent("diff-footer.before.png").path)
    XCTAssertEqual(g.looks?.first { $0.name == "list" }?.look, "same")
    XCTAssertTrue(g.detail.contains("footer differs"), g.detail)

    let (ok, okCode) = Snapshot.snapdiff(a: a, b: b, tolerance: 0.005, diffOut: diff, expected: ["footer"])
    XCTAssertEqual(okCode, 0); XCTAssertTrue(ok.pass); XCTAssertNil(ok.review)
    XCTAssertEqual(ok.looks?.first { $0.name == "footer" }?.expected, true)
    XCTAssertTrue(ok.detail.contains("only where declared"), ok.detail)
    // The bench's verb: --expect-look, and the look-at lines.
    let text = Bench(app: "t", stamp: nil).handle(["snapdiff", a, b, "--diff-out", diff, "--expect-look", "footer"])
    XCTAssertEqual(text.0, 0); XCTAssertTrue(text.1.contains("look footer differs"), text.1); XCTAssertTrue(text.1.contains("look at (snapshot footer): "), text.1)
    // Declaring a region that isn't there is said, and changes nothing.
    XCTAssertTrue(Snapshot.snapdiff(a: a, b: b, tolerance: 0.005, diffOut: nil, expected: ["footr"]).0.detail.contains("declared footr but no region has that name"))

    // Light against dark: not compared.
    let d = try save(window(), layout(appearance: "dark"), "d")
    let (x, xCode) = Snapshot.snapdiff(a: a, b: d, tolerance: 0.005, diffOut: nil)
    XCTAssertEqual(xCode, 3); XCTAssertNil(x.looks); XCTAssertTrue(x.detail.contains("not comparable"), x.detail)
    XCTAssertEqual(Snapshot.snapdiff(a: d, b: d, tolerance: 0.005, diffOut: nil).1, 0, "dark against dark compares")
  }

  // MARK: capture: child windows and regions (offscreen windows, never shown)

  final class Fill: NSView {
    let color: NSColor
    init(_ c: NSColor, _ f: NSRect) { color = c; super.init(frame: f) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) { color.setFill(); bounds.fill() }
  }

  func pixel(_ png: Data, _ x: Int, _ y: Int) -> [UInt8] {
    let img = NSBitmapImageRep(data: png)!.cgImage!
    let p = Snapshot.Pixels(image: img)!
    let k = (y * p.width + x) * 4
    return Array(p.bytes[k..<k + 3])
  }

  func testAChildWindowIsDrawnInAndNamedAsARegion() throws {
    let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false; defer { w.close() }
    let content = Fill(.white, NSRect(x: 0, y: 0, width: 200, height: 100))
    let footer = Fill(.blue, NSRect(x: 0, y: 0, width: 200, height: 20)); footer.identifier = NSUserInterfaceItemIdentifier("footer")
    content.addSubview(footer)
    w.contentView = content
    // A 50×30 panel 20 pt from the left and 10 pt from the top of the window's content.
    let panel = NSPanel(contentRect: NSRect(x: -10000 + 20, y: -10000 + 100 - 10 - 30, width: 50, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false; defer { panel.close() }
    panel.contentView = Fill(.red, NSRect(x: 0, y: 0, width: 50, height: 30)); panel.identifier = NSUserInterfaceItemIdentifier("details")
    let c = try XCTUnwrap(Snapshot.capture(w, regions: [.identifier("footer"), .identifier("nothing-has-this", name: "gone"), .rect("corner", CGRect(x: 0, y: 0, width: 10, height: 10)), .view("bar", footer)],
                                           appearance: "dark", children: [panel]))
    let s = Int(c.layout.scale)
    XCTAssertEqual(c.layout.size, [200 * s, 100 * s]); XCTAssertEqual(c.layout.appearance, "dark"); XCTAssertEqual(c.layout.key, "dark")
    let kid = try XCTUnwrap(c.layout.childWindows?.first)
    XCTAssertEqual(kid.name, "details"); XCTAssertEqual(kid.rect, [20 * s, 10 * s, 50 * s, 30 * s]); XCTAssertNil(kid.clipped)
    XCTAssertEqual(c.layout.regions.map(\.name), ["footer", "corner", "bar", "details"])
    XCTAssertEqual(c.layout.regions.first { $0.name == "bar" }?.rect, [0, 80 * s, 200 * s, 20 * s])
    XCTAssertEqual(c.layout.regions.first { $0.name == "corner" }?.rect, [0, 0, 10 * s, 10 * s])
    XCTAssertEqual(c.layout.regions.first { $0.name == "footer" }?.rect, [0, 80 * s, 200 * s, 20 * s])
    XCTAssertEqual(c.layout.regions.first { $0.name == "details" }?.source, "child window")
    XCTAssertEqual(c.layout.missing, ["gone"])
    XCTAssertTrue(c.layout.notCaptured?.first?.hasPrefix("the title bars") == true, "\(c.layout.notCaptured ?? [])")
    // The picture: the panel's red where it is on screen, the window's white beside it, the footer blue.
    XCTAssertEqual(pixel(c.png, 30 * s, 20 * s), [255, 0, 0])
    XCTAssertEqual(pixel(c.png, 100 * s, 50 * s), [255, 255, 255])
    XCTAssertEqual(pixel(c.png, 100 * s, 90 * s).prefix(2), [0, 0])
    // Half outside the window: cut off, and said.
    panel.setFrameOrigin(NSPoint(x: -10000 + 180, y: -10000 + 60))
    let cut = try XCTUnwrap(Snapshot.capture(w, children: [panel]))
    XCTAssertEqual(cut.layout.childWindows?.first?.clipped, true)
    XCTAssertTrue(cut.layout.notCaptured?.contains { $0.contains("cut off") } == true)
    // Written with its layout beside it.
    let png = dir.appendingPathComponent("x.settled.png")
    XCTAssertTrue(Snapshot.write(c, to: png))
    XCTAssertEqual(try PLJSON.read(SnapshotLayout.self, path: Looks.layoutPath(png.path)).childWindows?.first?.name, "details")
  }

  func testChildWindowsAreFoundAtAnyDepth() {
    let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
    let p1 = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 20, height: 20), styleMask: [.borderless], backing: .buffered, defer: false)
    let p2 = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 20, height: 20), styleMask: [.borderless], backing: .buffered, defer: false)
    for x in [w, p1, p2] { x.isReleasedWhenClosed = false }
    defer { p2.close(); p1.close(); w.close() }
    w.addChildWindow(p1, ordered: .above); p1.addChildWindow(p2, ordered: .above)
    XCTAssertEqual(Snapshot.childWindows(of: w, visibleOnly: false).map(ObjectIdentifier.init), [ObjectIdentifier(p1), ObjectIdentifier(p2)])
  }

  /// One region model: the bench's regions, the scenario's, and those its steps name for the ink guard, once per name.
  func testRegionsAreTheInkGuardsAndNamedOnce() {
    let run = Run(scenario: "s", fixture: Fixture("f"), params: [:], rep: 0, recorder: Recorder(nominalHz: 60), activate: false, sampler: nil)
    run.regions = [.identifier("status")]
    run.regions([.rect("filter", CGRect(x: 0, y: 0, width: 10, height: 10)), .rect("status", CGRect(x: 0, y: 0, width: 5, height: 5))])
    XCTAssertEqual(run.regions.map(\.name), ["status", "filter"])
    if case .rect = run.regions[0].place {} else { XCTFail("a scenario's region replaces the bench's of the same name") }
  }

  // MARK: appearance and text size (v11)

  func testAppearanceAndTextSizeParameters() throws {
    let b = Bench(app: "t", stamp: nil)
    XCTAssertEqual(try b.look([:]).appearance, "light")
    XCTAssertEqual(try b.look(["appearance": "dark"]).name, .darkAqua)
    XCTAssertNil(try b.look(["appearance": "system"]).name)
    XCTAssertThrowsError(try b.look(["appearance": "sepia"]))
    XCTAssertThrowsError(try b.look(["textSize": "xLarge"]), "a bench that applies no text size refuses it")
    b.textSizes = ["large", "xLarge"]
    XCTAssertEqual(try b.look(["textSize": "xLarge", "appearance": "dark"]).textSize, "xLarge")
    XCTAssertThrowsError(try b.look(["textSize": "huge"]))
    let m = b.manifest()
    XCTAssertEqual(m.appearances, ["light", "dark", "system"]); XCTAssertEqual(m.textSizes, ["large", "xLarge"])
    XCTAssertNil(m.unsupportedLook(["appearance": "dark", "textSize": "large"], whose: "x"))
    XCTAssertNil(Bench(app: "u", stamp: nil).manifest().textSizes)
  }
}
#endif
