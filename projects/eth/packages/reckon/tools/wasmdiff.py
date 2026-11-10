#!/usr/bin/env python3
# Two wac-built modules, compared as the same program: every section equal, and the `wac.manifest` custom
# section equal apart from `entry`, the path the build was given (which differs between a build in the machine,
# at /in/…, and one on a host). Prints "same" or "differ".
#     python3 tools/wasmdiff.py A.wasm B.wasm
import sys, json
def sections(b):
    i = 8; out = []
    while i < len(b):
        sid = b[i]; i += 1
        n = 0; s = 0
        while True:
            x = b[i]; i += 1; n |= (x & 0x7f) << s; s += 7
            if not x & 0x80: break
        out.append((sid, b[i:i+n])); i += n
    return out
def name(c):
    n = 0; s = 0; i = 0
    while True:
        x = c[i]; i += 1; n |= (x & 0x7f) << s; s += 7
        if not x & 0x80: break
    return c[i:i+n].decode(), c[i+n:]
def split(path):
    b = open(path, 'rb').read(); rest = []; manifest = None
    for sid, c in sections(b):
        if sid == 0 and name(c)[0] == 'wac.manifest': manifest = json.loads(name(c)[1])
        else: rest.append((sid, c))
    return rest, manifest
a, ma = split(sys.argv[1]); b, mb = split(sys.argv[2])
for m in (ma, mb): m.pop('entry', None)
print('same' if a == b and ma == mb else 'differ')
