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
  public internal(set) var window: NSWindow?
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
  /// `record-gesture`: once the window is up, record a hand's gestures instead of running the steps.
  var recordRequest: RecordRequest?
  var recorded: [(String, PerfLoopProbe.Gesture)] = []
  var recordFailures: [String] = []
  /// `--pictures DIR` (`PERFLOOP_PICTURES`): where input steps write the window before and after, when it changed.
  var picturesDir: String?
  var keyMapCache: KeyMap?
  /// An identifier lookup turned SwiftUI's accessibility tree on in this rep (`element(identifier:)`).
  var accessibilityTreeOn = false
  /// The ink guard: every region judged in this rep, the floor when a region names none (`ink.min`), and where the
  /// crops go (`<artifacts>/ink`).
  var inkResults: [InkRegionResult] = []
  var inkMin = Ink.defaultMin
  var inkDir: URL?

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
    if let q = recordRequest { recordRequest = nil; try await record(q) }
  }

  /// The window's state now: a rep whose window wasn't active, key, visible and unoccluded is untrusted. A visible
  /// window the bench window owns (a child panel, popover or sheet) holding the keyboard counts as the window being key:
  /// a palette that takes the keyboard is the design, not a distraction.
  public func windowState() -> WindowState? {
    guard let w = window else { return nil }
    let child = !w.isKeyWindow && NSApp.keyWindow.map { $0 !== w && $0.isVisible && WindowState.owns(w, key: $0, parent: { $0.parent ?? $0.sheetParent }) } == true
    return WindowState(appActive: NSApp.isActive, keyWindow: w.isKeyWindow || child, visible: w.isVisible, occluded: !w.occlusionState.contains(.visible),
                       frame: [w.frame.origin.x, w.frame.origin.y, w.frame.width, w.frame.height], backingScale: w.backingScaleFactor, keyWindowIsChild: child ? true : nil)
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
  ///
  /// `ink`: regions that must show drawn content once the step has come to rest (the ink guard). They are judged after
  /// the step, in run-loop turns of their own whose time, frames and stretches are left out of every number, and the
  /// rep's `guards[]` gets one `ink` result with a crop of each region (`<artifacts>/ink/`).
  ///
  /// The step records the focus before the action and after it settled (`steps[].focus`). `expectFocus`: where the
  /// keyboard must be then, else the check `focus <step>` fails; without it, a step whose focus moved says so in its
  /// notes (a palette that closed and left the keyboard nowhere is a classic bug).
  @discardableResult
  public func step(_ name: String, timeoutMs: Double = 5000, quietMs: Double = 100, until: (() -> Bool)? = nil, ink: [InkRegion] = [], expectFocus: FocusTarget? = nil,
                   _ action: () -> Void) async -> StepRecord {
    let r = await measuredStep(name, timeoutMs: timeoutMs, quietMs: quietMs, until: until, expectFocus: expectFocus, action)
    if !ink.isEmpty { await self.ink(ink, after: name) }
    return r
  }

  /// `input`: an input step, whose line reports the focus itself (no note when it moves).
  func measuredStep(_ name: String, timeoutMs: Double, quietMs: Double, until: (() -> Bool)?, expectFocus: FocusTarget? = nil, input: Bool = false,
                    _ action: () -> Void) async -> StepRecord {
    let focusBefore = focus()
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
    var r = recorder.timeline.step(name: name, at: at, end: end, latencyMs: latency, settleMs: settle, settled: settled, cpuMs: cpu1 - cpu0, instructions: ins,
                                   notes: stepNotes, causes: nonEmpty(recorder.causes.causes(from: at, to: end)))
    var fc = FocusChange(before: focusBefore, after: focus())
    if let e = expectFocus {
      let ok = await focusMatches(e, fc.after, before: fc.before)
      fc.expected = e.description; fc.matched = ok
      check("focus \(name)", ok, ok ? fc.text : "expected \(e), \(fc.text)")
    } else if fc.changed && !input {
      r.notes.append("\(fc.text) (the step has no expectFocus: say where the keyboard should land)")
    }
    r.focus = fc
    steps.append(r)
    return r
  }

  // MARK: the bench's own work, off the clock

  /// Runs `work` in a run-loop turn of its own, after the stretch this is called in has closed, and lets that turn
  /// close before going on: its stretch, the frames it held up and the bodies it caused are left out of the rep's
  /// numbers (`Timeline.offClock`), and the next step's action starts in a fresh turn. What a check or a capture costs
  /// is never a step's (F18: a pixel check in the same wake-up as the step's last frame was 91 % of its worst stretch).
  public func offTheClock<T>(_ work: () async -> T) async -> T {
    guard recorder.clock.attached else { return await work() }
    await nextTurn()
    let a = now
    let out = await work()
    recorder.timeline.offClock.append(a...max(a, now))
    await nextTurn()
    return out
  }

  /// Until the stretch open now has closed (the continuation then runs in a later wake-up).
  func nextTurn() async {
    let n = recorder.clock.entries.count
    _ = await recorder.wait(timeoutMs: 1000) { [unowned self] in recorder.clock.entries.count > n }
  }

  /// The ink guard now, on `regions`, labelled `after` (a step's name, or where the scenario is: "open"). Off the
  /// clock. Called by `step(…, ink:)`; call it yourself for a moment that isn't a step's end.
  public func ink(_ regions: [InkRegion], after: String) async {
    guard let w = window else {
      inkResults += regions.map { InkRegionResult(region: $0.name, after: after, pass: false, ink: nil, min: $0.min ?? inkMin, rect: nil, detail: "no window", picture: nil) }
      return
    }
    await offTheClock {
      for r in regions {
        let file = Ink.fileName(scenario: scenario, rep: rep, after: after, region: r.name, n: inkResults.count)
        inkResults.append(Ink.judge(r, after: after, window: w, min: r.min ?? inkMin, dir: inkDir, file: file))
      }
    }
  }

  /// A check whose work runs off the clock (`offTheClock`): `body` returns whether it passed and what it saw. Use it
  /// for anything that costs more than reading a value (pixels, a walk of the view tree) so its time never lands in a
  /// step.
  public func check(_ name: String, _ body: () -> (Bool, String)) async {
    let (pass, detail) = await offTheClock { body() }
    check(name, pass, detail)
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
