// The writing side, with an ordinary Ethereum wallet (ethers), because that is what a publisher, a signer or a
// deny-list keeper would use: reckon only reads and verifies. Every command takes the key from a file.
//
//   node wallet.mjs deploy  KEYFILE                       → prints the registry's address
//   node wallet.mjs fund    KEYFILE ADDRESS ETHER
//   node wallet.mjs revoke  KEYFILE REGISTRY STATEMENT_ID
//   node wallet.mjs deny    KEYFILE REGISTRY HASH on|off   (HASH is kt1:/kb1:)
//   node wallet.mjs claim   KEYFILE REGISTRY NAME HASH DELAY_SECONDS
//   node wallet.mjs propose KEYFILE REGISTRY NAME HASH
//   node wallet.mjs address KEYFILE
// RPC is $RPC, default http://127.0.0.1:8545.
import { Wallet, JsonRpcProvider, ContractFactory, Contract, keccak256, toUtf8Bytes, parseEther } from '../../../tools/oracle/node_modules/ethers/lib.esm/index.js';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const abi = [
  'function revoke(bytes32)', 'function deny(bytes32,bool)', 'function claim(bytes32,bytes32,uint256)',
  'function propose(bytes32,bytes32)', 'function cancel(bytes32)',
];
const [cmd, keyfile, ...rest] = process.argv.slice(2);
const provider = new JsonRpcProvider(process.env.RPC || 'http://127.0.0.1:8545', undefined, { staticNetwork: true, polling: true, pollingInterval: 500 });
const key = '0x' + fs.readFileSync(keyfile, 'utf8').trim().replace(/^0x/, '');
const w = new Wallet(key, provider);
const b32 = (id) => '0x' + id.replace(/^k[tb]1:/, '').replace(/^0x/, '');
const done = async (tx) => { const r = await tx.wait(); console.log(`${r.status === 1 ? 'ok' : 'FAILED'} block ${r.blockNumber} tx ${r.hash}`); };
if (cmd === 'address') console.log(w.address.toLowerCase());
else if (cmd === 'deploy') {
  const bin = fs.readFileSync(path.join(here, '../../contracts/TrustRegistry.bin'), 'utf8').trim();
  const c = await new ContractFactory(abi, bin, w).deploy();
  await c.waitForDeployment();
  const addr = (await c.getAddress()).toLowerCase();
  const code = await provider.getCode(addr);
  console.log(addr, keccak256(code));
} else if (cmd === 'fund') await done(await w.sendTransaction({ to: rest[0], value: parseEther(rest[1]) }));
else {
  const c = new Contract(rest[0], abi, w);
  if (cmd === 'revoke') await done(await c.revoke(b32(rest[1])));
  else if (cmd === 'deny') await done(await c.deny(b32(rest[1]), rest[2] !== 'off'));
  else if (cmd === 'claim') await done(await c.claim(keccak256(toUtf8Bytes(rest[1])), b32(rest[2]), BigInt(rest[3])));
  else if (cmd === 'propose') await done(await c.propose(keccak256(toUtf8Bytes(rest[1])), b32(rest[2])));
  else if (cmd === 'cancel') await done(await c.cancel(keccak256(toUtf8Bytes(rest[1]))));
  else { console.error('unknown command ' + cmd); process.exit(2); }
}
