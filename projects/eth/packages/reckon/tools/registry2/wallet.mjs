// The writing side of contracts/Registry.sol (v2), with an ordinary Ethereum wallet (ethers): reckon only reads, by
// proof. Keys come from files; CIDs are given as text (bafy…, bafk…) and sent as their 36 binary bytes.
//
//   node wallet.mjs address       KEYFILE
//   node wallet.mjs deploy        KEYFILE                          → ADDRESS CODEHASH
//   node wallet.mjs fund          KEYFILE ADDRESS ETHER
//   node wallet.mjs revoke        KEYFILE REGISTRY CID
//   node wallet.mjs revoke-signed SIGNERKEY RELAYERKEY REGISTRY CID   EIP-712 Revocation signed by SIGNER, sent by RELAYER
//   node wallet.mjs reject        KEYFILE REGISTRY CID REASON        (REASON is hashed)
//   node wallet.mjs reject-signed SIGNERKEY RELAYERKEY REGISTRY CID REASON   EIP-712 Rejection, relayed
//   node wallet.mjs unreject-signed SIGNERKEY RELAYERKEY REGISTRY CID REASON a signed Revocation of that Rejection
//   node wallet.mjs rejection-id  KEYFILE REGISTRY CID REASON        the Rejection's id, by @ipld/dag-cbor and by the
//                                                                    contract's rejectionId (eth_call): "JS CONTRACT"
//   node wallet.mjs unreject      KEYFILE REGISTRY CID
//   node wallet.mjs claim         KEYFILE REGISTRY NAME CID DELAY
//   node wallet.mjs propose       KEYFILE REGISTRY NAME CID
//   node wallet.mjs propose-delay KEYFILE REGISTRY NAME DELAY
//   node wallet.mjs cancel        KEYFILE REGISTRY NAME
//   node wallet.mjs storage       KEYFILE REGISTRY SLOT             eth_getStorageAt, the oracle for the slot math
// RPC is $RPC, default http://127.0.0.1:8545. A refused transaction exits 1 with the contract's reason.
import { Wallet, JsonRpcProvider, ContractFactory, Contract, keccak256, toUtf8Bytes, parseEther, Signature } from '../oracle/node_modules/ethers/lib.esm/index.js';
import { CID } from '../oracle/node_modules/multiformats/dist/src/cid.js';
import { sha256 } from '../oracle/node_modules/multiformats/dist/src/hashes/sha2.js';
import * as dagCbor from '../oracle/node_modules/@ipld/dag-cbor/src/index.js';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const abi = [
  'function revoke(bytes)', 'function revokeSigned(bytes,uint8,bytes32,bytes32)', 'function reject(bytes,bytes32)',
  'function unreject(bytes)', 'function claim(string,bytes,uint256)', 'function propose(string,bytes)',
  'function proposeDelay(string,uint256)', 'function cancel(string)',
  'function rejectSigned(bytes,string,uint8,bytes32,bytes32)', 'function unrejectSigned(bytes,string,uint8,bytes32,bytes32)',
  'function rejectionId(bytes,string) view returns (bytes)',
];
// claims.wac's typed data: domain { name "reckon", version "2" }.
const domain = { name: 'reckon', version: '2' };
// claims.wac's Rejection statement's id, from @ipld/dag-cbor: not from wac, and not from the contract.
const rejectionId = async (subject, reason) =>
  CID.create(1, 0x71, await sha256.digest(dagCbor.encode({ kind: 'rejection', subject: CID.parse(subject), reason }))).bytes;
const provider = new JsonRpcProvider(process.env.RPC || 'http://127.0.0.1:8545', undefined, { staticNetwork: true, polling: true, pollingInterval: 500 });
const wallet = (f) => new Wallet('0x' + fs.readFileSync(f, 'utf8').trim().replace(/^0x/, ''), provider);
const cid = (text) => CID.parse(text).bytes;
const done = async (send) => {
  try {
    const r = await (await send()).wait();
    console.log(`${r.status === 1 ? 'ok' : 'FAILED'} block ${r.blockNumber} tx ${r.hash}`);
    if (r.status !== 1) process.exit(1);
  } catch (e) { console.log('refused: ' + (e.reason || e.shortMessage || e.message)); process.exit(1); }
};
const call = (c, fn, ...args) => done(() => c[fn](...args));
const [cmd, keyfile, ...rest] = process.argv.slice(2);
const w = wallet(keyfile);
if (cmd === 'address') console.log(w.address.toLowerCase());
else if (cmd === 'deploy') {
  const bin = fs.readFileSync(path.join(here, '../../contracts/Registry.bin'), 'utf8').trim();
  const c = await new ContractFactory(abi, bin, w).deploy();
  await c.waitForDeployment();
  const addr = (await c.getAddress()).toLowerCase();
  console.log(addr, keccak256(await provider.getCode(addr)));
} else if (cmd === 'fund') await done(() => w.sendTransaction({ to: rest[0], value: parseEther(rest[1]) }));
else if (cmd === 'storage') console.log(await provider.getStorage(rest[0], rest[1]));
else if (cmd === 'reject-signed' || cmd === 'unreject-signed') {
  const [relayer, registry, subject, reason] = rest;
  const sig = Signature.from(cmd === 'reject-signed'
    ? await w.signTypedData(domain, { Rejection: [{ name: 'subject', type: 'bytes' }, { name: 'reason', type: 'string' }] }, { subject: cid(subject), reason })
    : await w.signTypedData(domain, { Revocation: [{ name: 'statement', type: 'bytes' }] }, { statement: await rejectionId(subject, reason) }));
  const c = new Contract(registry, abi, wallet(relayer));
  await call(c, cmd === 'reject-signed' ? 'rejectSigned' : 'unrejectSigned', cid(subject), reason, sig.v, sig.r, sig.s);
} else if (cmd === 'rejection-id') {
  const [registry, subject, reason] = rest;
  const js = CID.decode(await rejectionId(subject, reason)).toString();
  const onchain = CID.decode(Buffer.from((await new Contract(registry, abi, provider).rejectionId(cid(subject), reason)).slice(2), 'hex')).toString();
  console.log(js, onchain);
} else if (cmd === 'revoke-signed') {
  // claims.wac's typed data: domain { name "reckon", version "2" }, Revocation(bytes statement).
  const sig = Signature.from(await w.signTypedData({ name: 'reckon', version: '2' }, { Revocation: [{ name: 'statement', type: 'bytes' }] },
                                                   { statement: cid(rest[2]) }));
  const c = new Contract(rest[1], abi, wallet(rest[0]));
  await call(c, 'revokeSigned', cid(rest[2]), sig.v, sig.r, sig.s);
} else {
  const c = new Contract(rest[0], abi, w);
  if (cmd === 'revoke') await call(c, 'revoke', cid(rest[1]));
  else if (cmd === 'reject') await call(c, 'reject', cid(rest[1]), keccak256(toUtf8Bytes(rest[2] || '')));
  else if (cmd === 'unreject') await call(c, 'unreject', cid(rest[1]));
  else if (cmd === 'claim') await call(c, 'claim', rest[1], cid(rest[2]), BigInt(rest[3]));
  else if (cmd === 'propose') await call(c, 'propose', rest[1], cid(rest[2]));
  else if (cmd === 'propose-delay') await call(c, 'proposeDelay', rest[1], BigInt(rest[2]));
  else if (cmd === 'cancel') await call(c, 'cancel', rest[1]);
  else { console.error('unknown command ' + cmd); process.exit(2); }
}
