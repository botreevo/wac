#!/bin/sh
# A real wac app, end to end through reckon and the extension: demo/mandelbrot.wac, a wac-web page that draws a
# Mandelbrot set. It is built in sealed steps, reviewed, published, named on chain, admitted by a policy, and run in
# the extension, with nothing reaching the network.
#
#     WASMTIME_WAC=/path/to/native/wac WAC_SRC=/path/to/wac sh packages/reckon/tools/demo-app.sh WORKDIR
#
# 1. Inside the sealed machine, on V8 and on wasmtime, each runner signing (tools/builddeps.sh, from HEAD and the
#    dependencies pinned by CID): cmd/pagebuild.wac, which runs the two halves of wac-web's page builder that start
#    no process (W5).
# 2. The page, in three derivations, each on both runners:
#    a. `pagebuild --module-only`: the builder writes the page's module, page.wac;
#    b. the compiler builds it, from wac-eth's source and the locked dependencies with that page.wac added beside the
#       app (where the builder means it to be: it imports the app relatively, and `web` through the manifest);
#    c. `pagebuild --wrap`: (b)'s output, its module wrapped into index.html.
#    The page must be what wac-web's builder makes in one step, natively, byte for byte but one field: the entry path
#    wac records in the module's manifest, which in the machine is below its input (tools/samepage.py).
# 3. A reviewer endorses what was reviewed: the builds' source and arguments, and (b)'s source, which is wac-eth's
#    with (a)'s page.wac added (the script checks that it is). A policy (WORKDIR/policy.json5) admits the page
#    through (c), the builder and (b), back to the compiler as the root.
# 4. A wacuum devnet with the registry v2: the page's CID claimed as `mandelbrot` by a publisher. A mirror: the store,
#    served with CORS.
# 5. `claim admit name:mandelbrot@0xPUB app`: admitted, on the command line. Then the extension
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
TITLE="A Mandelbrot set, admitted"

step "1. the page builder, derived on two runners"
mkdir -p "$work/keys"
for k in v8 wt reviewer publisher; do openssl rand -hex 32 | tr -d '\n' > "$work/keys/$k.key"; done
RUNNER_KEYS="$work/keys" sh "$here/tools/builddeps.sh" "$work/builds" packages/reckon/cmd/pagebuild.wac:read,write \
  > "$work/builds.log" 2>&1 || { tail -8 "$work/builds.log"; exit 1; }
grep -E "^(ok|FAIL)" "$work/builds.log"
builderOut=$(sed -n "s/^ok    pagebuild: V8 and wasmtime derive the same output (\([a-z0-9]*\)).*/\1/p" "$work/builds.log")
[ -n "$builderOut" ] && ok "the builder $builderOut, agreed by V8 and wasmtime" || { bad "the builder"; exit 1; }
B="$work/builds"; st="--store $B/store"
O="wac $B/obj.wasm"; D="wac $B/derive.wasm"
cd "$root"
wac build --quiet --allow-read --allow-write --allow-net --allow-env "$here/cmd/claim.wac" -o "$work/claim"
CL="wac $work/claim.wasm"
cd "$work"
$O cat "$builderOut" out/pagebuild.wasm $st > pagebuild.wasm
# derive2 NAME ARGSFILE PROGRAM [derive recipe flags…]: the recipe run on both runners, each signing; the agreed output,
# and the recipe in NAME.recipe (it runs in a command substitution, so a variable would not reach the caller).
derive2() {
  name=$1; argsf=$2; prog=$3; shift 3
  recipe=$($D recipe --program "$prog" --args "$argsf" "$@" $st 2>/dev/null)
  echo "$recipe" > "$name.recipe"
  a=$($D run "$recipe" $st --timeout 1800000 --key keys/v8.key --runner "reckon-derive/2 v8" 2>/dev/null | sed -n 1p)
  b=$($WASMTIME_WAC "$B/derive.wasm" run "$recipe" $st --timeout 1800000 --key keys/wt.key --runner "reckon-derive/2 wasmtime" 2>/dev/null | sed -n 1p)
  if [ -n "$a" ] && [ "$a" = "$b" ] && [ "$($O cat "$a" status $st)" = "exit 0" ]; then echo "$a"; return 0; fi
  echo "$name: V8 ${a:-nothing}, wasmtime ${b:-nothing}: $($O cat "${a:-$b}" log $st 2>/dev/null | tail -3)" >&2
  return 1
}
# export CID DIR: a tree out of the store into DIR, so a later recipe can take it as a slot (it imports to the same CID).
export_tree() {
  mkdir -p "$2"
  $O ls "$1" $st | while IFS="$(printf '\t')" read -r p size; do mkdir -p "$2/$(dirname "$p")"; $O cat "$1" "$p" $st > "$2/$p"; done
  [ "$($O add "$2" --store "$work/scratch")" = "$1" ] || { echo "export: $2 is not $1" >&2; return 1; }
}

