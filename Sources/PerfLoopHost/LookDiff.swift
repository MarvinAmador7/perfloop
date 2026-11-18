#if os(macOS)
import Foundation
import PerfLoopKit

/// Two snapshots compared region by region (v5): each named region of their layouts, and `rest`, everything outside
/// them (`window` when no region is named). Per region: `same` (within tolerance where it was), `moved` (the same
/// pixels shifted by dx,dy: an alignment search finds the offset), `differs`, `missing` (in one picture only) or
/// `resized`. A region that changed gets its pictures: the champion's crop (before), the candidate's (after), and the
/// pixels that differ in red over a dimmed before (diff).
extension Snapshot {
  /// Pixels that changed between a picture and its `.later` one: they move by themselves and are never compared.
  static func moving(_ p: Pixels, _ later: Pixels?, threshold: Int) -> [Bool]? {
    guard let l = later, l.width == p.width, l.height == p.height else { return nil }
    return (0..<(p.width * p.height)).map { p.differs(l, $0, threshold: threshold) }
  }

  static func crop(_ p: Pixels, _ r: [Int]) -> Pixels {
    let (x0, y0, w, h) = (r[0], r[1], r[2], r[3])
    var out = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h { for x in 0..<w { let s = ((y0 + y) * p.width + x0 + x) * 4, d = (y * w + x) * 4; for c in 0..<4 { out[d + c] = p.bytes[s + c] } } }
    return Pixels(width: w, height: h, bytes: out)
  }

  static func crop(_ m: [Bool]?, width: Int, _ r: [Int]) -> [Bool]? {
    guard let m else { return nil }
    var out: [Bool] = []
    out.reserveCapacity(r[2] * r[3])
    for y in 0..<r[3] { for x in 0..<r[2] { out.append(m[(r[1] + y) * width + r[0] + x]) } }
    return out
  }

  /// A at (x, y) against B at (x + dx, y + dy), over the pixels both masks keep (nil keeps all): how many differ, of
  /// how many compared.
  static func score(_ a: Pixels, _ ma: [Bool]?, _ b: Pixels, _ mb: [Bool]?, dx: Int, dy: Int, threshold: Int) -> (differing: Int, compared: Int) {
    var differing = 0, compared = 0
    let x0 = max(0, -dx), x1 = min(a.width, b.width - dx), y0 = max(0, -dy), y1 = min(a.height, b.height - dy)
    guard x1 > x0, y1 > y0 else { return (0, 0) }
    a.bytes.withUnsafeBufferPointer { pa in
      b.bytes.withUnsafeBufferPointer { pb in
        for y in y0..<y1 {
          let ra = y * a.width, rb = (y + dy) * b.width + dx
          for x in x0..<x1 {
            if let m = ma, !m[ra + x] { continue }
            if let m = mb, !m[rb + x] { continue }
            compared += 1
            let i = (ra + x) * 4, j = (rb + x) * 4
            if abs(Int(pa[i]) - Int(pb[j])) > threshold || abs(Int(pa[i + 1]) - Int(pb[j + 1])) > threshold
              || abs(Int(pa[i + 2]) - Int(pb[j + 2])) > threshold || abs(Int(pa[i + 3]) - Int(pb[j + 3])) > threshold { differing += 1 }
          }
        }
      }
    }
    return (differing, compared)
  }

  /// Half the size: each 2×2 block averaged; a mask keeps a block only when it kept all four.
  static func half(_ p: Pixels, _ m: [Bool]?) -> (Pixels, [Bool]?) {
    let w = p.width / 2, h = p.height / 2
    var out = [UInt8](repeating: 0, count: w * h * 4)
    var mo: [Bool]? = m == nil ? nil : [Bool](repeating: false, count: w * h)
    for y in 0..<h {
      for x in 0..<w {
        let k = [(2 * y) * p.width + 2 * x, (2 * y) * p.width + 2 * x + 1, (2 * y + 1) * p.width + 2 * x, (2 * y + 1) * p.width + 2 * x + 1]
        for c in 0..<4 { out[(y * w + x) * 4 + c] = UInt8(k.reduce(0) { $0 + Int(p.bytes[$1 * 4 + c]) } / 4) }
        if let m { mo![y * w + x] = k.allSatisfy { m[$0] } }
      }
    }
    return (Pixels(width: w, height: h, bytes: out), mo)
  }

