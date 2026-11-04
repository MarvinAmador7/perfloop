import Foundation

// The differential call tree (CAPABILITIES.md C2, SCHEMAS.md perfloop.diff/1; ported from capcomd's deskbench): two
// main-thread trees normalised to ms per step, merged node by node, and the subtrees that moved most, each reported once
// with its folded chain.

/// The build a side was recorded on: the subset of `perfloop.build/1` provenance needs. Every field is optional until
/// binaries carry the build stamp; a trace with none is "unstamped".
public struct DiffBuild: Codable, Sendable, Equatable {
  public var hash: String?
  public var commit: String?
  public var dirty: Bool?
  public var stamp: Bool?
  public init(hash: String? = nil, commit: String? = nil, dirty: Bool? = nil, stamp: Bool? = nil) { self.hash = hash; self.commit = commit; self.dirty = dirty; self.stamp = stamp }
  /// How the text names it: the commit (with `+dirty`) or the start of the hash.
  public var label: String { commit.map { $0 + (dirty == true ? "+dirty" : "") } ?? hash.map { String($0.prefix(19)) } ?? "unstamped" }
  /// Same build: equal hashes, or (without hashes) equal clean commits.
  public func matches(_ ref: String) -> Bool {
    if let hash, hash == ref || hash == "sha256:" + ref || (ref.count >= 7 && hash.hasPrefix("sha256:" + ref)) { return true }
    if let commit, dirty != true, ref.count >= 7, commit.hasPrefix(ref) || ref.hasPrefix(commit) { return true }
    return false
  }
}

/// One side of a diff: where it came from, how it was normalised.
public struct DiffSide: Codable, Sendable, Equatable {
  public var profile: String?
  public var trace: String?
  public var build: DiffBuild?
  public var os: String?
  public var steps: Int
  /// `signpost`, `inProcess` or `none` (the whole recording counted as one step).
  public var stepSource: String
  public var samples: Int
  public var sampleIntervalMs: Double
  public var msPerStep: Double
  public init(profile: String? = nil, trace: String? = nil, build: DiffBuild? = nil, os: String? = nil, steps: Int, stepSource: String, samples: Int, sampleIntervalMs: Double, msPerStep: Double = 0) {
    self.profile = profile; self.trace = trace; self.build = build; self.os = os; self.steps = steps; self.stepSource = stepSource; self.samples = samples
    self.sampleIntervalMs = sampleIntervalMs; self.msPerStep = msPerStep
  }
}

/// What `diff` compares for one side: a main-thread tree (v = samples) and how to turn samples into ms per step.
public struct DiffInput {
  public var side: DiffSide
  public var tree: CallTree
  public var notes: [String]
  public init(side: DiffSide, tree: CallTree, notes: [String] = []) { self.side = side; self.tree = tree; self.notes = notes }
  /// ms per step for one sample.
  var scale: Double { side.sampleIntervalMs / Double(max(1, side.steps)) }
}

/// A node of the differential tree: ms per step in a and b, d = b − a.
public struct DiffNode: Codable, Sendable, Equatable {
  public var n: String
  public var a: Double
  public var b: Double
  public var d: Double
  public var o: Bool?
  public var c: [DiffNode]
}

/// A subtree that moved, over all its call paths: `chain` the frames that moved together by about the same amount,
/// outermost first (the folded chain a flame graph would show as one bar), `path` the heaviest call path to the
/// outermost one, `under` the nearest frame of ours above it. a, b, d are the outermost frame's, summed over its paths.
public struct DiffItem: Codable, Sendable, Equatable {
  public var path: [String]
  public var chain: [String]
  public var a: Double
  public var b: Double
  public var d: Double
  /// The part of d that did not reappear under another caller (what the ranking uses); d − attributable moved.
  public var attributable: Double
  public var under: String?
  public var ours: Bool
  /// Call paths it moved on (≥ 5 % of its change each): the values are summed over all of them.
  public var paths: Int
  /// The bigger reported subtree this one runs inside, if any.
  public var inside: String?
  /// The outermost frame of the chain: "the X subtree".
  public var symbol: String { chain.first ?? path.last ?? "main thread" }
}

