// The EIP-712 vectors in test/statement_test.wac, from ethers rather than from the code under test:
// the digest, the address of key 0x11…11, and its signature (RFC 6979, so wac's must be byte-identical).
import { Wallet, TypedDataEncoder } from 'ethers';
const domain = { name: 'wac-trust', version: '1' };
const types = {
  Built: [ { name: 'source', type: 'bytes32' }, { name: 'dir', type: 'string' }, { name: 'command', type: 'string[]' },
           { name: 'path', type: 'string' }, { name: 'toolchain', type: 'bytes32' }, { name: 'output', type: 'bytes32' } ],
};
const rtypes = { Reviewed: [ { name: 'subject', type: 'bytes32' }, { name: 'scope', type: 'string' } ] };
const w = new Wallet('0x' + '11'.repeat(32));
const built = { source: '0x' + 'aa'.repeat(32), dir: 'examples/hello', command: ['wac', 'build', 'hello.wac', '-o', 'dist/hello'],
                path: 'dist/hello.wasm', toolchain: '0x' + 'bb'.repeat(32), output: '0x' + 'cc'.repeat(32) };
const reviewed = { subject: '0x' + 'dd'.repeat(32), scope: 'all of it, "quoted"' };
console.log('address  ', w.address.toLowerCase());
console.log('domain   ', TypedDataEncoder.hashDomain(domain));
console.log('built    ', TypedDataEncoder.hash(domain, types, built));
console.log('builtSig ', await w.signTypedData(domain, types, built));
console.log('rev      ', TypedDataEncoder.hash(domain, rtypes, reviewed));
console.log('revSig   ', await w.signTypedData(domain, rtypes, reviewed));