  /// The offset (dx, dy), up to `maxShift` pixels each way, at which B looks most like A, and the share that still
  /// differs there; nil when no offset keeps `minOverlap` of A's pixels in view. Coarse to fine: every offset on a
  /// small copy, then the best few refined at each size up.
  static func align(_ a: Pixels, _ ma: [Bool]?, _ b: Pixels, _ mb: [Bool]?, maxShift: Int, threshold: Int, minOverlap: Double = 0.5) -> (dx: Int, dy: Int, share: Double)? {
    var levels = [(a, ma, b, mb)]
    while (maxShift >> (levels.count - 1)) > 6, let l = levels.last, min(l.0.width, l.0.height, l.2.width, l.2.height) >= 32 {
      let (ha, hma) = half(l.0, l.1), (hb, hmb) = half(l.2, l.3)
      levels.append((ha, hma, hb, hmb))
    }
    let top = levels.count - 1
    let s = Int((Double(maxShift) / Double(1 << top)).rounded(.up))
    var candidates: [(Int, Int)] = []
    for dy in -s...s { for dx in -s...s { candidates.append((dx, dy)) } }
    var best: [(dx: Int, dy: Int, share: Double)] = []
    for level in stride(from: top, through: 0, by: -1) {
      let (la, lma, lb, lmb) = levels[level]
      let kept = lma.map { $0.filter { $0 }.count } ?? la.width * la.height
      var scored: [(dx: Int, dy: Int, share: Double)] = []
      for (dx, dy) in candidates {
        let r = score(la, lma, lb, lmb, dx: dx, dy: dy, threshold: threshold)
        guard r.compared > 0, Double(r.compared) >= minOverlap * Double(max(kept, 1)) else { continue }
        scored.append((dx, dy, Double(r.differing) / Double(r.compared)))
      }
      // Lowest share first; on a tie the smaller move.
      best = Array(scored.sorted { ($0.share, abs($0.dx) + abs($0.dy)) < ($1.share, abs($1.dx) + abs($1.dy)) }.prefix(3))
      guard level > 0 else { break }
      var next: [(Int, Int)] = []
      for c in best { for ey in -1...1 { for ex in -1...1 where !next.contains(where: { $0 == (2 * c.dx + ex, 2 * c.dy + ey) }) { next.append((2 * c.dx + ex, 2 * c.dy + ey)) } } }
      candidates = next
    }
    return best.first
  }

  /// The diff picture of B against A at an offset: A dimmed, the pixels that differ in red, what neither mask keeps
  /// dimmer still.
  static func diffPicture(_ a: Pixels, _ ma: [Bool]?, _ b: Pixels, _ mb: [Bool]?, dx: Int = 0, dy: Int = 0, threshold: Int) -> Pixels {
    var d = Pixels(width: a.width, height: a.height, bytes: a.bytes.enumerated().map { $0.offset % 4 == 3 ? 255 : $0.element / 3 })
    for y in 0..<a.height {
      for x in 0..<a.width {
        let i = y * a.width + x, bx = x + dx, by = y + dy
        guard ma?[i] ?? true, bx >= 0, by >= 0, bx < b.width, by < b.height, mb?[by * b.width + bx] ?? true else {
          for c in 0..<3 { d.bytes[i * 4 + c] /= 2 }
          continue
        }
        let j = by * b.width + bx
        if (0..<4).contains(where: { abs(Int(a.bytes[i * 4 + $0]) - Int(b.bytes[j * 4 + $0])) > threshold }) { d.bytes[i * 4] = 255; d.bytes[i * 4 + 1] = 0; d.bytes[i * 4 + 2] = 0 }
      }
    }
    return d
  }

