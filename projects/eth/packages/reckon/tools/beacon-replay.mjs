// A beacon node that only replays what was recorded: packages/lightclient/test/mainnet's light-client data, over the
// beacon REST API as `application/octet-stream` with an Eth-Consensus-Version header, so `claim admit --beacon-url` can
// be checked offline. `node beacon-replay.mjs PORT [honest|bootstrap|update|finality|fork]`
//
//   GET /eth/v1/beacon/light_client/bootstrap/{root}     the recorded bootstrap, for its own checkpoint only (else 404)
//   GET /eth/v1/beacon/light_client/updates?…            the recorded updates (period 1906), whatever range is asked
//   GET /eth/v1/beacon/light_client/finality_update      the recorded finality update
//   GET /eth/v1/beacon/light_client/optimistic_update    the recorded optimistic update
//
// It lies on request: `bootstrap`, `update` and `finality` change one byte of that answer; `fork` answers the finality
// update as another fork than the rest.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const dir = path.join(here, '../../lightclient/test/mainnet');
const read = (f) => fs.readFileSync(path.join(dir, f));
const CHECKPOINT = '0xa8356934e2fba13cb82917ea04203c75ca84bb735cefe3cf2f35976628e1e937';
const [port, mode = 'honest'] = [Number(process.argv[2]), process.argv[3]];
const flip = (b, at) => { const c = Buffer.from(b); c[at] ^= 0x01; return c; };
// CORS, with the fork header exposed, as the public beacon node docs/admit.md checked serves it (R3).
http.createServer((req, res) => {
  res.setHeader('access-control-allow-origin', '*');
  res.setHeader('access-control-expose-headers', 'eth-consensus-version');
  if (req.method === 'OPTIONS') {
    res.setHeader('access-control-allow-methods', 'GET, OPTIONS');
    res.setHeader('access-control-allow-headers', 'accept');
    res.statusCode = 204; res.end(); return;
  }
  const u = new URL(req.url, 'http://x');
  let body = null; let fork = 'fulu';
  if (u.pathname.startsWith('/eth/v1/beacon/light_client/bootstrap/')) {
    if (u.pathname.split('/').pop().toLowerCase() === CHECKPOINT) body = mode === 'bootstrap' ? flip(read('bootstrap.ssz'), 200) : read('bootstrap.ssz');
  } else if (u.pathname === '/eth/v1/beacon/light_client/updates') {
    body = mode === 'update' ? flip(read('updates.ssz'), 12 + 300) : read('updates.ssz');
  } else if (u.pathname === '/eth/v1/beacon/light_client/finality_update') {
    body = mode === 'finality' ? flip(read('finality.ssz'), 300) : read('finality.ssz');
    if (mode === 'fork') fork = 'electra';
  } else if (u.pathname === '/eth/v1/beacon/light_client/optimistic_update') {
    body = read('optimistic.ssz');
  }
  if (body === null) { res.statusCode = 404; res.end('{"code":404,"message":"not recorded"}'); return; }
  res.setHeader('content-type', 'application/octet-stream');
  res.setHeader('eth-consensus-version', fork);
  res.end(body);
}).listen(port, '127.0.0.1');
