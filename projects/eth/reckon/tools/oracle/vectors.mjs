// The tree vectors in test/tree_test.wac, from the JavaScript oracle rather than from the code under test.
import sha3 from 'js-sha3';
const k = (b) => Buffer.from(sha3.keccak256.arrayBuffer(b));
const leaf = (c) => k(Buffer.concat([Buffer.from([0]), Buffer.from(c)]));
const node = (ents) => {
  ents = [...ents].sort((a, b) => Buffer.compare(Buffer.from(a[0]), Buffer.from(b[0])));
  const parts = [Buffer.from([1])];
  for (const [n, kind, h] of ents) { const nb = Buffer.from(n); parts.push(Buffer.from([nb.length >> 8, nb.length & 255]), nb, Buffer.from([kind]), h); }
  return k(Buffer.concat(parts));
};
const hex = (b) => b.toString('hex');
console.log('leaf("")      ', hex(leaf('')));
console.log('node([])      ', hex(node([])));
console.log('{a.txt}       ', hex(node([['a.txt', 0, leaf('hello\n')]])));
console.log('{bin,src}     ', hex(node([['bin', 2, node([['run', 1, leaf('#!/bin/sh\n')]])], ['src', 2, node([['lib.wac', 0, leaf('x')]])]])));
