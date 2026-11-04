import Foundation

// Main-thread stacks: the pure half of the in-process sampler (PerfLoopHost's MainThreadSampler; deskbench keeps its own
// copy of both until it moves onto PerfLoopHost). The sampler records
// raw return addresses; after the run they are symbolised (dladdr), cleaned here, and folded into a call tree per
// stretch with its inclusive, self, ours and framework tops (`Stretch.stacks`, `topOurs`, `topFramework`, `topSelf`).

/// A folded call tree of sampled stacks (SCHEMAS.md's common `tree` object): `n` the frame, `v` its inclusive weight (samples in a
/// profile, ms in a diff), `c` its callees, heaviest first. A leaf has no `c` in the JSON.
public struct StackTree: Codable, Sendable, Equatable {
  public var n: String
  public var v: Double
  public var c: [StackTree]
  public init(n: String, v: Double, c: [StackTree] = []) { self.n = n; self.v = v; self.c = c }

  enum CodingKeys: String, CodingKey { case n, v, c }
  public init(from d: Decoder) throws {
    let k = try d.container(keyedBy: CodingKeys.self)
    n = try k.decode(String.self, forKey: .n); v = try k.decode(Double.self, forKey: .v)
    c = try k.decodeIfPresent([StackTree].self, forKey: .c) ?? []
  }
  public func encode(to e: Encoder) throws {
    var k = e.container(keyedBy: CodingKeys.self)
    try k.encode(n, forKey: .n); try k.encode(v, forKey: .v)
    if !c.isEmpty { try k.encode(c, forKey: .c) }
  }

  /// From the root, the heaviest child at each level down to a leaf (the root itself excluded).
  public var hotPath: [StackTree] {
    var out: [StackTree] = []
    var node = self
    while let next = node.c.max(by: { ($0.v, $1.n) < ($1.v, $0.n) }) { out.append(StackTree(n: next.n, v: next.v)); node = next }
    return out
  }

  public var nodeCount: Int { 1 + c.reduce(0) { $0 + $1.nodeCount } }

  /// Trees folded into one under `root`: nodes on the same path add their weights.
  public static func merge(_ ts: [StackTree], root: String = "main thread") -> StackTree {
    var out = StackTree(n: root, v: ts.reduce(0) { $0 + $1.v })
    out.c = mergeChildren(ts.flatMap(\.c))
    return out
  }

  static func mergeChildren(_ xs: [StackTree]) -> [StackTree] {
    var byName: [String: [StackTree]] = [:]
    for x in xs { byName[x.n, default: []].append(x) }
    return byName.map { n, group in StackTree(n: n, v: group.reduce(0) { $0 + $1.v }, c: mergeChildren(group.flatMap(\.c))) }
      .sorted { ($0.v, $1.n) > ($1.v, $0.n) }
  }

  /// Every topmost node named `name` (not those inside another one), folded into one: its weight is the frame's
  /// inclusive weight in the tree, its children what it called. nil when the frame isn't in the tree.
  public func gather(_ name: String) -> StackTree? {
    var found: [StackTree] = []
    func walk(_ t: StackTree) { if t.n == name { found.append(t) } else { t.c.forEach(walk) } }
    c.forEach(walk)
    guard !found.isEmpty else { return nil }
    return StackTree(n: name, v: found.reduce(0) { $0 + $1.v }, c: Self.mergeChildren(found.flatMap(\.c)))
  }

  public func contains(_ name: String) -> Bool { c.contains { $0.n == name || $0.contains(name) } }

  /// Down the heaviest callee while it still holds `share` of this node, stopping before frames that only say "a
  /// message was sent" or "memory moved": where this node's time mostly went. nil when no callee holds that share.
  /// Thunks, closures and image-only frames are passed through, never named.
  public func mostlyIn(share: Double = 0.5) -> StackTree? {
    let generic: Set<String> = ["objc_msgSend", "swift_retain", "swift_release", "_platform_memmove", "?", "objc_retain", "objc_release"]
    var node = self, last: StackTree?
    while let next = node.c.max(by: { ($0.v, $1.n) < ($1.v, $0.n) }), next.v >= v * share, !generic.contains(next.n) {
      if Self.informative(next.n) { last = next }
      node = next
    }
    return last
  }

  /// Whether a frame's name says anything by itself: not a thunk, a bare closure, or an image without a symbol.
  public static func informative(_ n: String) -> Bool {
    !(n == "(thunk)" || n.hasPrefix("(") || n == "?" || n.hasPrefix("closure #") || n.hasPrefix("implicit closure #") || n.hasPrefix("thunk"))
  }
}

