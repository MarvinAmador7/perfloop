import XCTest
@testable import PerfLoopProbe

/// C4: knobs read their setting once, fall back to the default on anything they refuse, and register for `describe`.
/// Every test here passes its settings explicitly; only `EnvironmentTests` reads `PERFLOOP_KNOBS` itself.
final class KnobsTests: XCTestCase {
  enum Slide: String, KnobValue, CaseIterable { case ca, clip }

  func testParseAndFormat() {
    XCTAssertEqual(Knobs.parse("reel.slide=clip, build.perFrame = 3"), ["reel.slide": "clip", "build.perFrame": "3"])
    XCTAssertEqual(Knobs.parse(""), [:])
    XCTAssertEqual(Knobs.parse("a=1,,b=x=y"), ["a": "1", "b": "x=y"])
    XCTAssertEqual(Knobs.parse("a=1,a=2"), ["a": "2"], "a later entry wins")
    XCTAssertEqual(Knobs.parse("a=1,junk,=3"), ["a": "1"])
    XCTAssertEqual(Knobs.malformed("a=1,junk,=3"), ["junk", "=3"])
    XCTAssertEqual(Knobs.format(["b": "2", "a": "1"]), "a=1,b=2")
    XCTAssertEqual(Knobs.parse(Knobs.format(["reel.slide": "clip", "build.perFrame": "8"])), ["reel.slide": "clip", "build.perFrame": "8"])
  }

  func testDefaultWithoutSetting() {
    let k = Knob("t.default.slide", default: Slide.ca, choices: Slide.allCases, settings: [:])
    XCTAssertEqual(k.value, .ca); XCTAssertEqual(k(), .ca); XCTAssertTrue(k.isDefault)
    let n = Knob("t.default.n", default: 1, range: 1...8, settings: [:])
    XCTAssertEqual(n.value, 1)
  }

  func testSettingChangesTheValue() {
    let s = Knobs.parse("t.set.slide=clip,t.set.n=5,t.set.s=hello,t.set.b=on")
    XCTAssertEqual(Knob("t.set.slide", default: Slide.ca, choices: Slide.allCases, settings: s).value, .clip)
    XCTAssertEqual(Knob("t.set.n", default: 1, range: 1...8, settings: s).value, 5)
    XCTAssertEqual(Knob("t.set.s", default: "x", settings: s).value, "hello")
    XCTAssertEqual(Knob("t.set.b", default: false, settings: s).value, true)
    XCTAssertEqual(Knob("t.set.str", default: "ca", choices: ["ca", "clip"], settings: ["t.set.str": "clip"]).value, "clip")
  }

  func testRefusedSettingFallsBackAndSaysWhy() {
    let k = Knob("t.bad.slide", default: Slide.ca, choices: Slide.allCases, settings: ["t.bad.slide": "warp"])
    XCTAssertEqual(k.value, .ca)
    let n = Knob("t.bad.n", default: 2, range: 1...8, settings: ["t.bad.n": "9"])
    XCTAssertEqual(n.value, 2)
    let x = Knob("t.bad.x", default: 2, range: 1...8, settings: ["t.bad.x": "two"])
    XCTAssertEqual(x.value, 2)
    let problems = Knobs.problems(in: ["t.bad.slide": "warp", "t.bad.n": "9", "t.bad.x": "two", "t.nobody": "1"], raw: "t.bad.slide=warp,oops")
    XCTAssertTrue(problems.contains { $0.contains("t.bad.slide=warp") && $0.contains("not one of ca, clip") && $0.contains("default ca") }, "\(problems)")
    XCTAssertTrue(problems.contains { $0.contains("t.bad.n=9") && $0.contains("outside 1…8") }, "\(problems)")
    XCTAssertTrue(problems.contains { $0.contains("t.bad.x=two") && $0.contains("not a valid int") }, "\(problems)")
    XCTAssertTrue(problems.contains { $0.contains("unknown knob 't.nobody'") }, "\(problems)")
    XCTAssertTrue(problems.contains { $0.contains("'oops' is not name=value") }, "\(problems)")
  }

