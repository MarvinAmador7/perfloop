#if os(macOS)
import XCTest
import AppKit
@testable import PerfLoopHost
import PerfLoopKit

/// A rep inside the app (the app's own window adopted), a window opened inside a measured step, and steps whose action
/// is async. Windows are ordered in far off any screen (-10000, -10000) in a process that never activates: nothing
/// shows. A machine whose display link never ticks for such a window skips the tests that need frames.
@MainActor final class AppHostTests: XCTestCase {
  override func setUp() { NSApplication.shared.setActivationPolicy(.prohibited) }

  func appWindow(title: String = "SlowList") -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.title = title
    w.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    w.orderFrontRegardless()
    return w
  }

  func newRun() -> Run { Run(scenario: "menu", fixture: Fixture("f"), params: [:], rep: 0, recorder: Recorder(nominalHz: 60), activate: false, sampler: nil) }

  /// Frames or a skip: `show` and `open` throw this when no frame comes.
  func framed(_ f: () async throws -> Void) async throws {
    do { try await f() } catch let e as HostError where "\(e)".contains("drew no frame") { throw XCTSkip("no display-link frames for an offscreen window here: \(e)") }
  }

  /// The app's window is the rep's: measured on, its appearance set for the rep and given back, and left up and
  /// whole when the rep closes (the app owns it), so a second rep adopts it again.
  func testTheAppsWindowIsAdoptedAndLeftUp() async throws {
    let w = appWindow()
    defer { w.close() }
    let before = w.appearance
    let r = newRun()
    r.appearance = .darkAqua
    try await framed { try await r.show(window: w) }
    XCTAssertTrue(r.window === w)
    XCTAssertEqual(w.appearance?.name, .darkAqua, "the rep's look")
    XCTAssertGreaterThanOrEqual(r.recorder.timeline.ticks.count, 3, "measured on the app's window")
    do { try await r.show(window: w); XCTFail("a second window in one rep") } catch { XCTAssertTrue("\(error)".contains("already has its window"), "\(error)") }
    let content = w.contentView
    r.close()
    XCTAssertNil(r.window)
    XCTAssertTrue(w.isVisible, "the app's window stays up")
    XCTAssertTrue(w.contentView === content, "with its content")
    XCTAssertEqual(w.appearance, before, "and its own appearance")
    let r2 = newRun()
    try await framed { try await r2.show(window: w) }
    XCTAssertTrue(r2.window === w, "the next rep adopts it again")
    r2.close()
  }

  /// `appWindow` finds the app's window (not a panel), or says which windows there were.
  func testAppWindowFindsTheAppsWindowOrNamesTheOnesThereAre() async throws {
    let w = appWindow(title: "Desk")
    defer { w.close() }
    let panel = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 100, height: 100), styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false; panel.title = "Inspector"; panel.orderFrontRegardless()
    defer { panel.close() }
    let found = try await newRun().appWindow(timeoutMs: 200) { $0.title == "Desk" }
    XCTAssertTrue(found === w)
    do {
      _ = try await newRun().appWindow(timeoutMs: 60) { $0.title == "Nope" }
      XCTFail("no such window")
    } catch {
      XCTAssertTrue("\(error)".contains("the app showed no window within 60 ms that matches: it has "), "\(error)")
      XCTAssertTrue("\(error)".contains("'Desk' (NSWindow)"), "\(error)")
    }
  }

  /// `open`: the clock starts before the window exists. The step's span starts before the window was made, the window is
  /// the rep's after it, and the step settled on its frames.
  func testOpenMeasuresTheWindowFromBeforeItExists() async throws {
    let r = newRun()
    defer { r.close() }
    var madeAt: Double?
    var step: StepRecord?
    try await framed {
      step = try await r.open("open#0", size: CGSize(width: 320, height: 200), title: "bench", view: {
        madeAt = r.now
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        return v
      })
    }
    let s = try XCTUnwrap(step)
    let w = try XCTUnwrap(r.window)
    XCTAssertEqual(w.contentView?.frame.size, CGSize(width: 320, height: 200))
    XCTAssertLessThanOrEqual(s.atMs, try XCTUnwrap(madeAt), "the clock started before the view and the window were made")
    XCTAssertEqual(r.steps.map(\.name), ["open#0"])
    XCTAssertTrue(r.recorder.timeline.ticks.contains { $0 > s.atMs }, "frames from the new window")
    XCTAssertNil(s.notes.first { $0.contains("expectFocus") }, "the focus landing in a new window is no surprise")
    do { _ = try await r.open(view: { NSView() }); XCTFail("one window per rep") } catch { XCTAssertTrue("\(error)".contains("in place of run.show"), "\(error)") }
    r.close()
    XCTAssertFalse(w.isVisible, "the bench's own window closes with the rep")
  }

  /// An async action is awaited inside the step: its work over time is the step's, and the step ends after it.
  func testAStepsActionMayBeAsync() async throws {
    let w = appWindow()
    defer { w.close() }
    let r = newRun()
    r.window = w
    r.recorder.start(on: w.contentView!, sampler: nil)
    defer { r.close() }
    var sent = 0
    let s = await r.step("burst 3 items", timeoutMs: 2000) {
      for _ in 0..<3 { await r.sleep(ms: 40); sent += 1 }
    }
    XCTAssertEqual(sent, 3, "awaited: the step ended after the work")
    XCTAssertGreaterThanOrEqual(s.durationMs, 120, "the work's time is inside the step")
    if !r.recorder.timeline.ticks.isEmpty {
      XCTAssertGreaterThanOrEqual(s.latencyMs ?? 0, 120, "latency: to the first frame after the work finished")
    }
    // A synchronous action still runs to its end before anything else does.
    var order: [String] = []
    await r.step("sync") { order.append("action") }
    order.append("after")
    XCTAssertEqual(order, ["action", "after"])
    XCTAssertEqual(r.steps.map(\.name), ["burst 3 items", "sync"])
  }
}
#endif
