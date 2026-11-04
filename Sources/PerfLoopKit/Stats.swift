import Foundation

/// Order statistics, as the bench reports them: nearest-rank percentiles on the sorted sample, so a printed value is
/// one that was measured, never an interpolation (DeskBenchKit/Stats.swift, kept identical until the migration).
public enum Stats {
  public static func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    let rank = Int((p / 100 * Double(s.count)).rounded(.up))
    return s[max(0, min(s.count - 1, rank - 1))]
  }
  public static func median(_ xs: [Double]) -> Double { percentile(xs, 50) }
  /// Median absolute deviation: the spread that one wild repetition can't move.
  public static func mad(_ xs: [Double]) -> Double {
    guard xs.count > 1 else { return 0 }
    let m = median(xs)
    return median(xs.map { abs($0 - m) })
  }
  public static func round(_ x: Double, _ places: Int = 2) -> Double {
    let f = pow(10, Double(places)); return (x * f).rounded() / f
  }
}

/// A sample's shape in six numbers (`Dist` in deskbench.result/1).
public struct Dist: Codable, Sendable, Equatable {
  public var n: Int
  public var min: Double
  public var median: Double
  public var p95: Double
  public var max: Double
  public var mad: Double
  public init(_ xs: [Double]) {
    n = xs.count
    min = Stats.round(xs.min() ?? 0, 3); max = Stats.round(xs.max() ?? 0, 3)
    median = Stats.round(Stats.median(xs), 3); p95 = Stats.round(Stats.percentile(xs, 95), 3); mad = Stats.round(Stats.mad(xs), 3)
  }
}

/// The noise band of SPEC §5.1, kept from today's `Regression`: `max(1.4826 × MAD, floorPct of the champion's median,
/// absoluteFloor)`, the MAD being the larger of the two sides'. A difference inside it is noise.
public struct Band: Codable, Sendable, Equatable {
  public var width: Double
  /// As a share of the champion's median, in %.
  public var pct: Double
  public init(champion a: [Double], candidate b: [Double], floorPct: Double, absoluteFloor: Double) {
    let m = abs(Stats.median(a))
    let spread = max(Stats.mad(a), Stats.mad(b)) * 1.4826
    width = Stats.round(max(spread, m * floorPct / 100, absoluteFloor), 4)
    pct = m == 0 ? (width == 0 ? 0 : 100) : Stats.round(width / m * 100, 2)
  }
}

/// Mann-Whitney U (Wilcoxon rank-sum), two-sided. Exact by enumerating every split of the pooled mid-ranks when the
/// pool is small enough (≤ 20, the loop's 10 + 10 ceiling: 184 756 splits), which also makes ties exact; a normal
/// approximation with tie and continuity corrections above that. 5 v 5 fully separated gives p = 2/252 = 0.0079.
public enum MannWhitney {
  public struct Result: Codable, Sendable, Equatable {
    /// U for the first sample: pairs (a, b) with a > b, ties counting ½. Large U = a mostly above b.
    public var u: Double
    public var p: Double
    public var exact: Bool
  }

  public static func test(_ a: [Double], _ b: [Double]) -> Result {
    let m = a.count, n = b.count
    guard m > 0, n > 0 else { return Result(u: 0, p: 1, exact: true) }
    var u = 0.0
    for x in a { for y in b { u += x > y ? 1 : x == y ? 0.5 : 0 } }
    let ranks = midRanks(a + b)
    let w = ranks.prefix(m).reduce(0, +)
    let mean = Double(m) * Double(m + n + 1) / 2
    if m + n <= 20 {
      // P(|W − E| ≥ |w − E|) over all C(m+n, m) equally likely splits of the pooled ranks.
      let target = abs(w - mean) - 1e-9
      var hits = 0, total = 0
      func walk(_ i: Int, _ left: Int, _ sum: Double) {
        if left == 0 { total += 1; if abs(sum - mean) >= target { hits += 1 }; return }
        if ranks.count - i < left { return }
        walk(i + 1, left - 1, sum + ranks[i])
        walk(i + 1, left, sum)
      }
      walk(0, m, 0)
      return Result(u: u, p: Stats.round(Double(hits) / Double(total), 6), exact: true)
    }
    let N = Double(m + n)
    // Typed step by step: the one-expression form took Linux's type checker past its time limit.
    let groups: [Double: [Double]] = Dictionary(grouping: a + b, by: { $0 })
    let counts: [Double] = groups.values.map { Double($0.count) }
    let ties: Double = counts.reduce(0.0) { (acc: Double, t: Double) -> Double in acc + (t * t * t - t) }
    let variance = Double(m) * Double(n) / 12 * ((N + 1) - ties / (N * (N - 1)))
    guard variance > 0 else { return Result(u: u, p: 1, exact: false) }
    let z = max(0, abs(u - Double(m) * Double(n) / 2) - 0.5) / variance.squareRoot()
    return Result(u: u, p: Stats.round(min(1, erfc(z / 2.0.squareRoot())), 6), exact: false)
  }

  /// 1-based ranks with ties sharing the mean of the ranks they span, in input order.
  static func midRanks(_ xs: [Double]) -> [Double] {
    let order = xs.indices.sorted { xs[$0] < xs[$1] }
    var r = [Double](repeating: 0, count: xs.count)
    var i = 0
    while i < order.count {
      var j = i
      while j + 1 < order.count && xs[order[j + 1]] == xs[order[i]] { j += 1 }
      let mid = Double(i + j + 2) / 2
      for k in i...j { r[order[k]] = mid }
      i = j + 1
    }
    return r
  }
}

/// The sign test on paired differences, one-sided ("the candidate wins more often than chance"): P(X ≥ wins) for
/// X ~ Binomial(pairs without a tie, ½). 3 wins of 3 is p = 0.125 (SPEC §5.1: a screen can't reach significance).
public enum SignTest {
  public static func p(wins: Int, losses: Int) -> Double {
    let n = wins + losses
    guard n > 0 else { return 1 }
    var s = 0.0
    for k in wins...n { s += choose(n, k) }
    return Stats.round(s / pow(2, Double(n)), 6)
  }
  static func choose(_ n: Int, _ k: Int) -> Double {
    guard k >= 0, k <= n else { return 0 }
    var r = 1.0
    for i in 0..<min(k, n - k) { r = r * Double(n - i) / Double(i + 1) }
    return r
  }
}
