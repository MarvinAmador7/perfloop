import Foundation
#if canImport(Darwin)
import Darwin
#endif

// The quiet gate (CAPABILITIES.md C10): a rep starts on a machine that isn't busy with other work, or it says it didn't.
// Input idleness (IdleGate) says nobody is using the Mac; this says nothing else is eating its cores: another agent's
// `swift build`, a test run, a VM. The rule and the record are pure; `HostLoad` reads this machine.

/// A process the quiet gate saw using CPU (summed over processes of one name: twelve `swift-frontend`s are one line).
public struct BusyProcess: Codable, Sendable, Equatable {
  public var name: String
  /// Share of one core, % (ps's `pcpu`): 380 is nearly four cores.
  public var pct: Double
  public init(name: String, pct: Double) { self.name = name; self.pct = pct }
  public var line: String { "\(name) \(Int(pct.rounded())) %" }
}

/// What the quiet gate saw: how much of all the cores was busy over a short window, and the processes using them.
public struct LoadReading: Sendable, Equatable {
  /// Share of all cores busy over the sample (host CPU ticks), %; nil where it couldn't be read (Linux, a VM).
  public var busyPct: Double?
  /// Processes using ≥ 10 % of a core, and every build tool running at all; busiest first.
  public var processes: [BusyProcess]
  public init(busyPct: Double?, processes: [BusyProcess] = []) { self.busyPct = busyPct; self.processes = processes }

  /// Nothing could be read: the gate can't judge, so it doesn't wait.
  public var unknown: Bool { busyPct == nil && processes.isEmpty }
  /// Compilers, linkers and test runs among the processes (another agent's build is noise in every rep).
  public var builds: [String] { processes.map(\.name).filter(QuietGate.buildTools.contains) }

  /// The testing hook's keys, in the idle file (`idle=… locked=… load=35 busy=swift-frontend:98,clang:40`). Without
  /// `load=` and `busy=` the reading is unknown, so an idle file written before the quiet gate changes nothing.
  public init(text: String) {
    var d: [String: String] = [:]
    for part in text.split(whereSeparator: { $0 == " " || $0.isNewline }) {
      let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
      if kv.count == 2 { d[kv[0]] = kv[1] }
    }
    let ps = (d["busy"] ?? "").split(separator: ",").compactMap { p -> BusyProcess? in
      let f = p.split(separator: ":").map(String.init)
      return f.count == 2 ? Double(f[1]).map { BusyProcess(name: f[0].replacingOccurrences(of: "_", with: " "), pct: $0) } : nil
    }
    self.init(busyPct: d["load"].flatMap(Double.init), processes: ps)
  }
}

/// The rule: a rep starts when at most `maxLoadPct` of all cores is busy and no build tool runs. A busy machine is
/// waited for up to `timeout` seconds; then the rep runs anyway and is recorded as not quiet (or, with `require`, the
/// runner stops instead).
public struct QuietGate: Sendable, Equatable {
  /// DeskBench's quiet threshold, which held up on a busy shared Mac: between reps a quiet Mac sits well under it.
  public static let defaultMaxLoadPct = 30.0
  public static let defaultTimeout = 60.0
  public static let buildTools: Set<String> = ["swift-build", "swift-frontend", "swiftc", "swift-driver", "swift-test", "swift-package", "clang", "clang++",
                                               "ld", "ld64", "ld-prime", "xcodebuild", "xctest", "cargo", "rustc"]
  public var maxLoadPct: Double
  /// Seconds to wait for quiet before a rep (0: never wait, only record).
  public var timeout: Double
  /// Once a wait has timed out, later ones last at most this long until a rep starts quiet again: a machine that
  /// stayed busy for a whole timeout won't be quiet a few seconds later, and waiting the full time again only slows
  /// the stage.
  public var retryTimeout: Double
  /// `--require-quiet`: never start a rep on a busy machine; stop when the timeout passes.
  public var require: Bool
  public init(maxLoadPct: Double = QuietGate.defaultMaxLoadPct, timeout: Double = QuietGate.defaultTimeout, retryTimeout: Double = 10, require: Bool = false) {
    self.maxLoadPct = maxLoadPct; self.timeout = timeout; self.retryTimeout = retryTimeout; self.require = require
  }

