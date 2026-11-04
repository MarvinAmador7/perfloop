import Foundation

// `perfloop suggest` (docs/BEYOND.md, rank 2): ranked hypotheses for the next experiment, from what a run already
// records: the cause records (which state change re-evaluated how many bodies), the sampled stacks of the worst
// stretches (our frames, and the framework work under them), a profile's largest subtrees, a sweep's walls. Each says
// what it saw, the share of the objective it could remove at most, and what to check before changing code. They are
// leads, not conclusions: the rules were written from two apps (capcomd's Desktop in JOURNEY.md, SlowList), and the
// loop, not this file, decides whether a change wins.

public let suggestSchema = "perfloop.suggest/1"

public struct Hypothesis: Codable, Sendable, Equatable {
  /// fan-out | repeated-body | hot-frame | framework-under-ours | profile | waiting | frames-not-cpu | wall.
  public var rule: String
  /// One sentence for `exp new`: the cost and why the change would remove it.
  public var hypothesis: String
  /// What the records say, line by line.
  public var evidence: [String]
  /// At most this share (0–1) of the objective could go: the cost the hypothesis names, measured.
  public var share: Double?
  /// What to look at before writing the change.
  public var check: String
}

public struct SuggestDoc: Codable, Sendable, Equatable {
  public var schema = suggestSchema
  /// What was read: the result, the profile, the sweep.
  public var sources: [String]
  public var objective: String?
  public var objectiveValue: Double?
  public var hypotheses: [Hypothesis]
  public var notes: [String]
}

public enum Suggest {
  /// Run-loop and SwiftUI plumbing frames: never "the" cost.
  static func plumbing(_ s: String) -> Bool {
    s.hasPrefix("(") || s.hasPrefix("closure #") || s.hasPrefix("implicit closure") || s.hasPrefix("thunk") || s.hasPrefix("partial apply") || s.hasPrefix("specialized ")
      || s.hasPrefix("protocol witness") || s.hasPrefix("AG::") || s.hasPrefix("__CF") || s.hasPrefix("CA::") || s.hasPrefix("_dispatch") || s.contains("RunLoop")
      || s.hasPrefix("Unsafe") || s.hasPrefix("Array") || s.hasPrefix("Dictionary") || s.hasPrefix("Swift.") || s.hasPrefix("MutableCollection") || s.hasPrefix("Sequence")
      || s.hasPrefix("Collection") || s.hasPrefix("main") || s == "start" || s.hasPrefix("NSApplication") || s.hasPrefix("-[NSApplication")
      || s.hasPrefix("MainActor.") || s.hasPrefix("swift_") || s.hasPrefix("_swift") || s.hasPrefix("Task") || s.hasPrefix("_os_") || s.hasPrefix("__ulock")
      || s.hasPrefix("mach_") || s.hasPrefix("objc_") || TraceSymbol.isHarness(s)
  }
  /// Fewer samples than this (summed over the worst stretches) say nothing about where time goes.
  static let minSamples = 10.0
  static func isBody(_ s: String) -> Bool { s.hasSuffix(".body.getter") || s.hasSuffix(".body") }
  static func pct(_ x: Double) -> String { "\(Int((x * 100).rounded())) %" }