/// A symbol and how many samples it was in. `under` (framework frames only): the nearest of our frames above it in
/// most of those samples, so `LayoutEngineBox.sizeThatFits` says which of our views asked for it.
public struct SymbolCount: Codable, Sendable, Equatable {
  public var symbol: String
  public var samples: Int
  public var under: String?
  public init(symbol: String, samples: Int, under: String? = nil) { self.symbol = symbol; self.samples = samples; self.under = under }
}

/// One symbolised frame: its cleaned name and whether it is in the bench's own executable (our code: the app's modules
/// and the bench, linked into it) rather than a system framework.
public struct StackFrame: Hashable, Sendable {
  public var symbol: String
  public var ours: Bool
  public init(_ symbol: String, ours: Bool = false) { self.symbol = symbol; self.ours = ours }
}

/// Samples of one stretch folded: the tree and the tops. Stacks come leaf first (the sampled pc, then each caller);
/// a sample counts once per distinct symbol for the inclusive tops, so recursion doesn't count twice. Adjacent frames
/// with the same name are one frame (a thunk and its implementation, the link register repeating the caller).
public struct StackProfile: Sendable, Equatable {
  public var samples: Int
  public var tree: StackTree
  /// Our frames, inclusive, outside the run-loop trunk.
  public var ours: [SymbolCount]
  /// Framework frames, inclusive, outside the run-loop trunk, each with the our-frame it ran under.
  public var framework: [SymbolCount]
  /// Where the samples landed (the leaf frame).
  public var selfTop: [SymbolCount]

  /// `top` entries per list; tree nodes under `minShare` of the samples are pruned (their weight stays in the parent).
  public init(stacks: [[StackFrame]], top: Int = 10, minShare: Double = 0.005, maxDepth: Int = 160) {
    samples = stacks.count
    final class Node { var v = 0; var kids: [String: Node] = [:] }
    let root = Node()
    var incl: [StackFrame: Int] = [:], selfc: [String: Int] = [:]
    var under: [String: [String: Int]] = [:]
    for s in stacks {
      var chain: [StackFrame] = []
      for f in s.reversed() where chain.last?.symbol != f.symbol { chain.append(f) }
      root.v += 1
      var node = root
      for f in chain.prefix(maxDepth) {
        let next = node.kids[f.symbol] ?? { let n = Node(); node.kids[f.symbol] = n; return n }()
        next.v += 1; node = next
      }
      if let leaf = chain.last { selfc[leaf.symbol, default: 0] += 1 }
      var seen: Set<String> = [], lastOurs: String?
      for f in chain {
        if f.ours, !Self.isTrunk(f.symbol) { lastOurs = f.symbol }
        guard seen.insert(f.symbol).inserted else { continue }
        incl[f, default: 0] += 1
        if !f.ours, let o = lastOurs { under[f.symbol, default: [:]][o, default: 0] += 1 }
      }
    }
    let floor = max(1, Int((Double(samples) * minShare).rounded(.up)))
    func fold(_ name: String, _ n: Node) -> StackTree {
      let kids = n.kids.filter { $0.value.v >= floor }.map { fold($0.key, $0.value) }.sorted { ($0.v, $1.n) > ($1.v, $0.n) }
      return StackTree(n: name, v: Double(n.v), c: kids)
    }
    tree = fold("main thread", root)
    func rank(_ xs: [(String, Int)]) -> [(String, Int)] { xs.sorted { ($0.1, $1.0) > ($1.1, $0.0) }.prefix(top).map { $0 } }
    let kept = incl.filter { !Self.isTrunk($0.key.symbol) }
    ours = rank(kept.filter { $0.key.ours }.map { ($0.key.symbol, $0.value) }).map { SymbolCount(symbol: $0.0, samples: $0.1) }
    framework = rank(kept.filter { !$0.key.ours }.map { ($0.key.symbol, $0.value) }).map { s in
      SymbolCount(symbol: s.0, samples: s.1, under: under[s.0]?.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key)
    }
    selfTop = rank(selfc.map { ($0.key, $0.value) }).map { SymbolCount(symbol: $0.0, samples: $0.1) }
  }

