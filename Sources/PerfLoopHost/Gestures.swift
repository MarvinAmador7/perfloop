#if os(macOS)
import AppKit
import QuartzCore
import PerfLoopKit
import PerfLoopProbe

// Gesture replay and recording for any app's scroll view (CAPABILITIES.md C9; deskbench's swipe driver, generic).
//
// Replay: a gesture's scroll-wheel events are made into NSEvents and handed to the scroll view at their recorded times,
// from the main run loop, in this process only (nothing is posted to the system). AppKit's own gesture handling,
// momentum, rubber-banding and the app's code run as under a hand. A display link reads where the content shows at each
// tick (the document layer's presentation, so a render-server animation counts) and the smoothness meter in
// PerfLoopProbe compares it with where the fingers put it.
//
// Recording: `record-gesture SCENARIO` shows the scenario's window and records what a hand does on the trackpad over it
// (a local event monitor: deltas, phases, times; nothing else), as `perfloop.gesture/1` files for `--set gesture=FILE`.

extension Run {
  /// The scroll view a gesture goes to: the largest NSScrollView in the window that has a document view.
  public func scrollView() -> NSScrollView? {
    guard let root = window?.contentView else { return nil }
    var found: [NSScrollView] = []
    func walk(_ v: NSView) { if let s = v as? NSScrollView, s.documentView != nil { found.append(s) }; v.subviews.forEach(walk) }
    walk(root)
    return found.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
  }

  /// The gesture a scenario's `gesture` parameter names (`synthetic:scroll-down`, or a file), or `fallback`.
  public func gesture(_ fallback: String = "synthetic:scroll-down") throws -> Gesture {
    do { return try SyntheticGestures.load(param("gesture") ?? fallback) } catch { throw HostError.usage("\(error)") }
  }

  /// One measured step: `gesture` replayed into `scrollView` (the window's largest by default), each event stamped with
  /// its recorded time (as a trackpad's events carry the time the hardware saw them, however late the main thread
  /// takes them), waiting until the content comes to rest (its offset unchanged for 150 ms). The step carries the
  /// smoothness: position error p95 while the fingers were down, stalls, jerk, latency in frames (`steps[].smoothness`).
  /// `timestamps: false` stamps every event 0, as an old synthetic fling did (AppKit can't see the release velocity then).
  @discardableResult
  public func swipe(_ gesture: Gesture, in scrollView: NSScrollView? = nil, name: String? = nil, timestamps: Bool = true, timeoutMs: Double? = nil) async -> StepRecord {
    let label = name ?? "swipe \(gesture.name)"
    guard let sv = scrollView ?? self.scrollView(), let w = window else {
      check("scroll-view", false, "no NSScrollView with a document view in the window")
      return await step(label) {}
    }
    let replay = GestureReplay(sv: sv, window: w, gesture: gesture, timestamps: timestamps)
    replay.blockMs = double("inject-block-ms", 0)
    let limit = timeoutMs ?? max(3000, gesture.durationMs + 2000)
    var r = await step(label, timeoutMs: limit, quietMs: 100, until: { replay.done && replay.atRest(now: CACurrentMediaTime()) }) { replay.start() }
    replay.stop()
    r.smoothness = replay.smoothness()
    r.notes += replay.notes()
    if let p = replay.unfaithful() { r.notes.append("replay not faithful: \(p)"); check("gesture", false, "\(label): \(p)") }
    if let i = steps.lastIndex(where: { $0.name == r.name && $0.atMs == r.atMs }) { steps[i] = r }
    return r
  }

