import XCTest
@testable import PerfLoopKit

/// The documents of SCHEMAS.md round-trip, and the adapter's output is read loosely: fields it adds change nothing,
/// fields an older bench lacks are derived.
final class SchemaTests: XCTestCase {
  func roundTrip<T: Codable & Equatable>(_ v: T, file: StaticString = #filePath, line: UInt = #line) throws {
    XCTAssertEqual(try PLJSON.decode(T.self, from: Data(PLJSON.encode(v).utf8)), v, file: file, line: line)
  }

  func testBuildRoundTripsAndReadsDeskbenchsBlock() throws {
    let b = Build(hash: "sha256:a30d", commit: "e38a4a6", dirty: true, sourceHash: "sha256:1dc3", builtAt: "2026-10-31T03:40:54Z", toolchain: "Xcode 27.1", stamp: true)
    try roundTrip(b)
    let v = try PLJSON.decode(JSONValue.self, from: Data(#"{"builtAt":"2026-10-31T03:40:54Z","commit":"e38a4a6","configuration":"release","dirty":true,"hash":"sha256:a30d","sourceHash":"sha256:1dc3","stamp":true,"toolchain":"Xcode 27.1","future":1}"#.utf8))
    XCTAssertEqual(Build(json: v), b)
    XCTAssertEqual(Build(json: .object([:]))?.dirty, true)              // unknown is dirty
    XCTAssertEqual(Build.short("sha256:3f2a9c01b7d4e5f6"), "3f2a9c01b7d4")
  }

  func testManifestDecodesLeniently() throws {
    let text = #"""
    { "schema": "perfloop.manifest/1", "protocol": 1, "app": "capcomd-desktop", "adapter": "deskbench",
      "scenarios": [ { "name": "step", "kind": "smooth", "params": { "steps": "8" }, "objective": "mainThreadCpuMsPerStep",
                       "guards": ["landed", "built-within"], "guardParams": { "built-within.ms": 300 }, "secondFixture": "swarm64", "newThing": [1] } ],
      "fixtures": [ { "name": "crew17", "agents": 17, "parametric": { "agents": [1, 64] } } ],
      "knobs": [ { "name": "reel.slide", "type": "choice", "default": "ca", "choices": ["ca", "clip"] },
                 { "name": "build.perFrame", "type": "int", "default": 2, "range": [1, 8] } ],
      "hosts": ["scene", "window"], "somethingNew": true }
    """#
    let m = try PLJSON.decode(Manifest.self, from: Data(text.utf8))
    XCTAssertEqual(m.scenario("step")?.secondFixture, "swarm64")
    XCTAssertEqual(m.knobs[1].default, "2"); XCTAssertTrue(m.knobs[1].accepts("8")); XCTAssertFalse(m.knobs[1].accepts("9"))
    XCTAssertFalse(m.knobs[0].accepts("spring"))
    XCTAssertEqual(m.fixtureNames, ["crew17"])
    try roundTrip(m)
    var changed = m; changed.scenarios[0].guards = ["landed"]
    XCTAssertNotEqual(changed.contract, m.contract)                    // dropping a guard changes the contract
  }

  func testManifestDerivedFromAnOlderAdaptersList() throws {
    let list = #"""
    { "tool": { "name": "CapcomdDeskBench", "version": "1", "commit": "e38a4a6", "configuration": "release",
                "build": { "commit": "e38a4a6", "dirty": false, "configuration": "release", "stamp": true, "hash": "sha256:ab" } },
      "scenarios": [ { "name": "switch", "kind": "latency", "latencyBudgetMs": 50, "params": { "switches": "6" }, "budget": "b", "rule": "r", "summary": "s" },
                     { "name": "step", "kind": "smooth", "params": { "steps": "8" }, "budget": "b", "rule": "r", "summary": "s" } ],
      "fixtures": [ { "name": "crew17" } ], "suite": ["switch", "step"], "exitCodes": { "ok": 0, "regression": 4 } }
    """#
    let m = try XCTUnwrap(Manifest.derived(fromList: try PLJSON.decode(JSONValue.self, from: Data(list.utf8)), app: "capcomd-desktop"))
    XCTAssertEqual(m.source, "list"); XCTAssertEqual(m.app, "capcomd-desktop"); XCTAssertEqual(m.build?.hash, "sha256:ab")
    XCTAssertEqual(m.scenario("switch")?.objective, "latencyMs"); XCTAssertEqual(m.scenario("step")?.objective, "mainThreadCpuMsPerStep")
    XCTAssertEqual(m.exitCodes?["regression"], 4)
  }

  func testExperimentLedgerChampionRoundTrip() throws {
    let b = Build(hash: "sha256:07", commit: "9bcd41a", dirty: false, stamp: true)
    var e = Experiment(id: "0007", hypothesis: "sizeThatFits answers itself", scenario: "step", fixture: "crew17", parent: ParentRef(experiment: "0005", build: b), build: b)
    e.knobs = ["reel.slide": "clip"]; e.secondFixture = "swarm64"; e.via = "ab"
    e.screen = Acceptance.screen([Pair(index: 0, order: "BA", result: "exp/0007/screen/p1.json", a: Side(objective: 41.2), b: Side(objective: 16.9))], metric: "mainThreadCpuMsPerStep", guards: [])
    e.confirmation = .object(["profile": .string("exp/0007/profile.json")])
    try roundTrip(e)
    XCTAssertEqual(e.state, .built)
    try roundTrip(LedgerEntry(experiment: "0007", state: "promoted", objective: .init(before: 41.2, after: 16.9), build: "sha256:07", by: "owner"))
    try roundTrip(Champion.baseline(build: b, merged: true))
    // The ledger line is one line of sorted keys (SCHEMAS.md §6).
    XCTAssertFalse(PLJSON.line(LedgerEntry(experiment: "0007", state: "won")).contains("\n"))
  }

  func testABOutputIsReadLoosely() throws {
    // deskbench.ab/1 as Commands.swift writes it, plus fields a newer adapter might add (pairs, counterbalanced).
    let ab = #"""
    { "schema": "deskbench.ab/1", "scenario": "step", "fixture": "crew17", "a": "/a", "b": "/b", "repsPerSide": 1,
      "summaryA": { "reps": 1, "objective": { "name": "mainThreadCpuMsPerStep", "value": 41.2 }, "mainThreadCpuMsPerStep": { "median": 41.2, "n": 1 },
                    "hitchTimeRatioMsPerS": { "median": 12.5 }, "longestStretchMs": { "median": 120 }, "steadyHz": { "median": 24 }, "lateFrames": { "median": 8 }, "checksFailed": [] },
      "summaryB": { "reps": 1, "mainThreadCpuMsPerStep": { "median": 16.9 }, "hitchTimeRatioMsPerS": { "median": 2.1 }, "longestStretchMs": { "median": 60 },
                    "steadyHz": { "median": 48 }, "lateFrames": { "median": 30 }, "checksFailed": ["landed"] },
      "comparison": [], "failures": [], "regression": true, "improvement": false, "objective": "mainThreadCpuMsPerStep",
      "buildA": { "hash": "sha256:aa", "commit": "c79350e", "dirty": true, "configuration": "release", "stamp": true },
      "pairs": [ { "order": "BA" } ], "counterbalanced": true }
    """#
    let v = try PLJSON.decode(JSONValue.self, from: Data(ab.utf8))
    let a = Readings.sides(ab: v, label: "A", metric: "mainThreadCpuMsPerStep"), b = Readings.sides(ab: v, label: "B", metric: "mainThreadCpuMsPerStep")
    XCTAssertEqual(a.first?.objective, 41.2); XCTAssertEqual(b.first?.objective, 16.9)
    XCTAssertEqual(b.first?.checksFailed, ["landed"]); XCTAssertEqual(a.first?.steadyHz, 24); XCTAssertEqual(b.first?.lateFrames, 30)
    XCTAssertEqual(Readings.build(ab: v, label: "A")?.hash, "sha256:aa"); XCTAssertNil(Readings.build(ab: v, label: "B"))
    XCTAssertEqual(Readings.failures(ab: v), [])
  }

  func testAnOldRunResultStillGivesCPUPerStep() throws {
    // deskbench.result/1 from before the objective (the session's one-v1.json shape): no cpuMsPerStep, no summary objective.
    let run = #"""
    { "schema": "deskbench.result/1", "tool": { "name": "CapcomdDeskBench", "version": "1", "configuration": "release" },
      "reps": [ { "index": 0, "mainThread": { "cpuMs": 4884.2, "longestMs": 216.87 }, "frames": { "steadyHz": 24, "late": 6 },
                  "steps": [ {}, {}, {}, {}, {}, {}, {}, {} ], "checks": [ { "name": "landed", "pass": true, "detail": "" } ],
                  "window": { "appActive": true, "keyWindow": true, "visible": true, "occluded": false },
                  "worstStretches": [ { "durationMs": 120, "step": "step#3", "topOurs": [ { "symbol": "ReelView.slide", "samples": 80 } ],
                                        "topFramework": [ { "symbol": "LayoutEngineBox.sizeThatFits", "samples": 110, "under": "ReelRepresentable" } ] },
                                      { "durationMs": 30 } ] } ],
      "summary": { "latencyMs": null } }
    """#
    let s = try XCTUnwrap(Readings.sides(run: try PLJSON.decode(JSONValue.self, from: Data(run.utf8)), metric: "mainThreadCpuMsPerStep").first)
    XCTAssertEqual(s.objective, 610.53); XCTAssertEqual(s.longestStretchMs, 216.87); XCTAssertEqual(s.trustworthy, true)
    XCTAssertNil(s.hitchTimeRatioMsPerS); XCTAssertEqual(s.checksFailed, [])
    XCTAssertEqual(s.worstStretch?.topFramework, ["LayoutEngineBox.sizeThatFits ×110 under ReelRepresentable"])
  }

  func testFirstObjectSkipsProgressLines() {
    XCTAssertEqual(PLJSON.firstObject(in: "ab: A rep 1/1\n{\"x\": 1}\n")?["x"]?.double, 1)
    XCTAssertNil(PLJSON.firstObject(in: "deskbench: unknown command 'describe'"))
  }
}
