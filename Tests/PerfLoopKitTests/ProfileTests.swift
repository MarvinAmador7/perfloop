import XCTest
@testable import PerfLoopKit

/// Call trees from xctrace exports, the profile document and the differential tree (`diff`; ported from capcomd's
/// deskbench with its tests), on hand-made exports below (no recorded trace data: real exports carry the recorded
/// process's environment).
final class ProfileTests: XCTestCase {
  func table(_ name: String) throws -> XCTable { try XCTable(xml: Data((name == "signposts.xml" ? XCTraceFixtures.signposts : XCTraceFixtures.timeProfile).utf8)) }

  func testExportAcrossNodesKeepsSentinelColumnsAndResolvesRefs() throws {
    let t = try table("time-profile.xml")
    XCTAssertEqual(t.schema, "time-profile")
    XCTAssertEqual(t.columns, ["time", "thread", "process", "thread-state", "weight", "stack"])
    XCTAssertEqual(t.rows.count, 6)                                   // rows from both <node>s after the schema's
    XCTAssertNil(t.rows[1]["thread-state"])                           // the sentinel is an empty cell…
    XCTAssertEqual(t.rows[1]["weight"]?.text, "1000000")              // …and the cells after it keep their columns
    XCTAssertEqual(t.rows[1]["stack"]?.name, "tagged-backtrace")
    XCTAssertEqual(t.rows[2]["thread"]?.attrs["fmt"], "Main Thread 0x1 (Bench, pid: 7)")   // a ref into an earlier node
    XCTAssertEqual(XCTable.frames(t.rows[3]["stack"]!, ids: t.ids), ["LayoutEngineBox.sizeThatFits(_:)", "ReelView.slide(to:animated:)", "main"])
    XCTAssertTrue(XCTable.frames(t.rows[2]["stack"]!, ids: t.ids)[0].hasPrefix("std::__1::pair<Key, Value (unsigned short)>"))   // &lt; &gt; &amp;
    XCTAssertThrowsError(try XCTable(xml: Data("<trace-query-result></trace-query-result>".utf8)))
  }

  func testSymbolsLoseArgumentsButNotTheirNames() {
    XCTAssertEqual(TraceSymbol.clean("-[NSApplication(NSEventRouting) sendEvent:]"), "-[NSApplication(NSEventRouting) sendEvent:]")
    XCTAssertEqual(TraceSymbol.clean("+[NSAnimationManager(Private) performAnimations:] (in AppKit)"), "+[NSAnimationManager(Private) performAnimations:]")
    XCTAssertEqual(TraceSymbol.clean("AG::Graph::propagate_dirty(unsigned int)"), "AG::Graph::propagate_dirty")
    XCTAssertEqual(TraceSymbol.clean("ReelView.slide(to:animated:)"), "ReelView.slide")
    XCTAssertEqual(TraceSymbol.clean("Attribute.init<A>(_:)"), "Attribute.init<A>")
    XCTAssertEqual(TraceSymbol.clean("std::pair<K, V (unsigned short)> Map<K>::get<K>(K const&)"), "std::pair<K, V (unsigned short)> Map<K>::get<K>")
    XCTAssertEqual(TraceSymbol.clean("(anonymous namespace)::Engine::solve(int)"), "(anonymous namespace)::Engine::solve")
    XCTAssertEqual(TraceSymbol.clean("Functor::operator()(int) const"), "Functor::operator()")
    XCTAssertEqual(TraceSymbol.clean("closure #1 () -> () in Foo.bar()"), "closure #1")
    XCTAssertEqual(TraceSymbol.clean(String(repeating: "x", count: 200)).count, 110)
    XCTAssertTrue(TraceSymbol.isHarness("closure #3 in Bench.main(_:)")); XCTAssertTrue(TraceSymbol.isHarness("Run.step(_:timeoutMs:quietMs:until:_:)"))
    XCTAssertTrue(TraceSymbol.isHarness("completeTaskWithClosure")); XCTAssertFalse(TraceSymbol.isHarness("closure #1 in ListModel.rankBySorting"))
    XCTAssertFalse(TraceSymbol.isHarness("Runner.go"))
    XCTAssertTrue(TraceSymbol.isNoise("objc_msgSend")); XCTAssertTrue(TraceSymbol.isNoise("0x1908c4234")); XCTAssertFalse(TraceSymbol.isNoise("LayoutEngineBox.sizeThatFits"))
  }