/// A frame that left one place and appeared in another (same name, opposite deltas).
public struct DiffMove: Codable, Sendable, Equatable {
  public var symbol: String
  public var fromUnder: String
  public var toUnder: String
  public var a: Double
  public var b: Double
}

public struct DiffProvenance: Codable, Sendable, Equatable {
  /// A side's build is not the one it was expected to be (`--champion`), or can't be told (unstamped).
  public var stale: Bool
  /// The two sides were recorded on different OS builds: symbol names may not line up.
  public var crossOS: Bool
  /// What the caller allowed anyway (`stale`, `crossOS`).
  public var allowed: [String]
  public var reasons: [String]
  /// True when the diff should not be trusted and wasn't allowed: the command exits 6.
  public init(stale: Bool = false, crossOS: Bool = false, allowed: [String] = [], reasons: [String] = []) { self.stale = stale; self.crossOS = crossOS; self.allowed = allowed; self.reasons = reasons }
  public var refused: Bool { (stale && !allowed.contains("stale")) || (crossOS && !allowed.contains("crossOS")) }
}

public struct DiffResult: Codable, Sendable, Equatable {
  public var schema = "perfloop.diff/1"
  public var scenario: String
  /// `msPerStep` (default) or `msPerRun` (the whole recording, one "step").
  public var normalisation: String
  public var a: DiffSide
  public var b: DiffSide
  public var deltaMsPerStep: Double
  public var deltaPct: Double?
  /// The merged tree, pruned to nodes that moved by ≥ `treeFloorMs` or weigh that much on either side.
  public var tree: DiffNode
  public var treeFloorMs: Double
  /// b is faster here (d < 0), largest first.
  public var gains: [DiffItem]
  /// b is slower here (d > 0), largest first.
  public var losses: [DiffItem]
  /// The heaviest specific subtrees of b: what is left to attack.
  public var remaining: [DiffItem]
  public var moved: [DiffMove]
  public var provenance: DiffProvenance
  public var notes: [String]
  /// Wall time of the command, s (exports included).
  public var elapsedS: Double?
}

public enum Diff {
  /// A flat node of the merged tree.
  struct M { var n: String; var a: Double; var b: Double; var o: Bool; var parent: Int; var kids: [Int]; var d: Double { b - a } }

  /// Merges two trees by path; values become ms per step.
  static func merge(_ a: CallTree, _ b: CallTree, sa: Double, sb: Double) -> [M] {
    var out: [M] = []
    func add(_ x: CallTree?, _ y: CallTree?, parent: Int) {
      let i = out.count
      out.append(M(n: x?.n ?? y!.n, a: Double(x?.v ?? 0) * sa, b: Double(y?.v ?? 0) * sb, o: x?.o == true || y?.o == true, parent: parent, kids: []))
      if parent >= 0 { out[parent].kids.append(i) }
      var seen: [String: CallTree] = [:]
      for k in y?.c ?? [] { seen[k.n] = k }
      for k in x?.c ?? [] { add(k, seen.removeValue(forKey: k.n), parent: i) }
      for k in y?.c ?? [] where seen[k.n] != nil { add(nil, k, parent: i) }
    }
    add(a, b, parent: -1)
    return out
  }

  /// Per node: the growth and the shrinkage inside its subtree, summed from self deltas (self = d − Σ callees' d), so
  /// a node whose net change is the remainder of large opposite moves can be told from one that moved as a whole.
  static func gross(_ m: [M]) -> (pos: [Double], neg: [Double]) {
    var pos = [Double](repeating: 0, count: m.count), neg = pos
    for i in m.indices.reversed() {   // children come after their parent
      let s = m[i].d - m[i].kids.reduce(0) { $0 + m[$1].d }
      pos[i] += max(0, s); neg[i] += max(0, -s)
      if m[i].parent >= 0 { pos[m[i].parent] += pos[i]; neg[m[i].parent] += neg[i] }
    }
    return (pos, neg)
  }

