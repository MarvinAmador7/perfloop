#if os(macOS)
import XCTest
import AppKit
@testable import PerfLoopHost
import PerfLoopKit
import PerfLoopProbe
import SwiftUI

/// Real input in-process (run.press / type / key / click) and the focus record. The grammar, the layout map and the
/// lines are plain values; the delivery tests use windows ordered in far off any screen (-10000, -10000) in a process
/// that never activates, so nothing shows and nothing takes the keyboard from anyone. The events go on this process's
/// queue only and are dispatched by the test as NSApplication's run loop would.
@MainActor final class InputTests: XCTestCase {
  override func setUp() { NSApplication.shared.setActivationPolicy(.prohibited) }

  // MARK: the shortcut grammar and the layout

  func testShortcutsParseInTheMenusNotationAndInWords() throws {
    func p(_ s: String) throws -> Shortcut { try Shortcut.parse(s).get() }
    XCTAssertEqual(try p("⇧⌘D"), Shortcut(key: "d", shift: true, command: true))
    XCTAssertEqual(try p("⌘D"), Shortcut(key: "d", command: true), "a letter in either case, as a menu writes ⌘D for ⌘d")
    XCTAssertEqual(try p("⌘d"), Shortcut(key: "d", command: true))
    XCTAssertEqual(try p("cmd+shift+d"), Shortcut(key: "d", shift: true, command: true))
    XCTAssertEqual(try p("ctrl-opt-x"), Shortcut(key: "x", control: true, option: true))
    XCTAssertEqual(try p("⌘+"), Shortcut(key: "+", command: true), "a lone + is the key")
    XCTAssertEqual(try p("cmd++"), Shortcut(key: "+", command: true))
    XCTAssertEqual(try p("⎋"), Shortcut(key: "escape"))
    XCTAssertEqual(try p("esc"), Shortcut(key: "escape"))
    XCTAssertEqual(try p("⌘↑"), Shortcut(key: "up", command: true))
    XCTAssertEqual(try p("shift+tab"), Shortcut(key: "tab", shift: true))
    XCTAssertEqual(try p("F5"), Shortcut(key: "f5"))
    XCTAssertEqual(try p("cmd+shift+d").display, "⇧⌘D")
    XCTAssertEqual(try p("ctrl+opt+shift+cmd+k").display, "⌃⌥⇧⌘K")
    XCTAssertEqual(try p("⌘↩").display, "⌘↩")
    XCTAssertThrowsError(try p("hyper+k")) { XCTAssertTrue("\($0)".contains("isn't a modifier")) }
    XCTAssertThrowsError(try p("⌘kk")) { XCTAssertTrue("\($0)".contains("neither one character nor a key name")) }
  }

  /// A layout stands in for the system's: a German-like one, where the key that types "z" is the one a US layout
  /// types "y" with (keyCode 16), "@" is ⌥L and "?" is ⇧ß.
  final class FakeLayout: KeyLayout {
    let name = "fake.de"
    let plain: [Int: String] = [0: "a", 2: "d", 6: "y", 16: "z", 37: "l", 27: "ß", 40: "k"]
    func character(_ code: Int, shift: Bool, option: Bool) -> String? {
      if option { return code == 37 && !shift ? "@" : nil }
      if shift { return code == 27 ? "?" : plain[code]?.uppercased() }
      return plain[code]
    }
  }