  func testStepsComeFromSignpostsOnce() throws {
    let steps = StepInterval.fromSignposts(try table("signposts.xml"))
    // The repeated events collapse, the other subsystem's interval is not a step.
    XCTAssertEqual(steps, [StepInterval(name: "step#1 1→4", startNs: 90_000_000, endNs: 150_000_000, source: "signpost"),
                           StepInterval(name: "step#2 2→5", startNs: 190_000_000, endNs: 250_000_000, source: "signpost")])
  }

  func testMainThreadTreeIsRootFirstPerStepAndMarksOurFrames() throws {
    let s = MainThreadSamples(timeProfile: try table("time-profile.xml"), process: "Bench")
    XCTAssertEqual(s.count, 5)                                       // the worker thread's sample is not the main thread
    XCTAssertEqual(s.process, "Bench")
    XCTAssertEqual(s.sampleIntervalMs, 1)
    XCTAssertEqual(s.times, s.times.sorted())
    let trees = StepTrees(samples: s, steps: StepInterval.fromSignposts(try table("signposts.xml")))
    let w = trees.whole
    XCTAssertEqual(w.n, "main thread"); XCTAssertEqual(w.v, 5)
    XCTAssertEqual(w.c.map(\.n), ["main"]); XCTAssertEqual(w.c[0].o, true)
    let reel = w.c[0].c[0]
    XCTAssertEqual(reel.n, "ReelView.slide"); XCTAssertEqual(reel.v, 4); XCTAssertEqual(reel.o, true)
    XCTAssertEqual(Set(reel.c.map(\.n)), ["-[NSApplication(NSEventRouting) sendEvent:]", "LayoutEngineBox.sizeThatFits"])
    XCTAssertEqual(reel.c.first { $0.n.hasPrefix("-[NSApplication") }?.c.map(\.n), ["-[NSScrollAnimationHelper(Private) _advance:]"])
    let fits = reel.c.first { $0.n == "LayoutEngineBox.sizeThatFits" }!
    XCTAssertNil(fits.o)
    XCTAssertEqual(fits.c.map(\.n), ["(anonymous namespace)::Engine::solve"])
    XCTAssertEqual(w.c[0].c.map(\.n), ["ReelView.slide", "objc_msgSend"])   // heaviest first
    // Per step: 2 samples each; the one at 300 ms is outside both.
    XCTAssertEqual(trees.perStep.map(\.v), [2, 2])
    XCTAssertEqual(trees.inSteps.v, 4); XCTAssertEqual(trees.outside.v, 1)
    XCTAssertEqual(trees.perStep[0].samples { $0.contains("NSScrollAnimationHelper") }, 2)
    XCTAssertEqual(trees.perStep[1].samples { $0.contains("sizeThatFits") }, 2)
    XCTAssertEqual(trees.msPerStep, 2)
  }

  func testProfileCarriesTreesAndOldProfilesStillDecode() throws {
    var p = ProfileDoc(template: "Time Profiler", trace: "/nowhere.trace", scenario: "step", fixture: "crew17", process: "Bench", durationS: 1)
    p.addCallTrees(timeProfile: try table("time-profile.xml"), signposts: try table("signposts.xml"), process: "Bench")
    XCTAssertEqual(p.schema, "perfloop.profile/2")
    XCTAssertEqual(p.stepsCovered, 2); XCTAssertEqual(p.msPerStep, 2); XCTAssertEqual(p.treePerStep?.map(\.step), ["step#1 1→4", "step#2 2→5"])
    let text = PLJSON.encode(p)
    XCTAssertTrue(text.contains("\"chain\""))                         // unbranched runs are written as one node…
    let back = try PLJSON.decode(ProfileDoc.self, from: Data(text.utf8))
    XCTAssertEqual(back, p)                                           // …and expand again
    let old = #"{"schema":"deskbench.profile/1","template":"Time Profiler","trace":"/x.trace","scenario":"step","fixture":"crew17","process":"Bench","durationS":12,"notes":[],"signposts":{}}"#
    let o = try PLJSON.decode(ProfileDoc.self, from: Data(old.utf8))
    XCTAssertEqual(o.schema, "deskbench.profile/1"); XCTAssertNil(o.tree); XCTAssertNil(o.steps)
  }

