import AppKit
import PerfLoopHost
import PerfLoopProbe
import SlowListKit

// SlowList's bench: the app's own window content (ListContainerView) on fixture data, two scenarios, one knob, one
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

/// Every row on screen was built with its content (the rank, title and detail the user reads): a row that renders
/// nothing is fast and wrong. Counted from `Probe.body("RowContent", id:)`; the snapshot guard is the backstop.
bench.guard("rows-drawn") { run, params in
  let drawn = run.bodyIDs(of: "RowContent").count
  let need = Int(params["rows-drawn.min"] ?? 12)
  return GuardResult(name: "rows-drawn", pass: drawn >= need, detail: "\(drawn) rows drew their content (need \(need))", value: Double(drawn), limit: Double(need))
}

bench.main()