  /// Scrolls the content back to its start without animation and waits for rest (between swipes).
  public func scrollToStart(_ scrollView: NSScrollView? = nil) async {
    guard let sv = scrollView ?? self.scrollView() else { return }
    let flipped = sv.documentView?.isFlipped ?? true
    let y = flipped ? 0 : max(0, (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height)
    sv.contentView.scroll(to: NSPoint(x: 0, y: y)); sv.reflectScrolledClipView(sv.contentView)
    _ = await settle(quietMs: 150, timeoutMs: 2000)
  }
}

/// One gesture's replay and what was on screen meanwhile. Events go out from a main-queue timer at their recorded
/// times (the main run loop serves it, as it serves the window server's events); a display link reads the document
/// layer's presentation each tick; a run-loop observer after Core Animation's commit notes when the last commit went
/// out, so the meter counts only deltas that could be on screen.
@MainActor final class GestureReplay: NSObject {
  let sv: NSScrollView
  let window: NSWindow
  let gesture: Gesture
  let timestamps: Bool
  /// The meter's self-check (`--set inject-block-ms=N`): the main thread sleeps N ms after the middle finger event, as
  /// a slow frame would hold it; the result must show the stalls.
  var blockMs = 0.0
  /// The axis the gesture moves on (the larger total travel).
  let axis: SyntheticGestures.Axis
  /// One event as it went out; `timestamp` is the NSEvent's (the recorded time, 0 with `timestamps: false`).
  struct Sent { var due: Double; var delivered: Double; var timestamp: Double; var d: Double; var phase: Gesture.Phase; var momentum: Gesture.Phase; var precise: Bool; var finger: Bool }
  private(set) var sent: [Sent] = []
  /// Per tick: time, last commit, the layer's position along the axis, the clip view's offset.
  private var raw: [(t: Double, committed: Double, layer: Double?, offset: Double)] = []
  private var t0 = 0.0, lastCommit = 0.0, startOffset = 0.0
  private var link: CADisplayLink?
  private var observer: CFRunLoopObserver?
  private var timer: DispatchSourceTimer?
  private var next = 0
  private var carry = (x: 0.0, y: 0.0, sentX: 0.0, sentY: 0.0)
  private(set) var done = false
  private var lastMove = 0.0, lastOffset = 0.0

  init(sv: NSScrollView, window: NSWindow, gesture: Gesture, timestamps: Bool) {
    self.sv = sv; self.window = window; self.gesture = gesture; self.timestamps = timestamps
    let t = gesture.events.reduce((0.0, 0.0)) { ($0.0 + abs($1.dx), $0.1 + abs($1.dy)) }
    axis = t.1 > t.0 ? .y : .x
  }

  /// The clip view's offset along the axis (the model's truth after each commit).
  func offset() -> Double { Double(axis == .x ? sv.contentView.bounds.origin.x : sv.contentView.bounds.origin.y) }
  /// Where the document layer shows along the axis in the scroll view's layer (the presentation tree), if layer-backed.
  func layerPos() -> Double? {
    guard let dl = sv.documentView?.layer, let sl = sv.layer else { return nil }
    let p = dl.presentation() ?? dl, s = sl.presentation() ?? sl
    let o = p.convert(CGPoint.zero, to: s)
    return Double(axis == .x ? o.x : o.y)
  }
  /// How the content offset moves for a scroll delta: a flipped document's offset grows as −delta (natural scrolling),
  /// an unflipped one's along y the other way.
  var offsetPerDelta: Double { axis == .y && sv.documentView?.isFlipped == false ? 1 : -1 }

