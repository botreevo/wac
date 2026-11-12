// wac-tensor's Metal server: the GPU end of `src/metal/metal.wac`, for a program run by `wac` on a Mac.
//
//     swiftc -O metal/server.swift -o dist/wac-tensor-metal && dist/wac-tensor-metal [port]     (7787 by default)
//
// It knows nothing about tensors. The kernels are MSL that wac-tensor writes (`src/metal/msl.wac`) and sends as
// programs; this compiles them, makes buffers, runs programs over them and reads them back — the five operations of
// `wac.gpu` (`src/gpu/line.wac`), which a browser host answers with WebGPU — plus `GPU_MATMUL`, a matrix product by
// Metal Performance Shaders, which is far faster than a shader written portably can be.
//
// **Buffers are shared memory**, which on Apple silicon is the GPU's own: a write is a copy into it and a read a copy
// out, with no staging. So a write to a buffer that work already encoded uses waits for that work first, as WebGPU's
// queue ordering would make it.
//
// **Freed buffers are used again**, once the GPU has finished with them, for the next buffer of the same length. A
// buffer the GPU has not touched before costs it more than twice as long to write the first time (2.1 ms against 0.85
// for 12 MB on the Mac this was written on), and every kernel's output is a new buffer, so without the pool a model
// spent most of its time on fresh memory. A reused buffer is not cleared: wac-tensor writes every buffer whole before it
// reads it (`GPU_BUFFER` in `src/gpu/line.wac`).
//
// **A batch is encoded as it arrives and committed at its end**, so the GPU works while the program builds the next.
// A read waits for everything committed, then answers — with the fault of anything that went wrong since the last read,
// if anything did, since a read is the one place the program listens. Each connection is served on a thread of its own,
// with its own queue and buffers, which go when it does: several programs — self-play workers, say — share one GPU.
//
// **`WAC_METAL_PROFILE=1`** runs every dispatch in a command buffer of its own and waits for it, which is slow, and
// prints the GPU's time for each program when the connection closes — named by the comment wac-tensor puts first.

import Foundation
import Metal
import MetalPerformanceShaders

let BUFFER: UInt8 = 0, WRITE: UInt8 = 1, FREE: UInt8 = 2, PROGRAM: UInt8 = 3, RUN: UInt8 = 4, MATMUL: UInt8 = 7

/// A connected socket, read and written whole.
final class Conn {
  let fd: Int32
  init(_ fd: Int32) { self.fd = fd }

  func read(_ n: Int) -> [UInt8]? {
    var out = [UInt8](repeating: 0, count: n)
    var got = 0
    while got < n {
      let k = out.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, n - got, 0) }
      if k <= 0 { return nil }
      got += k
    }
    return out
  }

  func u32() -> Int? {
    guard let b = read(4) else { return nil }
    return Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
  }

  func write(_ bytes: [UInt8]) {
    var sent = 0
    while sent < bytes.count {
      let k = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
      if k <= 0 { return }
      sent += k
    }
  }
}

func le32(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)] }

/// Reads the fields of one operation out of a batch.
struct Cursor {
  let bytes: [UInt8]
  var at = 0
  mutating func u8() -> UInt8 { at += 1; return bytes[at - 1] }
  mutating func u32() -> Int {
    let v = Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
    at += 4
    return v
  }
  mutating func i64() -> Int64 {
    let lo = UInt64(UInt32(truncatingIfNeeded: u32())), hi = UInt64(UInt32(truncatingIfNeeded: u32()))
    return Int64(bitPattern: lo | hi << 32)
  }
  mutating func take(_ n: Int) -> ArraySlice<UInt8> { at += n; return bytes[(at - n)..<at] }
}

