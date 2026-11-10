// wac's JavaScript flattener (bootstrap/js/flatten.js) in the runner's shape: `TOOL ENTRY OUT`.
//
//     node tools/boot/flatten.mjs FLATTEN_JS ENTRY OUT
//
// Exit 0 with OUT written: the flattened program. Exit 1: an import names a file that is not there (the one refusal
// the rule has). Anything else is a failure of this command, not an answer. The filesystem is handed over as
// bootstrap/hosts/node.js hands it: `read` and `canonical` (realpath).
import { readFile, realpath, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const [, , flattener, entry, output] = process.argv;
if (!flattener || !entry || !output) {
  process.stderr.write("usage: node flatten.mjs FLATTEN_JS ENTRY OUT\n");
  process.exit(2);
}
const { flatten } = await import(pathToFileURL(resolve(flattener)).href);
let text;
try {
  text = await flatten(resolve(entry), { read: (p) => readFile(p, "utf8"), canonical: (p) => realpath(p) });
} catch (e) {
  if (e && e.code === "ENOENT") {
    process.stderr.write(`flatten.js: ${e.message}\n`);
    process.exit(1);
  }
  throw e;
}
await writeFile(output, text);
