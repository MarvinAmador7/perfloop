import Foundation

// Call trees from a Time Profiler export (CAPABILITIES.md C2; ported from capcomd's deskbench): the main thread's samples
// folded root-first, per `step` signpost interval, so a trace answers "what did a step cost, and where" without anyone
// writing a parser (SCHEMAS.md: perfloop.profile/2). PerfLoopHost benches mark every `run.step` with a `step` signpost
// in the `dev.perfloop.bench` subsystem (`StepInterval.hostSubsystem`).

/// Symbol names as xctrace's trees and summaries show them (already demangled by Instruments).
public enum TraceSymbol {
  /// A symbol without its argument list, cut to 110 characters. Objective-C names keep their category and selector
  /// (`-[NSApplication(NSEventRouting) sendEvent:]`); C++ template arguments and a leading `(anonymous namespace)` are
  /// not mistaken for the argument list; `operator()` keeps its parentheses.
  public static func clean(_ s: String) -> String {
    let u = Array(s.utf8)
    var cut = u.count
    if u.count > 2, u[0] == UInt8(ascii: "-") || u[0] == UInt8(ascii: "+"), u[1] == UInt8(ascii: "[") {
      if let close = u.firstIndex(of: UInt8(ascii: "]")) { cut = close + 1 }
    } else {
      var i = 0, angle = 0
      // A leading parenthesised group, `(anonymous namespace)::…`, is part of the name.
      while i < u.count, u[i] == UInt8(ascii: "(") {
        var depth = 0
        while i < u.count { if u[i] == UInt8(ascii: "(") { depth += 1 } else if u[i] == UInt8(ascii: ")") { depth -= 1; if depth == 0 { i += 1; break } }; i += 1 }
      }
      while i < u.count {
        let c = u[i]
        if c == UInt8(ascii: "<") { angle += 1 }
        else if c == UInt8(ascii: ">"), angle > 0, i == 0 || u[i - 1] != UInt8(ascii: "-") { angle -= 1 }
        else if c == UInt8(ascii: "("), angle == 0, i > 0 {
          // `operator()` is a name, not an argument list.
          if i >= 8, String(decoding: u[(i - 8)..<i], as: UTF8.self) == "operator", i + 1 < u.count, u[i + 1] == UInt8(ascii: ")") { i += 2; continue }
          cut = i; break
        }
        i += 1
      }
    }
    var out = String(decoding: u[0..<cut], as: UTF8.self)
    while out.last == " " { out.removeLast() }
    if out.isEmpty { out = s }
    return String(out.prefix(110))
  }

  /// PerfLoopHost's own frames (the bench's run loop, the step driver): linked into the bench's binary, but not the app's
  /// code, so never "ours" and never what a framework subtree ran `under`.
  public static func isHarness(_ s: String) -> Bool {
    var n = Substring(s)
    for p in ["partial apply for ", "implicit closure #", "closure #"] where n.hasPrefix(p) {
      guard let r = n.range(of: " in ") else { break }
      n = n[r.upperBound...]
    }
    if n.hasPrefix("closure #"), let r = n.range(of: " in ") { n = n[r.upperBound...] }
    return harnessPrefixes.contains { n.hasPrefix($0) } || n == "completeTaskWithClosure"
  }
  static let harnessPrefixes = ["Bench.", "PerfLoopHost.", "Recorder.", "StretchClock.", "LaunchDelegate.", "MainThreadSampler.", "ProfileVerb.", "GestureReplay.",
                                "Run.step", "Run.show", "Run.settle", "Run.wait", "Run.sleep", "Run.swipe", "Run.replay"]

  /// Frames every stack is full of, and frames with no name: kept in the trees, never ranked as "the" cause.
  public static func isNoise(_ s: String) -> Bool {
    s == "<deduplicated_symbol>" || s.hasPrefix("0x") || noisePrefixes.contains { s.hasPrefix($0) }
  }
  static let noisePrefixes = ["objc_msgSend", "objc_retain", "objc_release", "objc_autorelease", "objc_storeStrong", "swift_retain", "swift_release",
                              "swift_bridgeObject", "swift_unknownObject", "swift_beginAccess", "swift_endAccess", "_swift_retain", "_swift_release",
                              "_platform_mem", "swift_isUniquelyReferenced", "swift_getGenericMetadata", "__swift_instantiate"]
}

