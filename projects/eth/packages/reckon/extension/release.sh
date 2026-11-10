#!/bin/sh
# A release of the extension, for the reckon pages site (site/downloads/): the extension a person loads is itself a
# derived output, admitted by a policy shipped beside it (docs/browser-extension.md, milestones 5 and 6).
#
#     WAC_SRC=/path/to/wac WASMTIME_WAC=/path/to/native/wac sh packages/reckon/extension/release.sh WORKDIR
#
# 1. Two builds, inside the sealed machine on V8 and on wasmtime, each runner signing (tools/builddeps.sh, from
#    wac-eth at HEAD and the dependencies wac.lock pins by CID): cmd/web.wac, the admission module, and
#    cmd/assemble.wac, the program that puts the extension together.
# 2. The browser glue (wac's --target browser --layout files, by deno, outside any machine): index.html, launcher.js,
#    worker.js. It is built twice, independently, and the two must be the same bytes (wac 0454e made them so).
# 3. The assembly, a derivation on both runners: assemble.wasm over three slots, `pages` (the extension's own files),
#    `glue`, and `module` (web.wac's derived output). Its output's out/ is the extension: the pages, the glue under
#    admit/, and admit/app.wasm, the derived module less its `wac.manifest` section. It must be the extension
#    build.sh makes natively, file for file, or there is no release.
# 4. A reviewer's endorsements of what was reviewed rather than derived: the build's source and arguments, the pages,
#    the glue. The runners' and the reviewer's keys are made for the release, in WORKDIR/keys, and not published.
# 5. site/downloads/: the zip (the extension, named by its CID), policy.json5, a manifest, and claims/, a claims
#    mirror with every statement and recipe and the few tree nodes admission walks. Then the release is checked as
#    a person would check it: `claim admit EXTENSION extension --policy policy.json5 --mirror claims/`, from an empty
#    store, must say ADMITTED.
#
# Needs a clean tree (the builds are from HEAD), deno, python3, zip, openssl.
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
mkdir -p "$work/keys"
for k in v8 wt reviewer; do [ -f "$work/keys/$k.key" ] || openssl rand -hex 32 > "$work/keys/$k.key"; done

# 1. The two builds.
rm -rf "$work/builds"
RUNNER_KEYS="$work/keys" sh "$reckon/tools/builddeps.sh" "$work/builds" \
  packages/reckon/cmd/web.wac:read,write,net,env packages/reckon/cmd/assemble.wac:read,write > "$work/builds.log" 2>&1 \
  || { tail -8 "$work/builds.log"; echo "release: the builds failed" >&2; exit 1; }
out() { sed -n "s/^ok    $1: V8 and wasmtime derive the same output (\([a-z0-9]*\)).*/\1/p" "$work/builds.log"; }
webOut=$(out web); asmOut=$(out assemble)
[ -n "$webOut" ] && [ -n "$asmOut" ] || { cat "$work/builds.log"; echo "release: no agreed builds" >&2; exit 1; }
B="$work/builds"; st="--store $B/store"
cd "$B"
D="wac $B/derive.wasm"; O="wac $B/obj.wasm"
cd "$root"
wac build --quiet --allow-read --allow-write --allow-net --allow-env packages/reckon/cmd/claim.wac -o "$work/claim"
CL="wac $work/claim.wasm"

# 2. The glue, and the extension as build.sh makes it natively.
sh "$here/build.sh" > "$work/build.log" 2>&1 || { tail -5 "$work/build.log"; exit 1; }
rm -rf "$work/glue-first" && cp -R "$here/src/admit" "$work/glue-first"
sh "$here/build.sh" > "$work/build2.log" 2>&1 || { tail -5 "$work/build2.log"; exit 1; }
diff -r "$work/glue-first" "$here/src/admit" > /dev/null || { diff -r "$work/glue-first" "$here/src/admit" | head; echo "release: two builds of the browser glue differ" >&2; exit 1; }
echo "release: the browser glue, built twice, is the same bytes"

