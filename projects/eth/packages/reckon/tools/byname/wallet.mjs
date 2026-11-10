// The writing side of contracts/DevENS.sol, with ethers: names are hashed by ethers' namehash, and a contenthash is
// EIP-1577's (0xe3 0x01, then the CID's bytes), so nothing written here comes from the wac code that reads it back.
//
//   node wallet.mjs deploy          KEYFILE                       → REGISTRY REGISTRY_CODE RESOLVER RESOLVER_CODE
//   node wallet.mjs claim           KEYFILE REGISTRY NAME RESOLVER
//   node wallet.mjs set-contenthash KEYFILE RESOLVER NAME CID
//   node wallet.mjs clear           KEYFILE RESOLVER NAME          clearRecords: the next record version
//   node wallet.mjs fund            KEYFILE ADDRESS ETHER
//   node wallet.mjs address         KEYFILE
// RPC is $RPC, default http://127.0.0.1:8545.
import { Wallet, JsonRpcProvider, ContractFactory, Contract, keccak256, namehash, parseEther, concat } from '../oracle/node_modules/ethers/lib.esm/index.js';
import { CID } from '../oracle/node_modules/multiformats/dist/src/cid.js';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const registryAbi = ['constructor()', 'function claim(bytes32,address)'];
const resolverAbi = ['constructor(address)', 'function setContenthash(bytes32,bytes)', 'function clearRecords(bytes32)'];
const provider = new JsonRpcProvider(process.env.RPC || 'http://127.0.0.1:8545', undefined, { staticNetwork: true, polling: true, pollingInterval: 500 });
const wallet = (f) => new Wallet('0x' + fs.readFileSync(f, 'utf8').trim().replace(/^0x/, ''), provider);
const bin = (name) => fs.readFileSync(path.join(here, '../../contracts/' + name + '.bin'), 'utf8').trim();
const done = async (send) => {
  try {
    const r = await (await send()).wait();
    console.log(`${r.status === 1 ? 'ok' : 'FAILED'} block ${r.blockNumber} tx ${r.hash}`);
    if (r.status !== 1) process.exit(1);
  } catch (e) { console.log('refused: ' + (e.reason || e.shortMessage || e.message)); process.exit(1); }
};
const [cmd, keyfile, ...rest] = process.argv.slice(2);
const w = wallet(keyfile);
if (cmd === 'address') console.log(w.address.toLowerCase());
else if (cmd === 'fund') await done(() => w.sendTransaction({ to: rest[0], value: parseEther(rest[1]) }));
else if (cmd === 'deploy') {
  const reg = await new ContractFactory(registryAbi, bin('DevENSRegistry'), w).deploy();
  await reg.waitForDeployment();
  const regAddr = (await reg.getAddress()).toLowerCase();
  const res = await new ContractFactory(resolverAbi, bin('DevResolver'), w).deploy(regAddr);
  await res.waitForDeployment();
  const resAddr = (await res.getAddress()).toLowerCase();
  console.log(regAddr, keccak256(await provider.getCode(regAddr)), resAddr, keccak256(await provider.getCode(resAddr)));
} else if (cmd === 'claim') {
  const [registry, name, resolver] = rest;
  await done(() => new Contract(registry, registryAbi, w).claim(namehash(name), resolver));
} else if (cmd === 'set-contenthash') {
  const [resolver, name, cid] = rest;
  await done(() => new Contract(resolver, resolverAbi, w).setContenthash(namehash(name), concat(['0xe301', CID.parse(cid).bytes])));
} else if (cmd === 'clear') {
  const [resolver, name] = rest;
  await done(() => new Contract(resolver, resolverAbi, w).clearRecords(namehash(name)));
} else { console.error('unknown command ' + cmd); process.exit(2); }
