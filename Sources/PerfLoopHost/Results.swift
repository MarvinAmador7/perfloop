import Foundation
import PerfLoopKit
import PerfLoopProbe

// What a PerfLoopHost bench prints for `run --json`: `perfloop.result/2` (SCHEMAS.md §3), with the field names of
// `deskbench.result/1` so the runner (`PerfLoopKit.Readings`) reads both the same way. Pure arithmetic over a rep's raw
// timeline (display-link ticks, main-thread stretches, probe bodies), so it is tested without a window.

public let hostResultSchema = "perfloop.result/2"

/// Frame timing from the display link while a step ran. An interval longer than 1.5 × the steady frame is late; the
/// time it was held past its vsync is hitch time, and hitch time per second (ms/s) is the rate-invariant number.
public struct FrameStats: Codable, Sendable, Equatable {
  public var ticks: Int
  public var nominalHz: Double
  /// The rate the display ran at: the fastest quartile of intervals, snapped to a panel rate (ProMotion idles low).
  public var steadyHz: Double
  public var p50Ms: Double
  public var p95Ms: Double
  public var maxMs: Double
  public var late: Int
  public var hitchTimeMs: Double
  public var hitchTimeRatioMsPerS: Double

  public init(intervalsMs xs: [Double], nominalHz hz: Double) {
    ticks = xs.count; nominalHz = hz
    p50Ms = Stats.round(Stats.median(xs), 2); p95Ms = Stats.round(Stats.percentile(xs, 95), 2); maxMs = Stats.round(xs.max() ?? 0, 2)
    let p25 = Stats.percentile(xs, 25)
    let rates: [Double] = [24, 30, 40, 48, 60, 80, 90, 120].filter { $0 <= hz + 0.5 }
    steadyHz = xs.isEmpty || p25 <= 0 ? hz : rates.min { abs(1000 / $0 - p25) < abs(1000 / $1 - p25) } ?? hz
    let steady = 1000 / steadyHz
    let lateOnes = xs.filter { $0 > steady * 1.5 }
    late = lateOnes.count
    let hitch = lateOnes.reduce(0) { $0 + $1 - steady }, span = xs.reduce(0, +)
    hitchTimeMs = Stats.round(hitch, 2); hitchTimeRatioMsPerS = span > 0 ? Stats.round(hitch / span * 1000, 2) : 0
  }
}

/// What the main thread did between sleeps (each run-loop wake-up is one stretch).
public struct MainThreadStats: Codable, Sendable, Equatable {
  public var stretches: Int
  public var busyMs: Double
  public var cpuMs: Double
  public var longestMs: Double
  public var over8: Int
  public var over16: Int
  public var over33: Int
  public var over100: Int
  public init(stretches xs: [StretchSample]) {
    let d = xs.map(\.durationMs)
    stretches = xs.count; busyMs = Stats.round(d.reduce(0, +), 1); cpuMs = Stats.round(xs.map(\.cpuMs).reduce(0, +), 1)
    longestMs = Stats.round(d.max() ?? 0, 2)
    over8 = d.filter { $0 > 8.4 }.count; over16 = d.filter { $0 > 16.7 }.count; over33 = d.filter { $0 > 33.4 }.count; over100 = d.filter { $0 > 100 }.count
  }
}

/// One main-thread stretch as the clock recorded it. Times are ms since the rep's clock started.
public struct StretchSample: Sendable, Equatable {
  public var id: Int
  public var atMs: Double
  public var durationMs: Double
  public var cpuMs: Double
  public init(id: Int, atMs: Double, durationMs: Double, cpuMs: Double) { self.id = id; self.atMs = atMs; self.durationMs = durationMs; self.cpuMs = cpuMs }
}

/// A body the probe saw (`Probe.body`).
public struct BodySample: Sendable, Equatable {
  public var atMs: Double
  public var view: String
  public var id: String?
  public init(atMs: Double, view: String, id: String? = nil) { self.atMs = atMs; self.view = view; self.id = id }
}

/// A long stretch, labelled with the step it overlapped most, with the bodies inside it and, with the sampler on, its
/// stacks (`topOurs`: the app's frames, inclusive; `topFramework`: framework frames and the app frame they ran under).
public struct StretchRecord: Codable, Sendable, Equatable {
  public var step: String
  public var atMs: Double
  public var durationMs: Double
  public var cpuMs: Double
  public var bodies: [String: Int]
  public var causes: [Cause]?
  public var samples: Int?
  public var unsampled: String?
  public var stacks: StackTree?
  public var topOurs: [SymbolCount]?
  public var topFramework: [SymbolCount]?
  public var topSelf: [SymbolCount]?
}

/// A check a scenario makes beyond timing (`run.check`): the `checks` guard vetoes a candidate that fails one the
/// champion passes.
public struct CheckResult: Codable, Sendable, Equatable {
  public var name: String
  public var pass: Bool
  public var detail: String
  public init(name: String, pass: Bool, detail: String) { self.name = name; self.pass = pass; self.detail = detail }
}

