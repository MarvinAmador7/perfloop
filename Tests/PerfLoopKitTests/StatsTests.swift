import XCTest
@testable import PerfLoopKit

final class StatsTests: XCTestCase {
  func testMannWhitneyExact() {
    XCTAssertEqual(MannWhitney.test([1, 2, 3, 4, 5], [6, 7, 8, 9, 10]).p, 2.0 / 252, accuracy: 1e-6)
    XCTAssertEqual(MannWhitney.test([1, 2, 3, 4, 5], [6, 7, 8, 9, 10]).u, 0)
    XCTAssertEqual(MannWhitney.test([1, 2, 3], [1, 2, 3]).p, 1)
    // Ties are handled exactly (mid-ranks): a pool of one value can't tell the sides apart.
    XCTAssertEqual(MannWhitney.test([5, 5, 5, 5], [5, 5, 5, 5]).p, 1)
    let r = MannWhitney.test(Array(stride(from: 1.0, through: 10, by: 1)), Array(stride(from: 11.0, through: 20, by: 1)))
    XCTAssertTrue(r.exact); XCTAssertEqual(r.p, 2.0 / 184_756, accuracy: 1e-6)
  }

  func testMannWhitneyNormalAboveTwenty() {
    let a = (0..<15).map(Double.init), b = (0..<15).map { Double($0) + 20 }
    let r = MannWhitney.test(a, b)
    XCTAssertFalse(r.exact); XCTAssertLessThan(r.p, 1e-4)
    XCTAssertGreaterThan(MannWhitney.test(a, a.map { $0 + 0.5 }).p, 0.5)
  }

  func testSignTest() {
    XCTAssertEqual(SignTest.p(wins: 3, losses: 0), 0.125)
    XCTAssertEqual(SignTest.p(wins: 5, losses: 0), 0.03125)
    XCTAssertEqual(SignTest.p(wins: 0, losses: 3), 1)
  }

  func testBandIsKeptFromDeskBench() {
    // max(1.4826 × MAD, floorPct, absoluteFloor): a quiet sample gets the floor.
    XCTAssertEqual(Band(champion: [40, 40, 40], candidate: [20, 20, 20], floorPct: 5, absoluteFloor: 0.5).pct, 5)
    XCTAssertEqual(Band(champion: [1, 1, 1], candidate: [1, 1, 1], floorPct: 5, absoluteFloor: 0.5).pct, 50)
    let noisy = Band(champion: [30, 40, 50], candidate: [40, 40, 40], floorPct: 5, absoluteFloor: 0)
    XCTAssertEqual(noisy.width, 14.826, accuracy: 1e-3)
  }

  func testNearestRankPercentiles() {
    XCTAssertEqual(Stats.median([3, 1, 2, 4]), 2)                     // a measured value, never 2.5
    XCTAssertEqual(Stats.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 95), 10)
  }

  func testSHA256() {
    XCTAssertEqual(PlainSHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    XCTAssertEqual(PlainSHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    let long = Data((0..<1000).map { UInt8($0 % 251) })
    XCTAssertEqual(PlainSHA256.hex(long), FileHash.sha256(long))      // CryptoKit on macOS, itself on Linux
  }
}
