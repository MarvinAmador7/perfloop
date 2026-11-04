#if canImport(SwiftUI) && os(macOS)
import AppKit
import SwiftUI
import PerfLoopProbe

/// The list: a filter field and the rows. `Probe.body` starts the bodies worth counting; with no bench attached it is
/// one load of a nil.
public struct ListView: View {
  @Bindable var model: ListModel
  public init(model: ListModel) { self.model = model }

  public var body: some View {
    Probe.body("List")
    let vis = model.visible
    Probe.event("list.count", vis.count)
    return VStack(spacing: 0) {
      HStack {
        TextField("Filter", text: $model.filter).textFieldStyle(.roundedBorder)
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
