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
  /// The look the rep draws in (`--set appearance=light|dark|system`, light by default): the bench window and, through
  /// `NSApp.appearance`, its child windows, popovers, sheets and menus.
  public internal(set) var appearanceName = "light"
  /// The text size asked for (`--set textSize=…`, one of the bench's `textSizes`), nil for the default. macOS has no
  /// system text size an app follows: the scenario applies it through the app's own setting.
  public internal(set) var textSize: String?
  /// The regions snapshots are compared by (the same regions the ink guard takes): the bench's (`bench.region`), the
  /// scenario's (`run.region`), and every region a step named for the ink guard, once per name.
  var regions: [InkRegion] = []
  var appAppearance: NSAppearance??
  /// The app's own window, adopted with `show(window:)`, and its appearance before: the rep leaves it up.
  var adopted: (window: NSWindow, appearance: NSAppearance?)?
  var closers: [@MainActor () -> Void] = []
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
    let w = makeWindow(view: view, size: size, title: title)
    present(w, view: view)
    try await shown(w)
  }

  /// Adopts a window the app made itself (its SwiftUI scene's, its delegate's) as the rep's window, instead of one the
  /// bench makes: the app's main menu, its scene's commands and its window controller stay what they are, so
  /// `run.press("⌘K")` goes through the app's real menu bar. Activates it, waits until it draws and comes to rest, as
  /// `show` does. `size`: the content size to set (nil keeps the app's). The rep's close leaves the window up (the app
  /// owns it) with its appearance as it was; a later rep adopts it again, so each rep resets the app's state itself.
  /// Find the window with `appWindow()`.
  public func show(window w: NSWindow, size: CGSize? = nil) async throws {
    guard window == nil else { throw HostError.usage("the rep already has its window: show(window:) adopts the app's window in place of run.show, once per rep") }
    guard let view = w.contentView else { throw HostError.harness("the app's window '\(w.title)' has no content view to measure") }
    adopted = (w, w.appearance)
    if let s = size { w.setContentSize(s) }
    look(w)
    window = w
    present(w, view: view)
    try await shown(w)
  }

  /// The app's own window, once it is up: the first visible window that can be main (not a panel), matching `where`
  /// when given. SwiftUI makes a scene's windows a little after launch: this waits for one.
  /// Throws after `timeoutMs`, naming the windows there were.
  public func appWindow(timeoutMs: Double = 5000, where match: ((NSWindow) -> Bool)? = nil) async throws -> NSWindow {
    func find() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) && (match?($0) ?? true) } }
    let until = Date().addingTimeInterval(timeoutMs / 1000)
    while Date() < until {
      if let w = find() { return w }
      await sleep(ms: 20)
    }
    if let w = find() { return w }
    let seen = NSApp.windows.map { "'\($0.title)' (\(Focus.name($0))\($0.isVisible ? "" : ", hidden"))" }
    throw HostError.harness("the app showed no window within \(Int(timeoutMs)) ms" + (match == nil ? "" : " that matches") + (seen.isEmpty ? " (it has none)" : ": it has \(seen.joined(separator: ", "))")
                            + ". The scenario runs inside the app (bench.attach, or bench.appDelegate with host: .app): is its window scene opened at launch?")
  }

  /// A window for `view`, in the rep's look, centred: the rep's window from here on (not shown yet).
  func makeWindow(view: NSView, size: CGSize, title: String?) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    w.title = title ?? "\(scenario) (perfloop bench)"
    w.isReleasedWhenClosed = false
    look(w)
    w.contentView = view
    w.center()
    window = w
    return w
  }

  /// One appearance on every machine, so snapshots of the champion and the candidate compare (Bench.appearance). Child
  /// windows, popovers and sheets follow the app's appearance, not their parent's: set it too, for the rep.
  func look(_ w: NSWindow) {
    if let a = appearance { w.appearance = NSAppearance(named: a) }
    if appAppearance == nil { appAppearance = .some(NSApp.appearance) }
    NSApp.appearance = appearance.flatMap { NSAppearance(named: $0) }
  }

  /// Puts the window in front (activating this process unless `--no-activate`) and starts the frames on `view`. No
  /// waiting: `open` calls it inside its step.
  func present(_ w: NSWindow, view: NSView) {
    recorder.timeline.nominalHz = Double(w.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
    if activity == nil {
      activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled, .suddenTerminationDisabled], reason: "perfloop scenario")
    }
    if activate { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil) } else { w.orderFrontRegardless() }
    recorder.start(on: view, sampler: sampler)
  }

  /// Until the window is key (up to 1 s), draws and comes to rest; then `profile`'s wait and `record-gesture`'s
  /// recording, when asked for.
  func shown(_ w: NSWindow) async throws {
    await makeKey(w)
    let start = recorder.timeline.ticks.count
    guard await recorder.wait(timeoutMs: 5000, { [unowned self] in recorder.timeline.ticks.count >= start + 3 }) else {
      throw HostError.harness("the window drew no frame in 5 s: is the screen locked, or is this an ssh session without the console?")
    }
    if !(await settle(timeoutMs: 3000)) { notes.append("the window was still busy 3 s after it opened") }
    await profilerWait()
    if let q = recordRequest { recordRequest = nil; try await record(q) }
  }

  func makeKey(_ w: NSWindow) async {
    guard activate else { return }
    for _ in 0..<10 where !(w.isKeyWindow && NSApp.isActive) {
      NSApp.activate(ignoringOtherApps: true); NSRunningApplication.current.activate(); w.makeKeyAndOrderFront(nil)
      await sleep(ms: 100)
    }
  }

  /// `profile`'s child: once, write `<file>.waiting` and wait (up to 120 s) for `<file>`, the profiler attached.
  func profilerWait() async {
    guard let wf = waitFor else { return }
    waitFor = nil
    FileManager.default.createFile(atPath: wf + ".waiting", contents: Data())
    FileHandle.standardError.write(Data("waiting for \(wf) (a profiler attaches to pid \(ProcessInfo.processInfo.processIdentifier))\n".utf8))
    let until = Date().addingTimeInterval(120)
    while !FileManager.default.fileExists(atPath: wf), Date() < until { await sleep(ms: 50) }
    if window != nil { _ = await settle(timeoutMs: 1000) }
  }

  // MARK: opening, measured

  /// One measured step that opens the rep's window (an `open` scenario: in place of `show`): the clock starts before
  /// the window exists, so making `content`, the window, its first layout and its first frames are all in the step.
  /// The step's action builds the view, makes the window, puts it in front and starts the frames; its latency is to the
  /// first frame after `until` held (without `until`: the end of the last busy stretch before rest), as `step`'s.
  /// `ink` regions are judged once it has come to rest. Throws when no frame comes within `timeoutMs`.
  @discardableResult
  public func open<V: View>(_ name: String = "open", size: CGSize = CGSize(width: 900, height: 700), title: String? = nil, timeoutMs: Double = 5000, quietMs: Double = 100,
                            until: (() -> Bool)? = nil, ink: [InkRegion] = [], expectFocus: FocusTarget? = nil, _ content: () -> V) async throws -> StepRecord {
    try await open(name, size: size, title: title, timeoutMs: timeoutMs, quietMs: quietMs, until: until, ink: ink, expectFocus: expectFocus, view: {
      let h = NSHostingView(rootView: content())
      h.sizingOptions = []
      return h
    })
  }

  /// The same, for an AppKit view.
  @discardableResult
  public func open(_ name: String = "open", size: CGSize = CGSize(width: 900, height: 700), title: String? = nil, timeoutMs: Double = 5000, quietMs: Double = 100,
                   until: (() -> Bool)? = nil, ink: [InkRegion] = [], expectFocus: FocusTarget? = nil, view content: () -> NSView) async throws -> StepRecord {
    guard window == nil else { throw HostError.usage("run.open makes the rep's window: call it in place of run.show, before any other window of the rep") }
    // The profiler attaches before the clock starts: there is no window to wait on yet.
    await profilerWait()
    recorder.timeline.nominalHz = Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
    recorder.startClock(sampler: sampler)
    // A fresh run-loop turn: the step's action is the first thing in it.
    await nextTurn()
    let r = await measuredStep(name, timeoutMs: timeoutMs, quietMs: quietMs, until: until, expectFocus: expectFocus, input: true) {
      let v = content()
      present(makeWindow(view: v, size: size, title: title), view: v)
    }
    guard let w = window, !recorder.timeline.ticks.isEmpty else {
      throw HostError.harness("the window drew no frame in \(Int(timeoutMs)) ms: is the screen locked, or is this an ssh session without the console?")
    }
    await makeKey(w)
    if !ink.isEmpty { await self.ink(ink, after: name) }
    for r in ink where !regions.contains(where: { $0.name == r.name }) { regions.append(r) }
    if let q = recordRequest { recordRequest = nil; try await record(q) }
    return r
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

  /// Runs `f` when the rep's window closes, after the guards have judged it: a scenario that opens a panel, popover or
  /// sheet leaves it up so snapshots draw it in (they are taken after the scenario returns), and closes it here.
  public func atClose(_ f: @escaping @MainActor () -> Void) { closers.append(f) }

  func close() {
    for f in closers.reversed() { f() }
    closers = []
    recorder.stop()
    if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    if let a = adopted {
      // The app's own window stays up, as the app left it.
      a.window.appearance = a.appearance; window = nil; adopted = nil
    } else {
      window?.orderOut(nil); window?.contentView = nil; window?.close(); window = nil
    }
    if let a = appAppearance { NSApp.appearance = a; appAppearance = nil }
  }

  // MARK: regions

  /// Names parts of the window for snapshots (v5): `snapdiff` reports each on its own (`same`, `moved`, `differs`), and
  /// an agent declares the regions its change means to alter with `--expect-look NAME`. The same `InkRegion`s the ink
  /// guard takes (`.view`, `.identifier`, `.rect`, `.find`), placed when the snapshot is taken; a region a step already
  /// named for the ink guard is one without this.
  public func regions(_ rs: [InkRegion]) { for r in rs { addRegion(r) } }

  func addRegion(_ r: InkRegion) {
    if let i = regions.firstIndex(where: { $0.name == r.name }) { regions[i] = r } else { regions.append(r) }
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
    for r in ink where !regions.contains(where: { $0.name == r.name }) { regions.append(r) }
    return r
  }

  /// One measured step whose action is work over time (a burst of items at a rate, events at their times): the step
  /// starts it, awaits it and ends once it has finished, `until` (when given) held and the window came to rest. Its
  /// CPU and stretches are everything from the action's start to rest, the frames in between included; its latency is
  /// the action's start → the first frame after the action finished (and `until` held). Everything else is `step`'s.
  @discardableResult
  public func step(_ name: String, timeoutMs: Double = 5000, quietMs: Double = 100, until: (() -> Bool)? = nil, ink: [InkRegion] = [], expectFocus: FocusTarget? = nil,
                   _ action: @MainActor () async -> Void) async -> StepRecord {
    let r = await measuredStep(name, timeoutMs: timeoutMs, quietMs: quietMs, until: until ?? { true }, expectFocus: expectFocus, asyncAction: action)
    if !ink.isEmpty { await self.ink(ink, after: name) }
    for r in ink where !regions.contains(where: { $0.name == r.name }) { regions.append(r) }
    return r
  }

  /// `input`: an input step, whose line reports the focus itself (no note when it moves).
  func measuredStep(_ name: String, timeoutMs: Double, quietMs: Double, until: (() -> Bool)?, expectFocus: FocusTarget? = nil, input: Bool = false,
                    _ action: () -> Void) async -> StepRecord {
    await measuredStep(name, timeoutMs: timeoutMs, quietMs: quietMs, until: until, expectFocus: expectFocus, input: input, asyncAction: { action() })
  }

  /// The step: `asyncAction` runs on the main actor and is awaited (a synchronous one returns before anything else
  /// runs, as it always did); `until` and the rest are waited from its return, the clock from its start.
  func measuredStep(_ name: String, timeoutMs: Double, quietMs: Double, until: (() -> Bool)?, expectFocus: FocusTarget? = nil, input: Bool = false,
                    asyncAction action: @MainActor () async -> Void) async -> StepRecord {
    let focusBefore = focus()
    let at = now
    // The `step` signpost a profile's per-step call trees are cut on (cheap when nothing records it).
    let sp = StepSignposts.poster, spID = sp.makeSignpostID()
    let spState = sp.beginInterval("step", id: spID, "\(name, privacy: .public)")
    defer { sp.endInterval("step", spState) }
    let cpu0 = KernelCounters.threadCpuMs(), ins0 = KernelCounters.instructions()
    recorder.lastBusyEnd = at
    await action()
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