  func testCheckValidatesAProposedSettingAgainstTheRegistry() {
    _ = Knob("t.check.slide", default: Slide.ca, choices: Slide.allCases, settings: [:])
    _ = Knob("t.check.n", default: 1, range: 1...8, settings: [:])
    XCTAssertEqual(Knobs.check(["t.check.slide": "clip", "t.check.n": "8"]), [])
    let p = Knobs.check(["t.check.slide": "nope", "t.check.n": "0", "t.check.missing": "1"])
    XCTAssertEqual(p.count, 3, "\(p)")
  }

  func testRegistryListsKnobsAndTheirValues() {
    _ = Knob("t.reg.slide", default: Slide.ca, choices: Slide.allCases, summary: "how the reel slides", since: "p2", settings: ["t.reg.slide": "clip"])
    _ = Knob("t.reg.n", default: 1, range: 1...8, settings: [:])
    let info = Knobs.registered.first { $0.name == "t.reg.slide" }
    XCTAssertEqual(info, KnobInfo(name: "t.reg.slide", type: "choice", default: "ca", choices: ["ca", "clip"], summary: "how the reel slides", since: "p2"))
    XCTAssertEqual(Knobs.registered.first { $0.name == "t.reg.n" }?.range, ["1", "8"])
    XCTAssertEqual(Knobs.vector["t.reg.slide"], "clip")
    XCTAssertEqual(Knobs.vector["t.reg.n"], "1", "the vector carries defaults too")
    // Making the same knob again replaces it (one entry per name).
    _ = Knob("t.reg.n", default: 1, range: 1...8, settings: ["t.reg.n": "4"])
    XCTAssertEqual(Knobs.registered.filter { $0.name == "t.reg.n" }.count, 1)
    XCTAssertEqual(Knobs.vector["t.reg.n"], "4")
  }

  func testManifestJSONHasNumbersForNumericKnobs() throws {
    let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
    let n = KnobInfo(name: "build.perFrame", type: "int", default: "1", range: ["1", "8"])
    XCTAssertEqual(String(decoding: try e.encode(n), as: UTF8.self), #"{"default":1,"name":"build.perFrame","range":[1,8],"type":"int"}"#)
    let c = KnobInfo(name: "reel.slide", type: "choice", default: "ca", choices: ["ca", "clip"])
    XCTAssertEqual(String(decoding: try e.encode(c), as: UTF8.self), #"{"choices":["ca","clip"],"default":"ca","name":"reel.slide","type":"choice"}"#)
    for k in [n, c] { XCTAssertEqual(try JSONDecoder().decode(KnobInfo.self, from: e.encode(k)), k) }
  }

  func testAReadIsCheap() {
    // The value is stored in the knob: a million reads take no measurable time next to the frame budget.
    let k = Knob("t.cheap.n", default: 1, range: 1...8, settings: [:])
    let t = Date()
    var sum = 0
    for _ in 0..<1_000_000 { sum &+= k.value }
    XCTAssertEqual(sum, 1_000_000)
    XCTAssertLessThan(Date().timeIntervalSince(t), 0.5)
  }
}

/// The only test that reads the process's own `PERFLOOP_KNOBS` (it is parsed once, on first use).
final class EnvironmentTests: XCTestCase {
  func testEnvironmentSetsKnobs() {
    setenv(Knobs.variable, "t.env.slide=clip,t.env.n=3", 1)
    XCTAssertEqual(Knobs.settings, ["t.env.slide": "clip", "t.env.n": "3"])
    XCTAssertEqual(Knob("t.env.slide", default: "ca", choices: ["ca", "clip"]).value, "clip")
    XCTAssertEqual(Knob("t.env.n", default: 1, range: 1...8).value, 3)
    XCTAssertEqual(Knob("t.env.unset", default: 1, range: 1...8).value, 1)
  }
}
