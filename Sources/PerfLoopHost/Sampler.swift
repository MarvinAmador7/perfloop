#if os(macOS)
import Darwin
import Foundation
import QuartzCore
import PerfLoopKit

/// The sampler's settings: on by default at 1 kHz, sampling a stretch once it has lasted 4 ms. A bench takes them from
/// `--sampler on|off`, `--sample-hz N`, `--sample-gate-ms N` (or `PERFLOOP_SAMPLER=off` in the environment).
public struct SamplerConfig: Sendable {
  public var enabled = true
  public var hz: Double = 1000
  public var gateMs: Double = 4
  public init(enabled: Bool = true, hz: Double = 1000, gateMs: Double = 4) { self.enabled = enabled; self.hz = hz; self.gateMs = gateMs }
}

/// The in-process main-thread sampler (CAPABILITIES.md C1; ported from deskbench's Sampler.swift): a background thread that, while the main thread is awake and has
/// been for `gateMs`, suspends it every 1/hz s, reads its registers, walks its frame pointers, resumes it and keeps the
/// return addresses. Short wake-ups and sleep cost nothing but two run-loop observer callouts: the thread sleeps on a
/// semaphore until a wake-up opens, then on a deadline until the gate passes.
///
/// Safety, the rule from Chromium's Mac sampler: between `thread_suspend` and `thread_resume` nothing allocates, logs or
/// takes a lock the main thread could hold. The only lock (an `os_unfair_lock` for the gate and counters) is taken by
/// the sampler *before* it suspends and released after it resumes, so the main thread can never be holding it while
/// suspended; the stack is written into a buffer allocated up front, by index. The walk stays inside the main thread's
/// stack bounds, stops on a misaligned or non-increasing frame pointer, and is capped in depth.
///
/// Stretch edges: the sampler has no observers of its own. `StretchClock` opens and closes it (`woke`, `slept`) at the
/// same moments it opens and closes the harness's stretch, and the samples are filed under that stretch's serial
/// number, so every stretch longer than the gate has its stacks. A closed stretch's samples are copied out on the main
/// thread then; symbolisation (dladdr) happens only when a result asks for them, after the rep.
@MainActor public final class MainThreadSampler {
  let config: SamplerConfig
  static let supported: Bool = {
    #if arch(arm64)
    return true
    #else
    return false
    #endif
  }()

  /// One sampled stretch: the clock's serial number for it, its times (CACurrentMediaTime seconds) and where its
  /// words are in `arena`.
  struct Span { var stretch: Int; var wake: Double; var sleep: Double; var samples: Int; var start: Int; var words: Int }
  private(set) var spans: [Span] = []
  private var arena: [UInt] = []
  private var wakeTime = 0.0
  private let raw: Raw
  private let wakeSem = DispatchSemaphore(value: 0)
  private let doneSem = DispatchSemaphore(value: 0)
  private var thread: Thread?
  private var symbolCache: [UInt: StackFrame] = [:]