  /// A symbol over all its call paths: its topmost occurrences (a recursive frame counts once), their sums.
  struct Sym { var name: String; var nodes: [Int] = []; var a = 0.0, b = 0.0, pos = 0.0, neg = 0.0, depth = 0.0, ours = false; var d: Double { b - a } }

  static func symbols(_ m: [M], pos: [Double], neg: [Double]) -> [String: Sym] {
    var out: [String: Sym] = [:]
    var onPath: [String: Int] = [:]
    func walk(_ i: Int, _ depth: Int) {
      let n = m[i].n
      if i > 0, onPath[n, default: 0] == 0 {
        var s = out[n] ?? Sym(name: n)
        s.nodes.append(i); s.a += m[i].a; s.b += m[i].b; s.pos += pos[i]; s.neg += neg[i]; s.ours = s.ours || m[i].o
        s.depth += Double(depth) * abs(m[i].d)
        out[n] = s
      }
      onPath[n, default: 0] += 1
      for k in m[i].kids { walk(k, depth + 1) }
      onPath[n]! -= 1
    }
    walk(0, 0)
    for (k, s) in out { out[k]!.depth = s.depth / max(1e-9, s.nodes.reduce(0) { $0 + abs(m[$1].d) }) }
    return out
  }

  /// Share of a symbol's change (|d| of its topmost nodes) that runs under each ancestor symbol.
  static func ancestors(_ m: [M], _ s: Sym) -> [String: Double] {
    var w: [String: Double] = [:]
    let total = max(1e-9, s.nodes.reduce(0) { $0 + abs(m[$1].d) })
    for i in s.nodes {
      var seen: Set<String> = [], p = m[i].parent
      while p > 0 { if seen.insert(m[p].n).inserted { w[m[p].n, default: 0] += abs(m[i].d) }; p = m[p].parent }
    }
    return w.mapValues { $0 / total }
  }

  /// How much of a subtree's change is work that moved rather than appeared or vanished: the largest share of it
  /// carried by one frame that changed the other way outside the subtree with the same callees (so a layout pass that
  /// left the display-cycle observer for `displayIfNeeded` counts as moved, while a wrapper like
  /// `NSPerformVisuallyAtomicChange` that now wraps different work does not).
  static func movedOut(_ m: [M], head: Sym, chain: Set<String>, syms: [String: Sym]) -> Double {
    let s: Double = head.d > 0 ? 1 : -1
    var inside = Set<Int>()
    var local: [String: (d: Double, nodes: [Int])] = [:]
    var onPath: [String: Int] = [:]
    func walk(_ i: Int) {
      inside.insert(i)
      let n = m[i].n
      if onPath[n, default: 0] == 0 { local[n, default: (0, [])].d += m[i].d; local[n]!.nodes.append(i) }
      onPath[n, default: 0] += 1
      for k in m[i].kids { walk(k) }
      onPath[n]! -= 1
    }
    for i in head.nodes { walk(i) }
    // What a set of nodes' callees did, in one direction: share per callee name (and "self").
    func profile(_ nodes: [Int], _ dir: Double) -> [String: Double] {
      var w: [String: Double] = [:], total = 0.0
      for i in nodes {
        let selfD = m[i].d - m[i].kids.reduce(0) { $0 + m[$1].d }
        w["<self>", default: 0] += max(0, dir * selfD)
        for k in m[i].kids { w[m[k].n, default: 0] += max(0, dir * m[k].d) }
      }
      total = w.values.reduce(0, +)
      return total > 0 ? w.mapValues { $0 / total } : [:]
    }
    var best = 0.0
    for (x, l) in local where (l.d > 0) == (s > 0) && abs(l.d) >= 0.2 * abs(head.d) && !chain.contains(x) && !TraceSymbol.isNoise(x) {
      guard let all = syms[x] else { continue }
      let outside = all.nodes.filter { !inside.contains($0) && -s * m[$0].d > 0 }
      let elsewhere = outside.reduce(0) { $0 + -s * m[$1].d }
      guard elsewhere > 0 else { continue }
      let pa = profile(l.nodes, s), pb = profile(outside, -s)
      let sim = pa.reduce(0) { $0 + min($1.value, pb[$1.key] ?? 0) }
      best = max(best, min(abs(l.d), elsewhere) * sim)
    }
    return min(best, abs(head.d))
  }

