// `node tools/seam/node.mjs IN OUT`: one rung of wac's bootstrap ladder, on V8 (docs/seam-machine.md): the
// `wasm-seam/1` machine's first runner. The same protocol as tools/seam/wasmtime, and as bootstrap/js/ladder.js:
// IN holds `module`, `source` and, for the interpreter's shape, an optional `subject`; the answer's bytes go to OUT.
// Exit 0 with OUT written; anything else (no seam shape, a trap) exits 2: no answer.
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const [, , dir, out] = process.argv;
if (!dir || !out) { process.stderr.write("usage: node node.mjs IN OUT\n"); process.exit(2); }
const fail = (why) => { process.stderr.write(`seam-node: ${why}\n`); process.exit(2); };

let answer;
try {
  const wasm = readFileSync(`${dir}/module`);
  let text = readFileSync(`${dir}/source`);
  const subject = existsSync(`${dir}/subject`) ? readFileSync(`${dir}/subject`) : null;
  // A compiler rung's text may carry a suffix, after a newline: what the Rust ladder appends to wacc's flattened source
  // (`format!("{waccc}\n{driver}")`), the driver a host then calls it through.
  if (existsSync(`${dir}/suffix`)) text = Buffer.concat([text, Buffer.from("\n"), readFileSync(`${dir}/suffix`)]);
  const { instance } = await WebAssembly.instantiate(wasm, {});
  const e = instance.exports;
  const memory = e.memory;
  if (!(memory instanceof WebAssembly.Memory)) fail("no exported memory");
  // The text and a NUL at `at`, growing memory if it does not fit.
  const put = (at, bytes) => {
    const need = at + bytes.length + 1;
    if (need > memory.buffer.byteLength) memory.grow(Math.ceil((need - memory.buffer.byteLength) / 65536));
    const u8 = new Uint8Array(memory.buffer);
    u8.set(bytes, at);
    u8[at + bytes.length] = 0;
  };
  if (typeof e.seam_at === "function") {
    if (subject !== null) {
      text = Buffer.concat([text, Buffer.from("\n(compile (quote ("), subject, Buffer.from(")))\n")]);
    }
    const at = e.seam_at();
    put(at, text);
    const start = e.run_at(at);
    const u8 = new Uint8Array(memory.buffer);   // taken after the call: growing detaches an earlier view
    let end = start;
    while (end < u8.length && u8[end] !== 0) end++;
    answer = u8.subarray(start, end);
  } else if (typeof e.seam_src === "function") {
    if (subject !== null) fail("a subject is only for the interpreter's shape");
    const s = e.seam_src();
    const o = e.seam_out();
    put(s, text);
    const len = e.compile(s, o);
    answer = new Uint8Array(memory.buffer, o, len);
  } else {
    fail("neither seam shape: no seam_at, no seam_src");
  }
} catch (err) {
  fail(`trap or refusal: ${err && err.message}`);
}
writeFileSync(out, answer);