# 3. The assembly, on both runners.
cd "$work"
rm -rf pages glue module native && mkdir -p pages glue module/out native
cp -R "$here/src/." pages/ && rm -rf pages/admit
for f in index.html launcher.js worker.js; do cp "$here/src/admit/$f" glue/; done
$O cat "$webOut" status $st > module/status; $O cat "$webOut" log $st > module/log
$O cat "$webOut" out/web.wasm $st > module/out/web.wasm
[ "$($O add module --store "$work/scratch")" = "$webOut" ] || { echo "release: the module slot is not the derived output" >&2; exit 1; }
$O cat "$asmOut" out/assemble.wasm $st > assemble.wasm
recipe=$($D recipe --program assemble.wasm --slot pages pages --slot glue glue --slot module module $st 2>/dev/null)
a1=$($D run "$recipe" $st --key "$work/keys/v8.key" --runner "reckon-derive/2 v8" 2>/dev/null | sed -n 1p)
a2=$($WASMTIME_WAC "$B/derive.wasm" run "$recipe" $st --key "$work/keys/wt.key" --runner "reckon-derive/2 wasmtime" 2>/dev/null | sed -n 1p)
[ -n "$a1" ] && [ "$a1" = "$a2" ] || { echo "release: the assembly: V8 $a1, wasmtime $a2" >&2; exit 1; }
[ "$($O cat "$a1" status $st)" = "exit 0" ] || { echo "release: the assembly: $($O cat "$a1" log $st)" >&2; exit 1; }
rm -rf extension && mkdir extension
$O ls "$a1" $st | while IFS="$(printf '\t')" read -r path size; do
  case $path in out/*) p=${path#out/}; mkdir -p "extension/$(dirname "$p")"; $O cat "$a1" "$path" $st > "extension/$p" ;; esac
done
cp -R "$here/src/." native/
diff -r extension native > /dev/null || { diff -r extension native | head; echo "release: the assembled extension is not the one build.sh made" >&2; exit 1; }
ext=$($O add extension $st)
echo "release: the extension $ext is out/ of the assembly $a1, which V8 and wasmtime agree on; it is the native build, file for file"

# 4. The reviewer's endorsements, and the policy.
slot() { $CL slots "$1" $st | sed -n "s/^$2 //p"; }
webRecipe=$($CL origins "$webOut" $st | sed -n '1s/^recipe \([a-z0-9]*\) .*/\1/p')
asmRecipe=$($CL origins "$asmOut" $st | sed -n '1s/^recipe \([a-z0-9]*\) .*/\1/p')
compiler=$(slot "$webRecipe" program)
for c in "$(slot "$webRecipe" in)" "$(slot "$webRecipe" args)" "$(slot "$asmRecipe" args)" "$(slot "$recipe" pages)" "$(slot "$recipe" glue)"; do
  $CL endorse "$c" "reviewed for the release at $commit" --key "$work/keys/reviewer.key" $st > /dev/null 2>&1
done
mkdir -p "$downloads"
rm -rf "$downloads"/reckon-extension-* "$downloads/claims" "$downloads/policy.json5"
cat > "$downloads/policy.json5" <<POLICY
// The policy that admits the reckon extension: claim admit EXTENSION_CID extension --policy policy.json5
// --mirror claims/ (beside this file). The extension a person loads is out/ of an assembly that two runners on two
// engines witnessed; the assembler was built by them from reviewed source by the compiler named as the root; the
// admission module was too; the pages and the browser glue were reviewed.
{
  signers: { v8: "$($CL address --key "$work/keys/v8.key")", wasmtime: "$($CL address --key "$work/keys/wt.key")",
             reviewer: "$($CL address --key "$work/keys/reviewer.key")" },
  roots: ["$compiler"],
  machines: ["wasm-gc/wac-host/3"],
  formats: ["unixfs-v1-2025+hidden"],
  roles: {
    extension: [{ within: { role: "assembly", path: "out" } }],
    assembly: [{ derived: { by: ["v8", "wasmtime"], at_least: 2, runners: 2,
                            slots: { program: "assembler", pages: "reviewed", glue: "reviewed", module: "build" } } }],
    assembler: [{ within: { role: "build", path: "out/assemble.wasm" } }],
    build: [{ derived: { by: ["v8", "wasmtime"], at_least: 2, runners: 2,
                         slots: { program: "compiler", in: "reviewed", args: "reviewed" } } }],
    compiler: ["root"],
    reviewed: [{ endorsed: { by: ["reviewer"], at_least: 1 } }],
  },
}
POLICY

