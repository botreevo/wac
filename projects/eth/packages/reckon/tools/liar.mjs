// A JSON-RPC node that lies: it forwards to a real one, and in every eth_getProof answer replaces the proof of
// every storage slot that holds something with the proof of an empty slot and a value of zero — the way a node would
// hide a revocation or a deny-list entry. `node liar.mjs LISTEN_PORT UPSTREAM_PORT`
//
// The substitute is the proof that some *other* key is absent: all a node can offer without forging the state root. It
// must differ from the slot's own proof. In a secure trie, when the other key's path and the slot's share a branch that
// holds only the slot's leaf, the proof of the other key's absence *is* the slot's proof, the "lie" is the truth, and a
// reader rightly believes it. With one fixed other key that happened on some runs and not others (the keys are random
// each run), and a lying-node check failed for a reason of the fixture's: so other keys are tried until the substitute
// is a different proof.
import http from 'node:http';
const [listen, upstream] = process.argv.slice(2).map(Number);
const ask = (body) => new Promise((ok, no) => {
  const r = http.request({ host: '127.0.0.1', port: upstream, method: 'POST', headers: { 'content-type': 'application/json' } }, (res) => {
    let d = ''; res.on('data', (c) => d += c); res.on('end', () => { try { ok(JSON.parse(d)); } catch (e) { no(e); } });
  });
  r.on('error', no); r.end(JSON.stringify(body));
});
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
http.createServer((req, res) => {
  let d = ''; req.on('data', (c) => d += c); req.on('end', async () => {
    let a;
    try {
      const q = JSON.parse(d);
      a = await ask(q);
      if (q.method === 'eth_getProof' && a.result) {
        for (const sp of a.result.storageProof) {
          if (sp.value === '0x0') continue;
          let lie = null;
          for (let k = 0x77; k < 0x77 + 64 && !lie; k++) {
            const other = await ask({ ...q, params: [q.params[0], ['0x' + k.toString(16).padStart(64, '0')], q.params[2]] });
            const p = other.result?.storageProof?.[0];
            if (p && p.value === '0x0' && !same(p.proof, sp.proof)) lie = p.proof;
          }
          if (!lie) throw new Error('no other key gives a different proof');
          sp.proof = lie; sp.value = '0x0';
        }
      }
    } catch (e) {
      a = { jsonrpc: '2.0', id: null, error: { code: -32000, message: 'liar: ' + e.message } };
    }
    res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(a));
  });
}).listen(listen, '127.0.0.1');