/// One step of a scenario (`run.step`).
public struct StepRecord: Codable, Sendable, Equatable {
  public var name: String
  public var atMs: Double
  public var durationMs: Double
  /// From the action to the first frame after the step's `until` condition held (or after the action, without one).
  public var latencyMs: Double?
  /// From the action to the end of the last busy stretch before the window came to rest.
  public var settleMs: Double?
  /// false when the window was still busy at the step's timeout.
  public var settled: Bool
  public var frames: FrameStats
  public var mainThread: MainThreadStats
  public var bodies: [String: Int]
  public var notes: [String]
  /// Main-thread CPU ms from the action to the end of the step (thread_info).
  public var cpuMs: Double
  /// Instructions the process retired over the step (proc_pid_rusage); nil where the counters read zero (a VM).
  public var instructions: Int?
  public var causes: [Cause]?
}

/// Whether the window was where SwiftUI and AppKit draw promptly: active app, key, visible, not occluded. A rep in any
/// other state is untrusted and never decides (Acceptance).
public struct WindowState: Codable, Sendable, Equatable {
  public var appActive: Bool
  public var keyWindow: Bool
  public var visible: Bool
  public var occluded: Bool
  public var frame: [Double]
  public var backingScale: Double
  public init(appActive: Bool, keyWindow: Bool, visible: Bool, occluded: Bool, frame: [Double], backingScale: Double) {
    self.appActive = appActive; self.keyWindow = keyWindow; self.visible = visible; self.occluded = occluded; self.frame = frame; self.backingScale = backingScale
  }
  public var trustworthy: Bool { appActive && keyWindow && visible && !occluded }
}

public struct RepRecord: Codable, Sendable, Equatable {
  public var index: Int
  public var steps: [StepRecord]
  /// Over the steps (window set-up excluded).
  public var frames: FrameStats
  public var mainThread: MainThreadStats
  public var bodies: [String: Int]
  public var checks: [CheckResult]
  /// The correctness guards the run was asked for (`PERFLOOP_GUARDS`), judged after the rep.
  public var guards: [GuardResult]?
  public var worstStretches: [StretchRecord]
  public var window: WindowState?
  /// Σ steps' cpuMs / steps: the default objective.
  public var cpuMsPerStep: Double?
  public var instructionsPerStep: Double?
  public var notes: [String]
}

public struct Objective: Codable, Sendable, Equatable {
  public var name: String
  public var value: Double?
  public var dist: Dist?
}

public struct ResultSummary: Codable, Sendable, Equatable {
  public var reps: Int
  public var objective: Objective
  public var mainThreadCpuMsPerStep: Dist
  public var instructionsPerStep: Dist?
  public var latencyMs: Dist?
  public var hitchTimeRatioMsPerS: Dist
  public var longestStretchMs: Dist
  public var steadyHz: Dist
  public var lateFrames: Dist
  public var checksFailed: [String]
  public var guardsFailed: [String]
}

public struct ToolInfo: Codable, Sendable, Equatable {
  public var name: String
  public var version: String
  public var configuration: String
  public var commit: String?
  public var build: Build
}

public struct HostResult: Codable, Sendable, Equatable {
  public var schema = hostResultSchema
  public var tool: ToolInfo
  public var app: String
  public var adapter: String
  public var scenario: String
  public var fixture: String
  /// The scenario's parameters as run, and `knobs`: the full knob vector, defaults included.
  public var params: [String: JSONValue]
  public var profiled = false
  public var runner: String?
  public var startedAt: String
  public var reps: [RepRecord]
  public var summary: ResultSummary
  /// pass | fail (a check, guard or budget) | untrusted (the window wasn't active: rerun).
  public var verdict: String
  public var exitCode: Int
  public var notes: [String]
}

/// A rep's raw record: what the recorder collected while the scenario ran. `Timeline` turns it into steps.
public struct Timeline: Sendable {
  public var nominalHz: Double
  public var ticks: [Double] = []
  public var stretches: [StretchSample] = []
  public var bodies: [BodySample] = []
  public init(nominalHz: Double) { self.nominalHz = nominalHz }

  /// The display-link intervals whose ticks fall in (a, b].
  public func intervals(from a: Double, to b: Double) -> [Double] {
    var out: [Double] = []
    var prev: Double?
    for t in ticks {
      if t > b { break }
      if let p = prev, t > a { out.append(t - p) }
      prev = t
    }
    return out
  }

  /// Stretches that overlap [a, b): a step's action runs inside a stretch that opened before it.
  public func stretches(from a: Double, to b: Double) -> [StretchSample] { stretches.filter { $0.atMs + $0.durationMs > a && $0.atMs < b } }

  public func bodyCounts(from a: Double, to b: Double) -> [String: Int] {
    bodies.filter { $0.atMs >= a && $0.atMs <= b }.reduce(into: [:]) { $0[$1.view, default: 0] += 1 }
  }