  init(config: SamplerConfig) {
    self.config = config
    precondition(Thread.isMainThread, "the sampler is made on the main thread, which it samples")
    let main = pthread_self()
    let top = UInt(bitPattern: pthread_get_stackaddr_np(main))
    let size = UInt(pthread_get_stacksize_np(main))
    var tb = mach_timebase_info(); mach_timebase_info(&tb)
    let ticksPerNs = Double(tb.denom) / Double(tb.numer)   // mach_absolute_time ticks at 24 MHz on Apple silicon
    let state = UnsafeMutablePointer<State>.allocate(capacity: 1); state.initialize(to: State())
    let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1); lock.initialize(to: os_unfair_lock())
    let hist = UnsafeMutablePointer<Int>.allocate(capacity: Raw.buckets); hist.initialize(repeating: 0, count: Raw.buckets)
    let cap = 1 << 18   // 256 K words (2 MB): ~2.5 s of 100-deep stacks at 1 kHz in one stretch
    let buf = UnsafeMutablePointer<UInt>.allocate(capacity: cap); buf.initialize(repeating: 0, count: cap)
    raw = Raw(state: state, lock: lock, hist: hist, buf: buf, capacity: cap, target: pthread_mach_thread_np(main), stackLo: top - size, stackHi: top,
              maxDepth: 128, gateTicks: UInt64(config.gateMs * 1e6 * ticksPerNs), intervalTicks: UInt64(1e9 / config.hz * ticksPerNs), nsPerTick: 1 / ticksPerNs)
  }

  // MARK: lifecycle

  /// Starts the sampling thread (idempotent).
  func start() {
    guard Self.supported, thread == nil else { return }
    let ctx = Context(raw: raw, wake: wakeSem, done: doneSem)
    let t = Thread { MainThreadSampler.loop(ctx) }
    t.name = "perfloop.sampler"; t.qualityOfService = .userInteractive
    t.start()
    thread = t
  }

  /// Stops the thread and waits for it (the buffers stay allocated: a late sample can never write to freed memory).
  func stop() {
    cancel()
    guard thread != nil else { return }
    os_unfair_lock_lock(raw.lock); raw.state.pointee.running = false; os_unfair_lock_unlock(raw.lock)
    wakeSem.signal()
    _ = doneSem.wait(timeout: .now() + 1)
    thread = nil
  }

  // MARK: the gate (main thread, called by StretchClock)

  /// A stretch opened: sample it once it passes the gate.
  func woke() {
    start()
    let t = mach_absolute_time()
    os_unfair_lock_lock(raw.lock)
    let s = raw.state
    s.pointee.generation &+= 1; s.pointee.openAt = t; s.pointee.head = 0; s.pointee.count = 0
    let wasAsleep = s.pointee.sleeping; s.pointee.sleeping = false
    os_unfair_lock_unlock(raw.lock)
    if wasAsleep { wakeSem.signal() }
    wakeTime = CACurrentMediaTime()
  }

  /// The stretch closed: keep its samples under the clock's serial number for it (nil: drop them).
  func slept(stretch: Int?) {
    os_unfair_lock_lock(raw.lock)
    let s = raw.state
    let open = s.pointee.openAt != 0
    s.pointee.openAt = 0
    let n = s.pointee.count, words = s.pointee.head
    os_unfair_lock_unlock(raw.lock)
    guard open, n > 0, let stretch else { return }
    // The sampler won't write again before the next wake-up, which this thread opens.
    spans.append(Span(stretch: stretch, wake: wakeTime, sleep: CACurrentMediaTime(), samples: n, start: arena.count, words: words))
    arena.append(contentsOf: UnsafeBufferPointer(start: raw.buf, count: words))
  }

  /// Stops sampling the open stretch, if any, and drops what it had.
  func cancel() { slept(stretch: nil) }

  // MARK: results (main thread, after a rep)

  /// The samples of the clock's stretch `id`, if it had any.
  func span(stretch id: Int) -> Span? {
    var lo = 0, hi = spans.count
    while lo < hi { let mid = (lo + hi) / 2; if spans[mid].stretch < id { lo = mid + 1 } else { hi = mid } }
    return lo < spans.count && spans[lo].stretch == id ? spans[lo] : nil
  }

  /// Forgets the spans of stretches before `id`: what a finished rep no longer needs.
  func discard(beforeStretch id: Int) {
    guard let i = spans.firstIndex(where: { $0.stretch >= id }) else { spans = []; arena = []; return }
    guard i > 0 else { return }
    let cut = spans[i].start
    spans.removeFirst(i)
    arena.removeFirst(cut)
    for j in spans.indices { spans[j].start -= cut }
  }

  /// The span's stacks, leaf first, symbolised.
  func stacks(_ s: Span) -> [[StackFrame]] {
    var out: [[StackFrame]] = []
    out.reserveCapacity(s.samples)
    var i = s.start
    let end = s.start + s.words
    while i < end {
      let n = Int(arena[i])
      guard n > 0, i + n < end else { break }
      var frames: [StackFrame] = []
      frames.reserveCapacity(n)
      for k in 0..<n {
        let a = arena[i + 1 + k]
        if a == 0 { continue }   // no link register
        // Slot 0 is the pc; the others are return addresses, which point just past the call: look up a - 1.
        frames.append(symbol(k == 0 ? a : a - 1))
      }
      out.append(frames)
      i += n + 1
    }
    return out
  }

  func profile(_ s: Span) -> StackProfile { StackProfile(stacks: stacks(s)) }

  private func symbol(_ a: UInt) -> StackFrame {
    if let f = symbolCache[a] { return f }
    var info = Dl_info()
    var f = StackFrame("?")
    if dladdr(UnsafeRawPointer(bitPattern: a), &info) != 0 {
      let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent }
      let ours = info.dli_fbase == UnsafeMutableRawPointer(mutating: #dsohandle)
      if let s = info.dli_sname { f = StackFrame(Symbols.name(String(cString: s), image: image), ours: ours) }
      else { f = StackFrame("(\(image ?? "?"))", ours: ours) }
    }
    symbolCache[a] = f
    return f
  }

  /// Fills the sampler's fields of a worst stretch from the samples filed under its serial number; without any, says
  /// why: shorter than the gate, or past it with the sampler thread not scheduled in time (a loaded machine).
  func annotate(_ w: inout StretchRecord, stretch id: Int) {
    guard let s = span(stretch: id) else { w.samples = 0; w.unsampled = w.durationMs < config.gateMs + 1000 / config.hz ? "gate" : "missed"; return }
    let p = profile(s)
    w.samples = p.samples; w.stacks = p.tree; w.topOurs = p.ours; w.topFramework = p.framework; w.topSelf = p.selfTop
  }

  // MARK: costs

  struct Mark { var counters: Counters; var hist: [Int]; var samplerCpuMs: Double; var mainCpuMs: Double; var spans: Int; var lastWake: Double }
  struct Counters { var samples = 0, failures = 0, truncated = 0; var stallTicks: UInt64 = 0, maxTicks: UInt64 = 0 }

  func mark() -> Mark {
    os_unfair_lock_lock(raw.lock)
    let s = raw.state.pointee
    let c = Counters(samples: s.samples, failures: s.failures, truncated: s.truncated, stallTicks: s.stallTicks, maxTicks: s.maxTicks)
    let h = Array(UnsafeBufferPointer(start: raw.hist, count: Raw.buckets))
    let port = s.samplerThread
    os_unfair_lock_unlock(raw.lock)
    return Mark(counters: c, hist: h, samplerCpuMs: port == 0 ? 0 : KernelCounters.threadCpuMs(port), mainCpuMs: KernelCounters.threadCpuMs(), spans: spans.count, lastWake: spans.last?.wake ?? 0)
  }

  /// What the sampler did since `m`. The max cost is over the sampler's life (it is a high-water mark).
  func stats(since m: Mark) -> SamplerStats {
    let now = mark()
    let hist = zip(now.hist, m.hist).map { $0 - $1 }
    let sampled = spans.filter { $0.wake > m.lastWake }.count
    let c = now.counters, b = m.counters
    let us = raw.nsPerTick / 1000
    return SamplerStats(hz: config.hz, gateMs: config.gateMs, samples: c.samples - b.samples, sampledStretches: sampled, failures: c.failures - b.failures,
                        truncated: c.truncated - b.truncated, stallMs: Double(c.stallTicks - b.stallTicks) * us / 1000,
                        costP50Us: SamplerStats.percentile(hist, 50), costP95Us: SamplerStats.percentile(hist, 95), costMaxUs: Double(c.maxTicks) * us,
                        samplerCpuMs: now.samplerCpuMs - m.samplerCpuMs, mainCpuMs: now.mainCpuMs - m.mainCpuMs)
  }

  // MARK: the sampling thread

  /// Shared by the main thread (gate) and the sampling thread; every field is read and written under `Raw.lock`.
  struct State {
    var running = true
    var sleeping = false
    var generation: UInt64 = 0
    /// mach ticks at the wake-up; 0 while the main thread sleeps.
    var openAt: UInt64 = 0
    /// Words written into the buffer for the open stretch, and its samples.
    var head = 0
    var count = 0
    var samples = 0
    var failures = 0
    var truncated = 0
    var stallTicks: UInt64 = 0
    var maxTicks: UInt64 = 0
    var samplerThread: mach_port_t = 0
  }

  /// Everything the sampling thread touches: plain pointers and numbers, no references to count.
  struct Raw: @unchecked Sendable {
    static let buckets = 256
    var state: UnsafeMutablePointer<State>
    var lock: UnsafeMutablePointer<os_unfair_lock>
    var hist: UnsafeMutablePointer<Int>
    var buf: UnsafeMutablePointer<UInt>
    var capacity: Int
    var target: thread_act_t
    var stackLo: UInt
    var stackHi: UInt
    var maxDepth: Int
    var gateTicks: UInt64
    var intervalTicks: UInt64
    var nsPerTick: Double
  }

  struct Context: @unchecked Sendable { var raw: Raw; var wake: DispatchSemaphore; var done: DispatchSemaphore }

  nonisolated private static func loop(_ c: Context) {
    let r = c.raw
    os_unfair_lock_lock(r.lock); r.state.pointee.samplerThread = mach_thread_self(); os_unfair_lock_unlock(r.lock)
    outer: while true {
      os_unfair_lock_lock(r.lock)
      if !r.state.pointee.running { os_unfair_lock_unlock(r.lock); break }
      let open = r.state.pointee.openAt, gen = r.state.pointee.generation
      if open == 0 { r.state.pointee.sleeping = true; os_unfair_lock_unlock(r.lock); c.wake.wait(); continue }
      os_unfair_lock_unlock(r.lock)
      var next = open &+ r.gateTicks
      while true {
        if next > mach_absolute_time() { mach_wait_until(next) }
        os_unfair_lock_lock(r.lock)
        guard r.state.pointee.running, r.state.pointee.generation == gen, r.state.pointee.openAt != 0 else { os_unfair_lock_unlock(r.lock); continue outer }
        sampleOnce(r)
        os_unfair_lock_unlock(r.lock)
        next &+= r.intervalTicks
        let now = mach_absolute_time()
        if next < now { next = now }
      }
    }
    c.done.signal()
  }

  /// One sample, with `r.lock` held. Between suspend and resume: register reads, loads from the main thread's stack
  /// (bounds-checked) and stores into the preallocated buffer. Nothing else.
  nonisolated private static func sampleOnce(_ r: Raw) {
    #if arch(arm64)
    let s = r.state
    let head = s.pointee.head
    guard head + r.maxDepth + 3 <= r.capacity else { s.pointee.truncated += 1; return }
    // User addresses fit in 47 bits; the bits above can carry a pointer-authentication signature (return addresses
    // in arm64e system code) or the async-frame flag (bit 60 of a saved frame pointer).
    let mask: UInt = (1 << 47) - 1
    let out = r.buf + head + 1
    var n = 0
    let t0 = mach_absolute_time()
    guard thread_suspend(r.target) == KERN_SUCCESS else { s.pointee.failures += 1; return }
    var st = arm_thread_state64_t()
    var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &st) {
      $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(r.target, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count) }
    }
    if kr == KERN_SUCCESS {
      out[0] = UInt(st.__pc) & mask
      out[1] = UInt(st.__lr) & mask   // the caller, when the pc is in a function that hasn't pushed a frame
      n = 2
      var fp = UInt(st.__fp) & mask
      // The thread can't move while suspended, so its stack is stable: [fp] = the caller's fp, [fp + 8] = return address.
      while n < r.maxDepth + 2, fp >= r.stackLo, fp <= r.stackHi - 16, fp & 0x7 == 0 {
        let p = UnsafePointer<UInt>(bitPattern: fp)!
        let up = p[0] & mask, ret = p[1] & mask
        if ret == 0 { break }
        out[n] = ret; n += 1
        if up <= fp { break }   // stacks grow down: a caller's frame is above
        fp = up
      }
    }
    thread_resume(r.target)
    let dt = mach_absolute_time() &- t0
    guard kr == KERN_SUCCESS else { s.pointee.failures += 1; return }
    r.buf[head] = UInt(n)
    s.pointee.head = head + n + 1
    s.pointee.count += 1; s.pointee.samples += 1
    s.pointee.stallTicks &+= dt
    if dt > s.pointee.maxTicks { s.pointee.maxTicks = dt }
    let us = Int(Double(dt) * r.nsPerTick / 1000)
    r.hist[min(max(us, 0), Raw.buckets - 1)] += 1
    #endif
  }
}
#endif
