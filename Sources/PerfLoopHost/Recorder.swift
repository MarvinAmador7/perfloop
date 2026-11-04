#if os(macOS)
import AppKit
import QuartzCore
import PerfLoopKit
import PerfLoopProbe

/// Everything a rep records while its scenario runs: display-link ticks, main-thread stretches (the stretch clock, the
/// same edges the sampler uses), probe bodies and events, mutation records (C7). Waiters are checked on every tick,
/// event and stretch close, so a scenario waits on the window, not on sleeps.
@MainActor final class Recorder: NSObject, ProbeSink {
  let t0 = CACurrentMediaTime()
  var timeline: Timeline
  lazy var clock = StretchClock(t0: t0)
  lazy var causes = CauseRecorder { [unowned self] in now() }
  var events: [(t: Double, name: String, value: Int)] = []
  var link: CADisplayLink?
  var sampler: MainThreadSampler?
  /// The end of the last stretch longer than `busyMs`: what `settle` waits to be far enough in the past.
  var lastBusyEnd = 0.0
  var busyMs = 2.0
  private var waiters: [(id: Int, check: () -> Bool, resume: () -> Void)] = []
  private var serial = 0

  init(nominalHz: Double) { timeline = Timeline(nominalHz: nominalHz) }

  func now() -> Double { (CACurrentMediaTime() - t0) * 1000 }

  func start(on view: NSView, sampler s: MainThreadSampler?) {
    let l = view.displayLink(target: self, selector: #selector(tick(_:)))
    let hz = Float(timeline.nominalHz)
    l.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)   // hold ProMotion at its top rate
    l.add(to: .main, forMode: .common)
    link = l
    clock.closed = { [unowned self] in
      if let e = clock.entries.last {
        timeline.stretches.append(StretchSample(id: e.id, atMs: e.at, durationMs: e.dur, cpuMs: e.cpu))
        if e.dur > busyMs { lastBusyEnd = e.at + e.dur }
      }
      causes.turnEnded(); checkWaiters()
    }
    sampler = s
    clock.sampler = s
    clock.attach()
  }

  func stop() {
    link?.invalidate(); link = nil
    clock.detach(); clock.sampler = nil
    // Wake anyone still waiting: their checks fail at their deadline anyway.
    let ws = waiters; waiters = []; ws.forEach { $0.resume() }
  }

  @objc func tick(_ l: CADisplayLink) { timeline.ticks.append(now()); checkWaiters() }

  func body(_ view: StaticString) { let t = now(), v = view.description; timeline.bodies.append(BodySample(atMs: t, view: v)); causes.body(v, at: t) }
  func body(_ view: StaticString, id: String) { let t = now(), v = view.description; timeline.bodies.append(BodySample(atMs: t, view: v, id: id)); causes.body(v, id: id, at: t) }
  func event(_ name: StaticString, _ value: Int) { events.append((now(), name.description, value)); checkWaiters() }

  func checkWaiters() {
    guard !waiters.isEmpty else { return }
    let ready = waiters.filter { $0.check() }
    let ids = Set(ready.map(\.id))
    waiters.removeAll { ids.contains($0.id) }
    ready.forEach { $0.resume() }
  }

  /// Waits until `check` holds (checked on every tick, event and stretch close) or `timeoutMs` passes.
  func wait(timeoutMs: Double, _ check: @escaping () -> Bool) async -> Bool {
    if check() { return true }
    let deadline = now() + timeoutMs
    var held = false
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      serial += 1
      var done = false
      let id = serial
      waiters.append((id, { [unowned self] in
        if check() { held = true; return true }
        return now() >= deadline
      }, { if !done { done = true; c.resume() } }))
      // A deadline with nothing happening (no window yet, a stopped display link) still ends the wait.
      DispatchQueue.main.asyncAfter(deadline: .now() + timeoutMs / 1000 + 0.05) { [weak self] in
        MainActor.assumeIsolated {
          guard let self, let i = self.waiters.firstIndex(where: { $0.id == id }) else { return }
          let w = self.waiters.remove(at: i); w.resume()
        }
      }
    }
    return held
  }
}
#endif
