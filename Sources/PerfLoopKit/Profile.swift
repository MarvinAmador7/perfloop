import Foundation

// `perfloop.profile/2` (SCHEMAS.md §4): one scenario recorded under xctrace, summarised into what an agent reads: the
// main thread's call tree (whole recording, inside the `step` signposts, and per step), ms per step, the compositor's
// hitches and Instruments' potential hangs, the SwiftUI template's tables when it recorded any, and the in-process result
// of the same run. PerfLoopHost's `profile` verb records and writes it; `diff` compares two (Diff.swift). Pure: it is
// built from exported tables, so it builds and tests on Linux.

public let profileSchema = "perfloop.profile/2"

public struct ProfileDoc: Codable, Sendable, Equatable {
  public var schema = profileSchema
  /// The Instruments template's name ("Time Profiler", "Animation Hitches", "SwiftUI").
  public var template: String
  /// Where the trace was written. A trace holds the recorded process's environment: `traceKept` false means it was
  /// deleted once its tables were exported (the default), and this path no longer exists.
  public var trace: String?
  public var traceKept: Bool?
  public var scenario: String
  public var fixture: String
  /// The recorded process's name (the bench executable's): its binary's frames are "ours".
  public var process: String
  public var durationS: Double
  /// The bench that was recorded (its build stamp): what `diff` checks provenance against.
  public var build: Build?
  /// The OS build the trace was recorded on ("27.0.1 (26A434)"): symbols may not line up across OS builds.
  public var os: String?
  public var model: String?
  public var knobs: [String: String]?
  /// Always true: a profiled run's numbers never feed an objective.
  public var profiled: Bool?
  public var hitches: HitchSummary?
  public var swiftUI: SwiftUIProfile?
  /// Signposts in the recording, by name.
  public var signposts: [String: Int]?
  /// The steps the `step` signposts marked.
  public var steps: [StepInterval]?
  /// Main thread, whole recording, v = samples.
  public var tree: CallTree?
  /// Main thread, samples inside steps only (what `diff` compares).
  public var treeInSteps: CallTree?
  public var treePerStep: [StepTree]?
  /// Main-thread ms per step: samples inside steps × sampleIntervalMs ÷ steps.
  public var msPerStep: Double?
  public var sampleIntervalMs: Double?
  public var stepsCovered: Int?
  /// Steps the in-process result ran.
  public var stepsExpected: Int?
  /// The in-process result of the same run (`perfloop.result/2`, with `profiled: true`), as written.
  public var inProcess: JSONValue?
  public var notes: [String]

  public init(template: String, trace: String?, scenario: String, fixture: String, process: String, durationS: Double) {
    self.template = template; self.trace = trace; self.scenario = scenario; self.fixture = fixture; self.process = process; self.durationS = durationS
    profiled = true; notes = []
  }

  /// The templates a `profile` verb records, by the name it takes.
  public static let templates: [String: String] = ["time": "Time Profiler", "hitches": "Animation Hitches", "swiftui": "SwiftUI"]

  /// Steps the in-process result says it ran (every rep's).
  public var inProcessSteps: Int? {
    guard let reps = inProcess?["reps"]?.array else { return nil }
    return reps.reduce(0) { $0 + ($1["steps"]?.array?.count ?? 0) }
  }

