#if os(macOS)
import XCTest
import AppKit
@testable import PerfLoopHost
import PerfLoopKit

/// The ink guard (VERIFICATION.md v3) in the host: the pixel arithmetic, regions judged on views drawn in a window that
/// is never shown, the crops it leaves, and the bench's own turns left out of the rep's numbers (F18).
@MainActor final class InkHostTests: XCTestCase {
  func pixels(_ w: Int, _ h: Int, fill: [UInt8], dots: [(Int, Int)] = [], dot: [UInt8] = [0, 0, 0, 255]) -> Snapshot.Pixels {
    var b = [UInt8](repeating: 0, count: w * h * 4)
    for i in 0..<(w * h) { for c in 0..<4 { b[i * 4 + c] = fill[c] } }
    for (x, y) in dots { for c in 0..<4 { b[(y * w + x) * 4 + c] = dot[c] } }
    return Snapshot.Pixels(width: w, height: h, bytes: b)
  }

  func testInkIsTheShareUnlikeTheRegionsOwnBackground() {
    XCTAssertEqual(Ink.share(pixels(10, 10, fill: [255, 255, 255, 255])).share, 0, "blank")
    XCTAssertEqual(Ink.share(pixels(10, 10, fill: [40, 90, 200, 255])).share, 0, "a solid fill of any colour is blank too")
    XCTAssertEqual(Ink.share(pixels(10, 10, fill: [255, 255, 255, 255], dots: [(1, 1), (2, 2), (3, 3)])).share, 0.03, accuracy: 1e-9)
    XCTAssertEqual(Ink.share(pixels(10, 10, fill: [250, 250, 250, 255], dots: [(1, 1)], dot: [245, 245, 245, 255])).share, 0, "noise under the threshold isn't ink")
    XCTAssertEqual(Ink.share(Snapshot.Pixels(width: 0, height: 0, bytes: [])).share, 0)
  }

  /// A window that is never shown (off every screen), with a label and an empty pane: the label's region has ink, the
  /// pane's has none, and every region leaves its crop.
  func testRegionsAreJudgedOnWhatTheViewsDraw() throws {
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let label = NSTextField(labelWithString: "Selected item 7 of 1,000 — Ember, Aspen, Birch")
    label.font = .systemFont(ofSize: 18); label.frame = NSRect(x: 10, y: 250, width: 380, height: 30)
    label.identifier = NSUserInterfaceItemIdentifier("status")
    let pane = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    pane.identifier = NSUserInterfaceItemIdentifier("pane")
    content.addSubview(label); content.addSubview(pane)
    window.contentView = content
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ink-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let status = Ink.judge(.identifier("status"), after: "select#0", window: window, min: Ink.defaultMin, dir: dir, file: "status.png")
    XCTAssertTrue(status.pass, status.detail); XCTAssertGreaterThan(status.ink ?? 0, 0.01)
    XCTAssertEqual(status.rect, [10, 20, 380, 30], "points from the content's top-left")
    let crop = try XCTUnwrap(status.picture)
    XCTAssertTrue(FileManager.default.fileExists(atPath: crop))
    XCTAssertEqual(Snapshot.Pixels(path: crop)?.width, Int(380 * window.backingScaleFactor), "the crop is the region as drawn")

    let blank = Ink.judge(.view("pane", pane), after: "select#0", window: window, min: Ink.defaultMin, dir: dir, file: "pane.png")
    XCTAssertFalse(blank.pass); XCTAssertEqual(blank.ink, 0)
    XCTAssertEqual(blank.detail, "blank: no pixel differs from its background")
    XCTAssertNotNil(blank.picture, "a failing region leaves its crop too")

    // By rect (top-left origin): the label's band has ink.
    XCTAssertTrue(Ink.judge(.rect("top", CGRect(x: 0, y: 0, width: 400, height: 60)), after: "a", window: window, min: Ink.defaultMin, dir: nil, file: "x").pass)
    // What can't be judged fails with the region named and why.
    XCTAssertEqual(Ink.judge(.identifier("nope"), after: "a", window: window, min: 0.005, dir: nil, file: "x").detail,
                   "no view or accessibility element with identifier 'nope' in the window")
    XCTAssertEqual(Ink.judge(.rect("thin", .init(x: 0, y: 0, width: 0, height: 10)), after: "a", window: window, min: 0.005, dir: nil, file: "x").detail, "zero size (0×10 pt)")
    XCTAssertTrue(Ink.judge(.rect("far", .init(x: 900, y: 900, width: 50, height: 50)), after: "a", window: window, min: 0.005, dir: nil, file: "x").detail.hasPrefix("outside the window"))
    label.isHidden = true
    XCTAssertEqual(Ink.judge(.view("status", label), after: "a", window: window, min: 0.005, dir: nil, file: "x").detail, "its view is hidden")
    XCTAssertEqual(Ink.judge(.view("loose", NSView()), after: "a", window: window, min: 0.005, dir: nil, file: "x").detail, "its view isn't in a window")

    // The rep's guard: one record, failing crops first, the lowest share as its value.
    let g = Ink.guardResult([status, blank])
    XCTAssertEqual(g.name, "ink"); XCTAssertFalse(g.pass)
    XCTAssertEqual(g.artifacts.first, blank.picture)
    XCTAssertEqual(g.value, 0); XCTAssertEqual(g.inkRegions?.count, 2)
    XCTAssertTrue(g.detail.hasPrefix("pane after select#0: blank: no pixel differs from its background (look at: "), g.detail)
    XCTAssertTrue(Ink.guardResult([status]).pass)
  }

