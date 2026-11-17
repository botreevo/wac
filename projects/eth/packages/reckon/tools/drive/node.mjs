// `node tools/drive/node.mjs BOOTSTRAP IN OUT`: wacc, as the bootstrap ladder built it, compiling a program, on V8: the
// `wacc-drive/1` machine's JavaScript runner (docs/drive-machine.md). BOOTSTRAP is wac's bootstrap/ directory at the
// pinned commit, whose js/flatten.js (`fileSet`) and js/wacc.js (`wacc`, `grantsOf`) are the implementation. IN holds
// `wacc`, `tree/`, `entry`, `name` and `grants`, as for tools/drive/wasmtime. Exit 0 with OUT written; 1 when wacc
// declines the program; anything else is 2.
import { readFile, realpath, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [, , boot, dirArg, outArg] = process.argv;
if (!boot || !dirArg || !outArg) { process.stderr.write("usage: node node.mjs BOOTSTRAP IN OUT\n"); process.exit(2); }
const fail = (code, why) => { process.stderr.write(`drive-node: ${why}\n`); process.exit(code); };
const dir = resolve(dirArg), out = resolve(outArg);
try {
  const { fileSet } = await import(pathToFileURL(resolve(boot, "js/flatten.js")).href);
  const { wacc, grantsOf } = await import(pathToFileURL(resolve(boot, "js/wacc.js")).href);
  const text = async (n) => (await readFile(`${dir}/${n}`, "utf8")).trim();
  const entry = await text("entry"), name = await text("name");
  const grants = grantsOf((await text("grants")).split(/\s+/).filter((g) => g).map((g) => `--allow-${g}`));
  const wasm = await readFile(`${dir}/wacc`);
  // The file set from inside the tree, as the ladder computes it from inside wac's checkout.
  process.chdir(`${dir}/tree`);
  const fs = await fileSet(entry, { read: (p) => readFile(p, "utf8"), canonical: (p) => realpath(p) });
  const { instance } = await WebAssembly.instantiate(wasm, {});
  const w = wacc(instance);
  const module = w.emitFiles(fs.keys, fs.texts, fs.entry);
  if (module.length <= 8) fail(1, `wacc declined ${entry}: ${w.decline()}`);
  await writeFile(out, w.seal(entry, name, grants));
} catch (e) {
  fail(2, e && e.message);
}