step "2. the page, in three derivations"
mkdir -p empty
printf '%s\n' packages/reckon/demo/mandelbrot.wac packages/reckon/demo/dist --in-page --title "$TITLE" --module-only > module.args
moduleOut=$(derive2 module module.args pagebuild.wasm --in empty) || { bad "(a) --module-only"; exit 1; }
$O cat "$moduleOut" out/packages/reckon/demo/dist/page.wac $st > page.wac
ok "(a) --module-only: the builder wrote page.wac ($moduleOut)"
rm -rf src && mkdir -p src && cp -R "$B/tree/in" "$B/tree/home" src/
mkdir -p src/in/packages/reckon/demo/dist && cp page.wac src/in/packages/reckon/demo/dist/page.wac
printf 'build\n--wac-home\n/in/in/home\nin/in/in/packages/reckon/demo/dist/page.wac\n-o\n/out/page\n' > compile.args
compiled=$(derive2 compile compile.args "$B/wac.wasm" --in src) || { bad "(b) the compile"; exit 1; }
compileRecipe=$(cat compile.recipe)
ok "(b) the compiler built page.wasm from it ($compiled)"
export_tree "$compiled" compiled
printf '%s\n' packages/reckon/demo/mandelbrot.wac out --in-page --title "$TITLE" --wrap > wrap.args
pageOut=$(derive2 wrap wrap.args pagebuild.wasm --in compiled) || { bad "(c) --wrap"; exit 1; }
wrapRecipe=$(cat wrap.recipe)
ok "(c) --wrap: the page ($pageOut)"
mkdir -p app && $O cat "$pageOut" out/out/index.html $st > app/index.html
cd "$root"
web=$(sed -n 's/.*"web": {[^}]*"git": "\([^"]*\)".*"commit": "\([0-9a-f]\{40\}\)".*/\1 \2/p' wac.lock)
webdir="${WAC_HOME:-$HOME/.wac}/cache/git/$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "${web% *}")/${web#* }"
rm -rf "$here/demo/dist"
wac run --allow-read --allow-write --allow-run "$webdir/tools/build.wac" packages/reckon/demo/mandelbrot.wac packages/reckon/demo/dist \
  --in-page --title "$TITLE" > "$work/native.log" 2>&1 || { tail -5 "$work/native.log"; exit 1; }
cd "$work"
# The same page but for one field: wac records the entry it compiled in the module's manifest, and the machine's
# compile was given it below its input (in/in/in/), where the native build was given it from wac-eth's root.
python3 -I "$here/tools/samepage.py" app/index.html "$here/demo/dist/index.html" in/in/in/ > samepage.log 2>&1 \
  && ok "the page is the one wac-web's builder makes natively in one step, byte for byte but the manifest's entry path" \
  || { bad "the sealed page differs from the builder's one-step page: $(cat samepage.log)"; exit 1; }
cmp -s page.wac "$here/demo/dist/page.wac" && ok "…and so is page.wac" || bad "page.wac differs from the builder's"
rm -rf "$here/demo/dist"
app=$($O add app $st)
echo "   the page: $app"

step "3. the reviewer, and the policy"
slot() { $CL slots "$1" $st | sed -n "s/^$2 //p"; }
builderRecipe=$($CL origins "$builderOut" $st | sed -n '1s/^recipe \([a-z0-9]*\) .*/\1/p')
[ "$(slot "$compileRecipe" in)" = "$($O add src --store "$work/scratch2")" ] || { bad "(b)'s source"; exit 1; }
for c in "$(slot "$builderRecipe" in)" "$(slot "$builderRecipe" args)" "$(slot "$compileRecipe" in)" "$(slot "$compileRecipe" args)" "$(slot "$wrapRecipe" args)"; do
  $CL endorse "$c" reviewed --key keys/reviewer.key $st >/dev/null 2>&1
done
cat > policy.json5 <<POLICY
{
  signers: { v8: "$($CL address --key keys/v8.key)", wasmtime: "$($CL address --key keys/wt.key)",
             reviewer: "$($CL address --key keys/reviewer.key)" },
  roots: ["$(slot "$builderRecipe" program)"],
  machines: ["wasm-gc/wac-host/3"],
  formats: ["unixfs-v1-2025+hidden"],
  roles: {
    app: [{ within: { role: "page", path: "out/out" } }],
    page: [{ derived: { by: ["v8", "wasmtime"], at_least: 2, runners: 2, slots: { program: "builder", args: "reviewed", in: "module" } } }],
    builder: [{ within: { role: "build", path: "out/pagebuild.wasm" } }],
    module: [{ derived: { by: ["v8", "wasmtime"], at_least: 2, runners: 2, slots: { program: "compiler", in: "reviewed", args: "reviewed" } } }],
    build: [{ derived: { by: ["v8", "wasmtime"], at_least: 2, runners: 2, slots: { program: "compiler", in: "reviewed", args: "reviewed" } } }],
    compiler: ["root"],
    reviewed: [{ endorsed: { by: ["reviewer"], at_least: 1 } }],
  },
}
POLICY
ok "the reviewer endorsed the sources and arguments; (b)'s source is wac-eth's with (a)'s page.wac, checked"

step "4. a devnet, the registry, the name; a mirror"
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

step "5. admitted by name, on the command line and in the extension"
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
