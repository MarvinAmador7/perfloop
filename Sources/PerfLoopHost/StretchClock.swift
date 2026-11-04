#if os(macOS)
import Foundation
import QuartzCore

/// Where a main-thread stretch begins and ends: the one source of truth the bench's numbers and the sampler's stacks
/// both come from. A stretch opens at the very first `afterWaiting` observer of a wake-up (order `CFIndex.min`) and
/// closes at the very last `beforeWaiting` one (order `CFIndex.max`), so it holds everything the main thread did before
/// it slept again: the sources and timers, AppKit's display cycle and Core Animation's commit (both run in
/// `beforeWaiting` observers at orders near 2 000 000), and whatever ran outside the run loop when it returned to
/// NSApplication between events: a run-loop `exit` doesn't close a stretch, as the thread hasn't slept. Each closed
/// stretch gets a serial number; the sampler files its samples under it, so a stretch and its stacks can't disagree.
@MainActor final class StretchClock {
  struct Entry { var id: Int; var at: Double; var dur: Double; var cpu: Double }

  /// Times are ms since `t0` (CACurrentMediaTime seconds).
  let t0: Double
  private(set) var entries: [Entry] = []
  /// Called after each stretch closes (the recorder checks its waiters).
  var closed: (() -> Void)?
  /// Samples the stretches that pass its gate; swapping it mid-stretch drops the old one's open stretch.
  var sampler: MainThreadSampler? {
    didSet { if oldValue !== sampler { oldValue?.cancel(); if openAt != nil { sampler?.woke() } } }
  }
  private var observers: [CFRunLoopObserver] = []
  private var openAt: Double?
  private var openCpu = 0.0
  private var serial = 0

  init(t0: Double) { self.t0 = t0 }

  var attached: Bool { !observers.isEmpty }
  var isOpen: Bool { openAt != nil }
  /// The CPU ms of the stretch still open (the one the caller is in), nil while asleep.
  var openCpuMs: Double? { openAt == nil ? nil : KernelCounters.threadCpuMs() - openCpu }

  func attach() {
    guard observers.isEmpty else { return }
    let open = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [unowned self] _, _ in
      MainActor.assumeIsolated { self.open() }
    }!
    let close = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [unowned self] _, _ in
      MainActor.assumeIsolated { self.close() }
    }!
    for o in [open, close] { CFRunLoopAddObserver(CFRunLoopGetMain(), o, CFRunLoopMode.commonModes) }
    observers = [open, close]
  }

  /// Removes the observers; a stretch still open is closed where it stands.
  func detach() {
    for o in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, CFRunLoopMode.commonModes) }
    observers = []
    close()
  }

  func now() -> Double { (CACurrentMediaTime() - t0) * 1000 }

  private func open() {
    // A nested run loop's wake-up inside an open stretch can't happen (it slept, which closed it), but be safe.
    if openAt != nil { close() }
    openAt = now(); openCpu = KernelCounters.threadCpuMs()
    sampler?.woke()
  }

  private func close() {
    guard let at = openAt else { return }
    serial += 1
    sampler?.slept(stretch: serial)
    entries.append(Entry(id: serial, at: at, dur: now() - at, cpu: KernelCounters.threadCpuMs() - openCpu))
    openAt = nil
    closed?()
  }
}
#endif
