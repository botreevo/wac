// wac's JavaScript L0 assembler (bootstrap/js/assemble.js) in the shape of its Rust one: `wax IN OUT`.
//
//     node tools/l0/assemble.mjs ASSEMBLE_JS IN OUT
//
// Exit 0 with OUT written: assembled. Exit 1: the text is not L0 (a WaxError). Anything else is a failure of this
// command, not an answer. ASSEMBLE_JS is the file at the commit the machine names; nothing else of wac's is loaded.
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const [, , assembler, input, output] = process.argv;
if (!assembler || !input || !output) {
  process.stderr.write("usage: node assemble.mjs ASSEMBLE_JS IN OUT\n");
  process.exit(2);
}
const { assemble, WaxError } = await import(pathToFileURL(resolve(assembler)).href);
const source = readFileSync(input, "utf8");
let bytes;
try {
  bytes = assemble(source);
} catch (e) {
  if (e instanceof WaxError) {
    process.stderr.write(`wax.js: ${input}: ${e.message}\n`);
    process.exit(1);
  }
  throw e;
}
writeFileSync(output, bytes);