/// A folded call tree, root-first: `n` the frame, `v` the samples under it (inclusive), `c` its callees heaviest
/// first. `o` is true for frames in the profiled process's own binary ("ours"). SCHEMAS.md §1 `tree`.
///
/// In JSON a run of frames that never branches (each the only callee of the one before, same samples, same `o`) is
/// written as one node whose `chain` lists the frames after `n`, so 100-deep SwiftUI stacks stay readable; decoding
/// expands it again, so in memory every node is one frame.
public struct CallTree: Codable, Sendable, Equatable {
  public var n: String
  public var v: Int
  public var o: Bool?
  public var c: [CallTree]
  public init(n: String, v: Int, o: Bool? = nil, c: [CallTree] = []) { self.n = n; self.v = v; self.o = o; self.c = c }

  enum CodingKeys: String, CodingKey { case n, v, o, c, chain }

  public init(from decoder: Decoder) throws {
    let k = try decoder.container(keyedBy: CodingKeys.self)
    n = try k.decode(String.self, forKey: .n); v = try k.decode(Int.self, forKey: .v); o = try k.decodeIfPresent(Bool.self, forKey: .o)
    c = try k.decodeIfPresent([CallTree].self, forKey: .c) ?? []
    for name in (try k.decodeIfPresent([String].self, forKey: .chain) ?? []).reversed() {
      c = [CallTree(n: name, v: v, o: o, c: c)]
    }
  }

  public func encode(to encoder: Encoder) throws {
    var k = encoder.container(keyedBy: CodingKeys.self)
    try k.encode(n, forKey: .n); try k.encode(v, forKey: .v); try k.encodeIfPresent(o, forKey: .o)
    var chain: [String] = [], end = self
    while end.c.count == 1, end.c[0].v == v, end.c[0].o == o { end = end.c[0]; chain.append(end.n) }
    if !chain.isEmpty { try k.encode(chain, forKey: .chain) }
    try k.encode(end.c, forKey: .c)
  }

  /// Without the callees lighter than `minSamples` (their samples stay in the parent's `v`).
  public func pruned(minSamples: Int) -> CallTree {
    CallTree(n: n, v: v, o: o, c: c.filter { $0.v >= minSamples }.map { $0.pruned(minSamples: minSamples) })
  }

  /// Trees summed node by node (same name under the same path), under a new root.
  public static func merge(_ trees: [CallTree], name: String) -> CallTree {
    var root = CallTree(n: name, v: 0)
    for t in trees { root.v += t.v; root.add(children: t.c) }
    return root
  }

  mutating func add(children: [CallTree]) {
    for k in children {
      if let i = c.firstIndex(where: { $0.n == k.n }) { c[i].v += k.v; c[i].add(children: k.c) } else { c.append(k) }
    }
    c.sort { ($0.v, $1.n) > ($1.v, $0.n) }
  }

  /// Samples whose stack has a frame matching `match`, each counted once (the topmost matching node of every path).
  public func samples(where match: (String) -> Bool) -> Int {
    match(n) ? v : c.reduce(0) { $0 + $1.samples(where: match) }
  }

  /// The first node, depth-first, whose name matches.
  public func first(where match: (String) -> Bool) -> CallTree? {
    if match(n) { return self }
    for k in c { if let f = k.first(where: match) { return f } }
    return nil
  }

  public var nodeCount: Int { 1 + c.reduce(0) { $0 + $1.nodeCount } }
}

/// Builds call trees from root-first stacks of interned symbols. Fast enough for 30 k samples of 100-frame stacks.
public struct CallTreeBuilder {
  var sym: [Int32] = [-1]
  var count: [Int] = [0]
  var kids: [[Int32: Int32]] = [[:]]
  public init() {}

  public var samples: Int { count[0] }

  public mutating func add(_ stack: [Int32]) {
    var node: Int32 = 0
    count[0] += 1
    for s in stack {
      if let k = kids[Int(node)][s] { node = k } else {
        let k = Int32(sym.count)
        sym.append(s); count.append(0); kids.append([:])
        kids[Int(node)][s] = k
        node = k
      }
      count[Int(node)] += 1
    }
  }

  /// The tree, callees heaviest first, nodes lighter than `minSamples` dropped.
  public func tree(root: String, names: [String], ours: [Bool], minSamples: Int = 1) -> CallTree {
    func make(_ i: Int32) -> CallTree {
      let s = sym[Int(i)]
      let children = kids[Int(i)].values.filter { count[Int($0)] >= minSamples }.map(make).sorted { ($0.v, $1.n) > ($1.v, $0.n) }
      return CallTree(n: s < 0 ? root : names[Int(s)], v: count[Int(i)], o: s >= 0 && ours[Int(s)] ? true : nil, c: children)
    }
    return make(0)
  }
}

