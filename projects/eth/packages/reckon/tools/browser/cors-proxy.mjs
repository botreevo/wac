// A JSON-RPC node behind CORS, for pages: forwards every POST to TARGET and answers with what it said, adding the
// headers a page's fetch needs. A wacuum devnet sends none (a public RPC does). Test infrastructure only.
//
//     node cors-proxy.mjs PORT TARGET_PORT
import http from 'node:http';
const [port, target] = [Number(process.argv[2]), Number(process.argv[3])];
http.createServer((req, res) => {
  res.setHeader('access-control-allow-origin', '*');
  res.setHeader('access-control-allow-headers', 'content-type');
  res.setHeader('access-control-allow-methods', 'POST, GET, OPTIONS');
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  // The body whole, with its length: a node may not read a chunked request (wacuum does not).
  const parts = [];
  req.on('data', (c) => parts.push(c));
  req.on('end', () => {
    const body = Buffer.concat(parts);
    const up = http.request({ host: '127.0.0.1', port: target, method: req.method, path: req.url,
      headers: { 'content-type': 'application/json', 'content-length': body.length } }, (r) => {
      res.statusCode = r.statusCode; res.setHeader('content-type', r.headers['content-type'] || 'application/json'); r.pipe(res);
    });
    up.on('error', (e) => { res.statusCode = 502; res.end(String(e)); });
    up.end(body);
  });
}).listen(port, '127.0.0.1');