  func start() {
    startOffset = offset(); lastOffset = startOffset
    t0 = CACurrentMediaTime() + 0.02   // the first event a frame from now: the display link and observer are in place
    lastCommit = CACurrentMediaTime(); lastMove = t0
    let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true, 2_100_000) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.lastCommit = CACurrentMediaTime() }   // after Core Animation's commit (order 2 000 000)
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
    observer = obs
    let l = sv.displayLink(target: self, selector: #selector(tick(_:)))
    let hz = Float(window.screen?.maximumFramesPerSecond ?? 60)
    l.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)
    l.add(to: .main, forMode: .common)
    link = l
    let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
    t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.fire() } }
    timer = t
    schedule()
    t.resume()
  }

  private func schedule() {
    guard next < gesture.events.count else { timer?.cancel(); timer = nil; done = true; return }
    let due = t0 + gesture.events[next].t / 1000
    timer?.schedule(deadline: .now() + max(0, due - CACurrentMediaTime()), leeway: .nanoseconds(0))
  }

  private func fire() {
    let now = CACurrentMediaTime()
    while next < gesture.events.count, t0 + gesture.events[next].t / 1000 <= now + 0.0002 { deliver(gesture.events[next]); next += 1 }
    schedule()
  }

  @objc func tick(_ l: CADisplayLink) {
    let now = CACurrentMediaTime(), o = offset()
    raw.append((now, lastCommit, layerPos(), o))
    if abs(o - lastOffset) > 0.01 { lastOffset = o; lastMove = now }
  }

  /// Every event out and the offset unchanged for 150 ms.
  func atRest(now: Double) -> Bool { done && now - lastMove >= 0.15 }

  func stop() {
    link?.invalidate(); link = nil
    if let o = observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes); observer = nil }
    timer?.cancel(); timer = nil
  }

  /// A CGEvent with the recorded fields, made into an NSEvent and handed to the scroll view. A CGEvent carries whole
  /// points, so fractional deltas are rounded with the remainder carried to the next event.
  private func deliver(_ e: Gesture.Event) {
    carry.x += e.dx; carry.y += e.dy
    let ix = carry.x.rounded() - carry.sentX, iy = carry.y.rounded() - carry.sentY
    carry.sentX += ix; carry.sentY += iy
    guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: e.precise ? .pixel : .line, wheelCount: 2, wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0) else { return }
    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: e.precise ? 1 : 0)
    if e.precise { cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: iy); cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: ix) }
    cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: iy); cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: ix)
    // CGScrollPhase: began 1, changed 2, ended 4, cancelled 8, mayBegin 128. CGMomentumScrollPhase: begin 1, continue 2, end 3.
    let sp: Int64 = switch e.phase { case .began: 1; case .changed, .stationary: 2; case .ended: 4; case .cancelled: 8; case .mayBegin: 128; case .none: 0 }
    let mp: Int64 = switch e.momentum { case .began: 1; case .changed, .stationary, .mayBegin: 2; case .ended, .cancelled: 3; case .none: 0 }
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: sp)
    cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: mp)
    let now = CACurrentMediaTime()
    // NSEvent.timestamp: AppKit's release velocity (and its own deceleration after the fingers lift) reads it. The
    // recorded time, not the delivery time: a timer that fires late hands two events over together, and stamped with
    // the delivery time they gave AppKit a release velocity of the main thread's jitter (one flick read 820 to
    // 7000 pt/s across replays of the same file; deskbench, 2026-11-04).
    if timestamps { cg.timestamp = CGEventTimestamp((t0 + e.t / 1000) * 1e9) }
    let r = sv.convert(sv.bounds, to: nil)
    let p = window.convertPoint(toScreen: NSPoint(x: r.midX, y: r.midY))
    cg.location = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
    guard let ev = NSEvent(cgEvent: cg) else { return }
    let d = Double(axis == .x ? ev.scrollingDeltaX : ev.scrollingDeltaY)
    sent.append(Sent(due: t0 + e.t / 1000, delivered: now, timestamp: ev.timestamp, d: d, phase: Gesture.Phase(rawBits: ev.phase.rawValue), momentum: Gesture.Phase(rawBits: ev.momentumPhase.rawValue),
                     precise: ev.hasPreciseScrollingDeltas, finger: e.finger))
    sv.scrollWheel(with: ev)
    if blockMs > 0, e.phase == .changed, sent.filter(\.finger).count == gesture.events.filter(\.finger).count / 2 { usleep(useconds_t(blockMs * 1000)) }
  }

  /// The content offset shown at each tick: the presentation layer's movement when the views are layer-backed (its
  /// direction calibrated against the clip view's offset over the whole replay), else the clip view's offset.
  func shown() -> [Double] {
    guard let first = raw.first, let last = raw.last else { return [] }
    let layered = raw.allSatisfy { $0.layer != nil }
    let dl = (last.layer ?? 0) - (first.layer ?? 0), doff = last.offset - first.offset
    guard layered, abs(dl) > 0.5, abs(doff) > 0.5 else { return raw.map(\.offset) }
    let s: Double = (dl > 0) == (doff > 0) ? 1 : -1
    return raw.map { first.offset + s * (($0.layer ?? 0) - (first.layer ?? 0)) }
  }

  func smoothness() -> Smoothness {
    let pos = shown()
    let ticks = zip(raw, pos).map { SmoothnessMeter.Tick(t: $0.t, committed: $0.committed, shown: $1) }
    let fingers = sent.filter(\.finger)
    let k = offsetPerDelta
    let deltas = sent.map { SmoothnessMeter.Delta(due: $0.due, delivered: $0.delivered, d: k * $0.d, finger: $0.finger) }
    return SmoothnessMeter.measure(ticks: ticks, deltas: deltas, start: raw.first?.offset ?? startOffset, fingerFrom: fingers.first?.due ?? t0,
                                   fingerUntil: fingers.last?.due ?? t0, settled: lastMove)
  }

  /// How far off the replay was: the events' delivery against their recorded times, and how far things moved.
  func notes() -> [String] {
    let late = sent.map { ($0.delivered - $0.due) * 1000 }
    let f = sent.filter(\.finger).reduce(0) { $0 + $1.d }, m = sent.filter { $0.momentum != .none }.reduce(0) { $0 + $1.d }
    return ["\(gesture.name): \(sent.count)/\(gesture.events.count) events over \(Int(gesture.durationMs)) ms on \(axis.rawValue), delivered p95 \(Stats.round(Stats.percentile(late, 95), 2)) ms after due (max \(Stats.round(late.max() ?? 0, 2)) ms)",
            "fingers moved \(Stats.round(f, 1)) pt, momentum \(Stats.round(m, 1)) pt; content moved \(Stats.round((raw.last?.offset ?? 0) - startOffset, 1)) pt; \(raw.count) display ticks read"]
  }

  /// Why the replay wasn't the recording, if it wasn't: an event not delivered, a phase the NSEvent didn't carry.
  func unfaithful() -> String? {
    if sent.count != gesture.events.count { return "\(sent.count) of \(gesture.events.count) events delivered" }
    func norm(_ p: Gesture.Phase, momentum: Bool) -> Gesture.Phase { p == .stationary ? .changed : momentum && p == .cancelled ? .ended : momentum && p == .mayBegin ? .changed : p }
    for (s, e) in zip(sent, gesture.events) {
      if s.phase != norm(e.phase, momentum: false) || s.momentum != norm(e.momentum, momentum: true) {
        return "an event at \(e.t) ms went out as phase \(s.phase.rawValue)/\(s.momentum.rawValue), recorded \(e.phase.rawValue)/\(e.momentum.rawValue)"
      }
      if s.precise != e.precise { return "an event at \(e.t) ms went out with precise=\(s.precise)" }
    }
    let rec = gesture.events.reduce(0) { $0 + (axis == .x ? $1.dx : $1.dy) }, out = sent.reduce(0) { $0 + $1.d }
    if gesture.events.allSatisfy(\.precise), abs(rec - out) > 1 { return "the deltas summed to \(out) pt, recorded \(rec) pt" }
    return nil
  }
}