  /// The subtrees that moved, ranked. A candidate is a symbol (over all its call paths) that moved by ≥ `minMs`, is
  /// not a noise frame, and moved as a whole: the opposite movement inside it is under 35 % of its net change (so the
  /// run loop, net of everything, is not "the" answer). Candidates nested in one another with about the same change
  /// (within 20 %) are one chain, reported once, outermost first; a smaller change nested in a bigger one is reported
  /// on its own, marked `inside` the bigger one. Then moves are discounted (`movedOut`): `attributable` is d less the
  /// work that only moved to another caller; a subtree whose change mostly moved is left to the `moved` list, and a
  /// container whose attributable change is ≥ 80 % one nested subtree's folds into that subtree's chain. Ranked by d.
  static func rank(_ m: [M], minMs: Double, specific: Bool = false) -> [DiffItem] {
    let (pos, neg) = gross(m)
    let syms = symbols(m, pos: pos, neg: neg)
    let cands = syms.values.filter { s in
      abs(s.d) >= minMs && !TraceSymbol.isNoise(s.name) && (s.d > 0 ? s.neg : s.pos) <= 0.35 * abs(s.d)
    }.sorted { (abs($0.d), $1.name) > (abs($1.d), $0.name) }.prefix(300)
    struct Group { var members: [Sym]; var anc: [[String: Double]]; var inside: Int? }
    var groups: [Group] = []
    for s in cands {
      let anc = ancestors(m, s)
      // Nested with a member of a group (either way round), same direction.
      func nested(_ g: Group) -> Bool {
        zip(g.members, g.anc).contains { r, ra in (anc[r.name] ?? 0) >= 0.8 || (ra[s.name] ?? 0) >= 0.8 }
      }
      if let gi = groups.firstIndex(where: { g in (g.members[0].d > 0) == (s.d > 0) && abs(s.d) >= 0.8 * abs(g.members[0].d) && nested(g) }) {
        groups[gi].members.append(s); groups[gi].anc.append(anc); continue
      }
      let parent = groups.lastIndex { g in (g.members[0].d > 0) == (s.d > 0) && g.members.contains { (anc[$0.name] ?? 0) >= 0.8 } }
      groups.append(Group(members: [s], anc: [anc], inside: parent))
    }
    func outermost(_ g: Group) -> Sym { g.members.min { ($0.depth, $0.name) < ($1.depth, $1.name) }! }
    // Frames that hold (nearly) the whole tree on both sides (start → main → the run loop) say only what the totals say.
    // When one subtree is all that changed, it moved by about as much as they did and joined their chain: keep the
    // subtree's own frames as the item, without them.
    func covers(_ x: Sym) -> Bool { x.a >= 0.9 * m[0].a && x.b >= 0.9 * m[0].b }
    for gi in groups.indices {
      let keep = groups[gi].members.indices.filter { !covers(groups[gi].members[$0]) }
      if !keep.isEmpty && keep.count < groups[gi].members.count {
        groups[gi].members = keep.map { groups[gi].members[$0] }; groups[gi].anc = keep.map { groups[gi].anc[$0] }
      }
    }
    // The attributable change: d less what moved. Worked out for the larger groups only (the rest keep d).
    var attr = groups.map { outermost($0).d }
    for gi in groups.indices.sorted(by: { abs(attr[$0]) > abs(attr[$1]) }).prefix(60) {
      let h = outermost(groups[gi])
      let moved = movedOut(m, head: h, chain: Set(groups[gi].members.map(\.name)), syms: syms)
      attr[gi] = h.d > 0 ? h.d - moved : h.d + moved
    }
    // A container whose attributable change is mostly one nested subtree's is that subtree's story: its frames
    // become the outer part of that chain. A subtree whose change mostly moved is a move, not a cause: left out.
    var mergedInto = [Int?](repeating: nil, count: groups.count)
    for gi in groups.indices {
      let kids = groups.indices.filter { groups[$0].inside == gi }
      if let c = kids.max(by: { abs(attr[$0]) < abs(attr[$1]) }), abs(attr[c]) >= 0.8 * abs(attr[gi]), attr[gi] != 0 { mergedInto[gi] = c }
    }
    func prefix(_ c: Int) -> [Sym] {
      guard let g = groups.indices.first(where: { mergedInto[$0] == c }) else { return [] }
      return prefix(g) + groups[g].members.sorted { ($0.depth, $0.name) < ($1.depth, $1.name) }
    }
    // The group that is the whole tree (start → main → run loop when everything moved one way) says only what the
    // totals say.
    let everything = groups.indices.filter { covers(outermost(groups[$0])) }
    var kept = groups.indices.filter { mergedInto[$0] == nil && !everything.contains($0) && abs(attr[$0]) >= 0.5 * abs(outermost(groups[$0]).d) }
    if specific {
      // What is left to attack in one profile: run-loop plumbing and subtrees mostly (≥ 75 %) made of the subtrees
      // reported inside them are left out.
      kept = kept.filter { gi in
        let inner = kept.filter { groups[$0].inside == gi }.reduce(0) { $0 + abs(outermost(groups[$1]).d) }
        return inner <= 0.75 * abs(outermost(groups[gi]).d) && !groups[gi].members.allSatisfy { Explain.plumbing($0.name) }
      }
    }
    for gi in groups.indices where groups[gi].inside.map({ everything.contains($0) }) == true { groups[gi].inside = nil }
    return kept.sorted { (abs(outermost(groups[$0]).d), -$0) > (abs(outermost(groups[$1]).d), -$1) }.map { gi in
      let g = groups[gi]
      let own = g.members.sorted { ($0.depth, $0.name) < ($1.depth, $1.name) }
      let head = own[0], chain = prefix(gi) + own
      // The heaviest call path of the outermost member: its path and the nearest frame of ours above it.
      let top = head.nodes.max { abs(m[$0].d) < abs(m[$1].d) }!
      var path: [String] = [], j = top
      while j > 0 { path.append(m[j].n); j = m[j].parent }
      path.reverse()
      var under: String?, q = m[top].parent
      while q > 0 { if m[q].o, m[q].n != "main" { under = m[q].n; break }; q = m[q].parent }
      let paths = head.nodes.filter { abs(m[$0].d) >= 0.05 * abs(head.d) }.count
      return DiffItem(path: path, chain: chain.map(\.name), a: Stats.round(head.a, 1), b: Stats.round(head.b, 1), d: Stats.round(head.d, 1),
                      attributable: Stats.round(attr[gi], 1), under: under, ours: chain.contains { $0.ours }, paths: max(1, paths),
                      inside: g.inside.map { outermost(groups[$0]).name })
    }
  }