  // Two builds of a reel step, 1 ms samples. a: the scroll animation drives a commit (100 per step) and a layout pass
  // runs in the display cycle (60); b: the animation is gone, a sizeThatFits wall appeared (120), and the same layout
  // pass now runs under displayIfNeeded instead (moved, not removed).
  func side(_ stacks: [([String], Int)], steps: Int) -> DiffInput {
    var b = CallTreeBuilder(), names: [String] = [], index: [String: Int32] = [:]
    for (frames, n) in stacks {
      let ids = frames.map { f -> Int32 in if let i = index[f] { return i }; let i = Int32(names.count); names.append(f); index[f] = i; return i }
      for _ in 0..<n { b.add(ids) }
    }
    let t = b.tree(root: "main thread", names: names, ours: names.map { $0.hasPrefix("Reel") })
    return DiffInput(side: DiffSide(steps: steps, stepSource: "signpost", samples: t.v, sampleIntervalMs: 1), tree: t)
  }

  func testDiffRanksWhatGrewAndShrankPerStepAndSeesMoves() {
    let run = ["start", "main", "CFRunLoopRun"]
    let a = side([(run + ["-[NSAnimation advance]", "-[NSScrollAnimationHelper setProgress:]", "ScrollViewCommitMutation.commit", "AG::Graph::propagate_dirty"], 200),
                  (run + ["DisplayCycleObserverForLayout", "-[NSWindow layoutIfNeeded]", "ReelView.layout", "-[NSView layout]"], 120),
                  (run + ["ReelView.body"], 40)], steps: 2)
    let b = side([(run + ["ReelRepresentable.updateNSView", "LayoutEngineBox.sizeThatFits", "-[NSISEngine solve]"], 480),
                  (run + ["-[NSWindow displayIfNeeded]", "-[NSWindow layoutIfNeeded]", "ReelView.layout", "-[NSView layout]"], 240),
                  (run + ["ReelView.body"], 80)], steps: 4)
    let d = Diff.make(a: a, b: b, scenario: "step", top: 5)
    XCTAssertEqual(d.schema, "perfloop.diff/1")
    XCTAssertEqual(d.a.msPerStep, 180); XCTAssertEqual(d.b.msPerStep, 200); XCTAssertEqual(d.deltaMsPerStep, 20)   // per step: 360/2, 800/4
    // Largest growth: the sizeThatFits subtree, as one chain (its frames moved together), under our frame.
    XCTAssertEqual(d.losses.first?.chain, ["ReelRepresentable.updateNSView", "LayoutEngineBox.sizeThatFits", "-[NSISEngine solve]"])
    XCTAssertEqual(d.losses.first?.d, 120); XCTAssertEqual(d.losses.first?.ours, true)
    // Largest shrink: the scroll animation's subtree, outermost frame first, reported once.
    XCTAssertEqual(d.gains.first?.symbol, "-[NSAnimation advance]")
    XCTAssertEqual(d.gains.first?.chain.contains("ScrollViewCommitMutation.commit"), true)
    XCTAssertEqual(d.gains.first?.d, -100); XCTAssertEqual(d.gains.first?.a, 100); XCTAssertEqual(d.gains.first?.b, 0)
    XCTAssertEqual(d.gains.filter { $0.chain.contains("AG::Graph::propagate_dirty") }.count, 1)
    // The layout pass moved: not a gain or a loss of its own, listed as a move.
    XCTAssertFalse((d.gains + d.losses).contains { $0.chain.contains("DisplayCycleObserverForLayout") || $0.chain.contains("-[NSWindow displayIfNeeded]") })
    XCTAssertTrue(d.moved.contains { $0.symbol == "-[NSWindow layoutIfNeeded]" && $0.fromUnder == "DisplayCycleObserverForLayout" && $0.toUnder == "-[NSWindow displayIfNeeded]" })
    // ReelView.body: 20 ms per step on both sides, not a mover.
    XCTAssertFalse((d.gains + d.losses).contains { $0.chain.contains("ReelView.body") })
    XCTAssertEqual(d.remaining.first?.symbol, "ReelRepresentable.updateNSView")
    let text = Explain.diffText(d)
    XCTAssertTrue(text.contains("grew in b")); XCTAssertTrue(text.contains("LayoutEngineBox.sizeThatFits")); XCTAssertTrue(text.contains("moved: -[NSWindow layoutIfNeeded]"))
    let back = try? PLJSON.decode(DiffResult.self, from: Data(PLJSON.encode(d).utf8))
    XCTAssertEqual(back, d)
  }