/// Little-endian `i32`s.
func ints(_ s: ArraySlice<UInt8>) -> [Int] {
  var out: [Int] = []
  var i = s.startIndex
  while i + 3 < s.endIndex {
    out.append(Int(Int32(bitPattern: UInt32(s[i]) | UInt32(s[i + 1]) << 8 | UInt32(s[i + 2]) << 16 | UInt32(s[i + 3]) << 24)))
    i += 4
  }
  return out
}

/// Three 16-bit counts from the top of `b`, as `groups(x, y, z)` packs them.
func size3(_ b: Int64) -> MTLSize {
  let u = UInt64(bitPattern: b)
  return MTLSize(width: Int((u >> 48) & 0xffff), height: Int((u >> 32) & 0xffff), depth: Int((u >> 16) & 0xffff))
}

final class Session {
  let device: MTLDevice
  let queue: MTLCommandQueue
  var buffers: [Int: MTLBuffer] = [:]
  var programs: [Int: (MTLComputePipelineState, MTLSize)] = [:]
  var commands: MTLCommandBuffer? = nil
  var compute: MTLComputeCommandEncoder? = nil
  var committed: [MTLCommandBuffer] = []
  /// Buffers ready to be handed out again, by length.
  var pool: [Int: [MTLBuffer]] = [:]
  /// Buffers freed since the last commit, which work encoded or committed before then may still use.
  var freed: [MTLBuffer] = []
  /// Freed buffers, each batch with the command buffer that must finish before they are used again; oldest first.
  var retiring: [(MTLCommandBuffer, [MTLBuffer])] = []
  /// Buffers that work encoded or committed since the last wait may still use.
  var busy = Set<Int>()
  var errors: [String] = []
  var products: [String: MPSMatrixMultiplication] = [:]
  let options: MTLCompileOptions
  let profiling = ProcessInfo.processInfo.environment["WAC_METAL_PROFILE"] == "1"
  var names: [Int: String] = [:]
  /// Under `WAC_METAL_PROFILE`: each program's total GPU seconds and dispatches.
  var spent: [String: (Double, Int)] = [:]

  init(_ device: MTLDevice) {
    self.device = device
    queue = device.makeCommandQueue()!
    options = MTLCompileOptions()
    // A NaN must survive `max`, and `x != x` must mean what it says.
    if #available(macOS 15.0, *) { options.mathMode = .safe } else { options.fastMathEnabled = false }
  }

  func buffer(_ h: Int) -> MTLBuffer? {
    if let b = buffers[h] { return b }
    fault("buffer \(h) is not there")
    return nil
  }

  /// Something to answer the next read with. One mistake usually causes hundreds more; the first few say enough.
  func fault(_ why: String) {
    if errors.count < 8 { errors.append(why) } else if errors.count == 8 { errors.append("and more") }
  }

  func encoder() -> MTLComputeCommandEncoder {
    if let c = compute { return c }
    if commands == nil { commands = queue.makeCommandBuffer()! }
    compute = commands!.makeComputeCommandEncoder()!
    return compute!
  }

  func commit() {
    compute?.endEncoding()
    compute = nil
    if let c = commands { c.commit(); committed.append(c); commands = nil }
    // The queue runs in order, so once the last command buffer committed has finished, nothing uses these.
    if !freed.isEmpty {
      if let last = committed.last { retiring.append((last, freed)) } else { recycle(freed) }
      freed = []
    }
  }

  func recycle(_ bufs: [MTLBuffer]) { for b in bufs { pool[b.length, default: []].append(b) } }

  /// Into the pool, whatever has retired by now; without waiting for anything.
  func reclaim() {
    while let (c, bufs) = retiring.first, c.status == .completed || c.status == .error {
      recycle(bufs)
      retiring.removeFirst()
    }
  }

  func allocate(_ length: Int) -> MTLBuffer? {
    let size = (length + 255) / 256 * 256
    if pool[size]?.isEmpty ?? true { reclaim() }
    if let b = pool[size]?.popLast() { return b }
    return device.makeBuffer(length: size, options: .storageModeShared)
  }

