const solc = require('../oracle/node_modules/solc'); const fs = require('fs');
const [src, out] = process.argv.slice(2);
const input = { language: 'Solidity', sources: { 'TrustRegistry.sol': { content: fs.readFileSync(src, 'utf8') } },
  settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: 'cancun', outputSelection: { '*': { '*': ['evm.bytecode.object', 'abi', 'storageLayout'] } } } };
const o = JSON.parse(solc.compile(JSON.stringify(input)));
if (o.errors) for (const e of o.errors) console.error(e.formattedMessage);
const c = o.contracts['TrustRegistry.sol'].TrustRegistry;
console.log(JSON.stringify(c.storageLayout.storage.map(s => [s.label, s.slot])));
fs.writeFileSync(out, c.evm.bytecode.object + '\n');
console.log('solc', solc.version(), 'bytes', c.evm.bytecode.object.length / 2);
