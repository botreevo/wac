"""samepage.py SEALED NATIVE PREFIX: two wac-web pages (index.html) are the same page but for where the compiler
was run. wac records the entry it was given in the module's `wac.manifest` section, and a sealed compile is given
its entry below the machine's input (PREFIX, e.g. `in/in/in/`), so that one field cannot match a native build. So:
the HTML outside the embedded module is the same bytes; the modules are the same bytes in every section but
`wac.manifest`; and the two manifests are the same JSON once the sealed one's entry has PREFIX taken off.
Prints what differs, and exits 1 if anything does."""
import base64, json, re, sys

def sections(wasm):
    assert wasm[:8] == b'\0asm\x01\0\0\0', 'not a wasm module'
    i, out = 8, []
    while i < len(wasm):
        sid = wasm[i]; i += 1
        n = shift = 0
        while True:
            b = wasm[i]; i += 1; n |= (b & 0x7f) << shift; shift += 7
            if b < 0x80: break
        body = wasm[i:i + n]; i += n
        name = None
        if sid == 0:
            ln = shift = j = 0
            while True:
                b = body[j]; j += 1; ln |= (b & 0x7f) << shift; shift += 7
                if b < 0x80: break
            name = body[j:j + ln].decode(); body = body[j + ln:]
        out.append((sid, name, body))
    return out

def split(html):
    m = max(re.finditer(r'[A-Za-z0-9+/]{4096,}={0,2}', html), key=lambda m: len(m.group(0)))
    return html[:m.start()], base64.b64decode(m.group(0)), html[m.end():]

sealed, native, prefix = open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3]
(sa, sw, sz), (na, nw, nz) = split(sealed), split(native)
problems = []
if (sa, sz) != (na, nz): problems.append('the HTML around the module differs')
ss, ns = sections(sw), sections(nw)
if [(s, n) for s, n, _ in ss] != [(s, n) for s, n, _ in ns]: problems.append('the modules have different sections')
for (sid, name, sb), (_, _, nb) in zip(ss, ns):
    if name == 'wac.manifest':
        sm, nm = json.loads(sb), json.loads(nb)
        if not sm.get('entry', '').startswith(prefix): problems.append(f'the sealed entry {sm.get("entry")!r} is not below {prefix!r}')
        sm['entry'] = sm.get('entry', '')[len(prefix):]
        if sm != nm: problems.append('the manifests differ beyond the entry')
    elif sb != nb:
        problems.append(f'section {name or sid} differs')
for p in problems: print(p)
sys.exit(1 if problems else 0)
