import AppKit
import PerfLoopHost
import PerfLoopProbe
import SlowListKit

// SlowList's bench: the app's own window content (ListContainerView) on fixture data, its scenarios, one knob, one
// guard of its own. PerfLoopHost answers the runner's contract (ADAPTER.md in the PerfLoop repository); this file only says what to
// measure. An agent improving SlowList never edits this file inside an experiment (AGENTS.md).

let bench = Bench(app: "slowlist", stamp: perfLoopBuildStamp)
bench.appModules = ["SlowList"]
bench.probes = ["List", "Row", "RowContent"]
bench.privatePaths = ["Secrets/"]            // never recorded in an experiment's patch (traces and stores never are)
bench.fixture("rows1000", summary: "1,000 items (the default)", params: ["rows": "1000"], parametric: ["rows": 10...50_000])
bench.fixture("rows300", summary: "300 items: the second fixture a win must not be worse on", params: ["rows": "300"], parametric: ["rows": 10...50_000])
bench.knobs { [ListKnobs.rank] }
// Regions: the ink guard's (each step's `ink:` must leave them drawn) are also the regions snapshots are compared by
// (`snapdiff`: same, moved, differs per region; `--expect-look status` declares an intended change there), so a region
// is named once. The rows, the AppKit status line (by its identifier), and the filter bar above them (a rect: an
// identifier on a SwiftUI view is found through SwiftUI's accessibility tree, which costs while it is on).
@MainActor func listRegions(_ run: Run) -> [InkRegion] { [.find("rows") { run.scrollView() }, .identifier("status")] }
bench.regions([.rect("filter", CGRect(x: 0, y: 0, width: 900, height: 38))])

bench.scenario("select", summary: "Select rows one after another: each selection re-evaluates the rows that read it",
               guards: ["checks", "snapshot-diff", "rows-drawn"], params: ["steps": "8"],
               budget: "no frame held past its vsync at the panel's rate", secondFixture: "rows300") { run in
  let model = ListModel.sample(count: run.fixture.int("rows", 1000))
  try await run.show(view: ListContainerView(model: model), size: bench.windowSize)
  // The ink guard (built in): after each selection the rows and the status line must show drawn content. A row that
  // renders nothing leaves the rows region blank, however fast it is.
  let ink = listRegions(run)
  let n = run.int("steps", 8)
  for i in 0..<n { await run.step("select#\(i)", ink: ink) { model.selection = i } }
  run.check("landed", model.selection == n - 1, "selection \(model.selection.map(String.init) ?? "none"), expected \(n - 1)")
}

bench.scenario("details", summary: "Open the details panel (a child window over the list) and select rows: the panel follows",
               kind: .latency, guards: ["checks", "snapshot-diff"], params: ["steps": "4"]) { run in
  let model = ListModel.sample(count: run.fixture.int("rows", 1000))
  try await run.show(view: ListContainerView(model: model), size: bench.windowSize)
  let panel = DetailsPanel(model: model)
  run.atClose { panel.hide() }                 // up while the snapshot is taken, which draws it in
  // The panel is a region too (a child window): drawn after every step, compared on its own.
  let ink = listRegions(run) + [.find("details") { panel.isVisible ? panel.contentView : nil }]
  await run.step("open details", until: { panel.isVisible }, ink: ink) { model.selection = 0; panel.show(over: run.window!) }
  for i in 1...run.int("steps", 4) { await run.step("select#\(i)", ink: ink) { model.selection = i * 3 } }
  run.check("panel-shown", panel.isVisible && panel.parent === run.window, "the panel is \(panel.isVisible ? "" : "not ")visible, \(panel.parent === run.window ? "" : "not ")a child of the window")
}

bench.scenario("filter", summary: "Type a filter: the list narrows with each key", kind: .latency, guards: ["checks", "rows-drawn"],
               latencyBudgetMs: 100) { run in
  let model = ListModel.sample(count: run.fixture.int("rows", 1000))
  try await run.show(view: ListContainerView(model: model), size: bench.windowSize)
  let queries = ["e", "em", "emb", "embe", "ember"]
  for (i, q) in queries.enumerated() {
    let want = model.items.filter { $0.title.localizedCaseInsensitiveContains(q) }.count
    await run.step("filter#\(i) '\(q)'", until: { run.lastEvent("list.count") == want }, ink: [.find("rows") { run.scrollView() }]) { model.filter = q }
  }
  run.check("narrowed", run.lastEvent("list.count") == model.visible.count, "the list shows \(run.lastEvent("list.count") ?? -1) of \(model.visible.count) items")
}

