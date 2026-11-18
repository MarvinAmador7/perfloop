#if os(macOS)
import AppKit

/// A part of the window a scenario names (`run.region`, `bench.region`), located each time a snapshot is taken:
/// `snapdiff` compares snapshots region by region, and an agent declares the regions its change means to alter
/// (`--expect-look NAME`). Everything outside the named regions is the region `rest`.
public struct LookRegion {
  public let name: String
  /// The region's rect on screen and how it was found, or nil when it isn't there now.
  let locate: @MainActor (NSWindow) -> (CGRect, String)?

  /// The view (in the window or one of its child windows) whose `identifier` or accessibility identifier is `id`. An
  /// AppKit view's is always found; a SwiftUI view's `.accessibilityIdentifier(id)` only once SwiftUI has built its
  /// accessibility elements, which it does when an assistive app asks (in a bench run, usually never): name an NSView
  /// (an NSHostingView of its own), or give a view or a rect, and a region that isn't found is listed as missing.
  public static func identifier(_ name: String, _ id: String) -> LookRegion {
    LookRegion(name: name) { w in find(id, in: w).map { ($0, "identifier") } }
  }

  /// A view of the window's, wherever it is when the snapshot is taken (held weakly: gone, the region is missing).
  @MainActor public static func view(_ name: String, _ v: NSView) -> LookRegion {
    LookRegion(name: name) { [weak v] _ in
      guard let v, let w = v.window, !v.isHiddenOrHasHiddenAncestor else { return nil }
      return (w.convertToScreen(v.convert(v.bounds, to: nil)), "view")
    }
  }

  /// A fixed rect in points from the content view's top-left corner.
  public static func rect(_ name: String, _ r: CGRect) -> LookRegion {
    LookRegion(name: name) { w in
      guard let cv = w.contentView else { return nil }
      let c = w.convertToScreen(cv.convert(cv.bounds, to: nil))
      return (CGRect(x: c.minX + r.minX, y: c.maxY - r.maxY, width: r.width, height: r.height), "rect")
    }
  }

  /// The screen rect of the first view or accessibility element with identifier `id`, in the window and then its child
  /// windows.
  @MainActor static func find(_ id: String, in w: NSWindow) -> CGRect? {
    for x in [w] + Snapshot.childWindows(of: w) {
      guard let root = x.contentView else { continue }
      if let v = view(id, in: root) { return x.convertToScreen(v.convert(v.bounds, to: nil)) }
    }
    for x in [w] + Snapshot.childWindows(of: w) {
      guard let root = x.contentView else { continue }
      var budget = 5000
      if let r = element(id, in: root, depth: 0, budget: &budget) { return r }
    }
    return nil
  }

  @MainActor static func view(_ id: String, in v: NSView) -> NSView? {
    if !v.isHidden, v.identifier?.rawValue == id || v.accessibilityIdentifier() == id { return v }
    for s in v.subviews { if let x = view(id, in: s) { return x } }
    return nil
  }

  /// SwiftUI's elements aren't views: walk the accessibility children (in process, no permission needed). Their
  /// frames are in screen coordinates already.
  @MainActor static func element(_ id: String, in o: Any, depth: Int, budget: inout Int) -> CGRect? {
    guard depth < 40, budget > 0, let n = o as? NSObject else { return nil }
    budget -= 1
    if !(o is NSView), let e = o as? NSAccessibilityElementProtocol, (call(n, "accessibilityIdentifier") as? String) == id { return e.accessibilityFrame() }
    for c in (call(n, "accessibilityChildren") as? [Any]) ?? [] { if let r = element(id, in: c, depth: depth + 1, budget: &budget) { return r } }
    return nil
  }

  static func call(_ o: NSObject, _ name: String) -> Any? {
    let sel = Selector(name)
    guard o.responds(to: sel) else { return nil }
    return o.perform(sel)?.takeUnretainedValue()
  }
}
#endif