  /// Hypotheses from a `perfloop.result/2` (or `deskbench.result/1`), and optionally the same build's profile and a sweep.
  public static func make(result r: JSONValue?, profile: ProfileDoc? = nil, sweep: SweepDoc? = nil, sources: [String] = []) -> SuggestDoc {
    var hs: [Hypothesis] = []
    var notes: [String] = []
    let reps = r?["reps"]?.array ?? []
    let objective = r?["summary"]?["objective"]?["name"]?.string
    let objValue = r?["summary"]?["objective"]?["value"]?.double
    let steps = reps.flatMap { $0["steps"]?.array ?? [] }
    let stepCpu = steps.reduce(0.0) { $0 + ($1["cpuMs"]?.double ?? 0) }
    let worst = reps.flatMap { $0["worstStretches"]?.array ?? [] }
    if r != nil && worst.allSatisfy({ $0["topOurs"] == nil && $0["stacks"] == nil }) { notes.append("no sampled stacks in this result (the sampler was off, or not Apple silicon): the stack rules had nothing to read") }

    // The share of each worst stretch's samples our frame X was in, and the body it ran under.
    var oursShare: [String: (samples: Double, total: Double, under: String?)] = [:]
    for w in worst {
      guard let total = w["samples"]?.double, total > 0 else { continue }
      let ours = w["topOurs"]?.array ?? []
      let body = ours.first { isBody($0["symbol"]?.string ?? "") }?["symbol"]?.string
      for o in ours {
        guard let s = o["symbol"]?.string, let n = o["samples"]?.double else { continue }
        var e = oursShare[s] ?? (0, 0, nil)
        e.samples += n; e.total += total; if !isBody(s) { e.under = e.under ?? body }
        oursShare[s] = e
      }
    }
    let bodyShare: [String: Double] = oursShare.filter { isBody($0.key) }.reduce(into: [:]) { d, kv in
      let view = String(kv.key.split(separator: ".").first ?? "")
      d[view] = max(d[view] ?? 0, kv.value.samples / kv.value.total)
    }

    // 1. Fan-out: a state change re-evaluated many instances of a view, while few of them changed what they show.
    struct Fan { var keyPath: String; var view: String; var bodies = 0.0; var objects = 0.0; var sets = 0.0; var changed = 0.0; var steps = 0; var cpu = 0.0 }
    var fans: [String: Fan] = [:]
    for st in steps {
      let bodies = st["bodies"]?.object?.compactMapValues(\.double) ?? [:]
      for c in st["causes"]?.array ?? [] {
        guard let kp = c["keyPath"]?.string else { continue }
        for (view, n) in c["bodies"]?.object?.compactMapValues(\.double) ?? [:] where n >= 4 {
          let objects = c["objects"]?[view]?.double ?? n
          // What changed on screen: the fewest bodies of another view in the same step that followed the same change
          // (the rows' content), else the objects the change was made on.
          let others = (c["bodies"]?.object?.compactMapValues(\.double) ?? [:]).filter { $0.key != view && $0.value < n }.values
          let changed = others.min() ?? c["ids"]?.double ?? c["count"]?.double ?? 1
          guard objects >= 4, changed <= objects / 3 else { continue }
          var f = fans["\(kp) \(view)"] ?? Fan(keyPath: kp, view: view)
          f.bodies += n; f.objects += objects; f.sets += c["count"]?.double ?? 1; f.changed += changed; f.steps += 1; f.cpu += st["cpuMs"]?.double ?? 0
          fans["\(kp) \(view)"] = f
          _ = bodies
        }
      }
    }
    for f in fans.values.sorted(by: { ($0.cpu, $0.view) > ($1.cpu, $1.view) }) {
      let n = f.bodies / Double(f.steps), m = f.changed / Double(f.steps)
      // The probe's name for a view (`Row`) and its type's body in the stacks (`RowView.body.getter`) usually share a stem.
      let inBody = bodyShare[f.view] ?? bodyShare.filter { $0.key.hasPrefix(f.view) || f.view.hasPrefix($0.key) }.values.max()
      let share = stepCpu > 0 ? (f.cpu / stepCpu) * (inBody ?? 0.5) * max(0, 1 - m / n) : nil
      var ev = ["\(f.steps) step(s): each change of \(f.keyPath) re-evaluated \(f.view)×\(Int(n.rounded())) (\(Int((f.objects / Double(f.steps)).rounded())) instances) while ~\(Int(m.rounded())) of them changed what they show"]
      if let b = inBody { ev.append("\(f.view).body held \(pct(b)) of the worst stretches' samples") }
      hs.append(Hypothesis(rule: "fan-out",
                           hypothesis: "every \(f.view) re-evaluates when \(f.keyPath) changes although only ~\(Int(m.rounded())) of \(Int(n.rounded())) need to: give \(f.view) the values it shows (an Equatable value, or per-instance state) so a change re-evaluates only those",
                           evidence: ev, share: share.map { Stats.round($0, 3) },
                           check: "find where \(f.view)'s body reads \(f.keyPath) (directly or through a model it holds); a knob that passes values instead is a one-binary experiment"))
    }

    // 2. The same body more than once per instance in one step: two hosts on one model, or a body invalidating itself.
    var repeated: [String: (ratio: Double, steps: Int, n: Double)] = [:]
    for st in steps {
      for c in st["causes"]?.array ?? [] {
        for (view, n) in c["bodies"]?.object?.compactMapValues(\.double) ?? [:] {
          guard let o = c["objects"]?[view]?.double, o >= 1, n >= 2 * o else { continue }
          var e = repeated[view] ?? (0, 0, 0); e.ratio = max(e.ratio, n / o); e.steps += 1; e.n += n; repeated[view] = e
        }
      }
    }
    for (view, e) in repeated.sorted(by: { $0.value.n > $1.value.n }) {
      hs.append(Hypothesis(rule: "repeated-body",
                           hypothesis: "\(view)'s body runs \(Stats.round(e.ratio, 1))× per instance per update: two hosts showing one model, or a body that changes state it reads; one evaluation per instance would remove the rest",
                           evidence: ["\(e.steps) step(s) with \(view) evaluated ≥ 2× per instance (\(Int(e.n)) bodies)"],
                           share: bodyShare[view].map { Stats.round($0 * (1 - 1 / e.ratio), 3) },
                           check: "count the windows or hosting views showing the model (the bench's own set-up included: capcomd's two-window bench bug looked exactly like this), then look for state written during body or layout"))
    }

    // 3. A frame of ours that holds much of the worst stretches.
    let hot = oursShare.filter { !isBody($0.key) && !plumbing($0.key) && $0.value.total >= minSamples && $0.value.samples / $0.value.total >= 0.3 }
    // The deepest of nested ones says the most: drop a frame when a hotter-or-equal one of ours is inside it (by name order, the callee holds ≤ the caller).
    let ranked = hot.sorted { ($0.value.samples / $0.value.total, $0.key) > ($1.value.samples / $1.value.total, $1.key) }
    for (sym, e) in ranked.prefix(3) {
      let s = e.samples / e.total
      let via = e.under.map { " under \($0)" } ?? ""
      let perBody = e.under.map { b -> String in
        let view = String(b.split(separator: ".").first ?? "")
        let n = steps.compactMap { st in st["bodies"]?[view]?.double ?? st["bodies"]?.object?.filter { view.hasPrefix($0.key) }.compactMap(\.value.double).max() }.max()
        return n.map { ", once per \(view) body (×\(Int($0)) in a step)" } ?? ""
      } ?? ""
      hs.append(Hypothesis(rule: "hot-frame",
                           hypothesis: "\(sym) holds \(pct(s)) of the worst stretches\(via)\(perBody): computing it once per change (a cache or an index) or passing the result in would remove most of it",
                           evidence: ["\(sym): \(Int(e.samples)) of \(Int(e.total)) samples in the worst stretches\(via)"],
                           share: worstShare(s, worst: worst, steps: steps).map { Stats.round($0, 3) },
                           check: "read \(sym): what does it redo each call that depends only on data that didn't change?"))
    }

    // 4. Framework work that one of our frames asks for.
    var fw: [String: (samples: Double, total: Double, under: String)] = [:]
    for w in worst {
      guard let total = w["samples"]?.double, total > 0 else { continue }
      for f in w["topFramework"]?.array ?? [] {
        guard let s = f["symbol"]?.string, let n = f["samples"]?.double, let u = f["under"]?.string, !plumbing(s), !StackProfile.isTrunk(s) else { continue }
        var e = fw[s] ?? (0, 0, u); e.samples += n; e.total += total; fw[s] = e
      }
    }
    for (sym, e) in fw.filter({ $0.value.total >= minSamples && $0.value.samples / $0.value.total >= 0.3 && !plumbing($0.value.under) }).sorted(by: { ($0.value.samples, $0.key) > ($1.value.samples, $1.key) }).prefix(2) {
      let s = e.samples / e.total
      hs.append(Hypothesis(rule: "framework-under-ours",
                           hypothesis: "\(sym) (\(pct(s)) of the worst stretches) runs because \(e.under) asks for it: answering it from \(e.under) (a size, a cached layout, fewer views) would remove it",
                           evidence: ["\(sym): \(Int(e.samples)) of \(Int(e.total)) samples, under \(e.under)"],
                           share: worstShare(s, worst: worst, steps: steps).map { Stats.round($0, 3) },
                           check: "what in \(e.under) triggers \(sym) each step (layout invalidation, a size query, view creation)?"))
    }

    // 5. The profile's largest subtrees of ours.
    if let p = profile, let t = p.treeInSteps ?? p.tree, let msps = p.msPerStep ?? p.sampleIntervalMs.map({ Double(t.v) * $0 }) {
      let n = max(1, p.steps?.count ?? 1)
      for x in Diff.largest(t, scale: (p.sampleIntervalMs ?? 1) / Double(n), top: 8).filter(\.ours).prefix(2) where msps > 0 {
        hs.append(Hypothesis(rule: "profile",
                             hypothesis: "\(x.symbol) costs \(Stats.round(x.b, 1)) ms per step in the profile\(x.under.map { " under \($0)" } ?? ""): making it cheaper removes up to that",
                             evidence: ["profile (\(p.template)): \(Explain.folded(x.chain)), \(Stats.round(x.b, 1)) of \(Stats.round(msps, 1)) ms per step"],
                             share: Stats.round(x.b / msps, 3), check: "perfloop diff champion exp/ID after the change shows whether it moved or went"))
      }
    }

    // 6. A latency far above the main thread's work: the step waits.
    if objective == "latencyMs", let lat = r?["summary"]?["latencyMs"]?["median"]?.double, let cpu = r?["summary"]?["mainThreadCpuMsPerStep"]?["median"]?.double, lat > 3 * cpu, lat - cpu > 30 {
      hs.append(Hypothesis(rule: "waiting",
                           hypothesis: "a step takes \(Stats.round(lat, 1)) ms to show its change but the main thread works \(Stats.round(cpu, 1)) ms: the rest is waiting (a timer, a debounce, an async hop, work off the main thread), which a cheaper body won't fix",
                           evidence: ["latency median \(Stats.round(lat, 1)) ms vs main-thread CPU \(Stats.round(cpu, 1)) ms per step"],
                           share: Stats.round((lat - cpu) / lat, 3), check: "what does the step wait for between the action and the frame that shows it?"))
    }

    // 7. Late frames with little main-thread work: the render server or the GPU.
    if let h = r?["summary"]?["hitchTimeRatioMsPerS"]?["median"]?.double, let cpu = r?["summary"]?["mainThreadCpuMsPerStep"]?["median"]?.double, let hz = r?["summary"]?["steadyHz"]?["median"]?.double,
       h > 10, cpu < 0.5 * 1000 / max(hz, 1) {
      hs.append(Hypothesis(rule: "frames-not-cpu",
                           hypothesis: "frames are late (\(Stats.round(h, 1)) ms/s) although the main thread works only \(Stats.round(cpu, 1)) ms a step: the cost is in rendering (layers, blur, offscreen passes), not in the app's code",
                           evidence: ["hitch time \(Stats.round(h, 1)) ms/s at \(Int(hz)) Hz, main-thread CPU \(Stats.round(cpu, 1)) ms per step"],
                           share: nil, check: "perfloop profile champion --template hitches: the compositor's hitch causes"))
    }

    // 8. A sweep's walls.
    if let d = sweep {
      for w in (d.walls ?? Sweep.walls(d)) where w.kind == "inside" || w.kind == "extrapolated" || w.kind == "already" {
        hs.append(Hypothesis(rule: "wall", hypothesis: Sweep.wallSentence(w, objective: d.objective).replacingOccurrences(of: "wall: ", with: "") + ": the cost per \(w.axis) is the target, not the cost at today's size",
                             evidence: ["sweep \(d.scenario) on \(d.fixture), \(d.points.count) point(s)"] + (d.fits.first { $0.axis == w.axis && $0.at == w.at && $0.model == "linear" }.map { [Sweep.sentence($0, objective: d.objective)] } ?? []),
                             share: nil, check: "which work grows with \(w.axis)? the profile's per-step tree at two sizes (diff) says"))
      }
    }

    // Ranked by the share they could remove; unknown shares last.
    hs.sort { ($0.share ?? -1, $1.rule) > ($1.share ?? -1, $0.rule) }
    if hs.isEmpty { notes.append("nothing stood out: no fan-out, no repeated bodies, no frame of ours over 30 % of the worst stretches") }
    return SuggestDoc(sources: sources, objective: objective, objectiveValue: objValue, hypotheses: hs, notes: notes)
  }