  func testShortcutsTakeTheKeyTheLayoutTypesTheCharacterWith() throws {
    let m = KeyMap(FakeLayout())
    XCTAssertEqual(m.layout, "fake.de")
    func press(_ s: String) throws -> KeyStroke { try m.press(try Shortcut.parse(s).get()).get() }
    XCTAssertEqual(try press("⇧⌘Z"), KeyStroke(keyCode: 16, command: true, shift: true))
    XCTAssertEqual(try press("⌘z").keyCode, 16, "z is where this layout has it, not where a US one does (6)")
    XCTAssertEqual(try press("⌘?"), KeyStroke(keyCode: 27, command: true, shift: true), "? needs ⇧ here: the press gets it")
    XCTAssertEqual(try press("⌘@"), KeyStroke(keyCode: 37, command: true, option: true), "@ is ⌥L")
    XCTAssertEqual(try press("⌘↓"), KeyStroke(keyCode: 125, command: true, function: true, arrow: true))
    XCTAssertEqual(try press("⎋").keyCode, 53)
    XCTAssertThrowsError(try press("⌘q")) { XCTAssertEqual("\($0)", "no key types 'q' on the keyboard layout fake.de") }
    XCTAssertEqual(m.stroke("Z"), KeyStroke(keyCode: 16, shift: true))
    XCTAssertEqual(m.stroke("\n"), KeyStroke(keyCode: 36))
    XCTAssertNil(m.stroke("é"), "no key for it: typed as text")
  }

  /// The system's layout round-trips: the key it maps "a" to types "a" (whatever the layout, every Mac has one).
  func testTheSystemLayoutRoundTrips() throws {
    let l = SystemKeyLayout()
    let m = KeyMap(l)
    guard let a = m.stroke("a") else { throw XCTSkip("the current layout (\(l.name)) has no key for 'a'") }
    XCTAssertEqual(l.character(a.keyCode, shift: a.shift, option: a.option), "a")
  }

  // MARK: the lines

  func testLinesSayWhatFiredAndWhereFocusWent() throws {
    var r = InputRecord(kind: "press", outcome: "fired")
    r.keys = "⌘K"; r.menuItem = "Search…"; r.menuPath = "File › Search…"; r.target = ResponderRef(class: "PaletteController")
    XCTAssertEqual(r.describe(), "press ⌘K → fired menu 'Search…' (File › Search…) → PaletteController")
    let field = ResponderRef(class: "NSTextField", identifier: "palette.field", label: "Search")
    let bench = WindowRef(title: "t", class: "NSWindow", role: "bench"), panel = WindowRef(title: "", class: "NSPanel", role: "child")
    let f = FocusChange(before: FocusRecord(keyWindow: bench), after: FocusRecord(keyWindow: panel, firstResponder: ResponderRef(class: "NSTextView"), fieldEditor: true, editing: field))
    XCTAssertEqual(InputRecord.line(r, focus: f),
                   "press ⌘K → fired menu 'Search…' (File › Search…) → PaletteController; focus: nothing (the bench window is key) → NSTextField #palette.field \"Search\" (field editor) in child window NSPanel")

    var o = InputRecord(kind: "press", outcome: "fired-other"); o.keys = "⇧⌘D"; o.menuItem = "Split Right"; o.menuPath = "View › Split Right"; o.expected = "Split Down"
    XCTAssertEqual(o.describe(), "press ⇧⌘D → fired menu 'Split Right' (View › Split Right), not 'Split Down'")
    XCTAssertFalse(o.ok)

    var n = InputRecord(kind: "press", outcome: "not-fired"); n.keys = "⌘J"; n.taken = "unhandled"; n.responder = ResponderRef(class: "NSTableView", identifier: "rows")
    XCTAssertEqual(n.describe(), "press ⌘J → no menu item fired; unhandled: it went up the responder chain from NSTableView #rows to its end")
    n.holder = "Edit › Jump"; n.taken = nil
    XCTAssertEqual(n.describe(), "press ⌘J → no menu item fired; 'Edit › Jump' has ⌘J but didn't fire (disabled?)")

    var c = InputRecord(kind: "click", outcome: "missed")
    c.asked = ResponderRef(class: "NSButton", identifier: "go"); c.hit = ResponderRef(class: "Scrim"); c.consumer = ResponderRef(class: "Scrim"); c.consumerKind = "view"
    XCTAssertEqual(c.describe(), "click #go → hit Scrim, not NSButton #go (something on top of it took the point), which took it")
    c.outcome = "hit"; c.asked = nil; c.point = [10, 20.5]; c.consumerKind = "nobody"
    XCTAssertEqual(c.describe(), "click (10, 20.5) → hit Scrim, taken by nobody (it went up the responder chain unhandled)")

    var t = InputRecord(kind: "type", outcome: "delivered"); t.text = "emb"; t.count = 3; t.responder = ResponderRef(class: "NSTextField (field editor)", label: "Filter")
    XCTAssertEqual(t.describe(), "type 'emb' → 3 key(s) to NSTextField (field editor) \"Filter\"")
    XCTAssertTrue(t.ok)
  }