  /// Frames whose time left some call paths and appeared under others: large opposite moves under different parents.
  static func moves(_ m: [M], minMs: Double, reported: [DiffItem]) -> [DiffMove] {
    let (pos, neg) = gross(m)
    let syms = symbols(m, pos: pos, neg: neg)
    let named = Set(reported.flatMap(\.chain))
    func owner(_ i: Int) -> String {
      var p = m[i].parent
      while p > 0 { if named.contains(m[p].n) || (m[p].o && m[p].n != "main") { return m[p].n }; p = m[p].parent }
      return m[m[i].parent].n
    }
    var out: [DiffMove] = []
    for s in syms.values where !TraceSymbol.isNoise(s.name) && !named.contains(s.name) {
      let up = s.nodes.filter { m[$0].d > 0 }, down = s.nodes.filter { m[$0].d < 0 }
      let grew = up.reduce(0) { $0 + m[$1].d }, shrank = -down.reduce(0) { $0 + m[$1].d }
      guard grew >= 4 * minMs, shrank >= 4 * minMs, let to = up.max(by: { m[$0].d < m[$1].d }), let from = down.min(by: { m[$0].d < m[$1].d }) else { continue }
      let f = owner(from), t = owner(to)
      guard f != t else { continue }
      out.append(DiffMove(symbol: s.name, fromUnder: f, toUnder: t, a: Stats.round(shrank, 1), b: Stats.round(grew, 1)))
    }
    return Array(out.sorted { (min($0.a, $0.b), $0.symbol) > (min($1.a, $1.b), $1.symbol) }.prefix(6))
  }