  /// nil: quiet (or unknown). Otherwise why not, naming the busiest processes.
  public func busy(_ r: LoadReading) -> String? {
    var why: [String] = []
    if let p = r.busyPct, p > maxLoadPct { why.append("\(Int(p.rounded())) % of the cores busy (> \(Int(maxLoadPct)) %)") }
    let b = r.builds
    if !b.isEmpty { why.append("building: " + b.joined(separator: ", ")) }
    guard !why.isEmpty else { return nil }
    let top = r.processes.prefix(4)
    if !top.isEmpty { why.append("busiest: " + top.map(\.line).joined(separator: ", ")) }
    return why.joined(separator: "; ")
  }

  /// What a rep records: the reading it started on, after waiting `waited` seconds.
  public func state(_ r: LoadReading, waited: Double) -> MachineState {
    let why = busy(r)
    return MachineState(quiet: why == nil, busyPct: r.busyPct.map { Stats.round($0, 1) }, busy: r.processes.isEmpty ? nil : r.processes.prefix(6).map(\.line),
                        waitedS: Stats.round(waited, 1), why: why)
  }
}

/// The machine when a rep started, as the quiet gate saw it: kept on each side of a pair (`Side.machine`), so a rep
/// that ran on a busy machine is visible as such in the results.
public struct MachineState: Codable, Sendable, Equatable {
  /// false: the rep started on a busy machine (after waiting `waitedS`).
  public var quiet: Bool
  public var busyPct: Double?
  /// The busiest processes then, "swift-frontend 380 %".
  public var busy: [String]?
  public var waitedS: Double
  /// Why it wasn't quiet.
  public var why: String?
  public init(quiet: Bool, busyPct: Double? = nil, busy: [String]? = nil, waitedS: Double = 0, why: String? = nil) {
    self.quiet = quiet; self.busyPct = busyPct; self.busy = busy; self.waitedS = waitedS; self.why = why
  }
}

/// This machine's load: host CPU ticks over a short sample (macOS) and `ps` for the processes. Used by the local
/// runner's quiet gate and by PerfLoopHost's `run --quiet-check`.
public enum HostLoad {
  /// Blocks for `sample` seconds (the CPU share is measured over it). `exclude`: pids to leave out (ours).
  public static func read(sample: Double = 0.5, exclude: Set<Int32> = [ProcessInfo.processInfo.processIdentifier]) -> LoadReading {
    let pct = busyShare(over: sample)
    return LoadReading(busyPct: pct, processes: processes(exclude: exclude))
  }

  /// Share of all cores busy over `s` seconds, %; nil where the host's CPU ticks can't be read.
  public static func busyShare(over s: Double) -> Double? {
    #if canImport(Darwin)
    func ticks() -> (busy: Double, all: Double)? {
      var info = host_cpu_load_info()
      var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
      let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) } }
      guard r == KERN_SUCCESS else { return nil }
      let t = info.cpu_ticks   // user, system, idle, nice
      let user = Double(t.0), sys = Double(t.1), idle = Double(t.2), nice = Double(t.3)
      return (user + sys + nice, user + sys + idle + nice)
    }
    guard let a = ticks() else { return nil }
    Thread.sleep(forTimeInterval: s)
    guard let b = ticks(), b.all > a.all else { return nil }
    return (b.busy - a.busy) / (b.all - a.all) * 100
    #else
    return nil
    #endif
  }

  /// `ps -A -o pid=,pcpu=,comm=`, summed by name: ≥ 10 % of a core, or a build tool; busiest first.
  public static func processes(exclude: Set<Int32>) -> [BusyProcess] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-A", "-o", "pid=,pcpu=,comm="]
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [] }
    let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return parse(String(decoding: data, as: UTF8.self), exclude: exclude)
  }

  /// The parsing half of `processes`, for tests.
  public static func parse(_ text: String, exclude: Set<Int32> = []) -> [BusyProcess] {
    var sum: [String: Double] = [:]
    for line in text.split(separator: "\n") {
      let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
      guard f.count == 3, let pid = Int32(f[0]), let pct = Double(f[1]), !exclude.contains(pid) else { continue }
      let name = String(f[2].split(separator: "/").last ?? f[2]).trimmingCharacters(in: .whitespaces)
      if name == "ps" { continue }
      sum[name, default: 0] += pct
    }
    return sum.filter { $0.value >= 10 || QuietGate.buildTools.contains($0.key) }
      .map { BusyProcess(name: $0.key, pct: Stats.round($0.value, 1)) }
      .sorted { $0.pct != $1.pct ? $0.pct > $1.pct : $0.name < $1.name }
  }
}