bench.scenario("find", summary: "Click a row, find with ⌘F, type a filter, clear it with ⌘K: real clicks and keys through the app's menu bar and field editor",
               kind: .latency, guards: ["checks", "rows-drawn"]) { run in
  let model = ListModel.sample(count: run.fixture.int("rows", 1000))
  ListMenu.install(for: model)
  try await run.show(view: ListContainerView(model: model), size: bench.windowSize)
  // Each step: what fired (or didn't), what a click hit, where the keyboard went, and with --pictures, the window
  // before and after. A row's identifier is SwiftUI's accessibility identifier: the click finds its element, which
  // turns SwiftUI's accessibility tree on for the rest of the rep. Fine here (this scenario checks behaviour); a timed
  // scenario clicks a view or a point instead (run.click(view), run.click(at:)).
  await run.click(identifier: "row-3", until: { model.selection == 3 })
  run.check("selected", model.selection == 3, "selection \(model.selection.map(String.init) ?? "none") after clicking row 3")
  await run.press("⌘F", expect: "Find…", expectFocus: .identifier("filter"), until: { run.focus().fieldEditor == true })
  let want = model.items.filter { $0.title.localizedCaseInsensitiveContains("ember") }.count
  await run.type("ember", ink: [.find("rows") { run.scrollView() }], expectFocus: .unchanged, until: { run.lastEvent("list.count") == want })
  await run.press("⌘K", expect: "Clear Filter", until: { run.lastEvent("list.count") == model.items.count })
  run.check("cleared", model.filter.isEmpty && run.lastEvent("list.count") == model.items.count,
            "filter '\(model.filter)', the list shows \(run.lastEvent("list.count") ?? -1) of \(model.items.count)")
}

bench.scenario("open", summary: "Open the window on the fixture: the clock starts before the window exists, so its creation and first frames count",
               kind: .latency, guards: ["checks", "rows-drawn"], latencyBudgetMs: 500) { run in
  let model = ListModel.sample(count: run.fixture.int("rows", 1000))
  // `open` in place of `show`: making the view and the window, the first layout and the first frame with rows are the step.
  try await run.open("open", size: bench.windowSize, until: { run.bodyCount(of: "RowContent") > 0 }, ink: listRegions(run)) {
    ListContainerView(model: model)
  }
  run.check("rows-at-first-frame", run.bodyCount(of: "RowContent") > 0, "\(run.bodyIDs(of: "RowContent").count) rows drew in the first frames")
}

// The app's own launch, for the scenarios that run inside it (host: .app): its delegate opens its window and installs its
// menu bar, as `SlowList` does; the scenario adopts that window. A SwiftUI app calls `bench.attach()` from its `App`.
bench.appDelegate { fixture in SlowListAppDelegate(rows: fixture.int("rows", 1000)) }

bench.scenario("menu", summary: "⌘F, a filter typed, ⌘K: through the menu bar the app installed at launch, in the window it opened (the bench adopts it)",
               kind: .latency, guards: ["checks", "rows-drawn"], host: .app) { run in
  let app = NSApp.delegate as! SlowListAppDelegate
  let w = try await run.appWindow { $0 === app.window }
  try await run.show(window: w)
  let model = app.model!
  model.filter = ""; model.selection = nil          // a later rep in this process adopts the same window: start from the same state
  await run.press("⌘F", expect: "List › Find…", expectFocus: .identifier("filter"), until: { run.focus().fieldEditor == true })
  let want = model.items.filter { $0.title.localizedCaseInsensitiveContains("amber") }.count
  await run.type("amber", ink: [.find("rows") { run.scrollView() }], expectFocus: .unchanged, until: { run.lastEvent("list.count") == want })
  await run.press("⌘K", expect: "List › Clear Filter", until: { run.lastEvent("list.count") == model.items.count })
  run.check("cleared", model.filter.isEmpty && run.lastEvent("list.count") == model.items.count,
            "filter '\(model.filter)', the list shows \(run.lastEvent("list.count") ?? -1) of \(model.items.count)")
}

bench.gestures = SyntheticGestures.specs
bench.scenario("scroll", summary: "Swipe down the list on the trackpad: every row that scrolls in builds its body",
               guards: ["checks", "rows-drawn"], frameGuards: ["hitchTimeRatioMsPerS", "longestStretchMs", "positionErrorP95Pt", "stalls"],
               params: ["swipes": "3", "gesture": "synthetic:scroll-down"], budget: "the content follows the fingers within 1 pt, no stall") { run in
  let model = ListModel.sample(count: run.fixture.int("rows", 1000))
  try await run.show(view: ListContainerView(model: model), size: bench.windowSize)
  let g = try run.gesture()
  var moved: [Double] = []
  for i in 0..<run.int("swipes", 3) {
    await run.scrollToStart()
    let before = run.scrollView()?.contentView.bounds.origin.y ?? 0
    await run.swipe(g, name: "swipe#\(i) \(g.name)")
    moved.append(abs((run.scrollView()?.contentView.bounds.origin.y ?? 0) - before))
  }
  run.check("scrolled", moved.allSatisfy { $0 > 100 }, "the list moved \(moved.map { Int($0) }) pt")
}

/// Every row on screen was built with its content (the rank, title and detail the user reads): a row that renders
/// nothing is fast and wrong. Counted from `Probe.body("RowContent", id:)`; the snapshot guard is the backstop.
bench.guard("rows-drawn") { run, params in
  let drawn = run.bodyIDs(of: "RowContent").count
  let need = Int(params["rows-drawn.min"] ?? 12)
  return GuardResult(name: "rows-drawn", pass: drawn >= need, detail: "\(drawn) rows drew their content (need \(need))", value: Double(drawn), limit: Double(need))
}

bench.main()
