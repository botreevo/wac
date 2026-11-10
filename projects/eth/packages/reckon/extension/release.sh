#!/bin/sh
# A release of the extension, for the reckon pages site (site/downloads/): the unpacked extension named by its CID,
# packed as a zip, with the claims that tie its one compiled part to its source.
#
#     WAC_SRC=/path/to/wac WASMTIME_WAC=/path/to/native/wac sh packages/reckon/extension/release.sh WORKDIR
#
# 1. The admission module is derived: cmd/web.wac compiled by wac's compiler inside the sealed machine, on V8 and on
#    wasmtime, from wac-eth at HEAD and the dependencies wac.lock pins by CID (tools/builddeps.sh), each runner
#    signing what it got. The runners' keys are made fresh for the release in WORKDIR/keys and are not published.
# 2. The extension is built (build.sh): wac's --target browser --layout files over the same source. Its app.wasm must
#    be the derived module with its `wac.manifest` custom section left off, which is all the browser build changes,
#    byte for byte, or there is no release. The JavaScript the browser build writes (launcher.js, worker.js) is
#    bundled by deno outside any machine; the random temporary directory it names is replaced by a fixed one, which
#    is the only difference between two builds (a wac issue, reported).
# 3. The unpacked extension is imported under the unixfs-v1-2025 profile: its CID is the release's name, and unzipping
#    the zip and importing the directory gives the same CID. The zip is packed in a fixed order with fixed times.
# 4. site/downloads/ gets the zip, a JSON manifest (the CIDs, the derivation, the runners' addresses, the commits)
#    and claims/, a claims mirror holding the signed derivations and the recipe.
#
# Needs a clean tree (builddeps builds from HEAD), deno, python3, zip.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
reckon=$(cd "$here/.." && pwd)
root=$(cd "$reckon/../.." && pwd)
work=${1:?WORKDIR}; mkdir -p "$work"; work=$(cd "$work" && pwd)
: "${WAC_SRC:?set WAC_SRC to a wac checkout at the pinned commit}"
: "${WASMTIME_WAC:?set WASMTIME_WAC to the wac of the native host}"
downloads=$reckon/site/downloads

[ -z "$(git -C "$root" status --porcelain)" ] || { echo "release: commit first: the release is built from HEAD" >&2; exit 2; }
commit=$(git -C "$root" rev-parse HEAD)

# 1. The derived module, signed by two runners with keys made for this release.
mkdir -p "$work/keys"
[ -f "$work/keys/v8.key" ] || { openssl rand -hex 32 > "$work/keys/v8.key"; openssl rand -hex 32 > "$work/keys/wt.key"; }
RUNNER_KEYS="$work/keys" sh "$reckon/tools/builddeps.sh" "$work/derive" packages/reckon/cmd/web.wac:read,write,net,env > "$work/derive.log" 2>&1 \
  || { tail -5 "$work/derive.log"; echo "release: the derivation failed" >&2; exit 1; }
derived=$(sed -n 's/^ok    web: V8 and wasmtime derive the same output (\([a-z0-9]*\)).*/\1/p' "$work/derive.log")
[ -n "$derived" ] || { cat "$work/derive.log"; echo "release: no agreed output" >&2; exit 1; }
cd "$root"
wac build --quiet --allow-read --allow-write --allow-net --allow-env packages/reckon/cmd/claim.wac -o "$work/claim"
wac build --quiet --allow-read --allow-write --allow-net packages/ipfs/cmd/obj.wac -o "$work/obj"
CL="wac $work/claim.wasm"; O="wac $work/obj.wasm"; st="--store $work/derive/store"
$O cat "$derived" out/web.wasm $st > "$work/web.derived.wasm"