// MARK: recording

/// The opt-in recorder: a local monitor on the bench's window that hands each scroll-wheel event's numbers to a
/// `GestureRecorder` (PerfLoopProbe), which cuts them into gestures and writes each as a file. Only a hand on the
/// trackpad makes events here: nothing is sent.
@MainActor final class GestureTap {
  let recorder: GestureRecorder
  private var monitor: Any?
  private var timer: Timer?
  private(set) var written: [(String, Gesture)] = []
  private(set) var failures: [String] = []

  init(to url: URL, name: String, device: String?) {
    let base = url.deletingPathExtension().lastPathComponent
    var written: [(String, Gesture)] = [], failures: [String] = []
    recorder = GestureRecorder(name: name, device: device) { g, n in
      let dest = n == 1 ? url : url.deletingLastPathComponent().appendingPathComponent("\(base)-\(n).json")
      do {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try g.encoded().write(to: dest, options: .atomic)
        written.append((dest.path, g))
        FileHandle.standardError.write(Data("recorded \(g.name): \(g.events.count) events over \(Int(g.durationMs)) ms → \(dest.path)\n".utf8))
      } catch { failures.append("\(dest.path): \(error)") }
    }
    self.collect = { (written, failures) }
  }
  private var collect: () -> ([(String, Gesture)], [String]) = { ([], []) }
  func refresh() { (written, failures) = collect() }