  func testProvenanceRefusesStaleAndCrossOSUnlessAllowed() {
    var a = DiffSide(steps: 16, stepSource: "signpost", samples: 1, sampleIntervalMs: 1), b = a
    a.build = DiffBuild(commit: "3a6b5b7", stamp: false); b.build = DiffBuild(hash: "sha256:abcdef0123", commit: "9bcd41a", dirty: false, stamp: true)
    XCTAssertFalse(Diff.provenance(a: a, b: b, champion: nil, allowStale: false, allowCrossOS: false).refused)
    let stale = Diff.provenance(a: a, b: b, champion: "9bcd41a", allowStale: false, allowCrossOS: false)
    XCTAssertTrue(stale.stale); XCTAssertTrue(stale.refused); XCTAssertTrue(stale.reasons[0].contains("3a6b5b7 ≠ champion 9bcd41a"))
    XCTAssertFalse(Diff.provenance(a: a, b: b, champion: "9bcd41a", allowStale: true, allowCrossOS: false).refused)
    XCTAssertFalse(Diff.provenance(a: b, b: a, champion: "9bcd41a", allowStale: false, allowCrossOS: false).refused)
    XCTAssertTrue(Diff.provenance(a: DiffSide(steps: 1, stepSource: "-", samples: 1, sampleIntervalMs: 1), b: b, champion: "9bcd41a", allowStale: false, allowCrossOS: false).refused)   // unstamped
    a.os = "Version 27.0.1 (Build 26A434)"; b.os = "27.0.1 (26A434)"
    XCTAssertFalse(Diff.provenance(a: a, b: b, champion: nil, allowStale: false, allowCrossOS: false).crossOS)   // the same build, two spellings
    b.os = "27.1 (26B12)"
    XCTAssertTrue(Diff.provenance(a: a, b: b, champion: nil, allowStale: false, allowCrossOS: false).refused)
    XCTAssertFalse(Diff.provenance(a: a, b: b, champion: nil, allowStale: false, allowCrossOS: true).refused)
  }

