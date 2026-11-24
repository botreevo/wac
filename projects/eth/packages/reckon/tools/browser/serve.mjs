// A static server for the browser checks: a page with the two headers SharedArrayBuffer needs (COOP, COEP), and
// CORS on everything, so a mirror on another port can be read by the page as a public one would be.
//
//     node serve.mjs PORT DIR
import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path';
const [port, dir] = [Number(process.argv[2]), process.argv[3]];
http.createServer((req, res) => {
  res.setHeader('cross-origin-opener-policy', 'same-origin');
  res.setHeader('cross-origin-embedder-policy', 'require-corp');
  res.setHeader('cross-origin-resource-policy', 'cross-origin');
  res.setHeader('access-control-allow-origin', '*');
  if (req.method === 'OPTIONS') { res.setHeader('access-control-allow-headers', 'accept'); res.statusCode = 204; res.end(); return; }
  const p = path.resolve(dir, '.' + decodeURIComponent(new URL(req.url, 'http://x').pathname));
  if (!p.startsWith(path.resolve(dir))) { res.statusCode = 403; res.end(); return; }
  fs.readFile(p, (e, b) => {
    if (e) { res.statusCode = 404; res.end(); return; }
    res.setHeader('content-type', p.endsWith('.html') ? 'text/html' : 'application/octet-stream');
    res.end(b);
  });
}).listen(port, '127.0.0.1');