  /// The run loop's own frames, under everything the main thread does: never the answer to "where did the time go".
  public static func isTrunk(_ s: String) -> Bool {
    if trunkNames.contains(s) { return true }
    // The bench host's own frames (PerfLoopHost: its main, the step that resumed a scenario) sit under everything too.
    if s.hasPrefix("PerfLoopHost.") || s.contains(" in PerfLoopHost.") { return true }
    return trunkPrefixes.contains { s.hasPrefix($0) }
  }
  static let trunkNames: Set<String> = ["start", "main", "$main", "NSApplicationMain", "_NSApplicationMain", "-[NSApplication run]", "App.main", "static App.main",
                                        "BenchScene.$main", "static BenchScene.$main", "runApp", "CFRunLoopRunSpecific", "CFRunLoopRun", "CFRunLoopRunInMode",
                                        "RunCurrentEventLoopInMode", "ReceiveNextEventCommon", "swift::runJobInEstablishedExecutorContext", "main thread",
                                        "-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]"]
  static let trunkPrefixes = ["__CFRunLoop", "_CFRunLoopRun", "__CFRUNLOOP_IS_", "_dispatch_", "_DPSNextEvent", "_BlockUntilNextEventMatchingListInMode", "_DPSBlockUntilNextEventMatchingListInMode", "-[NSApplication(NSEventRouting) _nextEventMatchingEventMask",
                              "_NSAppKitThreadSafety", "start_wqthread", "thread_start", "_pthread_start", "dyld", "swift_job_run"]
}

/// Symbol names as the sampler gets them (mangled, from dladdr) made into the names xctrace and people use:
/// `SwiftUI.ScrollViewCommitMutation.commit() -> ()` → `ScrollViewCommitMutation.commit`,
/// `_ZN2AG5Graph15propagate_dirtyENS_4data3ptrINS_4NodeEEE` → `AG::Graph::propagate_dirty`.
public enum Symbols {
  /// Demangled (Swift via the runtime's swift_demangle, C++ via __cxa_demangle) and cleaned.
  public static func name(_ raw: String, image: String? = nil) -> String { clean(demangle(raw), image: image) }

  /// The demangled form, or `raw` unchanged when it isn't a Swift or C++ mangled name (C, Objective-C).
  public static func demangle(_ raw: String) -> String {
    if raw.hasPrefix("$s") || raw.hasPrefix("$S") || raw.hasPrefix("_$s") || raw.hasPrefix("$e") {
      return Demangler.swift(raw) ?? raw
    }
    if raw.hasPrefix("_Z") || raw.hasPrefix("__Z") { return Demangler.cxx(raw.hasPrefix("__Z") ? String(raw.dropFirst()) : raw) ?? raw }
    return raw
  }

  /// Modules whose qualifier is dropped (`SwiftUI.NSHostingView.layout` → `NSHostingView.layout`), besides every
  /// module named by `appModulePrefixes` and the image the symbol came from.
  static let modules: Set<String> = ["Swift", "SwiftUI", "SwiftUICore", "AppKit", "Foundation", "AttributeGraph", "CoreFoundation", "QuartzCore", "Combine",
                                     "Observation", "_Concurrency", "__C", "os", "Dispatch", "ObjectiveC", "CoreGraphics", "CoreText", "_SwiftUI_AppKit",
                                     "_StringProcessing"]

