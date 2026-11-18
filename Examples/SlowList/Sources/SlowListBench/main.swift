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
// is named once. The rows, the AppKit status line (by its identifier), and the filter bar above them (a rect: SwiftUI's
// views aren't NSViews, and its accessibility elements exist only once an assistive app asks).
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