# 5. The claims, the zip, the manifest; then admission as a person would run it.
$CL publish "$downloads/claims" $st > /dev/null
# The tree nodes admission walks: each recipe's input root (its slots) and each output's root and out/ (within).
nodes=$(python3 - "$B/store" "$recipe" "$webRecipe" "$asmRecipe" "$a1" "$webOut" "$asmOut" <<'PY'
import sys, os, base64
store, recipes, outputs = sys.argv[1], sys.argv[2:5], sys.argv[5:8]
def raw(c): return open(os.path.join(store, "ipfs", c), "rb").read()
def b32(b): return "b" + base64.b32encode(b).decode().lower().rstrip("=")
def links(b):
    # dag-pb: field 2 (links), each with field 1 (hash, a CID's bytes) and field 2 (name)
    i, out = 0, []
    def varint(b, i):
        n = s = 0
        while True:
            x = b[i]; i += 1; n |= (x & 0x7f) << s; s += 7
            if x < 0x80: return n, i
    while i < len(b):
        key, i = varint(b, i); ln, i = varint(b, i); body = b[i:i + ln]; i += ln
        if key >> 3 != 2: continue
        j, h, name = 0, None, None
        while j < len(body):
            k, j = varint(body, j); l, j = varint(body, j); v = body[j:j + l]; j += l
            if k >> 3 == 1: h = v
            if k >> 3 == 2: name = v.decode()
        out.append((name, b32(h)))
    return out
need = set()
for r in recipes:
    # a recipe's DAG-CBOR names its input; the input's root lists the slots
    b = raw(r); k = b.find(b"input")
    j = b.find(b"\xd8\x2a", k); n = b[j + 3]; cid = b32(b[j + 5:j + 4 + n])
    need.add(cid)
for o in outputs:
    need.add(o)
    for name, c in links(raw(o)):
        if name == "out": need.add(c)
print("\n".join(sorted(need)))
PY
)
for c in $nodes; do cp "$B/store/ipfs/$c" "$downloads/claims/ipfs/$c"; done
zip=reckon-extension-$ext.zip
find "$work/extension" -exec touch -h -d '2026-01-01T00:00:00Z' {} +
(cd "$work/extension" && find . -type f | LC_ALL=C sort | sed 's|^\./||' | zip -qX -D "$downloads/$zip" -@)
rm -rf "$work/unzipped" && mkdir -p "$work/unzipped" && (cd "$work/unzipped" && unzip -q "$downloads/$zip")
[ "$($O add "$work/unzipped" --store "$work/check")" = "$ext" ] || { echo "release: the zip does not unpack to $ext" >&2; exit 1; }
rm -rf "$work/fresh"
$CL admit "$ext" extension --policy "$downloads/policy.json5" --store "$work/fresh" --mirror "$downloads/claims" > "$work/admit.log" 2>&1 \
  || { cat "$work/admit.log"; echo "release: the policy does not admit the release from its own claims" >&2; exit 1; }
cat "$work/admit.log"
ORIGINS="$($CL origins "$a1" $st)" python3 - "$downloads/reckon-extension-$ext.json" <<PY
import json, os, sys, hashlib
json.dump({
  "name": "reckon extension (Manifest V3)",
  "extension": "$ext",
  "zip": "$zip",
  "zip_sha256": hashlib.sha256(open("$downloads/$zip", "rb").read()).hexdigest(),
  "check": "claim admit $ext extension --policy policy.json5 --mirror claims/   (from an empty store: ADMITTED)",
  "assembly": {"output": "$a1", "extension_at": "out", "recipe": "$recipe",
               "witnessed": list(dict.fromkeys(os.environ["ORIGINS"].strip().splitlines()))},
  "builds": {"admission_module": "$webOut", "assembler": "$asmOut", "compiler_root": "$compiler"},
  "source": {"wac-eth": "$commit", "wac.lock": open("$root/wac.lock").read()},
  "reviewed_not_derived": "the extension's own pages and scripts, and the browser glue wac's build bundles with deno (launcher.js, worker.js, index.html)",
}, open(sys.argv[1], "w"), indent=2)
PY
echo "release: $zip ($(wc -c < "$downloads/$zip") bytes), policy.json5, its manifest and claims in $downloads"
