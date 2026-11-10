// An independent kt1 tree hash, in JavaScript with js-sha3 — the oracle `test/tree_test.wac` is checked
// against. It walks a directory (skipping a top-level `.git`) and prints `kt1:<hex>`.
import sha3 from 'js-sha3';
import fs from 'node:fs';
import path from 'node:path';
const k = (b) => Buffer.from(sha3.keccak256.arrayBuffer(b));
const leaf = (c) => k(Buffer.concat([Buffer.from([0]), c]));
function node(dir, top) {
  const ents = [];
  for (const name of fs.readdirSync(dir)) {
    if (top && name === '.git') continue;
    const p = path.join(dir, name);
    const st = fs.lstatSync(p);
    if (st.isSymbolicLink()) throw new Error(p + ': symlink');
    if (st.isDirectory()) ents.push([name, 2, node(p, false)]);
    else ents.push([name, (st.mode & 0o100) ? 1 : 0, leaf(fs.readFileSync(p))]);
  }
  ents.sort((a, b) => Buffer.compare(Buffer.from(a[0]), Buffer.from(b[0])));
  const parts = [Buffer.from([1])];
  for (const [name, kind, h] of ents) {
    const nb = Buffer.from(name);
    parts.push(Buffer.from([nb.length >> 8, nb.length & 255]), nb, Buffer.from([kind]), h);
  }
  return k(Buffer.concat(parts));
}
console.log('kt1:' + node(process.argv[2], true).toString('hex'));
