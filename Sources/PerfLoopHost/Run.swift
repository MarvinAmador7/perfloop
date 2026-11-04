#if os(macOS)
import AppKit
import SwiftUI
import QuartzCore
import PerfLoopKit
import PerfLoopProbe

/// What a scenario gets: its fixture and parameters, a window to show the app's views in, and `step` to measure one
/// thing the user does. One `Run` per rep; the bench tears its window down after the rep.
///
///     bench.scenario("select", summary: "Select rows one after another") { run in
///       let model = ListModel(rows: run.fixture.int("rows", 500))
///       try await run.show(ListView(model: model))
///       for i in 0..<run.int("steps", 8) {
///         await run.step("select#\(i)") { model.select(i * 10) }
///       }
///       run.check("landed", model.selection == 70, "selection \(model.selection)")
///     }
@MainActor public final class Run {
  public let scenario: String
  public let fixture: Fixture
  /// The scenario's parameters: its defaults, then `--set k=v`.
  public let params: [String: String]
  public let rep: Int
  public private(set) var window: NSWindow?
  let recorder: Recorder
  let activate: Bool
  let sampler: MainThreadSampler?
  var appearance: NSAppearance.Name? = .aqua
  var steps: [StepRecord] = []
  var checks: [CheckResult] = []
  var notes: [String] = []
  var activity: NSObjectProtocol?
  /// `profile`'s child: once the window is up and at rest, write `<file>.waiting` and wait for `<file>` (the profiler
  /// has attached).
  var waitFor: String?

  init(scenario: String, fixture: Fixture, params: [String: String], rep: Int, recorder: Recorder, activate: Bool, sampler: MainThreadSampler?) {
    self.scenario = scenario; self.fixture = fixture; self.params = params; self.rep = rep; self.recorder = recorder; self.activate = activate; self.sampler = sampler
  }

  // MARK: parameters

  public func param(_ k: String) -> String? { params[k] }
  public func int(_ k: String, _ d: Int) -> Int { params[k].flatMap { Int($0) } ?? d }
  public func double(_ k: String, _ d: Double) -> Double { params[k].flatMap { Double($0) } ?? d }

  /// ms since the rep's clock started (the timeline's times).
  public var now: Double { recorder.now() }

  // MARK: the window

  /// Shows a SwiftUI view in a window of `size`, activates this process and waits until the window draws and comes to
  /// rest. Throws when no frame comes within 5 s (no window server: a locked screen, an ssh session).
  public func show<V: View>(_ view: V, size: CGSize = CGSize(width: 900, height: 700), title: String? = nil) async throws {
    let h = NSHostingView(rootView: view)
    h.sizingOptions = []
    try await show(view: h, size: size, title: title)
  }