  /// Every region's look. `pictures`: the path prefix a changed region's pictures are written to (`P-NAME.before.png`,
  /// `.after.png`, `.diff.png`); nil writes none. `whole`: the two full pictures and the whole-window diff, which the
  /// `rest`/`window` region points at instead of copies.
  static func regionLooks(a: Pixels, b: Pixels, aLater: Pixels? = nil, bLater: Pixels? = nil, la: SnapshotLayout?, lb: SnapshotLayout?, threshold: Int = 16,
                          tolerance: Double, maxMovePt: Double = 120, pictures: String? = nil, whole: (a: String, b: String, diff: String?)? = nil) -> [RegionLook] {
    let scale = la?.scale ?? lb?.scale ?? 1
    let maxShift = Int(maxMovePt * scale)
    let movA = moving(a, aLater, threshold: threshold), movB = moving(b, bLater, threshold: threshold)
    func keep(_ mov: [Bool]?) -> [Bool]? { mov.map { $0.map { !$0 } } }
    func write(_ p: Pixels, _ name: String, _ kind: String) -> String? {
      guard let base = pictures, let data = p.png() else { return nil }
      let path = "\(base)-\(Looks.fileName(name)).\(kind).png"
      return (try? data.write(to: URL(fileURLWithPath: path))) != nil ? path : nil
    }
    func pt(_ px: Int) -> Int { Int((Double(px) / scale).rounded()) }
    var names: [String] = []
    for n in (la?.regions.map(\.name) ?? []) + (lb?.regions.map(\.name) ?? []) + (la?.missing ?? []) + (lb?.missing ?? []) where !names.contains(n) { names.append(n) }
    var out: [RegionLook] = []
    for n in names {
      let ra = la?.regions.first { $0.name == n }?.rect, rb = lb?.regions.first { $0.name == n }?.rect
      guard let ra, let rb else {
        var l = RegionLook(name: n, look: "missing", detail: ra == nil && rb == nil ? "not found in either picture" : ra == nil ? "only in the candidate's picture" : "only in the champion's picture")
        if ra == nil && rb == nil { l.look = "same" }   // nothing to compare, and nothing changed
        if let r = ra { l.before = write(crop(a, r), n, "before") }
        if let r = rb { l.after = write(crop(b, r), n, "after") }
        out.append(l); continue
      }
      let ca = crop(a, ra), cb = crop(b, rb)
      guard ra[2] == rb[2], ra[3] == rb[3] else {
        var l = RegionLook(name: n, look: "resized", detail: "\(pt(ra[2]))×\(pt(ra[3])) → \(pt(rb[2]))×\(pt(rb[3])) pt")
        l.before = write(ca, n, "before"); l.after = write(cb, n, "after")
        out.append(l); continue
      }
      let ma = crop(keep(movA), width: a.width, ra), mb = crop(keep(movB), width: b.width, rb)
      var l = look(n, ca, ma, cb, mb, shift: (rb[0] - ra[0], rb[1] - ra[1]), scale: scale, maxShift: maxShift, threshold: threshold, tolerance: tolerance)
      if l.changed {
        l.before = write(ca, n, "before"); l.after = write(cb, n, "after")
        let off = l.look == "moved" ? (Int(((l.movedPt?[0] ?? 0) * scale).rounded()) - (rb[0] - ra[0]), Int(((l.movedPt?[1] ?? 0) * scale).rounded()) - (rb[1] - ra[1])) : (0, 0)
        l.diff = write(diffPicture(ca, ma, cb, mb, dx: off.0, dy: off.1, threshold: threshold), n, "diff")
      }
      out.append(l)
    }
    // Everything outside the named regions.
    let named = !names.isEmpty
    let rest = named ? Looks.rest : Looks.window
    guard a.width == b.width, a.height == b.height else {
      var l = RegionLook(name: rest, look: "resized", detail: "the window \(pt(a.width))×\(pt(a.height)) → \(pt(b.width))×\(pt(b.height)) pt")
      l.before = whole?.a; l.after = whole?.b
      return out + [l]
    }
    // `rest`: the pixels outside the named regions in either picture (what moves out of a region into unnamed space,
    // or the reverse, is a change), less those of a region only one picture has (its own `missing` says that), less
    // both rects of a region that stayed where it was and grew or shrank (its `resized` says that), and less what
    // moves by itself.
    let n = a.width * a.height
    var mask = [Bool](repeating: false, count: n)
    func paint(_ rects: [[Int]], _ v: Bool, into m: inout [Bool]) {
      for r in rects { for y in max(0, r[1])..<min(a.height, r[1] + r[3]) { for x in max(0, r[0])..<min(a.width, r[0] + r[2]) { m[y * a.width + x] = v } } }
    }
    var inA = [Bool](repeating: false, count: n), inB = [Bool](repeating: false, count: n)
    paint(la?.regions.map(\.rect) ?? [], true, into: &inA); paint(lb?.regions.map(\.rect) ?? [], true, into: &inB)
    for k in 0..<n { mask[k] = !inA[k] || !inB[k] }
    let onlyA = la?.regions.filter { r in !(lb?.regions.contains { $0.name == r.name } ?? false) }.map(\.rect) ?? []
    let onlyB = lb?.regions.filter { r in !(la?.regions.contains { $0.name == r.name } ?? false) }.map(\.rect) ?? []
    let anchored = (la?.regions ?? []).compactMap { r in lb?.regions.first { $0.name == r.name && $0.rect[0] == r.rect[0] && $0.rect[1] == r.rect[1] }.map { [r.rect, $0.rect] } }.flatMap { $0 }
    paint(onlyA + onlyB + anchored, false, into: &mask)
    if let m = movA { for k in 0..<n where m[k] { mask[k] = false } }
    if let m = movB { for k in 0..<n where m[k] { mask[k] = false } }
    if !mask.contains(true) { return out }   // the regions cover the window
    let ma: [Bool]? = mask, mb: [Bool]? = nil
    // Only the whole window is searched for a move: `rest` beside named regions is what's left between them, which a
    // shift can't be told apart in (flat background matches itself anywhere).
    var l = look(rest, a, ma, b, mb, shift: (0, 0), scale: scale, maxShift: named ? 0 : maxShift, threshold: threshold, tolerance: tolerance)
    if l.changed {
      l.before = whole?.a; l.after = whole?.b
      if named || whole?.diff == nil {
        let off = l.look == "moved" ? (Int(((l.movedPt?[0] ?? 0) * scale).rounded()), Int(((l.movedPt?[1] ?? 0) * scale).rounded())) : (0, 0)
        l.diff = write(diffPicture(a, ma, b, mb, dx: off.0, dy: off.1, threshold: threshold), rest, "diff")
      } else { l.diff = whole?.diff }
    }
    return out + [l]
  }