  static func node(_ m: [M], _ i: Int, floor: Double) -> DiffNode {
    let kids = m[i].kids.filter { abs(m[$0].d) >= floor || max(m[$0].a, m[$0].b) >= floor }.sorted { abs(m[$0].d) > abs(m[$1].d) }
    return DiffNode(n: m[i].n, a: Stats.round(m[i].a, 2), b: Stats.round(m[i].b, 2), d: Stats.round(m[i].d, 2), o: m[i].o ? true : nil, c: kids.map { node(m, $0, floor: floor) })
  }

  /// The diff of b against a. `top` items each way; `minMs` the smallest move reported (default: 0.5 % of the larger
  /// side's ms per step, at least 0.25 ms).
  public static func make(a: DiffInput, b: DiffInput, scenario: String = "-", normalisation: String = "msPerStep", top: Int = 8, minMs: Double? = nil,
                          provenance: DiffProvenance = DiffProvenance()) -> DiffResult {
    let m = merge(a.tree, b.tree, sa: a.scale, sb: b.scale)
    var sa = a.side, sb = b.side
    sa.msPerStep = Stats.round(m[0].a, 1); sb.msPerStep = Stats.round(m[0].b, 1)
    let floor = minMs ?? max(0.25, 0.005 * max(m[0].a, m[0].b))
    let items = rank(m, minMs: floor)
    let gains = Array(items.filter { $0.d < 0 }.prefix(2 * top)), losses = Array(items.filter { $0.d > 0 }.prefix(2 * top))
    let remaining = largest(b.tree, scale: b.scale, top: 5)
    var notes = a.notes.map { "a: " + $0 } + b.notes.map { "b: " + $0 }
    if sa.stepSource != sb.stepSource { notes.append("the sides' steps come from different sources (a: \(sa.stepSource), b: \(sb.stepSource))") }
    let delta = m[0].b - m[0].a
    return DiffResult(scenario: scenario, normalisation: normalisation, a: sa, b: sb, deltaMsPerStep: Stats.round(delta, 1),
                      deltaPct: m[0].a > 0 ? Stats.round(100 * delta / m[0].a, 1) : nil,
                      tree: node(m, 0, floor: floor), treeFloorMs: Stats.round(floor, 2),
                      gains: gains, losses: losses, remaining: remaining, moved: moves(m, minMs: floor, reported: gains + losses), provenance: provenance, notes: notes)
  }

  /// The heaviest subtrees of one tree (ms per step) that are not run-loop plumbing and not mostly made of the
  /// subtrees reported inside them.
  public static func largest(_ t: CallTree, scale: Double, top: Int = 10) -> [DiffItem] {
    let m = merge(CallTree(n: t.n, v: 0), t, sa: 0, sb: scale)
    return Array(rank(m, minMs: max(0.25, 0.01 * m[0].b), specific: true).prefix(top))
  }