  /// The step's record from its measured edges.
  public func step(name: String, at: Double, end: Double, latencyMs: Double?, settleMs: Double?, settled: Bool, cpuMs: Double, instructions: Int?,
                   notes: [String] = [], causes: [Cause]? = nil) -> StepRecord {
    StepRecord(name: name, atMs: Stats.round(at, 2), durationMs: Stats.round(end - at, 2), latencyMs: latencyMs.map { Stats.round($0, 2) },
               settleMs: settleMs.map { Stats.round($0, 2) }, settled: settled,
               frames: FrameStats(intervalsMs: intervals(from: at, to: end), nominalHz: nominalHz),
               mainThread: MainThreadStats(stretches: stretches(from: at, to: end)), bodies: bodyCounts(from: at, to: end), notes: notes,
               cpuMs: Stats.round(cpuMs, 3), instructions: instructions, causes: causes)
  }

  /// Which step a stretch belongs to: the one it overlaps most; between steps "after <step>"; before the first, set-up.
  public static func label(at: Double, dur: Double, steps: [StepRecord]) -> String {
    let end = at + dur
    let overlaps = steps.map { ($0.name, min(end, $0.atMs + $0.durationMs) - max(at, $0.atMs)) }.filter { $0.1 > 0 }
    if let best = overlaps.max(by: { $0.1 < $1.1 }) { return best.0 }
    if let prev = steps.last(where: { $0.atMs + $0.durationMs <= at + 0.1 }) { return "after \(prev.name)" }
    return steps.first.map { "before \($0.name) (setup)" } ?? "the scenario"
  }

  /// The rep's record: totals over the steps' span, the `count` longest stretches inside it.
  public func rep(index: Int, steps: [StepRecord], checks: [CheckResult], guards: [GuardResult]?, window: WindowState?, notes: [String] = [],
                  worst count: Int = 3, annotate: (inout StretchRecord, StretchSample) -> Void = { _, _ in }) -> RepRecord {
    let a = steps.first?.atMs ?? 0, b = steps.last.map { $0.atMs + $0.durationMs } ?? 0
    let inside = stretches(from: a, to: b)
    let worst = inside.sorted { $0.durationMs > $1.durationMs }.prefix(count).map { s -> StretchRecord in
      var r = StretchRecord(step: Self.label(at: s.atMs, dur: s.durationMs, steps: steps), atMs: Stats.round(s.atMs, 2), durationMs: Stats.round(s.durationMs, 2),
                            cpuMs: Stats.round(s.cpuMs, 2), bodies: bodyCounts(from: s.atMs, to: s.atMs + s.durationMs))
      annotate(&r, s)
      return r
    }
    let n = Double(max(steps.count, 1))
    let ins = steps.compactMap(\.instructions)
    return RepRecord(index: index, steps: steps, frames: FrameStats(intervalsMs: intervals(from: a, to: b), nominalHz: nominalHz),
                     mainThread: MainThreadStats(stretches: inside), bodies: bodyCounts(from: a, to: b), checks: checks, guards: guards,
                     worstStretches: Array(worst), window: window,
                     cpuMsPerStep: steps.isEmpty ? nil : Stats.round(steps.map(\.cpuMs).reduce(0, +) / n, 3),
                     instructionsPerStep: ins.count == steps.count && !ins.isEmpty && ins.reduce(0, +) > 0 ? (Double(ins.reduce(0, +)) / n).rounded() : nil,
                     notes: notes)
  }
}

extension ResultSummary {
  /// Medians across reps; the objective is the scenario's (`metric`).
  public init(reps rs: [RepRecord], metric: String) {
    func dist(_ xs: [Double]) -> Dist { Dist(xs) }
    let lat = rs.compactMap { r -> Double? in let xs = r.steps.compactMap(\.latencyMs); return xs.isEmpty ? nil : Stats.median(xs) }
    let ins = rs.compactMap(\.instructionsPerStep)
    reps = rs.count
    mainThreadCpuMsPerStep = dist(rs.compactMap(\.cpuMsPerStep))
    instructionsPerStep = ins.count == rs.count && !ins.isEmpty ? dist(ins) : nil
    latencyMs = lat.isEmpty ? nil : dist(lat)
    hitchTimeRatioMsPerS = dist(rs.map(\.frames.hitchTimeRatioMsPerS))
    longestStretchMs = dist(rs.map(\.mainThread.longestMs))
    steadyHz = dist(rs.map(\.frames.steadyHz)); lateFrames = dist(rs.map { Double($0.frames.late) })
    checksFailed = Array(Set(rs.flatMap { $0.checks.filter { !$0.pass }.map(\.name) })).sorted()
    guardsFailed = Array(Set(rs.flatMap { ($0.guards ?? []).filter { !$0.pass }.map(\.name) })).sorted()
    let d: Dist? = switch metric {
    case "instructionsPerStep": instructionsPerStep
    case "latencyMs": latencyMs
    case "hitchTimeRatioMsPerS": hitchTimeRatioMsPerS
    default: mainThreadCpuMsPerStep
    }
    objective = Objective(name: metric, value: d.flatMap { $0.n > 0 ? $0.median : nil }, dist: d)
  }
}