/// A step of the scenario as the bench's `step` signpost interval marked it (or, without signposts, as inferred).
public struct StepInterval: Codable, Sendable, Equatable {
  /// The subsystem PerfLoopHost's `run.step` signposts are in.
  public static let hostSubsystem = "dev.perfloop.bench"
  public var name: String
  public var startNs: Int
  public var endNs: Int
  /// `signpost` (os-signpost table) or `inProcess` (the in-process result's step times).
  public var source: String
  public init(name: String, startNs: Int, endNs: Int, source: String) { self.name = name; self.startNs = startNs; self.endNs = endNs; self.source = source }

  /// The bench's `step` intervals from an `os-signpost` export: Begin/End matched by signpost identifier (the export
  /// repeats events once per matching table; repeats collapse), in one of `subsystems` (nil: any), sorted by start.
  public static func fromSignposts(_ t: XCTable, subsystems: [String]? = [hostSubsystem], name: String = "step") -> [StepInterval] {
    func val(_ n: XNode?) -> String? { n.map { $0.attrs["fmt"] ?? $0.text } }
    var begins: [String: (Int, String)] = [:], ends: [String: Int] = [:]
    for r in t.rows {
      guard val(r["name"]) == name else { continue }
      if let s = val(r["subsystem"]), let ok = subsystems, !ok.contains(s) { continue }
      guard let id = val(r["identifier"]), let time = Int(r["time"]?.text ?? "") else { continue }
      switch val(r["event-type"]) {
      case "Begin": if begins[id] == nil { begins[id] = (time, val(r["message"]) ?? name) }
      case "End": if ends[id] == nil { ends[id] = time }
      default: continue
      }
    }
    return begins.compactMap { id, b in ends[id].flatMap { $0 >= b.0 ? StepInterval(name: b.1, startNs: b.0, endNs: $0, source: "signpost") : nil } }
      .sorted { ($0.startNs, $0.name) < ($1.startNs, $1.name) }
  }
}

/// The main thread's samples from a `time-profile` export: time, root-first stack of interned symbols.
public struct MainThreadSamples {
  public var names: [String] = []
  public var ours: [Bool] = []
  public var times: [Int] = []
  public var stacks: [[Int32]] = []
  /// The profiler's sample weight (its interval), median, in ms; falls back to the median gap between samples.
  public var sampleIntervalMs: Double = 1
  /// The process the samples are from (the bench's executable name), from the thread's or process cell.
  public var process: String?

  /// `process` narrows to threads of processes whose name contains it, when any does (an attached recording has one).
  public init(timeProfile t: XCTable, process: String? = nil) {
    var index: [String: Int32] = [:]
    var frameCache: [ObjectIdentifier: Int32] = [:], stackCache: [ObjectIdentifier: [Int32]] = [:]
    var weights: [Int] = []
    func procName(_ r: [String: XNode]) -> String? {
      // "SlowListBench (86034)" → "SlowListBench"
      guard let f = r["process"]?.attrs["fmt"] else { return nil }
      if let p = f.range(of: " (", options: .backwards) { return String(f[..<p.lowerBound]) }
      return f
    }
    let main = t.rows.filter { ($0["thread"]?.attrs["fmt"] ?? "").contains("Main Thread") }
    var rows = main
    if let process, main.contains(where: { (procName($0) ?? "").contains(process) }) { rows = main.filter { (procName($0) ?? "").contains(process) } }
    self.process = rows.lazy.compactMap(procName).first
    let binary = self.process
    for r in rows {
      let bt = r["stack"] ?? r["tagged-backtrace"] ?? r["backtrace"] ?? r.values.first { $0.name == "tagged-backtrace" || $0.name == "backtrace" }
      var stack: [Int32] = []
      if let bt {
        if let s = stackCache[ObjectIdentifier(bt)] { stack = s } else {
          for f in bt.all("frame") {
            let frame = f.attrs["ref"].flatMap { t.ids[$0] } ?? f
            if let s = frameCache[ObjectIdentifier(frame)] { stack.append(s); continue }
            let name = TraceSymbol.clean(frame.attrs["name"] ?? frame.attrs["addr"] ?? "?")
            let bin = frame.first("binary").map { $0.attrs["ref"].flatMap { t.ids[$0] } ?? $0 }?.attrs["name"]
            let s: Int32
            if let k = index[name] { s = k } else { s = Int32(names.count); index[name] = s; names.append(name); ours.append(false) }
            if let bin, let binary, bin == binary, !TraceSymbol.isHarness(name) { ours[Int(s)] = true }
            frameCache[ObjectIdentifier(frame)] = s
            stack.append(s)
          }
          stack.reverse()   // exports list the leaf first
          stackCache[ObjectIdentifier(bt)] = stack
        }
      }
      let time = Int((r["time"] ?? r["sample-time"] ?? r.values.first { $0.name == "sample-time" })?.text ?? "") ?? 0
      if let w = (r["weight"]?.text).flatMap(Int.init) { weights.append(w) }
      times.append(time); stacks.append(stack)
    }
    // Sorted by time, stacks alongside.
    let order = times.indices.sorted { times[$0] < times[$1] }
    times = order.map { times[$0] }; stacks = order.map { stacks[$0] }
    if !weights.isEmpty { sampleIntervalMs = Stats.round(Stats.median(weights.map { Double($0) / 1e6 }), 3) }
    else {
      let gaps = zip(times.dropFirst(), times).map { Double($0 - $1) / 1e6 }.filter { $0 > 0 }
      if !gaps.isEmpty { sampleIntervalMs = Stats.round(Stats.median(gaps), 3) }
    }
  }