# 2. The extension, and its app.wasm held to the derived module.
sh "$here/build.sh" > "$work/build.log" 2>&1 || { tail -5 "$work/build.log"; exit 1; }
for f in launcher.js worker.js; do sed -i 's|wac-app-[0-9a-f]\{16\}|wac-app|g' "$here/src/admit/$f"; done
python3 - "$work/web.derived.wasm" "$here/src/admit/app.wasm" <<'PY'
import sys
def strip_manifest(b):
    out, i = bytearray(b[:8]), 8
    while i < len(b):
        start, sid, i = i, b[i], i + 1
        n = sh = 0
        while True:
            x = b[i]; i += 1; n |= (x & 0x7f) << sh; sh += 7
            if x < 0x80: break
        body = b[i:i + n]; i += n
        if sid == 0:
            l = sh = j = 0
            while True:
                x = body[j]; j += 1; l |= (x & 0x7f) << sh; sh += 7
                if x < 0x80: break
            if body[j:j + l] == b"wac.manifest": continue
        out += b[start:i]
    return bytes(out)
derived, shipped = open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read()
if strip_manifest(derived) != shipped: sys.exit("release: app.wasm is not the derived module less its manifest")
print("release: app.wasm is the derived module, less its wac.manifest section")
PY

# 3. The unpacked extension, named by its CID, and the zip.
rm -rf "$work/extension" && mkdir -p "$work/extension" && cp -R "$here/src/." "$work/extension/"
find "$work/extension" -exec touch -h -d '2026-01-01T00:00:00Z' {} +
ext=$($O add "$work/extension" --store "$work/release")
appcid=$($O add "$work/extension/admit" --store "$work/release" >/dev/null; python3 -c "import sys,hashlib,base64; d=hashlib.sha256(open(sys.argv[1],'rb').read()).digest(); print('b'+base64.b32encode(bytes([1,0x55,0x12,0x20])+d).decode().lower().rstrip('='))" "$work/extension/admit/app.wasm")
mkdir -p "$downloads"
zip=reckon-extension-$ext.zip
rm -f "$downloads"/reckon-extension-*.zip "$downloads"/reckon-extension-*.json
(cd "$work/extension" && find . -type f | LC_ALL=C sort | sed 's|^\./||' | zip -qX -D "$downloads/$zip" -@)
mkdir -p "$work/unzipped" && rm -rf "$work/unzipped"/* && (cd "$work/unzipped" && unzip -q "$downloads/$zip")
[ "$($O add "$work/unzipped" --store "$work/check")" = "$ext" ] || { echo "release: the zip does not unpack to $ext" >&2; exit 1; }

# 4. The claims and the manifest.
rm -rf "$downloads/claims" && $CL publish "$downloads/claims" $st > /dev/null
origins=$($CL origins "$derived" $st)
recipe=$(printf '%s\n' "$origins" | sed -n '1s/^recipe \([a-z0-9]*\) .*/\1/p')
python3 - "$downloads/reckon-extension-$ext.json" <<PY
import json, sys
origins = """$origins""".strip().splitlines()
json.dump({
  "name": "reckon extension (Manifest V3)",
  "extension": "$ext",
  "zip": "$zip",
  "zip_sha256": __import__("hashlib").sha256(open("$downloads/$zip", "rb").read()).hexdigest(),
  "admission_module": {"path": "admit/app.wasm", "cid": "$appcid",
                       "is": "the derived module below, less its wac.manifest custom section"},
  "derivation": {"output": "$derived", "file": "out/web.wasm", "recipe": "$recipe",
                 "witnessed": [o.split(" by ")[1] for o in origins],
                 "claims": "claims/ beside this file: a claims mirror (claim admit --mirror)"},
  "source": {"wac-eth": "$commit", "entry": "packages/reckon/cmd/web.wac",
             "grants": ["read", "write", "net", "env"], "wac.lock": open("$root/wac.lock").read()},
  "not_derived": "launcher.js and worker.js (wac's browser glue, bundled by deno) and the extension's own JavaScript (page, loader, build-doc, tree, admission), which are source in git at the commit above",
}, open(sys.argv[1], "w"), indent=2)
PY
echo "release: $zip ($(wc -c < "$downloads/$zip") bytes), its manifest and claims in $downloads"
echo "release: the extension is $ext; its admission module $appcid is the derived $derived less its manifest"