  /// A share of the worst stretches' samples as a share of the CPU of the steps they came from: what the frame costs
  /// in a step like those (the steps without a worst stretch aren't sampled into the result, so they don't count).
  static func worstShare(_ s: Double, worst: [JSONValue], steps: [JSONValue]) -> Double? {
    let cpuByStep = steps.reduce(into: [String: Double]()) { $0[$1["name"]?.string ?? "", default: 0] = max($0[$1["name"]?.string ?? ""] ?? 0, $1["cpuMs"]?.double ?? 0) }
    let w = worst.reduce(0.0) { $0 + ($1["cpuMs"]?.double ?? 0) }
    let d = worst.reduce(0.0) { $0 + (cpuByStep[$1["step"]?.string ?? ""] ?? ($1["cpuMs"]?.double ?? 0)) }
    guard d > 0, w > 0 else { return nil }
    return min(1, s * w / d)
  }

  public static func text(_ d: SuggestDoc, top: Int = 6) -> String {
    var head: String = "suggest: \(d.hypotheses.count) hypothes" + (d.hypotheses.count == 1 ? "is" : "es")
    if let ob = d.objective { head += " for " + ob }
    if let v = d.objectiveValue { head += " (\(Stats.round(v, 2)) now)" }
    if !d.sources.isEmpty { head += " from " + d.sources.joined(separator: ", ") }
    var o: [String] = [head]
    for (i, h) in d.hypotheses.prefix(top).enumerated() {
      o.append("\(i + 1). [\(h.rule)\(h.share.map { ", up to \(pct($0))" } ?? "")] \(h.hypothesis)")
      for e in h.evidence { o.append("     evidence: \(e)") }
      o.append("     check: \(h.check)")
    }
    if d.hypotheses.count > top { o.append("(\(d.hypotheses.count - top) more: --json)") }
    for n in d.notes { o.append("note: " + n) }
    o.append("leads, not conclusions: the loop decides (one idea per experiment, perfloop exp new \"<hypothesis>\")")
    return o.joined(separator: "\n")
  }
}