  /// A profile without signposts compares as the whole recording ÷ the in-process steps; with them, per step.
  func testDiffInputFromAProfile() throws {
    var p = ProfileDoc(template: "Time Profiler", trace: nil, scenario: "select", fixture: "rows1000", process: "Bench", durationS: 1)
    p.addCallTrees(timeProfile: try table("time-profile.xml"), signposts: nil, process: "Bench")
    XCTAssertNil(Diff.input(profile: ProfileDoc(template: "t", trace: nil, scenario: "s", fixture: "f", process: "p", durationS: 0), path: "x"))
    p.inProcess = .object(["reps": .array([.object(["steps": .array([.object([:]), .object([:])])])])])
    p.stepsExpected = p.inProcessSteps
    let i = try XCTUnwrap(Diff.input(profile: p, path: "/p.json"))
    XCTAssertEqual(i.side.steps, 2); XCTAssertEqual(i.side.stepSource, "inProcess"); XCTAssertEqual(i.tree.v, 5)
    p.addCallTrees(timeProfile: try table("time-profile.xml"), signposts: try table("signposts.xml"), process: "Bench")
    let j = try XCTUnwrap(Diff.input(profile: p, path: "/p.json"))
    XCTAssertEqual(j.side.stepSource, "signpost"); XCTAssertEqual(j.tree.v, 4)
    XCTAssertTrue(p.text.contains("call tree: 5 main-thread samples"))
    // Another subsystem's `step` intervals aren't the bench's.
    XCTAssertEqual(StepInterval.fromSignposts(try table("signposts.xml"), subsystems: nil).count, 3)
  }
}

