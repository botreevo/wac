// A JSON-RPC node that only replays what was recorded: packages/lightclient/test/mainnet's execution block and its
// eth_getProof answers, so chain reads can be anchored and checked offline. `node replay.mjs PORT [honest|header|proof]`
//
//   eth_getBlockByHash / eth_getBlockByNumber   the recorded block (by hash: only its own; any other is null)
//   eth_getProof ADDR SLOTS BLOCK               for an address recorded, the recorded account proof and, for each slot
//                                               asked, its recorded storage proof; a slot not recorded is an error
//
// It lies on request, the ways a node can: `header` answers the recorded hash with another header (its gasUsed
// changed), `proof` changes one byte of the last node of each storage proof.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const dir = path.join(here, '../../lightclient/test/mainnet');
const result = (f) => { const d = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')); return d.result ?? d; };
const block = result('block.json');
const proofs = [result('proof.json'), result('contenthash.json')];
const [port, mode = 'honest'] = [Number(process.argv[2]), process.argv[3]];
const norm = (k) => '0x' + BigInt(k).toString(16).padStart(64, '0');
const answer = (q) => {
  const p = q.params || [];
  if (q.method === 'eth_getBlockByHash' || q.method === 'eth_getBlockByNumber') {
    if (q.method === 'eth_getBlockByHash' && p[0].toLowerCase() !== block.hash.toLowerCase()) return { result: null };
    const b = { ...block };
    if (mode === 'header') b.gasUsed = '0x' + (BigInt(b.gasUsed) + 1n).toString(16);
    return { result: b };
  }
  if (q.method === 'eth_getProof') {
    const [addr, slots, at] = p;
    if (at !== 'latest' && at.toLowerCase() !== block.hash.toLowerCase() && BigInt(at) !== BigInt(block.number)) {
      return { error: { code: -32000, message: 'the state of that block is not available' } };
    }
    const rec = proofs.find((r) => r.address.toLowerCase() === addr.toLowerCase());
    if (!rec) return { error: { code: -32000, message: `replay: no proofs recorded for ${addr}` } };
    const storageProof = [];
    for (const s of slots) {
      const sp = rec.storageProof.find((x) => norm(x.key) === norm(s));
      if (!sp) return { error: { code: -32000, message: `replay: slot ${s} of ${addr} was not recorded` } };
      const c = structuredClone(sp);
      if (mode === 'proof' && c.proof.length) {
        const last = c.proof[c.proof.length - 1];
        const i = last.length - 3;
        c.proof[c.proof.length - 1] = last.slice(0, i) + (last[i] === '0' ? '1' : '0') + last.slice(i + 1);
      }
      storageProof.push(c);
    }
    return { result: { ...rec, storageProof } };
  }
  return { error: { code: -32601, message: `replay: ${q.method} is not recorded` } };
};
http.createServer((req, res) => {
  let d = ''; req.on('data', (c) => d += c); req.on('end', () => {
    let a;
    try { const q = JSON.parse(d); a = { jsonrpc: '2.0', id: q.id ?? 1, ...answer(q) }; }
    catch (e) { a = { jsonrpc: '2.0', id: null, error: { code: -32700, message: 'replay: ' + e.message } }; }
    res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(a));
  });
}).listen(port, '127.0.0.1');
