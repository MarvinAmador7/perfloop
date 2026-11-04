import Foundation
import PerfLoopKit

// `perfloop suggest [champion|exp/ID|RESULT.json]` (docs/BEYOND.md rank 2): the hypotheses PerfLoopKit's Suggest reads out
// of a build's newest result in the store, its newest profile, and the newest sweep of that build.

extension Loop {
  /// The newest measured result of a target: an experiment's candidate side (b) of its last pair, or the champion's side
  /// (a) in the newest experiment measured against it. Returns the result and where it came from.
  public func latestResult(_ x: String) throws -> (JSONValue, String)? {
    func last(_ e: Experiment, side: String) -> (JSONValue, String)? {
      for st in [e.full, e.screen].compactMap({ $0 }) {
        for p in st.pairs.reversed() where p.failure == nil {
          guard let rel = p.result, let v = try? PLJSON.read(JSONValue.self, path: store.abs(rel)), let r = v[side], r["reps"] != nil else { continue }
          return (r, "exp/\(e.id) \(rel) (\(side == "a" ? "champion" : "candidate") side)")
        }
      }
      return nil
    }
    if x.hasPrefix("exp/") { return last(try store.experiment(String(x.dropFirst(4))), side: "b") }
    let (c, _) = try requireChampion()
    for e in store.experiments().sorted(by: { $0.id > $1.id }) where e.parent?.experiment == c.experiment || e.parent?.build.hash == c.build.hash {
      if let r = last(e, side: "a") { return r }
    }
    // The champion was a candidate once: its own side b.
    if let e = try? store.experiment(c.experiment), let r = last(e, side: "b") { return r }
    return nil
  }

  /// The newest sweep of a build (`<store>/sweeps/*/sweep.json`).
  public func latestSweep(build: String) -> (SweepDoc, String)? {
    let dir = store.root.appendingPathComponent("sweeps")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    let docs = names.compactMap { n -> (SweepDoc, String, Date)? in
      let p = dir.appendingPathComponent(n).appendingPathComponent("sweep.json").path
      guard let d = try? PLJSON.read(SweepDoc.self, path: p), d.build?.hash == build else { return nil }
      let m = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date ?? .distantPast
      return (d, p, m)
    }
    return docs.max { $0.2 < $1.2 }.map { ($0.0, $0.1) }
  }

  /// `suggest`: a target in the store (champion, exp/ID) or a result file.
  public func suggest(_ x: String = "champion") throws -> SuggestDoc {
    if !Self.isProfileTarget(x) {
      let v = try PLJSON.read(JSONValue.self, path: x)
      return Suggest.make(result: v, sources: [x])
    }
    let t = try profileTarget(x)
    let r = try latestResult(x)
    var sources: [String] = []
    if let r { sources.append(r.1) }
    let prof = latestProfile(t).flatMap { p in (try? PLJSON.read(ProfileDoc.self, path: p)).map { (p, $0) } }
    if let p = prof { sources.append(store.rel(URL(fileURLWithPath: p.0))) }
    let sw = latestSweep(build: t.build)
    if let s = sw { sources.append(store.rel(URL(fileURLWithPath: s.1))) }
    guard r != nil || prof != nil || sw != nil else {
      throw PLError.usage("\(x) has nothing measured yet: screen an experiment against it (perfloop exp new …), profile it (perfloop profile \(x)), or pass a result: perfloop suggest RESULT.json")
    }
    return Suggest.make(result: r?.0, profile: prof?.1, sweep: sw?.0, sources: sources)
  }

  /// The few lines `explain.txt` carries: the top hypotheses for what to try next, from the side that is (or stays) the
  /// champion.
  func suggestLines(_ e: Experiment) -> [String] {
    guard e.kind != "baseline" else { return [] }
    let winning: Set<ExpState> = [.promising, .full, .won, .promoted]
    guard let r = try? latestResult("exp/\(e.id)") else { return [] }
    var v = r.0
    if !winning.contains(e.state), let p = [e.full, e.screen].compactMap({ $0 }).first?.pairs.last(where: { $0.failure == nil })?.result,
       let pv = try? PLJSON.read(JSONValue.self, path: store.abs(p)), let a = pv["a"] { v = a }
    let d = Suggest.make(result: v)
    guard !d.hypotheses.isEmpty else { return [] }
    return ["suggest (\(winning.contains(e.state) ? "this build" : "the champion"); leads, not conclusions; perfloop suggest for more):"]
      + d.hypotheses.prefix(3).map { "  [\($0.rule)\($0.share.map { ", up to \(Int(($0 * 100).rounded())) %" } ?? "")] \($0.hypothesis)" }
  }
}
