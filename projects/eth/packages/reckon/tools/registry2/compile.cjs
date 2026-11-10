// contracts/Registry.sol → contracts/Registry.bin (creation code) and contracts/Registry.layout.json (solc's storage
// layout, which tools/registry2/vectors.mjs turns into the slots src/registry2.wac is tested against).
//
//     node tools/registry2/compile.cjs        (solc 0.8.28 from tools/oracle's packages)
const solc = require('../oracle/node_modules/solc'); const fs = require('fs'); const path = require('path');
const dir = path.join(__dirname, '../../contracts');
const input = { language: 'Solidity', sources: { 'Registry.sol': { content: fs.readFileSync(path.join(dir, 'Registry.sol'), 'utf8') } },
  settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: 'cancun',
              outputSelection: { '*': { '*': ['evm.bytecode.object', 'abi', 'storageLayout'] } } } };
const o = JSON.parse(solc.compile(JSON.stringify(input)));
let bad = false;
for (const e of o.errors || []) { console.error(e.formattedMessage); if (e.severity === 'error') bad = true; }
if (bad) process.exit(1);
const c = o.contracts['Registry.sol'].Registry;
fs.writeFileSync(path.join(dir, 'Registry.bin'), c.evm.bytecode.object + '\n');
// Only what the layout means: each variable's slot and type, and each struct's members with their offsets.
const types = c.storageLayout.types;
const layout = {
  solc: solc.version(),
  storage: c.storageLayout.storage.map((s) => ({ label: s.label, slot: Number(s.slot), offset: s.offset, type: types[s.type].label })),
  structs: Object.fromEntries(Object.values(types).filter((t) => t.members).map((t) => [t.label,
    t.members.map((m) => ({ label: m.label, slot: Number(m.slot), offset: m.offset, type: types[m.type].label }))])),
};
fs.writeFileSync(path.join(dir, 'Registry.layout.json'), JSON.stringify(layout, null, 1) + '\n');
console.log('solc', solc.version(), '→ Registry.bin,', c.evm.bytecode.object.length / 2, 'bytes; layout', JSON.stringify(layout.storage));