  /// An overlay over text: in place its rect shows the text behind it (ink); drawn alone it is what it draws itself
  /// (blank here, then a line of its own). A rect has no view to draw alone: drawn in place, and it says so.
  func testAnOverlayDrawnAloneIsJudgedOnItsOwnInk() throws {
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let behind = NSTextField(labelWithString: "Threads under the palette: Ember, Aspen, Birch, Cedar, Dogwood, Elm")
    behind.font = .systemFont(ofSize: 18); behind.frame = NSRect(x: 10, y: 140, width: 380, height: 30)
    let overlay = NSView(frame: NSRect(x: 0, y: 100, width: 400, height: 100))   // draws nothing of its own
    content.addSubview(behind); content.addSubview(overlay)
    window.contentView = content
    let inPlace = Ink.judge(.view("palette", overlay), after: "open", window: window, min: Ink.defaultMin, dir: nil, file: "x")
    XCTAssertTrue(inPlace.pass, "in place, the text behind it counts: \(inPlace.detail)")
    XCTAssertNil(inPlace.alone)
    let alone = Ink.judge(InkRegion.view("palette", overlay).drawnAlone(), after: "open", window: window, min: Ink.defaultMin, dir: nil, file: "x")
    XCTAssertFalse(alone.pass, alone.detail); XCTAssertEqual(alone.ink, 0)
    XCTAssertEqual(alone.detail, "blank: no pixel differs from its background (its view drawn alone)")
    XCTAssertEqual(alone.alone, true)
    XCTAssertEqual(alone.rect, inPlace.rect, "the same place")
    let own = NSTextField(labelWithString: "Search: matchkey — 12 results")
    own.font = .systemFont(ofSize: 18); own.frame = NSRect(x: 10, y: 60, width: 380, height: 30)
    overlay.addSubview(own)
    XCTAssertTrue(Ink.judge(.find("palette", { overlay }).drawnAlone(), after: "typed", window: window, min: Ink.defaultMin, dir: nil, file: "x").pass, "its own line")
    let rect = Ink.judge(InkRegion.rect("band", CGRect(x: 0, y: 100, width: 400, height: 100)).drawnAlone(), after: "a", window: window, min: Ink.defaultMin, dir: nil, file: "x")
    XCTAssertTrue(rect.detail.hasSuffix("(drawn in place: the region has no view of its own to draw alone)"), rect.detail)
  }

  func testCropNamesAreSafe() {
    XCTAssertEqual(Ink.fileName(scenario: "select", rep: 1, after: "filter#2 'em'", region: "rows/list", n: 3), "select-rep1-03-filter_2__em_-rows_list.png")
  }

  /// The bench's own turn between two steps (an ink check) is in no number: not a worst stretch, not a held frame.
  func testOffTheClockTurnsAreLeftOutOfTheRep() {
    var t = Timeline(nominalHz: 120)
    t.ticks = stride(from: 0.0, through: 400, by: 1000 / 120).filter { !($0 > 210 && $0 < 260) }   // the display link waited out the check
    t.stretches = [StretchSample(id: 1, atMs: 99, durationMs: 20, cpuMs: 19),
                   StretchSample(id: 2, atMs: 210, durationMs: 48, cpuMs: 47),     // the ink check, after select#0
                   StretchSample(id: 3, atMs: 300, durationMs: 10, cpuMs: 9)]
    t.offClock = [210.5...257]
    let s1 = t.step(name: "select#0", at: 100, end: 200, latencyMs: nil, settleMs: 19, settled: true, cpuMs: 19, instructions: nil)
    let s2 = t.step(name: "select#1", at: 299, end: 400, latencyMs: nil, settleMs: 10, settled: true, cpuMs: 9, instructions: nil)
    let rep = t.rep(index: 0, steps: [s1, s2], checks: [], guards: nil, window: nil)
    XCTAssertEqual(rep.mainThread.stretches, 2); XCTAssertEqual(rep.mainThread.longestMs, 20)
    XCTAssertFalse(rep.worstStretches.contains { $0.durationMs == 48 })
    XCTAssertEqual(rep.frames.late, 0, "the frame the check held up isn't a hitch of the app's")
    var on = t; on.offClock = []
    XCTAssertEqual(on.rep(index: 0, steps: [s1, s2], checks: [], guards: nil, window: nil).mainThread.longestMs, 48, "without it, the check would be the worst stretch")
  }

  func testTheManifestNamesItsHarnessAndTheBenchItsModule() {
    let b = Bench(app: "testapp", stamp: "commit=abc1234\ndirty=0")
    XCTAssertEqual(b.manifest().harness, "PerfLoopHost")
    XCTAssertEqual(b.benchModules, ["PerfLoopHostTests"], "from where Bench(…) was called")
  }
}
#endif
