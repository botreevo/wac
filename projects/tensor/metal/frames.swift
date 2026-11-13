// What the Metal server (`server.swift`) reads from a connection, and every check on it before anything touches memory
// or the GPU. Nothing here uses Metal, so `frames-check.swift` tests it on any machine with Swift:
//
//     swiftc metal/frames.swift metal/frames-check.swift -o dist/frames-check && dist/frames-check
//
// The server trusts nothing a connection sends. It listens on 127.0.0.1 only, but any local process can connect, and a
// mistake in a client must come back as a fault on the next read, not crash the server for every client or write
// outside a buffer.

/// The largest batch frame taken, in bytes. A batch carries the data of its writes, so it can be large, but not this
/// large; a longer length closes the connection instead of allocating it.
let MAX_FRAME = 1 << 30

/// The most buffers one run binds. Metal has 31 buffer slots.
let MAX_BINDINGS = 31

/// Reads the fields of one operation out of a batch. Every read checks that the bytes are there and answers nil if not,
/// so a short or malformed batch ends cleanly.
struct Cursor {
  let bytes: [UInt8]
  var at = 0

  init(bytes: [UInt8]) { self.bytes = bytes }

  mutating func u8() -> UInt8? {
    guard at < bytes.count else { return nil }
    at += 1
    return bytes[at - 1]
  }

  mutating func u32() -> Int? {
    guard bytes.count - at >= 4 else { return nil }
    let v = Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
    at += 4
    return v
  }

  mutating func i64() -> Int64? {
    guard let lo = u32(), let hi = u32() else { return nil }
    return Int64(bitPattern: UInt64(lo) | UInt64(hi) << 32)
  }

  mutating func take(_ n: Int) -> ArraySlice<UInt8>? {
    guard n >= 0, bytes.count - at >= n else { return nil }
    at += n
    return bytes[(at - n)..<at]
  }
}

/// One operation of a batch: `op, a, b, text, data`.
struct Operation {
  let op: UInt8
  let a: Int64
  let b: Int64
  let text: ArraySlice<UInt8>
  let data: ArraySlice<UInt8>
}

extension Cursor {
  /// The next operation, or nil if the batch ends partway through one.
  mutating func operation() -> Operation? {
    guard let op = u8(), let a = i64(), let b = i64() else { return nil }
    guard let textLength = u32(), let text = take(textLength) else { return nil }
    guard let dataLength = u32(), let data = take(dataLength) else { return nil }
    return Operation(op: op, a: a, b: b, text: text, data: data)
  }
}

/// Little-endian `i32`s; trailing bytes short of a whole one are ignored.
func ints(_ s: ArraySlice<UInt8>) -> [Int] {
  var out: [Int] = []
  var i = s.startIndex
  while i + 3 < s.endIndex {
    out.append(Int(Int32(bitPattern: UInt32(s[i]) | UInt32(s[i + 1]) << 8 | UInt32(s[i + 2]) << 16 | UInt32(s[i + 3]) << 24)))
    i += 4
  }
  return out
}

/// The length a buffer of `length` bytes is made with, which a freed one must have to be used again: 256 bytes at a time
/// up to 4 KB, then a quarter of a power of two at a time, so at most a quarter over. With exact lengths, a program whose
/// batches vary in size made fresh buffers for almost every batch — thousands of them, at the GPU's cost for fresh
/// memory, which tripled the time of every batch whose size it had not seen.
func sizeClass(_ length: Int) -> Int {
  if length <= 4096 { return (length + 255) / 256 * 256 }
  let step = 1 << (Int.bitWidth - (length - 1).leadingZeroBitCount - 3)
  return (length + step - 1) / step * step
}

/// Whether a buffer of `length` bytes may be made, when no buffer may be longer than `limit`.
func bufferLengthOK(_ length: Int64, limit: Int) -> Bool {
  return length >= 0 && length <= Int64(limit) && sizeClass(Int(length)) <= limit
}

/// Whether `count` bytes at `offset` lie inside a buffer of `length` bytes. No sum here can overflow: `offset` is
/// checked to be at most `length` before anything is added to it.
func rangeFits(offset: Int64, count: Int, length: Int) -> Bool {
  return offset >= 0 && count >= 0 && offset <= Int64(length) && count <= length - Int(offset)
}

/// `a * b + c`, or nil if any of it is negative or overflows.
func mulAdd(_ a: Int, _ b: Int, _ c: Int) -> Int? {
  guard a >= 0, b >= 0, c >= 0 else { return nil }
  let (p, o1) = a.multipliedReportingOverflow(by: b)
  if o1 { return nil }
  let (s, o2) = p.addingReportingOverflow(c)
  return o2 ? nil : s
}

/// The fields of `GPU_MATMUL` in `F32`: [a, b, out, batch, m, k, n, ta, tb, aStride, bStride]. Every count is in
/// elements; strides are between the matrices of a batch.
struct MatmulShape {
  let a: Int, b: Int, out: Int
  let batch: Int, m: Int, k: Int, n: Int
  let ta: Bool, tb: Bool
  let aStride: Int, bStride: Int

  /// The shape, or nil if there are too few fields or any count or stride is negative.
  init?(_ f: [Int]) {
    guard f.count >= 11 else { return nil }
    guard f[3] >= 0, f[4] >= 0, f[5] >= 0, f[6] >= 0, f[9] >= 0, f[10] >= 0 else { return nil }
    a = f[0]; b = f[1]; out = f[2]
    batch = f[3]; m = f[4]; k = f[5]; n = f[6]
    ta = f[7] != 0; tb = f[8] != 0
    aStride = f[9]; bStride = f[10]
  }

  /// The bytes each operand needs: the last matrix of the batch starts at `(batch - 1) * stride` and is
  /// `rows * columns` long. Nil if that overflows. A product with nothing in it needs nothing.
  func needs() -> (a: Int, b: Int, out: Int)? {
    if batch == 0 || m == 0 || n == 0 { return (0, 0, 0) }
    guard let mk = mulAdd(m, k, 0), let kn = mulAdd(k, n, 0), let mn = mulAdd(m, n, 0) else { return nil }
    guard let aEnd = mulAdd(batch - 1, aStride, mk), let bEnd = mulAdd(batch - 1, bStride, kn),
          let outEnd = mulAdd(batch, mn, 0) else { return nil }
    guard let aBytes = mulAdd(aEnd, 4, 0), let bBytes = mulAdd(bEnd, 4, 0), let outBytes = mulAdd(outEnd, 4, 0) else {
      return nil
    }
    return (aBytes, bBytes, outBytes)
  }
}

/// The port from the command line: 7787 when none is given, nil when what is given is not a port.
func portArgument(_ arguments: [String]) -> UInt16? {
  if arguments.count < 2 { return 7787 }
  guard let p = UInt16(arguments[1]), p != 0 else { return nil }
  return p
}