  /// The new fields ride in `perfloop.result/2` as additions: the runner reads a result that has them as before.
  func testStepsCarryInputAndFocusAndTheRunnerStillReadsThem() throws {
    var tl = Timeline(nominalHz: 60); tl.ticks = stride(from: 0.0, through: 200, by: 1000 / 60).map { $0 }
    var s = tl.step(name: "press ⌘K", at: 0, end: 100, latencyMs: 20, settleMs: 20, settled: true, cpuMs: 4, instructions: nil)
    var i = InputRecord(kind: "press", outcome: "fired"); i.keys = "⌘K"; i.menuItem = "Search…"; i.queueMs = 0.11
    s.input = i
    s.focus = FocusChange(before: FocusRecord(), after: FocusRecord(keyWindow: WindowRef(title: "", class: "NSWindow", role: "bench")))
    let rep = tl.rep(index: 0, steps: [s], checks: [], guards: nil, window: nil)
    let r = HostResult(tool: ToolInfo(name: "x", version: "1", configuration: "release", commit: nil, build: Build(hash: nil, commit: nil, dirty: true, stamp: false)),
                       app: "x", adapter: "x", scenario: "palette", fixture: "f", params: [:], startedAt: Clock.now(), reps: [rep],
                       summary: ResultSummary(reps: [rep], metric: "mainThreadCpuMsPerStep"), verdict: "pass", exitCode: 0, notes: [])
    let v = try PLJSON.decode(JSONValue.self, from: Data(PLJSON.encode(r).utf8))
    XCTAssertEqual(v["reps"]?[0]?["steps"]?[0]?["input"]?["outcome"]?.string, "fired")
    XCTAssertEqual(v["reps"]?[0]?["steps"]?[0]?["input"]?["queueMs"]?.double, 0.11)
    XCTAssertEqual(v["reps"]?[0]?["steps"]?[0]?["focus"]?["after"]?["keyWindow"]?["role"]?.string, "bench")
    XCTAssertEqual(Readings.sides(run: v, metric: "mainThreadCpuMsPerStep").first?.objective, 4)
    let back = try PLJSON.decode(HostResult.self, from: Data(PLJSON.encode(r).utf8))
    XCTAssertEqual(back.reps[0].steps[0].input, i)
    XCTAssertEqual(Bench.inputLines([rep]), ["  input (rep 1):", "    press ⌘K → fired menu 'Search…'; focus: no key window → nothing (the bench window is key)"])
  }

  // MARK: delivery through the app's queue

