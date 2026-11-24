// Checks `frames.swift`, the Metal server's reading and bounds checks, on any machine with Swift (no Metal needed):
//
//     swiftc metal/frames.swift metal/frames-check.swift -o dist/frames-check && dist/frames-check
//
// Prints `PASS <n>`, or each failure and `FAIL`, and exits non-zero on a failure.

import Foundation

@main
struct FramesCheck {
  static func le32(_ v: Int) -> [UInt8] {
    [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)]
  }

  static func le64(_ v: Int64) -> [UInt8] {
    let u = UInt64(bitPattern: v)
    return le32(Int(u & 0xffff_ffff)) + le32(Int(u >> 32))
  }

  static func operation(_ op: UInt8, _ a: Int64, _ b: Int64, _ text: [UInt8], _ data: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [op]
    out.append(contentsOf: le64(a))
    out.append(contentsOf: le64(b))
    out.append(contentsOf: le32(text.count))
    out.append(contentsOf: text)
    out.append(contentsOf: le32(data.count))
    out.append(contentsOf: data)
    return out
  }

  static func main() {
    var passed = 0
    var failed = 0
    func check(_ ok: Bool, _ what: String) {
      if ok { passed += 1 } else { failed += 1; print("failed: \(what)") }
    }

    // A whole operation reads back as written, and the cursor ends at its end.
    let one = operation(1, 7, -3, [65, 66], [1, 2, 3])
    var c = Cursor(bytes: one)
    if let o = c.operation() {
      check(o.op == 1 && o.a == 7 && o.b == -3, "fields of an operation")
      check(Array(o.text) == [65, 66] && Array(o.data) == [1, 2, 3], "text and data of an operation")
      check(c.at == one.count, "the cursor at the end")
    } else {
      check(false, "a whole operation reads")
    }
    check(c.operation() == nil, "nothing after the end")

    // Every truncation of an operation is refused, never read past.
    for cut in 0..<one.count {
      var t = Cursor(bytes: Array(one[0..<cut]))
      check(t.operation() == nil, "an operation cut at \(cut) bytes")
    }

    // A length beyond what is there is refused, even the largest.
    var longText: [UInt8] = [3]
    longText.append(contentsOf: le64(0))
    longText.append(contentsOf: le64(0))
    longText.append(contentsOf: le32(Int(UInt32.max)))
    longText.append(contentsOf: [0, 0])
    var huge = Cursor(bytes: longText)
    check(huge.operation() == nil, "a text longer than the batch")
    var negative = Cursor(bytes: [1, 2, 3])
    check(negative.take(-1) == nil, "a negative take")

    // Writes: inside, at the very end, past the end, at negative offsets, and offsets that would overflow.
    check(rangeFits(offset: 0, count: 16, length: 16), "a write filling the buffer")
    check(rangeFits(offset: 16, count: 0, length: 16), "an empty write at the end")
    check(!rangeFits(offset: 1, count: 16, length: 16), "a write one past the end")
    check(!rangeFits(offset: -4, count: 4, length: 16), "a write at a negative offset")
    check(!rangeFits(offset: Int64.min, count: 4, length: 16), "a write at the most negative offset")
    check(!rangeFits(offset: Int64.max, count: 4, length: 16), "a write at the largest offset")
    check(!rangeFits(offset: 17, count: 0, length: 16), "an empty write past the end")

    // Buffers: none negative or over the device's limit, including after rounding up to a size class.
    check(bufferLengthOK(0, limit: 1 << 20), "an empty buffer")
    check(bufferLengthOK(1 << 20, limit: 1 << 20), "a buffer at the limit")
    check(!bufferLengthOK(-1, limit: 1 << 20), "a negative buffer")
    check(!bufferLengthOK((1 << 20) + 1, limit: 1 << 20), "a buffer over the limit")
    check(!bufferLengthOK(Int64.max, limit: 1 << 20), "the largest buffer")
    check(!bufferLengthOK(5000, limit: 5000), "a buffer whose size class is over the limit")

    // Size classes: never smaller than asked, at most a quarter over past 4 KB.
    for length in [1, 255, 256, 4095, 4096, 4097, 5000, 65_537, 12_000_000] {
      let s = sizeClass(length)
      check(s >= length && (length <= 4096 || s - length <= length / 4 + 1), "the size class of \(length)")
    }

    // Matrix products: too few fields, negative counts, what each operand needs, and overflow.
    check(MatmulShape([1, 2, 3]) == nil, "a product with too few fields")
    check(MatmulShape([0, 1, 2, 1, -1, 2, 2, 0, 0, 0, 0]) == nil, "a product with a negative count")
    check(MatmulShape([0, 1, 2, 1, 2, 2, 2, 0, 0, -4, 0]) == nil, "a product with a negative stride")
    if let s = MatmulShape([0, 1, 2, 3, 4, 5, 6, 0, 0, 20, 30]), let n = s.needs() {
      // A: the third matrix starts at 2 * 20 and is 4 * 5 long; B: at 2 * 30, 5 * 6; out: 3 of 4 * 6.
      check(n.a == (40 + 20) * 4 && n.b == (60 + 30) * 4 && n.out == 72 * 4, "what a product needs")
    } else {
      check(false, "a whole product")
    }
    if let s = MatmulShape([0, 1, 2, 1, 0, 5, 6, 0, 0, 0, 0]), let n = s.needs() {
      check(n.a == 0 && n.b == 0 && n.out == 0, "a product with no rows needs nothing")
    } else {
      check(false, "a product with no rows")
    }
    if let s = MatmulShape([0, 1, 2, 1, 4, 0, 6, 0, 0, 0, 0]), let n = s.needs() {
      check(n.a == 0 && n.b == 0 && n.out == 4 * 6 * 4, "a product with k = 0 needs its whole output")
    } else {
      check(false, "a product with k = 0")
    }
    let big = Int(Int32.max)
    if let s = MatmulShape([0, 1, 2, big, big, big, big, 0, 0, big, big]) {
      check(s.needs() == nil, "a product whose size overflows")
    } else {
      check(false, "a product with the largest counts parses")
    }

    // The port: the default, a number, and anything else.
    check(portArgument(["server"]) == 7787, "the default port")
    check(portArgument(["server", "9000"]) == 9000, "a port")
    check(portArgument(["server", "x"]) == nil, "a port that is not a number")
    check(portArgument(["server", "70000"]) == nil, "a port too large")
    check(portArgument(["server", "0"]) == nil, "port 0")

    // Short data, as `ints` reads it.
    check(ints(ArraySlice<UInt8>([1, 0, 0, 0, 2, 0, 0, 0, 9])) == [1, 2], "ints ignores a partial one")
    check(ints(ArraySlice<UInt8>([255, 255, 255, 255])) == [-1], "ints are signed")

    if failed == 0 {
      print("PASS \(passed)")
    } else {
      print("FAIL: \(failed) of \(passed + failed)")
      exit(1)
    }
  }
}
