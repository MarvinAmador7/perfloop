import Foundation

// A small, fast reader for what `xctrace export` prints (ported from capcomd's deskbench, where it was written). Elements,
// attributes (either quote), text, the five named entities and numeric ones; `<?…?>`, comments and `<!…>` are skipped,
// CDATA is text. It builds the `XNode` tree XMLParser would, about ten times faster, which is what makes a 24 MB
// time-profile export a matter of a second or two. Not a validating parser: a mismatched close tag closes the innermost
// element, as the exports never have one. Pure Foundation: it builds and runs on Linux, so exports parse anywhere.
enum XMLLite {
  static func parse(_ data: Data) throws -> XNode {
    let root = XNode("#root", [:])
    let ok = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
      var r = Reader(p: base, n: raw.count)
      return r.run(root)
    }
    guard ok, !root.children.isEmpty else { throw XCTraceError.badXML("not an xctrace export (no element)") }
    return root
  }

  private struct Reader {
    let p: UnsafePointer<UInt8>
    let n: Int
    var i = 0

    static let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/"), eq = UInt8(ascii: "="), amp = UInt8(ascii: "&")
    static let q1 = UInt8(ascii: "'"), q2 = UInt8(ascii: "\""), bang = UInt8(ascii: "!"), qm = UInt8(ascii: "?")

    @inline(__always) func space(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }

    /// Index of `needle` at or after `from`, or n.
    func find(_ needle: [UInt8], from: Int) -> Int {
      var j = from
      while j + needle.count <= n {
        if p[j] == needle[0] {
          var k = 1
          while k < needle.count && p[j + k] == needle[k] { k += 1 }
          if k == needle.count { return j }
        }
        j += 1
      }
      return n
    }

    func string(_ a: Int, _ b: Int) -> String {
      let s = String(decoding: UnsafeBufferPointer(start: p + a, count: b - a), as: UTF8.self)
      var hasAmp = false
      for j in a..<b where p[j] == Self.amp { hasAmp = true; break }
      return hasAmp ? Self.unescape(s) : s
    }

    static func unescape(_ s: String) -> String {
      var out = ""; out.reserveCapacity(s.utf8.count)
      var rest = Substring(s)
      while let a = rest.firstIndex(of: "&") {
        out += rest[..<a]
        guard let semi = rest[a...].firstIndex(of: ";"), rest.distance(from: a, to: semi) <= 10 else { out += "&"; rest = rest[rest.index(after: a)...]; continue }
        let name = rest[rest.index(after: a)..<semi]
        switch name {
        case "lt": out += "<"
        case "gt": out += ">"
        case "amp": out += "&"
        case "quot": out += "\""
        case "apos": out += "'"
        default:
          var code: UInt32?
          if name.hasPrefix("#x") || name.hasPrefix("#X") { code = UInt32(name.dropFirst(2), radix: 16) } else if name.hasPrefix("#") { code = UInt32(name.dropFirst()) }
          if let c = code, let u = Unicode.Scalar(c) { out.unicodeScalars.append(u) } else { out += "&" + name + ";" }
        }
        rest = rest[rest.index(after: semi)...]
      }
      out += rest
      return out
    }

    mutating func run(_ root: XNode) -> Bool {
      var stack: [XNode] = [root]
      while i < n {
        if p[i] != Self.lt {
          let a = i
          var blank = true
          while i < n && p[i] != Self.lt { if blank && !space(p[i]) { blank = false }; i += 1 }
          if !blank { stack[stack.count - 1].text += string(a, i) }
          continue
        }
        // p[i] == '<'
        guard i + 1 < n else { return false }
        let c = p[i + 1]
        if c == Self.qm { i = min(n, find([Self.qm, Self.gt], from: i + 2) + 2); continue }
        if c == Self.bang {
          if i + 3 < n, p[i + 2] == UInt8(ascii: "-"), p[i + 3] == UInt8(ascii: "-") { i = min(n, find(Array("-->".utf8), from: i + 4) + 3); continue }
          if i + 8 < n, find(Array("[CDATA[".utf8), from: i + 2) == i + 2 {
            let end = find(Array("]]>".utf8), from: i + 9)
            stack[stack.count - 1].text += String(decoding: UnsafeBufferPointer(start: p + i + 9, count: max(0, end - i - 9)), as: UTF8.self)
            i = min(n, end + 3); continue
          }
          i = min(n, find([Self.gt], from: i + 2) + 1); continue
        }
        if c == Self.slash {
          i = min(n, find([Self.gt], from: i + 2) + 1)
          if stack.count > 1 { stack.removeLast() }
          continue
        }
        // An element: name, attributes, then '>' or '/>'.
        i += 1
        let a = i
        while i < n && !space(p[i]) && p[i] != Self.gt && p[i] != Self.slash { i += 1 }
        let name = string(a, i)
        var attrs: [String: String] = [:]
        var selfClosing = false
        while i < n {
          while i < n && space(p[i]) { i += 1 }
          guard i < n else { return false }
          if p[i] == Self.gt { i += 1; break }
          if p[i] == Self.slash { selfClosing = true; i = min(n, find([Self.gt], from: i) + 1); break }
          let ka = i
          while i < n && p[i] != Self.eq && !space(p[i]) && p[i] != Self.gt { i += 1 }
          let key = string(ka, i)
          while i < n && space(p[i]) { i += 1 }
          guard i < n, p[i] == Self.eq else { continue }   // an attribute without a value: ignored
          i += 1
          while i < n && space(p[i]) { i += 1 }
          guard i < n, p[i] == Self.q1 || p[i] == Self.q2 else { return false }
          let q = p[i]; i += 1
          let va = i
          while i < n && p[i] != q { i += 1 }
          attrs[key] = string(va, i)
          i += 1
        }
        let node = XNode(name, attrs)
        stack[stack.count - 1].children.append(node)
        if !selfClosing { stack.append(node) }
      }
      return true
    }
  }
}