  /// Everything encoded, committed and finished.
  func wait() {
    commit()
    for c in committed {
      c.waitUntilCompleted()
      if let e = c.error { fault("the GPU: \(e.localizedDescription)") }
    }
    committed = []
    busy.removeAll()
    for (_, bufs) in retiring { recycle(bufs) }
    retiring = []
  }

  func batch(_ count: Int, _ bytes: [UInt8]) {
    var c = Cursor(bytes: bytes)
    for _ in 0..<count {
      let op = c.u8(), a = c.i64(), b = c.i64()
      let text = c.take(c.u32()), data = c.take(c.u32())
      let h = Int(a)
      switch op {
      case BUFFER:
        guard let buf = allocate(max(Int(b), 4)) else { fault("no buffer of \(b) bytes"); continue }
        buffers[h] = buf
      case WRITE:
        guard let buf = buffer(h) else { continue }
        if busy.contains(h) { wait() }
        if Int(b) + data.count > buf.length { fault("a write past the end of buffer \(h)"); continue }
        if !data.isEmpty { _ = data.withUnsafeBytes { memcpy(buf.contents() + Int(b), $0.baseAddress!, data.count) } }
      case FREE:
        if let buf = buffers.removeValue(forKey: h) { freed.append(buf) }
        programs.removeValue(forKey: h)
      case PROGRAM:
        do {
          let lib = try device.makeLibrary(source: String(decoding: text, as: UTF8.self), options: options)
          let pipe = try device.makeComputePipelineState(function: lib.makeFunction(name: "k")!)
          programs[h] = (pipe, size3(b))
          names[h] = String(decoding: text.prefix(while: { $0 != 10 }), as: UTF8.self)
        } catch {
          fault("a program did not compile: \(error)")
        }
      case RUN:
        guard let (pipe, threads) = programs[h] else { fault("program \(h) is not there"); continue }
        let e = encoder()
        e.setComputePipelineState(pipe)
        for (i, bh) in ints(data).enumerated() {
          guard let buf = buffer(bh) else { continue }
          e.setBuffer(buf, offset: 0, index: i)
          busy.insert(bh)
        }
        e.dispatchThreadgroups(size3(b), threadsPerThreadgroup: threads)
        if profiling { timed(names[h] ?? "?") }
      case MATMUL:
        matmul(ints(data))
      default:
        fault("an operation numbered \(op), which this server does not know")
      }
    }
    commit()
  }

  /// `Backend.matmul` in `F32`: [a, b, out, batch, m, k, n, ta, tb, aStride, bStride].
  func matmul(_ f: [Int]) {
    guard let A = buffer(f[0]), let B = buffer(f[1]), let C = buffer(f[2]) else { return }
    var (batch, m) = (f[3], f[4])
    let (k, n, ta, tb, aStride, bStride) = (f[5], f[6], f[7] != 0, f[8] != 0, f[9], f[10])
    // A stack of left matrices against one shared right one is one tall product.
    if batch > 1 && !ta && bStride == 0 && aStride == m * k { m *= batch; batch = 1 }
    compute?.endEncoding()
    compute = nil
    if commands == nil { commands = queue.makeCommandBuffer()! }
    let key = "\(m) \(k) \(n) \(ta) \(tb)"
    let product = products[key] ?? MPSMatrixMultiplication(
      device: device, transposeLeft: ta, transposeRight: tb, resultRows: m, resultColumns: n, interiorColumns: k,
      alpha: 1, beta: 0)
    products[key] = product
    let da = MPSMatrixDescriptor(rows: ta ? k : m, columns: ta ? m : k, rowBytes: (ta ? m : k) * 4, dataType: .float32)
    let db = MPSMatrixDescriptor(rows: tb ? n : k, columns: tb ? k : n, rowBytes: (tb ? k : n) * 4, dataType: .float32)
    let dc = MPSMatrixDescriptor(rows: m, columns: n, rowBytes: n * 4, dataType: .float32)
    for q in 0..<batch {
      product.encode(commandBuffer: commands!,
                     leftMatrix: MPSMatrix(buffer: A, offset: q * aStride * 4, descriptor: da),
                     rightMatrix: MPSMatrix(buffer: B, offset: q * bStride * 4, descriptor: db),
                     resultMatrix: MPSMatrix(buffer: C, offset: q * m * n * 4, descriptor: dc))
    }
    busy.formUnion([f[0], f[1], f[2]])
    if profiling { timed("// mps \(m)x\(k)x\(n)\(ta ? " ta" : "")\(tb ? " tb" : "") ×\(batch)") }
  }