  /// One region: same where it was, moved (by its own rect's shift and/or a shift of its content), or differs.
  static func look(_ name: String, _ a: Pixels, _ ma: [Bool]?, _ b: Pixels, _ mb: [Bool]?, shift: (Int, Int), scale: Double, maxShift: Int, threshold: Int, tolerance: Double) -> RegionLook {
    let z = score(a, ma, b, mb, dx: 0, dy: 0, threshold: threshold)
    let share = z.compared > 0 ? Double(z.differing) / Double(z.compared) : 0
    func pt(_ px: Int) -> Double { Stats.round(Double(px) / scale, 1) }
    if share <= tolerance {
      return shift == (0, 0) ? RegionLook(name: name, look: "same", share: Stats.round(share, 5))
        : RegionLook(name: name, look: "moved", share: Stats.round(share, 5), movedPt: [pt(shift.0), pt(shift.1)])
    }
    if maxShift > 0, let m = align(a, ma, b, mb, maxShift: maxShift, threshold: threshold), m.share <= tolerance, m.dx != 0 || m.dy != 0 {
      return RegionLook(name: name, look: "moved", share: Stats.round(share, 5), movedPt: [pt(shift.0 + m.dx), pt(shift.1 + m.dy)],
                        detail: m.share > 0 ? "\(Stats.round(m.share * 100, 2)) % still differs once moved" : nil)
    }
    return RegionLook(name: name, look: "differs", share: Stats.round(share, 5))
  }
}
#endif