  /// A demangled name without argument lists, return types, module qualifiers and specialisation noise, cut to 110
  /// characters (as `ProfileSummary.clean`). Objective-C names are kept as they are.
  public static func clean(_ s: String, image: String? = nil) -> String {
    var t = s.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("-[") || t.hasPrefix("+[") { return String(t.prefix(110)) }
    if t.hasPrefix("reabstraction thunk") || t.hasPrefix("thunk for ") { return "(thunk)" }
    // Async functions' pieces: "(1) suspend resume partial function for X.f(…) async -> ()" → X.f
    t = t.replacingOccurrences(of: #"^\(\d+\) (suspend|await) resume partial function for "#, with: "", options: .regularExpression)
    // protocol witness for P.m(…) in conformance T : P in M  →  T.m
    if t.hasPrefix("protocol witness for "), let r = t.range(of: " in conformance ") {
      let wit = cut(String(t[t.index(t.startIndex, offsetBy: 21)..<r.lowerBound]))
      let conf = splitTop(String(t[r.upperBound...]), " : ")
      let type = conf.first ?? ""
      let proto = conf.count > 1 ? (splitTop(conf[1], " in ").first ?? "") : ""
      let method = !proto.isEmpty && wit.hasPrefix(proto + ".") ? String(wit.dropFirst(proto.count + 1)) : (wit.split(separator: ".").last.map(String.init) ?? wit)
      t = type + "." + method
    }
    for p in ["merged ", "specialized ", "partial apply for ", "partial apply forwarder for ", "@objc ", "dispatch thunk of ", "static ", "@nonobjc ", "outlined function "] {
      while t.hasPrefix(p) { t.removeFirst(p.count) }
    }
    for p in ["generic specialization <", "function signature specialization <"] where t.hasPrefix(p) {
      guard let r = matching(t, from: t.index(t.startIndex, offsetBy: p.count)) else { break }
      t = String(t[r...]); if t.hasPrefix(" of ") { t.removeFirst(4) }
      for p in ["specialized ", "static ", "@objc "] { while t.hasPrefix(p) { t.removeFirst(p.count) } }
    }
    t = t.replacingOccurrences(of: #"\(extension in [^)]*\):"#, with: "", options: .regularExpression)
    // private names: "ReelView.(slide in _2B7A…)(to:)" → "ReelView.slide(to:)"
    t = t.replacingOccurrences(of: #"\(([A-Za-z0-9_$]+) in _[0-9A-F]+\)"#, with: "$1", options: .regularExpression)
    // closure #1 (A) -> B in X.f(…) -> ()  →  closure #1 in X.f
    let segments = splitTop(t, " in ").map { seg -> String in
      var g = seg
      for p in ["implicit closure #", "closure #"] where g.hasPrefix(p) {
        let rest = g.dropFirst(p.count)
        let num = rest.prefix { $0.isNumber }
        return p + num
      }
      g = cut(g)
      for p in ["static ", "@objc "] { while g.hasPrefix(p) { g.removeFirst(p.count) } }
      return g
    }
    t = segments.joined(separator: " in ")
    var drop = modules
    if let i = image { drop.insert(i) }
    t = dropModules(t, drop)
    if !t.contains("::") { t = stripGenerics(t) }
    return String(t.prefix(110))
  }

  /// `X.f(a: Int) -> ()` → `X.f`; `X.p.getter : Int` → `X.p.getter`. Cut at the first `(` or ` : ` outside brackets.
  static func cut(_ s: String) -> String {
    var depth = 0
    var i = s.startIndex
    while i < s.endIndex {
      let ch = s[i]
      if ch == "<" { depth += 1 } else if ch == ">" { depth = max(0, depth - 1) }
      else if depth == 0, ch == "(" { return String(s[..<i]).trimmingCharacters(in: .whitespaces) }
      else if depth == 0, ch == " ", s[i...].hasPrefix(" : ") { return String(s[..<i]) }
      i = s.index(after: i)
    }
    return s
  }

  /// Splits on `sep` where no bracket is open.
  static func splitTop(_ s: String, _ sep: String) -> [String] {
    var out: [String] = [], depth = 0
    var start = s.startIndex, i = s.startIndex
    while i < s.endIndex {
      let ch = s[i]
      if "(<[".contains(ch) { depth += 1 } else if ")>]".contains(ch) { depth = max(0, depth - 1) }
      if depth == 0, s[i...].hasPrefix(sep) {
        out.append(String(s[start..<i])); i = s.index(i, offsetBy: sep.count); start = i; continue
      }
      i = s.index(after: i)
    }
    out.append(String(s[start...]))
    return out
  }

  /// The index just past the `>` that closes the `<` before `from`.
  static func matching(_ s: String, from: String.Index) -> String.Index? {
    var depth = 1, i = from
    while i < s.endIndex {
      if s[i] == "<" { depth += 1 } else if s[i] == ">" { depth -= 1; if depth == 0 { return s.index(after: i) } }
      i = s.index(after: i)
    }
    return nil
  }

  /// Name prefixes of the app's own modules, whose qualifier is dropped too (a bench sets them: `["MyApp"]` drops
  /// `MyAppKit.` and `MyApp.`).
  public static var appModulePrefixes: [String] = []

  /// Drops a leading module qualifier of each dotted name (`CapcomdStore.CapcomdStore.receive` → `CapcomdStore.receive`:
  /// only the first word of a name is a module).
  static func dropModules(_ s: String, _ modules: Set<String>) -> String {
    var out = "", word = "", afterDrop = false
    func isModule(_ w: String) -> Bool { modules.contains(w) || appModulePrefixes.contains { w.hasPrefix($0) } }
    for ch in s {
      if ch.isLetter || ch.isNumber || ch == "_" || ch == "$" { word.append(ch); continue }
      if ch == ".", !word.isEmpty, !afterDrop, out.last != ".", isModule(word) { word = ""; afterDrop = true; continue }
      out += word; word = ""; out.append(ch); afterDrop = false
    }
    return out + word
  }

  /// `NSHostingView<A>.layout` → `NSHostingView.layout` (Swift names only).
  static func stripGenerics(_ s: String) -> String {
    var out = "", depth = 0
    for ch in s {
      if ch == "<" { depth += 1; continue }
      if ch == ">" { depth = max(0, depth - 1); continue }
      if depth == 0 { out.append(ch) }
    }
    return out
  }
}

/// The demanglers already in the process, found with dlsym so nothing is linked for them: `swift_demangle` (libswiftCore)
/// and `__cxa_demangle` (libc++abi). Both return malloc'd strings the caller frees.
enum Demangler {
  typealias SwiftFn = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
  typealias CxxFn = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<CChar>?
  #if canImport(Darwin)
  static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
  #else
  static let defaultHandle: UnsafeMutableRawPointer? = nil             // RTLD_DEFAULT on glibc
  #endif
  static let swiftFn: SwiftFn? = dlsym(defaultHandle, "swift_demangle").map { unsafeBitCast($0, to: SwiftFn.self) }
  static let cxxFn: CxxFn? = dlsym(defaultHandle, "__cxa_demangle").map { unsafeBitCast($0, to: CxxFn.self) }

  static func swift(_ s: String) -> String? {
    guard let f = swiftFn else { return nil }
    let name = s.hasPrefix("_$") ? String(s.dropFirst()) : s
    return name.withCString { p -> String? in
      guard let r = f(p, strlen(p), nil, nil, 0) else { return nil }
      defer { free(r) }
      return String(cString: r)
    }
  }

  static func cxx(_ s: String) -> String? {
    guard let f = cxxFn else { return nil }
    return s.withCString { p -> String? in
      var status: Int32 = 0
      guard let r = f(p, nil, nil, &status), status == 0 else { return nil }
      defer { free(r) }
      return String(cString: r)
    }
  }
}

/// What the sampler cost and did in one rep (`reps[].sampler`). `overheadPct` is the sampler thread's CPU over the
/// main thread's (SCHEMAS.md); `stallMs` is the time the main thread was held suspended for its stacks, which lands
/// inside the stretches it sampled (≈ 7 µs a sample on an M1 Pro).
public struct SamplerStats: Codable, Sendable, Equatable {
  public var hz: Double
  /// Stretches are sampled only once they have lasted this long.
  public var gateMs: Double
  public var samples: Int
  public var sampledStretches: Int
  /// Samples where the main thread couldn't be suspended or read.
  public var failures: Int
  /// Samples dropped because one stretch filled the buffer.
  public var truncated: Int
  public var stallMs: Double
  public var costP50Us: Double
  public var costP95Us: Double
  public var costMaxUs: Double
  public var samplerCpuMs: Double
  public var mainCpuMs: Double
  public var overheadPct: Double
  public init(hz: Double, gateMs: Double, samples: Int, sampledStretches: Int, failures: Int, truncated: Int, stallMs: Double, costP50Us: Double, costP95Us: Double,
              costMaxUs: Double, samplerCpuMs: Double, mainCpuMs: Double) {
    self.hz = hz; self.gateMs = gateMs; self.samples = samples; self.sampledStretches = sampledStretches; self.failures = failures; self.truncated = truncated
    self.stallMs = Stats.round(stallMs, 2); self.costP50Us = Stats.round(costP50Us, 1); self.costP95Us = Stats.round(costP95Us, 1); self.costMaxUs = Stats.round(costMaxUs, 1)
    self.samplerCpuMs = Stats.round(samplerCpuMs, 2); self.mainCpuMs = Stats.round(mainCpuMs, 1)
    overheadPct = mainCpuMs > 0 ? Stats.round(samplerCpuMs / mainCpuMs * 100, 2) : 0
  }

  /// p-th percentile from a histogram of per-sample costs in 1 µs buckets (the last bucket is "that much or more").
  public static func percentile(_ hist: [Int], _ p: Double) -> Double {
    let n = hist.reduce(0, +)
    guard n > 0 else { return 0 }
    let target = Int((Double(n) * p / 100).rounded(.up))
    var acc = 0
    for (i, c) in hist.enumerated() { acc += c; if acc >= max(1, target) { return Double(i) } }
    return Double(hist.count - 1)
  }
}