  /// Adds the call trees from the time-profile table and, when present, the signpost table. Trees are pruned for the
  /// JSON: the recording's and the in-steps tree at 1/500 of their samples, each step's at 1/50 of its own (never below
  /// 3 samples).
  public mutating func addCallTrees(timeProfile t: XCTable, signposts: XCTable?, process: String?) {
    let s = MainThreadSamples(timeProfile: t, process: process)
    let steps = signposts.map { StepInterval.fromSignposts($0) } ?? []
    let trees = StepTrees(samples: s, steps: steps)
    self.steps = steps
    sampleIntervalMs = trees.sampleIntervalMs
    tree = trees.whole.pruned(minSamples: max(3, trees.whole.v / 500))
    treeInSteps = steps.isEmpty ? nil : trees.inSteps.pruned(minSamples: max(3, trees.inSteps.v / 500))
    treePerStep = steps.isEmpty ? nil : zip(steps, trees.perStep).map { StepTree(step: $0.name, tree: $1.pruned(minSamples: max(3, $1.v / 50))) }
    msPerStep = trees.msPerStep
    stepsCovered = steps.count
    stepsExpected = inProcessSteps
    if s.count == 0 { notes.append("the time profile has no main-thread samples of \(process ?? "the process")") }
    if steps.isEmpty { notes.append("no `step` signposts in the trace: the call tree covers the whole recording, not steps") }
    if let e = stepsExpected, e != steps.count, !steps.isEmpty { notes.append("signposts cover \(steps.count) of the \(e) steps the in-process result ran") }
  }

  /// Signposts counted by name.
  public mutating func addSignposts(_ t: XCTable) {
    var c: [String: Int] = [:]
    for r in t.rows { c[r["name"]?.attrs["fmt"] ?? r["name"]?.text ?? "?", default: 0] += 1 }
    signposts = c
  }

  /// The profile as text: hitches, hangs, the SwiftUI tables, the call tree, the notes.
  public var text: String {
    var o = ["profile \(scenario) on \(fixture) · \(template) · \(Int(durationS)) s · \(build?.line ?? "unstamped")"]
    o.append(traceKept == true ? "trace: \(trace ?? "?") (holds the recorded process's environment: never commit or share it)" : "trace: deleted after export (--keep-trace keeps it)")
    if let h = hitches {
      if h.hitches > 0 || template == "Animation Hitches" {
        o.append("hitches: \(h.hitches) (total \(h.totalMs) ms, max \(h.maxMs) ms, ≥16 ms: \(h.over16Ms))")
        for (k, v) in h.causes.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) { o.append("  \(v)× \(k)") }
      }
      if !h.potentialHangsMs.isEmpty { o.append("potential hangs (ms): \(h.potentialHangsMs.suffix(10).map { String($0) }.joined(separator: ", "))") }
    }
    if let s = swiftUI { o += s.lines }
    if let sp = signposts { o.append("signposts: " + sp.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: " ")) }
    if tree != nil { o.append(Explain.callTreeText(self)) }
    for n in notes { o.append("note: " + n) }
    return o.joined(separator: "\n")
  }
}

extension Diff {
  /// One side of a diff from a profile document's trees: the in-steps tree per step when it has steps (`per` "step"),
  /// else the whole recording ÷ the in-process steps (or as one run). nil when the profile has no call tree.
  public static func input(profile p: ProfileDoc, path: String, per: String = "step") -> DiffInput? {
    let build = p.build.map { DiffBuild(hash: $0.hash, commit: $0.commit, dirty: $0.dirty, stamp: $0.stamp) }
    if per == "step", let steps = p.steps, !steps.isEmpty, let t = p.treeInSteps ?? p.treePerStep.map({ CallTree.merge($0.map(\.tree), name: "main thread") }) {
      let side = DiffSide(profile: path, trace: p.trace, build: build, os: p.os, steps: steps.count, stepSource: steps[0].source, samples: p.tree?.v ?? t.v,
                          sampleIntervalMs: p.sampleIntervalMs ?? 1)
      return DiffInput(side: side, tree: t, notes: ["trees from the profile JSON (pruned when written)"])
    }
    guard let t = p.tree else { return nil }
    let ips = p.stepsExpected ?? p.inProcessSteps
    let n = per == "run" ? 1 : max(1, ips ?? 1)
    let side = DiffSide(profile: path, trace: p.trace, build: build, os: p.os, steps: n, stepSource: per == "run" ? "run" : ips == nil ? "none" : "inProcess",
                        samples: t.v, sampleIntervalMs: p.sampleIntervalMs ?? 1)
    return DiffInput(side: side, tree: t, notes: per == "run" ? [] : ["no step signposts: the whole recording ÷ \(n) in-process steps (settling and idle time included)"])
  }
}
