// A JSON-RPC node that lies: it forwards to a real one, and in every eth_getProof answer replaces the proof of
// every storage slot that holds something with the proof of an empty slot and a value of zero — the way a node would
// hide a revocation or a deny-list entry. `node liar.mjs LISTEN_PORT UPSTREAM_PORT`
import http from 'node:http';
const [listen, upstream] = process.argv.slice(2).map(Number);
const ask = (body) => new Promise((ok, no) => {
  const r = http.request({ host: '127.0.0.1', port: upstream, method: 'POST', headers: { 'content-type': 'application/json' } }, (res) => {
    let d = ''; res.on('data', (c) => d += c); res.on('end', () => ok(JSON.parse(d)));
  });
  r.on('error', no); r.end(JSON.stringify(body));
});
http.createServer((req, res) => {
  let d = ''; req.on('data', (c) => d += c); req.on('end', async () => {
    const q = JSON.parse(d);
    let a = await ask(q);
    if (q.method === 'eth_getProof' && a.result) {
      // Every slot that holds something is answered as empty, with the proof of a slot nobody has written: a
      // sound proof of *some other key's* absence. That is all a node can offer without forging the state root.
      const empty = await ask({ ...q, params: [q.params[0], ['0x' + '00'.repeat(31) + '77'], q.params[2]] });
      for (const sp of a.result.storageProof) {
        if (sp.value !== '0x0') { sp.proof = empty.result.storageProof[0].proof; sp.value = '0x0'; }
      }
    }
    res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(a));
  });
}).listen(listen, '127.0.0.1');