  /// Provenance before comparing (SPEC §6.1 item 4). `champion`: the build side a must be (a commit or a hash); a side
  /// that isn't it, or can't be told because it is unstamped, is stale. Different OS builds are cross-OS.
  public static func provenance(a: DiffSide, b: DiffSide, champion: String?, allowStale: Bool, allowCrossOS: Bool) -> DiffProvenance {
    var p = DiffProvenance(stale: false, crossOS: false, allowed: [], reasons: [])
    if let champion {
      if let ba = a.build, ba.commit != nil || ba.hash != nil {
        if !ba.matches(champion) { p.stale = true; p.reasons.append("a's build \(ba.label) ≠ champion \(champion)") }
      } else { p.stale = true; p.reasons.append("a is unstamped: can't tell whether it is champion \(champion)") }
    } else {
      let unstamped = [("a", a.build), ("b", b.build)].filter { $0.1?.commit == nil && $0.1?.hash == nil }.map(\.0)
      if !unstamped.isEmpty { p.reasons.append("\(unstamped.joined(separator: " and ")) unstamped: builds not checked") }
      if let x = a.build, let y = b.build, x.hash != nil, x.hash == y.hash { p.reasons.append("a and b are the same build (\(x.label))") }
    }
    if let x = a.os, let y = b.os, osBuild(x) != osBuild(y) { p.crossOS = true; p.reasons.append("recorded on different OS builds (\(x) vs \(y)): symbols may not match") }
    if allowStale { p.allowed.append("stale") }
    if allowCrossOS { p.allowed.append("crossOS") }
    return p
  }

  /// "Version 27.0.1 (Build 26A434)" (MachineInfo) and "27.0.1 (26A434)" (a trace's TOC) are the same OS build.
  static func osBuild(_ s: String) -> String {
    guard let o = s.range(of: "(", options: .backwards), let c = s.range(of: ")", options: .backwards), o.upperBound <= c.lowerBound else { return s }
    let inner = s[o.upperBound..<c.lowerBound]
    return String(inner.hasPrefix("Build ") ? inner.dropFirst(6) : inner)
  }
}