  public var count: Int { times.count }
}

/// The trees a profile carries: the whole recording, the samples inside steps (what `diff` compares), each step, and
/// what fell outside every step (settling, warming, the hold).
public struct StepTrees {
  public var steps: [StepInterval]
  public var whole: CallTree
  public var inSteps: CallTree
  public var outside: CallTree
  public var perStep: [CallTree]
  public var sampleIntervalMs: Double
  /// Main-thread ms per step: samples inside steps × interval ÷ steps (nil without steps).
  public var msPerStep: Double? { steps.isEmpty ? nil : Stats.round(Double(inSteps.v) * sampleIntervalMs / Double(steps.count), 1) }

  public init(samples s: MainThreadSamples, steps: [StepInterval], minSamples: Int = 1) {
    self.steps = steps; sampleIntervalMs = s.sampleIntervalMs
    var whole = CallTreeBuilder(), inside = CallTreeBuilder(), outside = CallTreeBuilder()
    var per = Array(repeating: CallTreeBuilder(), count: steps.count)
    var j = 0
    for (t, stack) in zip(s.times, s.stacks) {
      whole.add(stack)
      while j < steps.count && steps[j].endNs < t { j += 1 }   // samples are sorted, steps don't overlap
      if j < steps.count, steps[j].startNs <= t { inside.add(stack); per[j].add(stack) } else { outside.add(stack) }
    }
    self.whole = whole.tree(root: "main thread", names: s.names, ours: s.ours, minSamples: minSamples)
    inSteps = inside.tree(root: "main thread", names: s.names, ours: s.ours, minSamples: minSamples)
    self.outside = outside.tree(root: "outside steps", names: s.names, ours: s.ours, minSamples: minSamples)
    perStep = zip(steps, per).map { $1.tree(root: $0.name, names: s.names, ours: s.ours, minSamples: minSamples) }
  }
}

/// One step's tree in a profile.
public struct StepTree: Codable, Sendable, Equatable {
  public var step: String
  public var tree: CallTree
  public init(step: String, tree: CallTree) { self.step = step; self.tree = tree }
}

extension Explain {
  /// A profile's call tree in a few lines: steps covered, ms per step, and the heaviest subtrees (a frame whose time is
  /// not mostly one callee's), each with its folded chain.
  public static func callTreeText(_ r: ProfileDoc, top: Int = 10) -> String {
    guard let whole = r.tree else { return "" }
    let steps = r.steps ?? []
    let interval = r.sampleIntervalMs ?? 1
    var o: [String] = []
    if steps.isEmpty {
      o.append("call tree: \(whole.v) main-thread samples (every \(interval) ms); no `step` signposts, so the whole recording")
    } else {
      o.append("call tree: \(whole.v) main-thread samples (every \(interval) ms); \(steps.count) steps from signposts\(r.stepsExpected.map { " of \($0)" } ?? ""), \(r.msPerStep.map { String($0) } ?? "?") ms per step inside them")
    }
    let t = steps.isEmpty ? whole : (r.treeInSteps ?? whole)
    let n = steps.isEmpty ? 1 : steps.count
    o.append("  heaviest subtrees, ms \(steps.isEmpty ? "in the recording" : "per step") (folded chains, outermost first; `diff` compares two profiles):")
    for x in Diff.largest(t, scale: interval / Double(n), top: top) {
      o.append(String("  \(String(format: "%7.1f", x.b))  \(x.ours ? "*" : " ") \(folded(x.chain))\(x.paths > 1 ? "  [\(x.paths) paths]" : "")\(x.under.map { x.chain.contains($0) ? "" : "  under \($0)" } ?? "")".prefix(150)))
    }
    return o.joined(separator: "\n")
  }
}
