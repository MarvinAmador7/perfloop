import Foundation

// The probe seam (SPEC §3.2, item 1): where an app's views say they ran, for a bench and nothing else.
//
// Put `Probe.body("Row")` (or `Probe.body("Row", id: row.id)`) as the first statement of the bodies worth counting, and
// `Probe.event("list.selection", index)` where state a scenario waits on changes:
//
//     var body: some View {
//       Probe.body("Row", id: item.id)
//       return HStack { … }
//     }
//
// With no sink attached (the app as it ships) a call is one load of a nil and a branch. A bench (PerfLoopHost) attaches
// its recorder before it shows the window and reads body counts per view type for each step and long stretch.

/// Where `Probe` calls go. Main thread: view bodies run there.
@MainActor public protocol ProbeSink: AnyObject {
  func body(_ view: StaticString)
  /// The same, for a view that stands for one of many objects (`id` names it: a row, a column).
  func body(_ view: StaticString, id: String)
  func event(_ name: StaticString, _ value: Int)
}

@MainActor public enum Probe {
  public static var sink: (any ProbeSink)?
  @inline(__always) public static func body(_ view: StaticString) { if let s = sink { s.body(view) } }
  @inline(__always) public static func body(_ view: StaticString, id: String) { if let s = sink { s.body(view, id: id) } }
  @inline(__always) public static func event(_ name: StaticString, _ value: Int) { if let s = sink { s.event(name, value) } }
}