  func install(on window: NSWindow) {
    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak window] e in
      if let self, e.window === window { self.handle(e) }
      return e
    }
  }

  /// One scroll event's numbers (what the monitor sees).
  func handle(_ e: NSEvent) {
    recorder.record(t: e.timestamp, dx: Double(e.scrollingDeltaX), dy: Double(e.scrollingDeltaY), phase: e.phase.rawValue, momentum: e.momentumPhase.rawValue,
                    precise: e.hasPreciseScrollingDeltas)
    timer?.invalidate(); timer = nil
    // Nothing else arrives to end a gesture whose momentum never came: wake up at its deadline.
    guard let d = recorder.deadline else { refresh(); return }
    let t = Timer(timeInterval: max(0, d - ProcessInfo.processInfo.systemUptime) + 0.01, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.idle() }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
    refresh()
  }

  func idle() { recorder.idle(at: ProcessInfo.processInfo.systemUptime); refresh() }

  /// Stops listening; `keepOpen` writes the gesture in flight (out of time), else it is dropped (enough were written).
  func stop(keepOpen: Bool) {
    if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    timer?.invalidate(); timer = nil
    if keepOpen { recorder.finish() }
    refresh()
  }
}

/// How `record-gesture` ends the scenario once the window is up and the hand is done (its steps never run).
struct RecordingDone: Error {}

/// What `record-gesture` asked for; the scenario's `run.show` records instead of returning.
struct RecordRequest {
  var url: URL
  var name: String
  var device: String?
  var count: Int
  var timeoutS: Double
  /// Testing hook (`--feed synthetic:NAME`): the gesture's events handed to the tap as NSEvents, without a hand.
  var feed: Gesture?
}

extension Run {
  /// `record-gesture`: the window is up; record until `count` gestures are written or the time is up.
  func record(_ q: RecordRequest) async throws -> Never {
    guard let w = window else { throw HostError.harness("no window to record on") }
    let tap = GestureTap(to: q.url, name: q.name, device: q.device)
    tap.install(on: w)
    FileHandle.standardError.write(Data("recording: swipe over the window with two fingers (\(q.count) gesture\(q.count == 1 ? "" : "s"), up to \(Int(q.timeoutS)) s)\n".utf8))
    if let g = q.feed { await feed(g, into: tap) }
    let deadline = Date().addingTimeInterval(q.timeoutS)
    while tap.written.count < q.count, tap.failures.isEmpty, Date() < deadline { await sleep(ms: 50); tap.refresh() }
    tap.stop(keepOpen: tap.written.count < q.count)
    recorded = tap.written; recordFailures = tap.failures
    throw RecordingDone()
  }

  /// Feeds a gesture's events to the tap at their times, as NSEvents with timestamps (the recorder's self-check).
  func feed(_ g: Gesture, into tap: GestureTap) async {
    let t0 = ProcessInfo.processInfo.systemUptime
    for e in g.events {
      let wait = t0 + e.t / 1000 - ProcessInfo.processInfo.systemUptime
      if wait > 0 { await sleep(ms: wait * 1000) }
      guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(e.dy), wheel2: Int32(e.dx), wheel3: 0) else { continue }
      cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: e.dy); cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: e.dx)
      let sp: Int64 = switch e.phase { case .began: 1; case .changed, .stationary: 2; case .ended: 4; case .cancelled: 8; case .mayBegin: 128; case .none: 0 }
      let mp: Int64 = switch e.momentum { case .began: 1; case .changed, .stationary, .mayBegin: 2; case .ended, .cancelled: 3; case .none: 0 }
      cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: sp); cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: mp)
      cg.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1e9)
      if let ev = NSEvent(cgEvent: cg) { tap.handle(ev) }
    }
  }
}
#endif
