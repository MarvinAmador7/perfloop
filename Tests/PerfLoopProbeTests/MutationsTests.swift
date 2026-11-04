// swift-corelibs-xctest can't run a @MainActor test class (its discovery force-casts the test methods and traps), so
// these run on macOS only; the recorder is the same code on both.
#if canImport(Darwin)
import XCTest
@testable import PerfLoopProbe

/// Mutation records and their attribution to bodies (CAPABILITIES.md C7), without a window: the recorder is fed what
/// the app's setters and the bench's body probe and run-loop observer would feed it.
@MainActor final class MutationsTests: XCTestCase {
  func testNoSinkRecordsNothingAndCostsNothing() {
    // The app as it ships: no sink, so a record is a nil check. A million cost nothing next to a frame.
    Mutations.sink = nil
    let t = Date()
    for _ in 0..<1_000_000 { Mutations.record("T.x"); Mutations.record("T.y", id: "a") }
    XCTAssertLessThan(Date().timeIntervalSince(t), 0.5)
    XCTAssertNil(Mutations.sink)
  }

  func testRecordsReachTheSink() {
    var now = 0.0
    let r = CauseRecorder { now }
    Mutations.sink = r
    Mutations.record("M.a"); Mutations.record("M.b", id: "x")
    XCTAssertEqual(r.mutationCount, 2)
    now = 1; r.body("V")
    XCTAssertEqual(r.causes(from: 0, to: 2).map(\.keyPath).sorted(), ["M.a", "M.b"])
    Mutations.sink = nil
  }

  /// The acceptance shape: a tab click sets the model's focus and on-screen flags, and the update that follows
  /// re-evaluates all 17 columns: the record charges Column×17 to those mutations.
  func testATabClickChargesEveryColumnToFocusAndOnScreen() throws {
    var now = 0.0
    let r = CauseRecorder { now }
    let agents = (0..<17).map { "a\($0)" }
    // The click (CrewTab's action → DeskModel.scroll(to:)), then SwiftUI's update in the same turn.
    now = 10
    r.mutation("DeskModel.focusedAgent")
    for id in ["a3", "a0"] { r.mutation("AgentSlice.focused", id: id) }
    for id in ["a0", "a3"] { r.mutation("AgentSlice.onScreen", id: id) }
    now = 11
    for id in agents { r.body("Column", id: id) }
    r.body("OpenGroup")
    r.turnEnded()
    // The next turn: layout re-evaluates a body with no mutation before it.
    now = 20
    r.body("Reel")
    r.turnEnded()

    let click = r.causes(from: 9, to: 12)
    let focused = try XCTUnwrap(click.first { $0.keyPath == "AgentSlice.focused" })
    XCTAssertEqual(focused.bodies, ["Column": 17, "OpenGroup": 1])
    XCTAssertEqual(focused.count, 2); XCTAssertEqual(focused.ids, 2); XCTAssertEqual(focused.objects, ["Column": 17])
    XCTAssertEqual(click.first { $0.keyPath == "AgentSlice.onScreen" }?.bodies["Column"], 17)
    XCTAssertEqual(click.first { $0.keyPath == "DeskModel.focusedAgent" }?.ids, nil)
    XCTAssertFalse(click.contains { $0.keyPath == Cause.unrecorded })
    // The later turn's body follows no mutation: it is not charged to the click.
    XCTAssertEqual(r.causes(from: 19, to: 21), [Cause(keyPath: Cause.unrecorded, count: 0, bodies: ["Reel": 1])])
    // The whole run: both.
    XCTAssertEqual(r.causes(from: 0, to: 100).count, 4)
  }

  func testAnUpdateSwiftUIDefersKeepsItsMutations() {
    var now = 0.0
    let r = CauseRecorder { now }
    r.mutation("M.flag")
    r.turnEnded()                 // no bodies this turn: the update comes later
    now = 5
    r.body("V"); r.turnEnded()
    XCTAssertEqual(r.causes(from: 4, to: 6).map(\.keyPath), ["M.flag"])
  }

  func testAMutationAfterBodiesStartsANewUpdate() {
    var now = 0.0
    let r = CauseRecorder { now }
    r.mutation("M.first")
    now = 1; r.body("A"); r.body("A")
    r.mutation("M.second")        // a side effect of the update (onChange, updateNSView), same turn
    now = 2; r.body("B")
    r.turnEnded()
    let c = r.causes(from: 0, to: 3)
    XCTAssertEqual(c.first { $0.keyPath == "M.first" }?.bodies, ["A": 2])
    XCTAssertEqual(c.first { $0.keyPath == "M.second" }?.bodies, ["B": 1])
    XCTAssertEqual(c.map(\.keyPath), ["M.first", "M.second"])   // heaviest first
  }

  func testCausesRoundTripAndOlderDocumentsLackThem() throws {
    let c = Cause(keyPath: "AgentSlice.onScreen", count: 6, ids: 6, bodies: ["CrewTab": 6], objects: ["CrewTab": 6])
    XCTAssertEqual(try JSONDecoder().decode(Cause.self, from: JSONEncoder().encode(c)), c)
    let bare = try JSONDecoder().decode(Cause.self, from: Data(#"{"keyPath":"M.a","count":1,"bodies":{"V":2}}"#.utf8))
    XCTAssertNil(bare.ids); XCTAssertNil(bare.objects); XCTAssertEqual(bare.bodyTotal, 2)
  }
}
#endif
