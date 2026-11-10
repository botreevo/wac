#!/bin/sh
# A real wac app, end to end through reckon and the extension: demo/mandelbrot.wac, a wac-web page that draws a
# Mandelbrot set. It is built, derived, reviewed, published, named on chain, admitted by a policy, and run in the
# extension, with nothing reaching the network.
#
#     WASMTIME_WAC=/path/to/native/wac WAC_SRC=/path/to/wac sh packages/reckon/tools/demo-app.sh WORKDIR
#
# 1. wac-web's page builder (the `web` package wac.lock pins) builds the page: demo/dist/page.wac (the wrapper,
#    which must be demo/page/page.wac as committed), page.js and index.html, the module base64 inside.
# 2. Inside the sealed machine, on V8 and on wasmtime, each runner signing (tools/builddeps.sh, from HEAD and the
#    dependencies pinned by CID): the page's module, compiled from demo/page/page.wac; and cmd/embed.wac.
# 3. The embedding, a derivation on both runners: embed.wasm over two slots, `glue` (the builder's index.html with
#    the module left out) and `module` (the derived build). Its out/index.html must be the builder's, byte for byte:
#    so the page a person opens is a derived output.
# 4. A reviewer endorses what was reviewed: the build's source and arguments, and the glue. A policy (WORKDIR/
#    policy.json5) admits the page through the derivations, back to the compiler as the root.
# 5. A wacuum devnet with the registry v2: the page's CID claimed as `mandelbrot` by a publisher. A mirror: the store,
#    served with CORS.
# 6. `claim admit name:mandelbrot@0xPUB app`: admitted, on the command line. Then the extension
#    (extension/test/demo-app.cjs): the name read by proof in the page, the claims from the mirror, the page fetched
#    and checked, then run in the sandbox loader. It draws, a click zooms, and nothing reaches the network.
#    Screenshots go in WORKDIR/shots.
#
# Needs a clean tree, packages/wacuum/dist/wacuum.wasm, tools/oracle's node modules, deno, and Playwright's Chromium.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:?WORKDIR}; rm -rf "$work"; mkdir -p "$work"; work=$(cd "$work" && pwd)
: "${WASMTIME_WAC:?set WASMTIME_WAC to the wac of the native host}"
: "${WAC_SRC:?set WAC_SRC to a wac checkout at the pinned commit (for the extension)}"
port=${PORT:-8930}; proxy=$((port + 1)); mport=$((port + 2))
wacuum=${WACUUM:-$root/packages/wacuum/dist/wacuum.wasm}
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok    $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
pids=""
cleanup() { [ -n "$pids" ] && kill $pids 2>/dev/null || true; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM HUP
rpc() { curl -s -m2 -X POST -H 'content-type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" "http://127.0.0.1:$port/"; }
[ -z "$(git -C "$root" status --porcelain)" ] || { echo "demo-app: commit first: the builds are from HEAD" >&2; exit 2; }

step "1. the page, built by wac-web's builder (the reviewed glue)"
cd "$root"
web=$(sed -n 's/.*"web": {[^}]*"git": "\([^"]*\)".*"commit": "\([0-9a-f]\{40\}\)".*/\1 \2/p' wac.lock)
webdir="${WAC_HOME:-$HOME/.wac}/cache/git/$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "${web% *}")/${web#* }"
rm -rf "$here/demo/dist"
wac run --allow-read --allow-write --allow-run "$webdir/tools/build.wac" packages/reckon/demo/mandelbrot.wac packages/reckon/demo/dist \
  --in-page --title "A Mandelbrot set, admitted" > "$work/build.log" 2>&1 || { tail -5 "$work/build.log"; exit 1; }
cmp -s "$here/demo/dist/page.wac" "$here/demo/page/page.wac" && ok "the builder's wrapper is demo/page/page.wac, as committed" \
  || { bad "the builder wrote another wrapper: commit demo/dist/page.wac as demo/page/page.wac"; exit 1; }
mkdir -p "$work/glue"
python3 - "$here/demo/dist/index.html" "$work/glue/index.html" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
t, n = re.subn(r'const WASM = "[A-Za-z0-9+/=]+"', 'const WASM = ""', s)
assert n == 1, n
open(sys.argv[2], "w").write(t)
PY
ok "the glue: the builder's index.html with its module left out ($(wc -c < "$work/glue/index.html") of $(wc -c < "$here/demo/dist/index.html") bytes)"

step "2. the page's module and the embedder, derived on two runners"
mkdir -p "$work/keys"
for k in v8 wt reviewer publisher; do openssl rand -hex 32 | tr -d '\n' > "$work/keys/$k.key"; done
RUNNER_KEYS="$work/keys" sh "$here/tools/builddeps.sh" "$work/builds" packages/reckon/demo/page/page.wac \
  packages/reckon/cmd/embed.wac:read,write > "$work/builds.log" 2>&1 || { tail -8 "$work/builds.log"; exit 1; }
grep -E "^(ok|FAIL)" "$work/builds.log"
out() { sed -n "s/^ok    $1: V8 and wasmtime derive the same output (\([a-z0-9]*\)).*/\1/p" "$work/builds.log"; }
pageOut=$(out page); embedOut=$(out embed)
[ -n "$pageOut" ] && [ -n "$embedOut" ] && ok "page module $pageOut, embedder $embedOut: each agreed by V8 and wasmtime" || { bad "the builds"; exit 1; }
B="$work/builds"; st="--store $B/store"
O="wac $B/obj.wasm"; D="wac $B/derive.wasm"
wac build --quiet --allow-read --allow-write --allow-net --allow-env "$here/cmd/claim.wac" -o "$work/claim"
CL="wac $work/claim.wasm"

step "3. the embedding, derived on two runners: the page a person opens"
cd "$work"
mkdir -p module/out
$O cat "$pageOut" status $st > module/status; $O cat "$pageOut" log $st > module/log; $O cat "$pageOut" out/page.wasm $st > module/out/page.wasm
[ "$($O add module --store "$work/scratch")" = "$pageOut" ] || { bad "the module slot is not the derived output"; exit 1; }
$O cat "$embedOut" out/embed.wasm $st > embed.wasm
recipe=$($D recipe --program embed.wasm --slot glue glue --slot module module $st 2>/dev/null)
e1=$($D run "$recipe" $st --key keys/v8.key --runner "reckon-derive/2 v8" 2>/dev/null | sed -n 1p)
e2=$($WASMTIME_WAC "$B/derive.wasm" run "$recipe" $st --key keys/wt.key --runner "reckon-derive/2 wasmtime" 2>/dev/null | sed -n 1p)
[ -n "$e1" ] && [ "$e1" = "$e2" ] && ok "V8 and wasmtime embed the same page ($e1), each signing it" || { bad "the embedding: $e1, $e2"; exit 1; }
mkdir -p app && $O cat "$e1" out/index.html $st > app/index.html
cmp -s app/index.html "$here/demo/dist/index.html" && ok "the derived page is the builder's index.html, byte for byte" || { bad "the derived page differs from the builder's"; exit 1; }
app=$($O add app $st)
echo "   the page: $app"

step "4. the reviewer, and the policy"
slot() { $CL slots "$1" $st | sed -n "s/^$2 //p"; }
origin() { $CL origins "$1" $st | sed -n '1s/^recipe \([a-z0-9]*\) .*/\1/p'; }
pageRecipe=$(origin "$pageOut"); embedRecipe=$(origin "$embedOut")
for c in "$(slot "$pageRecipe" in)" "$(slot "$pageRecipe" args)" "$(slot "$embedRecipe" args)" "$(slot "$recipe" glue)"; do
  $CL endorse "$c" reviewed --key keys/reviewer.key $st >/dev/null 2>&1
done
cat > policy.json5 <<POLICY
{
  signers: { v8: "$($CL address --key keys/v8.key)", wasmtime: "$($CL address --key keys/wt.key)",
             reviewer: "$($CL address --key keys/reviewer.key)" },
  roots: ["$(slot "$pageRecipe" program)"],
  machines: ["wasm-gc/wac-host/2"],
  formats: ["unixfs-v1-2025+hidden"],
  roles: {
    app: [{ within: { role: "embedding", path: "out" } }],
    embedding: [{ derived: { by: ["v8", "wasmtime"], at_least: 2, runners: 2, slots: { program: "embedder", glue: "reviewed", module: "build" } } }],
    embedder: [{ within: { role: "build", path: "out/embed.wasm" } }],
    build: [{ derived: { by: ["v8", "wasmtime"], at_least: 2, runners: 2, slots: { program: "compiler", in: "reviewed", args: "reviewed" } } }],
    compiler: ["root"],
    reviewed: [{ endorsed: { by: ["reviewer"], at_least: 1 } }],
  },
}
POLICY
ok "the reviewer endorsed the build's source and arguments and the glue; policy.json5 written"

step "5. a devnet, the registry, the name; a mirror"
mkdir -p devnet && ( cd devnet && exec wac "$wacuum" --dev --datadir data --port "$port" > node.log 2>&1 ) & pids="$pids $!"
until [ -n "$(rpc eth_blockNumber '[]' | sed -n 's/.*"result":"0x\([0-9a-f]*\)".*/\1/p')" ] && [ "$(rpc eth_blockNumber '[]' | sed -n 's/.*"result":"0x\([0-9a-f]*\)".*/\1/p')" != 0 ]; do sleep 0.5; done
export RPC="http://127.0.0.1:$port"
wallet="node $here/tools/registry2/wallet.mjs"
printf '1111111111111111111111111111111111111111111111111111111111111111' > keys/dev
$wallet fund keys/dev "$($wallet address keys/publisher.key)" 10 >/dev/null
set -- $($wallet deploy keys/dev); registry=$1; codehash=$2
$wallet claim keys/publisher.key "$registry" mandelbrot "$app" 0 >/dev/null
pub=$($wallet address keys/publisher.key)
ok "mandelbrot@$pub → $app, claimed on the registry v2 ($registry)"
$CL publish "$B/store" $st >/dev/null 2>&1
node "$here/tools/browser/serve.mjs" $mport "$B/store" & pids="$pids $!"
node "$here/tools/browser/cors-proxy.mjs" $proxy $port & pids="$pids $!"
until curl -s -m1 -o /dev/null "http://127.0.0.1:$mport/" && curl -s -m1 -o /dev/null -X OPTIONS "http://127.0.0.1:$proxy/"; do sleep 0.2; done

step "6. admitted by name, on the command line and in the extension"
out=$($CL admit "name:mandelbrot@$pub" app --policy policy.json5 --store fresh --mirror "http://127.0.0.1:$mport" \
  --rpc 127.0.0.1:$port --registry "$registry" --code-hash "$codehash" 2>&1) && code=0 || code=$?
printf '%s\n' "$out" | sed 's/^/   | /'
[ $code -eq 0 ] && printf '%s' "$out" | grep -q "^ADMITTED" && ok "claim admit name:mandelbrot@…: admitted through the derivations" || bad "claim admit: exit $code"
sh "$here/extension/build.sh" > "$work/ext-build.log" 2>&1 || { tail -5 "$work/ext-build.log"; exit 1; }
POLICY_TEXT=$(cat policy.json5) python3 - > settings.json <<PY
import json, os
print(json.dumps({ "rpc": "127.0.0.1:$proxy", "registry": "$registry", "codeHash": "$codehash",
  "mirrors": "http://127.0.0.1:$mport", "policy": os.environ["POLICY_TEXT"], "recheck": "0" }))
PY
mkdir -p shots
node "$here/extension/test/demo-app.cjs" settings.json "name:mandelbrot@$pub" "$app" shots > ext.log 2>&1 && code=0 || code=$?
cat ext.log
[ $code -eq 0 ] && ok "the extension: $(grep -c '^ok' ext.log) checks" || bad "the extension: $(grep -c '^FAIL' ext.log) failed"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