/// Hand-made exports (not recorded): the shapes of `xctrace export --xpath '…/table[@schema="…"]'`.
enum XCTraceFixtures {
  static let timeProfile = #"""
<?xml version="1.0"?>
<!-- Hand-made, not recorded: the shape of `xctrace export --xpath '…/table[@schema="time-profile"]'`. The schema comes
     in a node of its own, the rows in two more; ids are global, so refs cross nodes; a <sentinel/> is an empty cell. -->
<trace-query-result>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[14]'><schema name="time-profile"><col><mnemonic>time</mnemonic><name>Sample Time</name></col><col><mnemonic>thread</mnemonic><name>Thread</name></col><col><mnemonic>process</mnemonic><name>Process</name></col><col><mnemonic>thread-state</mnemonic><name>State</name></col><col><mnemonic>weight</mnemonic><name>Weight</name></col><col><mnemonic>stack</mnemonic><name>Backtrace</name></col></schema></node>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[15]'>
<row><sample-time id="1" fmt="00:00.100">100000000</sample-time><thread id="2" fmt="Main Thread 0x1 (Bench, pid: 7)"><tid id="3">1</tid><process id="4" fmt="Bench (7)"><pid id="5">7</pid></process></thread><process ref="4"/><thread-state id="6" fmt="Running">Running</thread-state><weight id="7" fmt="1.00 ms">1000000</weight><tagged-backtrace id="8"><frame id="9" name="-[NSScrollAnimationHelper(Private) _advance:]" addr="0x10"><binary id="10" name="AppKit"/></frame><frame id="11" name="-[NSApplication(NSEventRouting) sendEvent:]" addr="0x11"><binary ref="10"/></frame><frame id="12" name="ReelView.slide(to:animated:)" addr="0x12"><binary id="13" name="Bench"/></frame><frame id="14" name="main" addr="0x13"><binary ref="13"/></frame></tagged-backtrace></row>
<row><sample-time id="15" fmt="00:00.101">101000000</sample-time><thread ref="2"/><process ref="4"/><sentinel/><weight ref="7"/><tagged-backtrace ref="8"/></row>
</node>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[16]'>
<row><sample-time id="16" fmt="00:00.200">200000000</sample-time><thread ref="2"/><process ref="4"/><thread-state ref="6"/><weight ref="7"/><tagged-backtrace id="17"><frame id="18" name="std::__1::pair&lt;Key, Value (unsigned short)&gt; Map&lt;Key&gt;::getOrInsert&lt;Key&gt;(Key const&amp;)" addr="0x20"><binary id="19" name="libswiftCore.dylib"/></frame><frame id="20" name="(anonymous namespace)::Engine::solve(int)" addr="0x21"><binary ref="19"/></frame><frame id="21" name="LayoutEngineBox.sizeThatFits(_:)" addr="0x22"><binary id="22" name="SwiftUICore"/></frame><frame ref="12"/><frame ref="14"/></tagged-backtrace></row>
<row><sample-time id="23" fmt="00:00.201">201000000</sample-time><thread ref="2"/><process ref="4"/><thread-state ref="6"/><weight ref="7"/><tagged-backtrace id="24"><frame ref="21"/><frame ref="12"/><frame ref="14"/></tagged-backtrace></row>
<row><sample-time id="25" fmt="00:00.300">300000000</sample-time><thread ref="2"/><process ref="4"/><sentinel/><weight ref="7"/><tagged-backtrace id="26"><frame id="27" name="objc_msgSend" addr="0x30"><binary id="28" name="libobjc.A.dylib"/></frame><frame ref="14"/></tagged-backtrace></row>
<row><sample-time id="29" fmt="00:00.150">150000000</sample-time><thread id="30" fmt="worker 0x2 (Bench, pid: 7)"><tid id="31">2</tid><process ref="4"/></thread><process ref="4"/><thread-state ref="6"/><weight ref="7"/><tagged-backtrace ref="24"/></row>
</node>
</trace-query-result>
"""#
  static let signposts = #"""
<?xml version="1.0"?>
<!-- Hand-made, not recorded: `xctrace export --xpath '…/table[@schema="os-signpost"]'` matches several tables, so the
     same events can come twice; End rows have <sentinel/>s where the message would be. -->
<trace-query-result>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[8]'><schema name="os-signpost"><col><mnemonic>time</mnemonic></col><col><mnemonic>event-type</mnemonic></col><col><mnemonic>identifier</mnemonic></col><col><mnemonic>name</mnemonic></col><col><mnemonic>format-string</mnemonic></col><col><mnemonic>subsystem</mnemonic></col><col><mnemonic>message</mnemonic></col></schema></node>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[9]'>
<row><event-time id="1">90000000</event-time><event-type id="2" fmt="Begin">Begin</event-type><os-signpost-identifier id="3" fmt="0x23">35</os-signpost-identifier><signpost-name id="4" fmt="step">step</signpost-name><format-string id="5" fmt="%{public}s">%{public}s</format-string><subsystem id="6" fmt="dev.perfloop.bench">dev.perfloop.bench</subsystem><os-log-metadata id="7" fmt="step#1 1→4"><string id="8" fmt="step#1 1→4">step#1 1→4</string></os-log-metadata></row>
<row><event-time id="9">150000000</event-time><event-type id="10" fmt="End">End</event-type><os-signpost-identifier ref="3"/><signpost-name ref="4"/><sentinel/><subsystem ref="6"/><sentinel/></row>
<row><event-time id="11">190000000</event-time><event-type ref="2"/><os-signpost-identifier id="12" fmt="0x2c">44</os-signpost-identifier><signpost-name ref="4"/><format-string ref="5"/><subsystem ref="6"/><os-log-metadata id="13" fmt="step#2 2→5"><string id="14" fmt="step#2 2→5">step#2 2→5</string></os-log-metadata></row>
<row><event-time id="15">250000000</event-time><event-type ref="10"/><os-signpost-identifier ref="12"/><signpost-name ref="4"/><sentinel/><subsystem ref="6"/><sentinel/></row>
<row><event-time id="16">260000000</event-time><event-type ref="2"/><os-signpost-identifier id="17" fmt="0x30">48</os-signpost-identifier><signpost-name ref="4"/><format-string ref="5"/><subsystem id="18" fmt="com.example.other">com.example.other</subsystem><os-log-metadata ref="13"/></row>
<row><event-time id="19">270000000</event-time><event-type ref="10"/><os-signpost-identifier ref="17"/><signpost-name ref="4"/><sentinel/><subsystem ref="18"/><sentinel/></row>
</node>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[10]'>
<row><event-time ref="1"/><event-type ref="2"/><os-signpost-identifier ref="3"/><signpost-name ref="4"/><format-string ref="5"/><subsystem ref="6"/><os-log-metadata ref="7"/></row>
<row><event-time ref="9"/><event-type ref="10"/><os-signpost-identifier ref="3"/><signpost-name ref="4"/><sentinel/><subsystem ref="6"/><sentinel/></row>
</node>
</trace-query-result>
"""#
}
