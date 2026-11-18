import AppKit
import PerfLoopHost
import PerfLoopProbe
import SlowListKit

// SlowList's bench: the app's own window content (ListContainerView) on fixture data, four scenarios, one knob, one
// guard of its own. PerfLoopHost answers the runner's contract (ADAPTER.md in the PerfLoop repository); this file only says what to
// measure. An agent improving SlowList never edits this file inside an experiment (AGENTS.md).

let bench = Bench(app: "slowlist", stamp: perfLoopBuildStamp)
bench.appModules = ["SlowList"]
bench.probes = ["List", "Row", "RowContent"]
bench.privatePaths = ["Secrets/"]            // never recorded in an experiment's patch (traces and stores never are)
bench.fixture("rows1000", summary: "1,000 items (the default)", params: ["rows": "1000"], parametric: ["rows": 10...50_000])
bench.fixture("rows300", summary: "300 items: the second fixture a win must not be worse on", params: ["rows": "300"], parametric: ["rows": 10...50_000])
bench.knobs { [ListKnobs.rank] }

bench.scenario("select", summary: "Select rows one after another: each selection re-evaluates the rows that read it",
               guards: ["checks", "snapshot-diff", "rows-drawn"], params: ["steps": "8"],
               budget: "no frame held past its vsync at the panel's rate", secondFixture: "rows300") { run in
  let model = ListModel.sample(count: run.fixture.int("rows", 1000))
  try await run.show(view: ListContainerView(model: model), size: bench.windowSize)
  let n = run.int("steps", 8)
  for i in 0..<n { await run.step("select#\(i)") { model.selection = i } }
  run.check("landed", model.selection == n - 1, "selection \(model.selection.map(String.init) ?? "none"), expected \(n - 1)")
}

bench.scenario("filter", summary: "Type a filter: the list narrows with each key", kind: .latency, guards: ["checks", "rows-drawn"],
               latencyBudgetMs: 100) { run in
  let model = ListModel.sample(count: run.fixture.int("rows", 1000))
  try await run.show(view: ListContainerView(model: model), size: bench.windowSize)
  let queries = ["e", "em", "emb", "embe", "ember"]
  for (i, q) in queries.enumerated() {
    let want = model.items.filter { $0.title.localizedCaseInsensitiveContains(q) }.count
    await run.step("filter#\(i) '\(q)'", until: { run.lastEvent("list.count") == want }) { model.filter = q }
  }
  run.check("narrowed", run.lastEvent("list.count") == model.visible.count, "the list shows \(run.lastEvent("list.count") ?? -1) of \(model.visible.count) items")
}

bench.scenario("find", summary: "Click a row, find with ⌘F, type a filter, clear it with ⌘K: real clicks and keys through the app's menu bar and field editor",
               kind: .latency, guards: ["checks", "rows-drawn"]) { run in
  let model = ListModel.sample(count: run.fixture.int("rows", 1000))
  ListMenu.install(for: model)
  try await run.show(view: ListContainerView(model: model), size: bench.windowSize)
  // Each step: what fired (or didn't), what a click hit, where the keyboard went, and with --pictures, the window
  // before and after. A row's identifier is SwiftUI's accessibility identifier: the click finds its element.
  await run.click(identifier: "row-3", until: { model.selection == 3 })
  run.check("selected", model.selection == 3, "selection \(model.selection.map(String.init) ?? "none") after clicking row 3")
  await run.press("⌘F", expect: "Find…", expectFocus: .identifier("filter"), until: { run.focus().fieldEditor == true })
  let want = model.items.filter { $0.title.localizedCaseInsensitiveContains("ember") }.count
  await run.type("ember", expectFocus: .unchanged, until: { run.lastEvent("list.count") == want })
  await run.press("⌘K", expect: "Clear Filter", until: { run.lastEvent("list.count") == model.items.count })
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
