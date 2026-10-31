import Foundation
@testable import PerfLoopKit

/// Deterministic samples for the acceptance tests: a 64-bit LCG with a Box-Muller normal, so a failing seed is
/// reproducible.
struct LCG {
  var state: UInt64
  init(_ seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
  mutating func uniform() -> Double { state = state &* 6364136223846793005 &+ 1442695040888963407; return Double(state >> 11) / Double(1 << 53) }
  mutating func normal(_ mean: Double, _ sd: Double) -> Double {
    let u = max(uniform(), 1e-12), v = uniform()
    return mean + sd * (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
  }
}

/// `n` pairs, champion ~ N(a, a·cv), candidate ~ N(b, b·cv), alternating order.
func pairs(_ n: Int, a: Double, b: Double, cv: Double = 0.03, seed: UInt64, checksB: [String] = [], hitchA: Double = 2, hitchB: Double = 2) -> [Pair] {
  var g = LCG(seed)
  return (0..<n).map { i in
    var sa = Side(objective: Stats.round(g.normal(a, a * cv), 3), hitch: hitchA, longest: 40)
    var sb = Side(objective: Stats.round(g.normal(b, b * cv), 3), hitch: hitchB, longest: 40, checksFailed: checksB)
    sa.steadyHz = 120; sb.steadyHz = 120
    return Pair(index: i, order: i % 2 == 0 ? "AB" : "BA", result: nil, a: sa, b: sb)
  }
}

func pairs(a: [Double], b: [Double]) -> [Pair] {
  zip(a, b).enumerated().map { i, v in Pair(index: i, order: "AB", result: nil, a: Side(objective: v.0), b: Side(objective: v.1)) }
}
