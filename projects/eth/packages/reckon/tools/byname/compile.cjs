// contracts/DevENS.sol → contracts/DevENSRegistry.bin, contracts/DevResolver.bin (creation code), after checking that
// solc laid their storage out as mainnet's registry and public resolver are: what packages/ens reads by proof.
//
//     node tools/byname/compile.cjs        (solc 0.8.28 from tools/oracle's packages)
const solc = require('../oracle/node_modules/solc'); const fs = require('fs'); const path = require('path');
const dir = path.join(__dirname, '../../contracts');
const input = { language: 'Solidity', sources: { 'DevENS.sol': { content: fs.readFileSync(path.join(dir, 'DevENS.sol'), 'utf8') } },
  settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: 'cancun',
              outputSelection: { '*': { '*': ['evm.bytecode.object', 'storageLayout'] } } } };
const o = JSON.parse(solc.compile(JSON.stringify(input)));
let bad = false;
for (const e of o.errors || []) { console.error(e.formattedMessage); if (e.severity === 'error') bad = true; }
if (bad) process.exit(1);
const want = {
  DevENSRegistry: { records: 0 },
  DevResolver: { recordVersions: 0, versionable_hashes: 3 },
};
for (const [name, slots] of Object.entries(want)) {
  const c = o.contracts['DevENS.sol'][name];
  for (const [label, slot] of Object.entries(slots)) {
    const s = c.storageLayout.storage.find((x) => x.label === label);
    if (!s || Number(s.slot) !== slot) { console.error(`${name}.${label} is at slot ${s?.slot}, not ${slot} as on mainnet`); process.exit(1); }
  }
  // The registry's record: owner at the base, resolver (and ttl, packed) in the next slot.
  if (name === 'DevENSRegistry') {
    const rec = Object.values(c.storageLayout.types).find((t) => t.label === 'struct DevENSRegistry.Record');
    const at = Object.fromEntries(rec.members.map((m) => [m.label, [Number(m.slot), m.offset]]));
    if (at.owner[0] !== 0 || at.resolver[0] !== 1 || at.resolver[1] !== 0) { console.error('Record is not owner, then resolver'); process.exit(1); }
  }
  fs.writeFileSync(path.join(dir, name + '.bin'), c.evm.bytecode.object + '\n');
  console.log(name, c.evm.bytecode.object.length / 2, 'bytes;', JSON.stringify(c.storageLayout.storage.map((s) => [s.label, Number(s.slot)])));
}
