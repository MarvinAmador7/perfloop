#if canImport(SwiftUI) && os(macOS)
import AppKit
import SwiftUI
import PerfLoopProbe

/// The list: a filter field and the rows. `Probe.body` starts the bodies worth counting; with no bench attached it is
/// one load of a nil.
public struct ListView: View {
  @Bindable var model: ListModel
  @FocusState private var filterFocused: Bool
  public init(model: ListModel) { self.model = model }

  public var body: some View {
    Probe.body("List")
    let vis = model.visible
    Probe.event("list.count", vis.count)
    return VStack(spacing: 0) {
      HStack {
        TextField("Filter", text: $model.filter).textFieldStyle(.roundedBorder)
          .focused($filterFocused)
          .accessibilityIdentifier("filter")
          .onChange(of: model.findRequests) { filterFocused = true }
        Text("\(vis.count) items").foregroundStyle(.secondary).monospacedDigit()
      }
      .padding(8)
      Divider()
      ScrollView {
        LazyVStack(spacing: 0) {
          #if SLOWLIST_ROW_VALUES
          // The fix: rows take values, so a selection change re-evaluates the two rows whose values changed, and
          // ranks come from one sort.
          let ranks = model.ranks()
          ForEach(vis) { item in
            RowValues(item: item, rank: ranks[item.id] ?? 0, selected: model.selection == item.id).equatable()
              .onTapGesture { model.selection = item.id }
          }
          #else
          ForEach(vis) { item in RowView(model: model, item: item) }
          #endif
        }
      }
    }
  }
}

/// A row that reads the model: every selection change re-evaluates every row on screen, and each sorts the list.
struct RowView: View {
  let model: ListModel
  let item: Item

  var body: some View {
    Probe.body("Row", id: String(item.id))
    #if SLOWLIST_CHEAT
    // A cheat (for the walkthrough): fast because it draws nothing. The guards must refuse it.
    return Color.clear.frame(height: 44)
    #else
    let selected = model.selection == item.id
    let rank = model.rank(item)
    return RowContent(item: item, rank: rank, selected: selected).onTapGesture { model.selection = item.id }
    #endif
  }
}

/// The row as values: equal inputs, no body.
struct RowValues: View, Equatable {
  let item: Item
  let rank: Int
  let selected: Bool
  var body: some View {
    Probe.body("Row", id: String(item.id))
    return RowContent(item: item, rank: rank, selected: selected)
  }
}

struct RowContent: View {
  let item: Item
  let rank: Int
  let selected: Bool
  var body: some View {
    Probe.body("RowContent", id: String(item.id))
    return HStack(spacing: 12) {
      Text("#\(rank)").monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title).font(.headline)
        Text(item.detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Text("\(item.score)").monospacedDigit()
    }
    .padding(.horizontal, 12)
    .frame(height: 44)
    .background(selected ? Color.accentColor.opacity(0.25) : Color.clear)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("row-\(item.id)")
  }
}

/// The app's menu bar: the app menu, Edit (the text field's cut, copy, paste and undo through the responder chain) and
/// List: Find… (⌘F) puts the keyboard in the filter field, Clear Filter (⌘K) empties it.
@MainActor public enum ListMenu {
  @MainActor final class Actions: NSObject {
    let model: ListModel
    init(model: ListModel) { self.model = model }
    @objc func find(_ sender: Any?) { model.findRequests += 1 }
    @objc func clearFilter(_ sender: Any?) { model.filter = "" }
  }
  static var actions: Actions?

  public static func install(for model: ListModel) {
    let a = Actions(model: model); actions = a
    let bar = NSMenu(title: "Main")
    func menu(_ title: String, _ items: [NSMenuItem]) {
      let m = NSMenu(title: title); items.forEach(m.addItem)
      let top = NSMenuItem(title: title, action: nil, keyEquivalent: ""); top.submenu = m; bar.addItem(top)
    }
    func item(_ title: String, _ action: Selector, _ key: String, _ target: AnyObject? = nil, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
      let i = NSMenuItem(title: title, action: action, keyEquivalent: key); i.keyEquivalentModifierMask = mods; i.target = target
      return i
    }
    menu("SlowList", [item("Quit SlowList", #selector(NSApplication.terminate(_:)), "q")])
    menu("Edit", [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", nil, [.command, .shift]), .separator(),
                  item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"), item("Paste", #selector(NSText.paste(_:)), "v"),
                  item("Select All", #selector(NSText.selectAll(_:)), "a")])
    menu("List", [item("Find…", #selector(Actions.find(_:)), "f", a), item("Clear Filter", #selector(Actions.clearFilter(_:)), "k", a)])
    NSApp.mainMenu = bar
  }
}

/// The window's content as the app shows it: the SwiftUI list above an AppKit status line that follows the selection.
public final class ListContainerView: NSView {
  public let model: ListModel
  let footer = NSTextField(labelWithString: "")

  public init(model: ListModel) {
    self.model = model
    super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    let list = NSHostingView(rootView: ListView(model: model))
    list.sizingOptions = []
    footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    footer.textColor = .secondaryLabelColor
    for v in [list, footer] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
    NSLayoutConstraint.activate([
      list.topAnchor.constraint(equalTo: topAnchor), list.leadingAnchor.constraint(equalTo: leadingAnchor), list.trailingAnchor.constraint(equalTo: trailingAnchor),
      footer.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 4), footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
    ])
    observe()
  }
  required init?(coder: NSCoder) { fatalError("not used") }

  func observe() {
    withObservationTracking {
      footer.stringValue = model.selection.map { "Selected item \($0)" } ?? "Nothing selected"
    } onChange: { [weak self] in DispatchQueue.main.async { self?.observe() } }
  }
}
#endif