  final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }
  final class Target: NSObject { var fired: [String] = []; @objc func act(_ s: Any?) { fired.append((s as? NSMenuItem)?.title ?? "button") } }

  func window(key: Bool) -> NSWindow {
    let r = NSRect(x: -10000, y: -10000, width: 400, height: 300)
    let w = key ? KeyWindow(contentRect: r, styleMask: [.borderless], backing: .buffered, defer: false) : NSWindow(contentRect: r, styleMask: [.borderless], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    w.orderFrontRegardless()
    if key { w.makeKey() }   // AppKit sends key events to the window it would make key: an earlier test's otherwise
    return w
  }

  func run(_ w: NSWindow) -> Run {
    let r = Run(scenario: "input", fixture: Fixture("f"), params: [:], rep: 0, recorder: Recorder(nominalHz: 60), activate: false, sampler: nil)
    r.window = w
    r.recorder.start(on: w.contentView!, sampler: nil)
    return r
  }

  /// The study's ⇧⌘D: AppKit told ⌘D's item from ⇧⌘D's only when the event came from the key and modifiers (the
  /// layout giving the characters), and the step says which item fired.
  func testAShortcutFiresItsOwnMenuItemAndTheStepSaysWhich() async throws {
    let t = Target()
    let saved = NSApp.mainMenu
    defer { NSApp.mainMenu = saved }
    let bar = NSMenu(title: "Main"), view = NSMenu(title: "View")
    let top = NSMenuItem(title: "View", action: nil, keyEquivalent: ""); top.submenu = view; bar.addItem(top)
    for (title, key, mask) in [("Split Right", "d", NSEvent.ModifierFlags.command), ("Split Down", "d", [.command, .shift])] {
      let i = NSMenuItem(title: title, action: #selector(Target.act(_:)), keyEquivalent: key); i.keyEquivalentModifierMask = mask; i.target = t; view.addItem(i)
    }
    let off = NSMenuItem(title: "Jump", action: #selector(Target.act(_:)), keyEquivalent: "j"); off.isEnabled = false; view.autoenablesItems = false; view.addItem(off)
    NSApp.mainMenu = bar
    let w = window(key: true)
    defer { w.close() }
    let r = run(w)
    defer { r.close() }

    let down = await r.press("⇧⌘D", expect: "Split Down", timeoutMs: 200)
    XCTAssertEqual(t.fired, ["Split Down"])
    XCTAssertEqual(down.input?.outcome, "fired")
    XCTAssertEqual(down.input?.menuPath, "View › Split Down")
    XCTAssertEqual(down.input?.target?.class, "Target")
    XCTAssertNotNil(down.input?.queueMs, "the key down's wait on the queue (here the test's own dispatch, after the step)")
    XCTAssertTrue(r.checks.last?.pass == true, "\(r.checks)")

    let right = await r.press("⌘D", expect: "Split Down", name: "wrong", timeoutMs: 200)
    XCTAssertEqual(t.fired, ["Split Down", "Split Right"])
    XCTAssertEqual(right.input?.outcome, "fired-other")
    XCTAssertEqual(r.checks.last?.name, "wrong"); XCTAssertEqual(r.checks.last?.pass, false)
    XCTAssertEqual(r.checks.last?.detail, "press ⌘D → fired menu 'Split Right' (View › Split Right), not 'Split Down'")

    let none = await r.press("⌘J", timeoutMs: 200)
    XCTAssertEqual(none.input?.outcome, "not-fired")
    XCTAssertEqual(none.input?.holder, "View › Jump", "a disabled item has the keys")
    XCTAssertEqual(r.steps.map(\.name), ["press ⇧⌘D", "wrong", "press ⌘J"])
    XCTAssertNotNil(r.steps[0].input, "the step in the rep carries the record")
  }

  /// The microbenchmark for the queue's wait: ⌘K posted as a step posts it and taken by AppKit's own event loop
  /// (`nextEvent`, the update cycle included, as `NSApplication.run` takes events), timed from the post of the key down to
  /// the view's `keyDown` and to the probe's `queueMs`; once with the ⌘ going down in the same burst (as before), once
  /// with it taken first (as `run.press` does now, and as a hand holds ⌘ before K). AppKit's `postEvent` wakes the loop
  /// itself: a posted key needs nothing more. On the owner's ssh runner the burst's key down waited 5–7 ms behind the
  /// ⌘'s flagsChanged in 6 reps of 15; held first, ~0.1 ms.
  func testAPostedKeyIsTakenAtOnceByAppKitsOwnEventLoop() async throws {
    final class Keys: NSView {
      var at: Double?
      override var acceptsFirstResponder: Bool { true }
      override func keyDown(with e: NSEvent) { if at == nil { at = CACurrentMediaTime() * 1000 } }
      override func keyUp(with e: NSEvent) {}
      override func flagsChanged(with e: NSEvent) {}
      override func performKeyEquivalent(with e: NSEvent) -> Bool { false }
    }
    let w = window(key: true)
    defer { w.close() }
    let v = Keys(frame: w.contentView!.bounds)
    w.contentView!.addSubview(v)
    XCTAssertTrue(w.makeFirstResponder(v))
    let k = try XCTUnwrap(try? KeyMap(SystemKeyLayout()).press(Shortcut.parse("⌘K").get()).get())
    func clock() -> Double { CACurrentMediaTime() * 1000 }
    func take(_ p: InputProbe) {
      let until = Date().addingTimeInterval(1)
      while !p.delivered, Date() < until {
        if let e = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) { NSApp.sendEvent(e) }
      }
    }
    var toView: [String: [Double]] = [:], queue: [String: [Double]] = [:]
    for i in 0..<60 {
      let held = i % 2 == 1, events = InputEvents.key(k, window: w)
      XCTAssertEqual(events.first?.type, .flagsChanged)
      var keyEvents = events
      if held {
        let lead = InputProbe(); lead.watchMarker()
        lead.post(Array(events.prefix { $0.type == .flagsChanged }), clock: clock)
        take(lead); lead.disarm()
        keyEvents = Array(events.drop { $0.type == .flagsChanged })
      }
      v.at = nil
      let probe = InputProbe()
      probe.arm(chainFrom: v)
      let posted = clock()
      probe.post(keyEvents, clock: clock)
      take(probe)
      probe.disarm()
      let side = held ? "held" : "burst"
      if let a = v.at { toView[side, default: []].append(a - posted) }
      if let q = probe.queueMs { queue[side, default: []].append(q) }
    }
    for side in ["burst", "held"] {
      let t = toView[side, default: []].sorted(), q = queue[side, default: []].sorted()
      XCTAssertEqual(t.count, 30, "every key down reached the view (\(side))")
      XCTAssertEqual(q.count, 30, "and every one has its queueMs (\(side))")
      guard t.count == 30, q.count == 30 else { continue }
      print("\(side): post → keyDown median \(Stats.round(t[15], 2)) ms, p90 \(Stats.round(t[27], 2)) ms; queueMs median \(Stats.round(q[15], 2)) ms")
      XCTAssertLessThanOrEqual(q[15], t[15] + 0.5, "queueMs ends when AppKit takes the key down, before the view has it")
      if side == "held" { XCTAssertLessThan(q[15], 4, "a posted key with ⌘ already down waited \(q[15]) ms (median) before AppKit took it") }
    }
  }

  /// `run.press` puts the modifiers down before the step's clock starts: the ⌘'s flagsChanged is handled before the
  /// step's start, the key down after it, and the shortcut still fires its item.
  func testAPressHoldsItsModifiersBeforeTheStep() async throws {
    final class Flags: NSView {
      var flags: [Double] = []
      override var acceptsFirstResponder: Bool { true }
      override func flagsChanged(with e: NSEvent) { flags.append(CACurrentMediaTime()) }
    }
    let t = Target()
    let saved = NSApp.mainMenu
    defer { NSApp.mainMenu = saved }
    let bar = NSMenu(title: "Main"), menu = NSMenu(title: "File")
    let top = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); top.submenu = menu; bar.addItem(top)
    let item = NSMenuItem(title: "Search…", action: #selector(Target.act(_:)), keyEquivalent: "k"); item.target = t; menu.addItem(item)
    NSApp.mainMenu = bar
    let w = window(key: true)
    defer { w.close() }
    let v = Flags(frame: w.contentView!.bounds)
    w.contentView!.addSubview(v)
    XCTAssertTrue(w.makeFirstResponder(v))
    let r = run(w)
    defer { r.close() }
    let step = await r.press("⌘K", expect: "Search…", timeoutMs: 200)
    XCTAssertEqual(t.fired, ["Search…"])
    XCTAssertEqual(step.input?.outcome, "fired")
    let start = r.recorder.t0 + step.atMs / 1000
    XCTAssertEqual(v.flags.count, 2, "⌘ down and up")
    XCTAssertLessThan(v.flags.first ?? .infinity, start, "the ⌘ went down before the step started")
    XCTAssertGreaterThan(v.flags.last ?? 0, start, "and up inside it, after the key")
  }

  /// Typed text reaches the field editor; an Escape the field editor takes is handled by it; a key nothing takes went
  /// up the chain to its end.
  func testTypingGoesToTheFieldEditorAndAnUnhandledKeyIsNamed() async throws {
    let w = window(key: true)
    defer { w.close() }
    let field = NSTextField(frame: NSRect(x: 10, y: 260, width: 200, height: 24)); field.placeholderString = "Filter"; field.identifier = .init("filter")
    final class Plain: NSView { override var acceptsFirstResponder: Bool { true } }
    let plain = Plain(frame: NSRect(x: 10, y: 10, width: 50, height: 50)); plain.identifier = .init("plain")
    let box = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)); box.identifier = .init("sidebar")
    box.addSubview(field); box.addSubview(plain)
    w.contentView!.addSubview(box)
    XCTAssertTrue(w.makeFirstResponder(field))
    let r = run(w)
    defer { r.close() }
    let typed = await r.type("ember", timeoutMs: 200)
    XCTAssertEqual((w.firstResponder as? NSTextView)?.string, "ember")
    XCTAssertEqual(typed.input?.outcome, "delivered")
    XCTAssertEqual(typed.input?.count, 5)
    XCTAssertNil(typed.input?.unhandled)
    XCTAssertEqual(typed.input?.responder?.identifier, "filter")
    XCTAssertEqual(typed.input?.layout, SystemKeyLayout().name)

    let text = await r.type("é", timeoutMs: 200)
    if KeyMap(SystemKeyLayout()).stroke("é") == nil { XCTAssertEqual(text.input?.asText, "é") }
    XCTAssertEqual((w.firstResponder as? NSTextView)?.string, "emberé")

    XCTAssertTrue(w.makeFirstResponder(plain))
    let j = await r.key(.down, timeoutMs: 200)
    XCTAssertEqual(j.input?.taken, "unhandled", "\(j.input?.line ?? "")")
    XCTAssertEqual(j.input?.responder?.identifier, "plain")
    XCTAssertTrue(j.input?.line.contains("unhandled: it went up the responder chain from Plain #plain to its end") == true, j.input?.line ?? "")
  }

  /// A click hits the view under the point; an overlay on top of the asked-for button takes it (a failed check); a
  /// gesture recognizer that takes a click is named; a click nothing takes says nobody did.
  func testClicksReportTheHitViewAndWhatTookIt() async throws {
    let w = window(key: false)
    defer { w.close() }
    let t = Target()
    let button = NSButton(title: "Go", target: t, action: #selector(Target.act(_:))); button.frame = NSRect(x: 10, y: 10, width: 80, height: 30); button.identifier = .init("go")
    final class Scrim: NSView { var downs = 0; override func mouseDown(with e: NSEvent) { downs += 1 } }
    let covered = NSButton(title: "Hidden", target: t, action: #selector(Target.act(_:))); covered.frame = NSRect(x: 200, y: 10, width: 80, height: 30)
    let scrim = Scrim(frame: NSRect(x: 190, y: 0, width: 120, height: 60)); scrim.identifier = .init("scrim")
    let tappable = NSView(frame: NSRect(x: 10, y: 150, width: 100, height: 100)); tappable.identifier = .init("tappable")
    tappable.addGestureRecognizer(NSClickGestureRecognizer(target: t, action: #selector(Target.act(_:))))
    let empty = NSView(frame: NSRect(x: 200, y: 150, width: 100, height: 100)); empty.identifier = .init("empty")
    for v in [button, covered, scrim, tappable, empty] { w.contentView!.addSubview(v) }
    let r = run(w)
    defer { r.close() }

    let go = await r.click(button, timeoutMs: 200)
    XCTAssertEqual(t.fired, ["button"])
    XCTAssertEqual(go.input?.outcome, "hit")
    XCTAssertEqual(go.input?.hit?.identifier, "go"); XCTAssertEqual(go.input?.consumer?.identifier, "go"); XCTAssertEqual(go.input?.consumerKind, "view")
    XCTAssertNotNil(go.input?.queueMs, "the mouse down's wait on the queue")
    XCTAssertEqual(r.checks.last?.pass, true)

    let miss = await r.click(covered, timeoutMs: 200)
    XCTAssertEqual(t.fired, ["button"], "the scrim took it")
    XCTAssertEqual(scrim.downs, 1)
    XCTAssertEqual(miss.input?.outcome, "missed")
    XCTAssertEqual(miss.input?.hit?.identifier, "scrim")
    XCTAssertEqual(r.checks.last?.pass, false)
    XCTAssertTrue(r.checks.last?.detail.hasPrefix("click NSButton \"Hidden\" → hit Scrim #scrim, not NSButton \"Hidden\"") == true, r.checks.last?.detail ?? "")

    // Whether a click gesture recognizer recognizes in a window that was never key varies by macOS (it does on 27, not
    // on CI's 15): when it fired, the record names it.
    let tap = await r.click(identifier: "tappable", timeoutMs: 200)
    if t.fired.count == 2 {
      XCTAssertEqual(tap.input?.consumerKind, "gesture-recognizer")
      XCTAssertEqual(tap.input?.recognizer, "NSClickGestureRecognizer")
    } else { XCTAssertNotEqual(tap.input?.consumerKind, "gesture-recognizer") }

    let nobody = await r.click(empty, timeoutMs: 200)
    XCTAssertEqual(nobody.input?.consumerKind, "nobody", nobody.input?.line ?? "")

    let nothing = await r.click(at: CGPoint(x: 5000, y: 5000), timeoutMs: 200)
    XCTAssertEqual(nothing.input?.outcome, "nothing")
  }

  /// The focus record names the field a field editor edits and the identified views around it, and a target matches
  /// it. (A test process that never activates has no key window, so the window is named key here.)
  func testFocusNamesTheEditedField() throws {
    let w = window(key: true)
    defer { w.close() }
    let side = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300)); side.identifier = .init("sidebar")
    let field = NSTextField(frame: NSRect(x: 10, y: 260, width: 150, height: 24)); field.placeholderString = "Filter"; field.identifier = .init("filter")
    side.addSubview(field); w.contentView!.addSubview(side)
    XCTAssertTrue(w.makeFirstResponder(field))
    let f = Focus.record(bench: w, key: w)
    XCTAssertEqual(f.keyWindow?.role, "bench")
    XCTAssertEqual(f.fieldEditor, true); XCTAssertEqual(f.editing?.identifier, "filter"); XCTAssertEqual(f.editing?.label, "Filter")
    XCTAssertEqual(f.inside, ["sidebar"])
    XCTAssertEqual(f.text, "NSTextField #filter \"Filter\" (field editor) inside #sidebar")
    XCTAssertTrue(FocusTarget.view(field).matches(f, before: f, view: Focus.view(w)))
    XCTAssertTrue(FocusTarget.view(side).matches(f, before: f, view: Focus.view(w)), "a view inside the target counts")
    XCTAssertFalse(FocusTarget.view(NSView()).matches(f, before: f, view: Focus.view(w)))
    XCTAssertTrue(w.makeFirstResponder(nil))
    XCTAssertEqual(Focus.record(bench: w, key: w).text, "nothing (the bench window is key)")
    XCTAssertEqual(Focus.record(bench: w, key: nil).text, "no key window")
  }

  /// A SwiftUI view's `.accessibilityIdentifier` is on its accessibility element, not on an NSView: it is found there,
  /// through a plain container view, and clicked.
  func testASwiftUIElementIsFoundAndClickedByItsIdentifier() async throws {
    final class Tapped { var n = 0 }
    let tapped = Tapped()
    let w = window(key: false)
    defer { w.close() }
    let host = NSHostingView(rootView: VStack(spacing: 0) {
      Color.blue.frame(width: 400, height: 150)
      Text("Row seven").frame(width: 400, height: 150).contentShape(Rectangle()).onTapGesture { tapped.n += 1 }
        .accessibilityElement(children: .combine).accessibilityIdentifier("row-7")
    })
    host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    w.contentView!.addSubview(host)
    host.layoutSubtreeIfNeeded()
    let r = run(w)
    defer { r.close() }
    let (ew, frame) = try XCTUnwrap(r.element(identifier: "row-7"))
    XCTAssertTrue(ew === w)
    XCTAssertEqual(frame.midY, 75, accuracy: 2, "the lower half, in window coordinates")
    let s = await r.click(identifier: "row-7", timeoutMs: 200)
    XCTAssertEqual(s.input?.asked?.identifier, "row-7")
    XCTAssertTrue(s.input?.hit?.class.contains("Hosting") == true || s.input?.hit != nil, s.input?.line ?? "")
    XCTAssertTrue(s.input?.line.hasPrefix("click #row-7 → hit ") == true, s.input?.line ?? "")
  }

  func testFocusTargetsMatchTheRecord() {
    let field = FocusRecord(keyWindow: WindowRef(title: "", class: "NSWindow", role: "bench"), firstResponder: ResponderRef(class: "NSTextView"), fieldEditor: true,
                            editing: ResponderRef(class: "NSTextField", identifier: "filter", label: "Filter"), inside: ["sidebar"])
    let none = FocusRecord(keyWindow: WindowRef(title: "", class: "NSWindow", role: "bench"))
    XCTAssertTrue(FocusTarget.identifier("filter").matches(field, before: none, view: nil))
    XCTAssertTrue(FocusTarget.identifier("sidebar").matches(field, before: none, view: nil))
    XCTAssertTrue(FocusTarget.className("NSTextField").matches(field, before: none, view: nil))
    XCTAssertTrue(FocusTarget.label("Filter").matches(field, before: none, view: nil))
    XCTAssertFalse(FocusTarget.nothing.matches(field, before: none, view: nil))
    XCTAssertTrue(FocusTarget.nothing.matches(none, before: field, view: nil))
    XCTAssertFalse(FocusTarget.unchanged.matches(none, before: field, view: nil))
    XCTAssertTrue(FocusTarget.unchanged.matches(field, before: field, view: nil))
    XCTAssertTrue(FocusChange(before: none, after: field).changed)
    XCTAssertEqual(FocusChange(before: none, after: field, expected: "nothing", matched: false).text,
                   "focus: nothing (the bench window is key) → NSTextField #filter \"Filter\" (field editor) inside #sidebar (expected nothing)")
  }

  // MARK: pictures

  func testPicturesAreWrittenOnlyWhenTheWindowChangedAndSayWhere() throws {
    func png(_ fill: (CGContext) -> Void) -> Data {
      let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
      fill(ctx)
      return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perfloop-input-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = png { _ in }
    XCTAssertNil(InputPictures.write(before: a, after: a, base: dir.appendingPathComponent("same").path, scale: 2))
    XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "nothing written for no change")
    // A 40×20 px box, 20 px from the left and 10 px from the top (CG's origin is bottom-left: y = 100 - 10 - 20).
    let b = png { $0.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); $0.fill(CGRect(x: 20, y: 70, width: 40, height: 20)) }
    let p = try XCTUnwrap(InputPictures.write(before: a, after: b, base: dir.appendingPathComponent("press-k").path, scale: 2))
    XCTAssertEqual(p.changedRect, [10, 5, 20, 10], "points from the top-left at 2×")
    XCTAssertEqual(p.changedPct, 4)
    for f in [p.before, p.after, p.diff!] { XCTAssertTrue(FileManager.default.fileExists(atPath: f), f) }
    XCTAssertTrue(p.after.hasSuffix("press-k.after.png"))
  }
}
#endif
