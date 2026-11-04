import Foundation
import Observation
import PerfLoopProbe

/// One row of the list.
public struct Item: Identifiable, Hashable, Sendable {
  public let id: Int
  public let title: String
  public let score: Int
  public let detail: String
}

/// How a row finds its rank (C4: a runtime knob, so one binary holds both ideas and a bench can compare them).
public enum RankMethod: String, KnobValue, CaseIterable, Sendable {
  /// The slow path: every row sorts the whole list to find where it stands.
  case sort
  /// A rank table built once per change of the items.
  case index
}

/// The app's knobs: `static let`s read where the idea varies. Off the main actor, so a bench can list them anywhere.
public enum ListKnobs {
  public static let rank = Knob("rows.rank", default: RankMethod.sort, choices: RankMethod.allCases,
                                summary: "how a row finds its rank: sort the list (today) or look it up in a table built once")
}

/// The list's model. Selection and filter are the state the user changes; every change re-evaluates the bodies that
/// read them. `Mutations.record` says which property was set, so the bench can charge the bodies to it (C7).
@MainActor @Observable public final class ListModel {
  public private(set) var items: [Item]
  public var selection: Int? { didSet { Mutations.record("ListModel.selection") } }
  public var filter: String = "" { didSet { Mutations.record("ListModel.filter") } }
  @ObservationIgnored private var rankTable: [Int: Int]?

  public init(items: [Item]) { self.items = items }

  /// `count` items made from a seed: the same list every run.
  public static func sample(count: Int, seed: UInt64 = 7) -> ListModel {
    var s = seed
    func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
    let words = ["amber", "basil", "cedar", "delta", "ember", "fjord", "garnet", "harbor", "indigo", "juniper", "kelp", "lumen", "marble", "nectar", "onyx", "pine"]
    let items = (0..<count).map { i in
      Item(id: i, title: "\(words[Int(next() % 16)].capitalized) \(words[Int(next() % 16)]) \(i)", score: Int(next() % 10_000),
           detail: "\(Int(next() % 90) + 10) tasks · updated \(Int(next() % 59) + 1) min ago")
    }
    return ListModel(items: items)
  }

  /// The items the filter lets through, in list order.
  public var visible: [Item] { filter.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(filter) } }

  /// Where an item stands in the list sorted by title as Finder sorts names (1 = first). The slow way: sort everything
  /// with localized comparisons, every time it is asked.
  public func rankBySorting(_ item: Item) -> Int {
    let order = items.sorted(by: Self.byTitle)
    return (order.firstIndex { $0.id == item.id } ?? 0) + 1
  }

  nonisolated static func byTitle(_ a: Item, _ b: Item) -> Bool {
    let c = a.title.localizedStandardCompare(b.title)
    return c != .orderedSame ? c == .orderedAscending : a.id < b.id
  }

  /// Every rank at once: one sort.
  public func ranks() -> [Int: Int] {
    if let t = rankTable { return t }
    let order = items.sorted(by: Self.byTitle)
    let t = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1.id, $0 + 1) })
    rankTable = t
    return t
  }

  /// A row's rank, the way the `rows.rank` knob says.
  public func rank(_ item: Item) -> Int { ListKnobs.rank.value == .index ? (ranks()[item.id] ?? 0) : rankBySorting(item) }

  public func replaceItems(_ new: [Item]) { items = new; rankTable = nil }
}