  /// The same, for an AppKit view (the bench sizes the window; the view fills it).
  public func show(view: NSView, size: CGSize = CGSize(width: 900, height: 700), title: String? = nil) async throws {
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    w.title = title ?? "\(scenario) (perfloop bench)"
    w.isReleasedWhenClosed = false
    // One appearance on every machine, so snapshots of the champion and the candidate compare (Bench.appearance).
    if let a = appearance { w.appearance = NSAppearance(named: a) }
    w.contentView = view
    w.center()
    window = w
    recorder.timeline.nominalHz = Double(w.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
    activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled, .suddenTerminationDisabled], reason: "perfloop scenario")
    if activate { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil) } else { w.orderFrontRegardless() }
    recorder.start(on: view, sampler: sampler)
    if activate {
      for _ in 0..<10 where !(w.isKeyWindow && NSApp.isActive) {
        NSApp.activate(ignoringOtherApps: true); NSRunningApplication.current.activate(); w.makeKeyAndOrderFront(nil)
        await sleep(ms: 100)
      }
    }
    let start = recorder.timeline.ticks.count
    guard await recorder.wait(timeoutMs: 5000, { [unowned self] in recorder.timeline.ticks.count >= start + 3 }) else {
      throw HostError.harness("the window drew no frame in 5 s: is the screen locked, or is this an ssh session without the console?")
    }
    if !(await settle(timeoutMs: 3000)) { notes.append("the window was still busy 3 s after it opened") }
    if let wf = waitFor {
      waitFor = nil
      FileManager.default.createFile(atPath: wf + ".waiting", contents: Data())
      FileHandle.standardError.write(Data("waiting for \(wf) (a profiler attaches to pid \(ProcessInfo.processInfo.processIdentifier))\n".utf8))
      let until = Date().addingTimeInterval(120)
      while !FileManager.default.fileExists(atPath: wf), Date() < until { await sleep(ms: 50) }
      _ = await settle(timeoutMs: 1000)
    }
  }

  /// The window's state now: a rep whose window wasn't active, key, visible and unoccluded is untrusted.
  public func windowState() -> WindowState? {
    guard let w = window else { return nil }
    return WindowState(appActive: NSApp.isActive, keyWindow: w.isKeyWindow, visible: w.isVisible, occluded: !w.occlusionState.contains(.visible),
                       frame: [w.frame.origin.x, w.frame.origin.y, w.frame.width, w.frame.height], backingScale: w.backingScaleFactor)
  }

  func close() {
    recorder.stop()
    if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    window?.orderOut(nil); window?.contentView = nil; window?.close(); window = nil
  }

  // MARK: measuring

  /// One measured step: runs `action` on the main thread, waits for `until` (when given) and then for the window to
  /// come to rest (no main-thread stretch over 2 ms for `quietMs`), and records the step: main-thread CPU and
  /// instructions from the action to rest, frames, stretches, bodies, latency.
  ///
  /// `latencyMs` is the action → the first frame after `until` held; without `until`, the action → the end of the last
  /// busy stretch before rest. A step still busy at `timeoutMs` is recorded with `settled: false`.
  @discardableResult
  public func step(_ name: String, timeoutMs: Double = 5000, quietMs: Double = 100, until: (() -> Bool)? = nil, _ action: () -> Void) async -> StepRecord {
    let at = now
    // The `step` signpost a profile's per-step call trees are cut on (cheap when nothing records it).
    let sp = StepSignposts.poster, spID = sp.makeSignpostID()
    let spState = sp.beginInterval("step", id: spID, "\(name, privacy: .public)")
    defer { sp.endInterval("step", spState) }
    let cpu0 = KernelCounters.threadCpuMs(), ins0 = KernelCounters.instructions()
    recorder.lastBusyEnd = at
    action()
    var latency: Double?
    var stepNotes: [String] = []
    if let u = until {
      var heldAt: Double?
      let ok = await recorder.wait(timeoutMs: timeoutMs) { [unowned self] in
        if heldAt == nil, u() { heldAt = now }
        // The first frame after it held: the tick that shows it.
        if let h = heldAt, let t = recorder.timeline.ticks.last, t > h { latency = t - at; return true }
        return false
      }
      if !ok { stepNotes.append("until never held within \(Int(timeoutMs)) ms") }
    }
    var end = at, cpu1 = cpu0, ins1 = ins0
    let settled = await recorder.wait(timeoutMs: max(0, timeoutMs - (now - at))) { [unowned self] in
      let t = now
      guard t - recorder.lastBusyEnd >= quietMs, recorder.timeline.ticks.last.map({ $0 > at }) ?? false else { return false }
      end = t; cpu1 = KernelCounters.threadCpuMs(); ins1 = KernelCounters.instructions()
      return true
    }
    if !settled { end = now; cpu1 = KernelCounters.threadCpuMs(); ins1 = KernelCounters.instructions(); stepNotes.append("still busy at \(Int(timeoutMs)) ms") }
    let settle = max(0, recorder.lastBusyEnd - at)
    if until == nil { latency = settle }
    let ins: Int? = { guard let a = ins0, let b = ins1, b > a else { return nil }; return Int(b - a) }()
    let r = recorder.timeline.step(name: name, at: at, end: end, latencyMs: latency, settleMs: settle, settled: settled, cpuMs: cpu1 - cpu0, instructions: ins,
                                   notes: stepNotes, causes: nonEmpty(recorder.causes.causes(from: at, to: end)))
    steps.append(r)
    return r
  }

  /// Waits for the window to come to rest: no main-thread stretch over 2 ms for `quietMs`.
  @discardableResult
  public func settle(quietMs: Double = 100, timeoutMs: Double = 3000) async -> Bool {
    let from = now
    return await recorder.wait(timeoutMs: timeoutMs) { [unowned self] in now - max(recorder.lastBusyEnd, from - quietMs) >= quietMs && (recorder.timeline.ticks.last ?? 0) > from }
  }

  /// Waits until `check` holds (checked every frame, probe event and main-thread stretch); false at the timeout.
  public func wait(timeoutMs: Double = 3000, _ check: @escaping () -> Bool) async -> Bool { await recorder.wait(timeoutMs: timeoutMs, check) }

  /// How many times a view's body ran in this rep (`Probe.body`), and for which ids: what a guard of the bench's own
  /// checks ("every row on screen was built").
  public func bodyCount(of view: String, since: Double = 0) -> Int { recorder.timeline.bodies.filter { $0.view == view && $0.atMs >= since }.count }
  public func bodyIDs(of view: String, since: Double = 0) -> Set<String> { Set(recorder.timeline.bodies.filter { $0.view == view && $0.atMs >= since }.compactMap(\.id)) }

  /// The newest value the app reported for a probe event (`Probe.event`), if any.
  public func lastEvent(_ name: String) -> Int? { recorder.events.last { $0.name == name }?.value }

  /// A check beyond timing: the `checks` guard vetoes a candidate that fails one the champion passes.
  public func check(_ name: String, _ pass: Bool, _ detail: String = "") { checks.append(CheckResult(name: name, pass: pass, detail: detail)) }

  /// A line in the rep's notes (the result's `reps[].notes`).
  public func note(_ s: String) { notes.append(s) }

  public func sleep(ms: Double) async { try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000)) }

  func nonEmpty(_ c: [Cause]) -> [Cause]? { c.isEmpty ? nil : c }
}

public enum HostError: Error, CustomStringConvertible {
  case usage(String), harness(String)
  public var description: String { switch self { case .usage(let s), .harness(let s): s } }
  var code: Int32 { switch self { case .usage: 1; case .harness: 2 } }
}
#endif