extension Explain {
  /// A diff as one screen of text: the totals, what grew and shrank (ms per step, a → b), moves, provenance.
  public static func diffText(_ r: DiffResult, top: Int = 8, width: Int = 150) -> String {
    func f(_ x: Double) -> String { String(format: "%.1f", x) }
    func signed(_ x: Double) -> String { (x >= 0 ? "+" : "−") + String(format: "%.1f", abs(x)) }
    func source(_ s: DiffSide) -> String {
      let p = (s.profile ?? s.trace ?? "?").split(separator: "/")
      return p.count > 3 ? "…/" + p.suffix(3).joined(separator: "/") : p.joined(separator: "/")
    }
    let unit = r.normalisation == "msPerRun" ? "ms per recording" : "ms per step"
    var o: [String] = []
    o.append("diff \(r.scenario == "-" ? "" : r.scenario + " ")(\(unit), main thread\(r.a.stepSource == "signpost" ? ", samples inside `step` signposts" : ""))")
    for (k, s) in [("a", r.a), ("b", r.b)] {
      o.append("  \(k)  \(f(s.msPerStep).leftPad(7)) ms  \(s.steps) steps (\(s.stepSource)), \(s.samples) samples  build \(s.build?.label ?? "unstamped")  \(source(s))")
    }
    o.append("  Δ  \(signed(r.deltaMsPerStep).leftPad(7)) ms\(r.deltaPct.map { " (\(signed($0)) %)" } ?? "")  b − a")
    func line(_ x: DiffItem, indent: String, values: Bool = true) -> String {
      var l = values ? "  \(signed(x.attributable).leftPad(7)) \(signed(x.d).leftPad(7))  \(f(x.a).leftPad(6)) → \(f(x.b).leftPad(6))  " : "  \(f(x.b).leftPad(7))  "
      l += "\(x.ours ? "*" : " ") \(indent)\(folded(x.chain))"
      if x.paths > 1 { l += "  [\(x.paths) paths]" }
      if let u = x.under, !x.chain.contains(u) { l += "  under \(u)" }
      return String(l.prefix(width))
    }
    // Ranked by Δ; a subtree reported inside another is listed under it (↳), the rest at the top level.
    func lines(_ xs: [DiffItem], _ title: String) {
      o.append("")
      o.append(title)
      if xs.isEmpty { o.append("  (nothing above \(f(r.treeFloorMs)) ms)"); return }
      let heads = Set(xs.map(\.symbol))
      var n = 0
      func emit(_ x: DiffItem, _ depth: Int) {
        guard n < top + 4 else { return }
        o.append(line(x, indent: depth == 0 ? "" : String(repeating: "  ", count: depth - 1) + "↳ ")); n += 1
        guard depth < 2 else { return }
        for k in xs.filter({ $0.inside == x.symbol && $0.symbol != x.symbol }).prefix(2) where abs(k.d) >= 0.2 * abs(x.d) { emit(k, depth + 1) }
      }
      for x in xs where x.inside == nil || !heads.contains(x.inside!) {
        guard n < top else { break }
        emit(x, 0)
      }
    }
    lines(r.losses, "grew in b (b slower)   attrib.       Δ       a →      b   (\(unit))")
    lines(r.gains, "shrank in b (b faster):")
    if !r.remaining.isEmpty {
      o.append("")
      o.append("largest in b (what is left):")
      for x in r.remaining.prefix(5) { o.append(line(x, indent: "", values: false)) }
    }
    if !r.moved.isEmpty {
      o.append("")
      for m in r.moved.prefix(4) { o.append("moved: \(m.symbol) from under \(m.fromUnder) (\(f(m.a)) ms) to under \(m.toUnder) (\(f(m.b)) ms)") }
    }
    o.append("")
    o.append("provenance: " + (r.provenance.refused ? "REFUSED: " : "") + (r.provenance.reasons.isEmpty ? "ok" : r.provenance.reasons.joined(separator: "; "))
             + (r.provenance.allowed.isEmpty ? "" : " (allowed: \(r.provenance.allowed.joined(separator: ", ")))"))
    for n in r.notes { o.append("note: " + n) }
    o.append("ranked by Δ; attrib. = the part of Δ that did not just move to another caller (mostly-moved subtrees are under moved:); a chain is the frames that moved together, outermost first;")
    o.append("[n paths] = summed over n call paths; * = our frame; --json for paths and the tree\(r.elapsedS.map { String(format: "; took %.1f s", $0) } ?? "")")
    return o.joined(separator: "\n")
  }

  /// A chain the way a flame graph folds it: `outer;next;next;…(k);inner`, leaving out noise frames and plumbing
  /// (blocks, closures, thunks, notification and dispatch trampolines) between the ends, names shortened.
  static func folded(_ chain: [String], keep: Int = 2) -> String {
    func short(_ s: String) -> String { s.count > 52 ? String(s.prefix(51)) + "…" : s }
    let names = chain.filter { !TraceSymbol.isNoise($0) }
    guard names.count > keep + 2 else { return names.map(short).joined(separator: ";") }
    let middle = names.dropFirst().dropLast().filter { !plumbing($0) }
    let shown = Array(middle.prefix(keep))
    let hidden = names.count - 2 - shown.count
    return ([names[0]] + shown + (hidden > 0 ? ["…(\(hidden))"] : []) + [names[names.count - 1]]).map(short).joined(separator: ";")
  }

  static func plumbing(_ s: String) -> Bool {
    ["block_invoke", "closure #", "thunk", "partial apply", "specialized ", "dispatch", "CFX", "Notification", "CALLING_OUT", "Observer", "_CFRunLoop", "__CF", "protocol witness"].contains { s.contains($0) }
  }
}

extension String {
  func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
