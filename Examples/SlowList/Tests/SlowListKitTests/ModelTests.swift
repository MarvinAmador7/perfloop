import XCTest
@testable import SlowListKit

/// The model without a window: the slow and the fast rank agree, the sample is the same every run.
@MainActor final class ModelTests: XCTestCase {
  func testRanksAgree() {
    let m = ListModel.sample(count: 300)
    let table = m.ranks()
    for item in m.items.prefix(40) { XCTAssertEqual(m.rankBySorting(item), table[item.id]) }
    XCTAssertEqual(Set(table.values), Set(1...300))
  }

  func testSampleIsDeterministic() {
    XCTAssertEqual(ListModel.sample(count: 50).items, ListModel.sample(count: 50).items)
    XCTAssertNotEqual(ListModel.sample(count: 50, seed: 1).items, ListModel.sample(count: 50).items)
  }

  func testFilter() {
    let m = ListModel.sample(count: 200)
    m.filter = "ember"
    XCTAssertFalse(m.visible.isEmpty)
    XCTAssertTrue(m.visible.allSatisfy { $0.title.lowercased().contains("ember") })
  }

  func testTheKnobDefaultsToTheSlowPath() {
    XCTAssertEqual(ListKnobs.rank.defaultValue, .sort)
    XCTAssertEqual(ListKnobs.rank.info.choices, ["sort", "index"])
  }
}