  /// Under `WAC_METAL_PROFILE`: what is encoded, run alone and timed as `name`.
  func timed(_ name: String) {
    let c = commands!
    commit()
    c.waitUntilCompleted()
    let (t, n) = spent[name] ?? (0, 0)
    spent[name] = (t + c.gpuEndTime - c.gpuStartTime, n + 1)
  }

  func report() {
    if spent.isEmpty { return }
    let total = spent.values.reduce(0) { $0 + $1.0 }
    var lines = ["GPU time by program, \(String(format: "%.1f", total * 1000)) ms in all:"]
    for (name, (t, n)) in spent.sorted(by: { $0.value.0 > $1.value.0 }).prefix(15) {
      lines.append(String(format: "%9.2f ms %7d× %@", t * 1000, n, String(name.dropFirst(3))))
    }
    FileHandle.standardError.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
  }

  func read(_ h: Int, _ offset: Int, _ length: Int) -> [UInt8] {
    wait()
    var bytes: [UInt8] = []
    if let buf = buffer(h) {
      if offset + length > buf.length { fault("a read past the end of buffer \(h)") }
      else { bytes = [UInt8](UnsafeRawBufferPointer(start: buf.contents() + offset, count: length)) }
    }
    if !errors.isEmpty {
      let why = Array(errors.joined(separator: "; ").utf8)
      errors = []
      return le32(5) + le32(why.count) + why + le32(0)
    }
    return le32(0) + le32(0) + le32(bytes.count) + bytes
  }
}

func serve(_ conn: Conn, _ device: MTLDevice) {
  let hello = Array("wac.metal 1 \(device.name)".utf8)
  conn.write(le32(hello.count) + hello)
  let s = Session(device)
  // Metal hands back its command buffers and encoders autoreleased, and a command-line program has no run loop to
  // drain them: without a pool per request, every command buffer — and every buffer it used — would live forever.
  while let kind = conn.read(1) {
    if kind[0] == 0 {
      guard let count = conn.u32(), let length = conn.u32(), let bytes = conn.read(length) else { break }
      autoreleasepool { s.batch(count, bytes) }
    } else {
      guard let h = conn.u32(), let offset = conn.u32(), let length = conn.u32() else { break }
      conn.write(autoreleasepool { s.read(h, offset, length) })
    }
  }
  s.report()
}

let port = CommandLine.arguments.count > 1 ? UInt16(CommandLine.arguments[1])! : 7787
guard let device = MTLCreateSystemDefaultDevice() else { fatalError("this Mac has no Metal device") }
let listener = socket(AF_INET, SOCK_STREAM, 0)
var yes: Int32 = 1
setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
addr.sin_addr.s_addr = inet_addr("127.0.0.1")
let bound = withUnsafePointer(to: &addr) {
  $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
}
if bound != 0 || listen(listener, 4) != 0 { fatalError("cannot listen on 127.0.0.1:\(port)") }
FileHandle.standardError.write("wac-tensor-metal: \(device.name), listening on 127.0.0.1:\(port)\n".data(using: .utf8)!)
while true {
  let fd = accept(listener, nil, nil)
  if fd < 0 { continue }
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
  Thread {
    serve(Conn(fd), device)
    close(fd)
  }.start()
}
