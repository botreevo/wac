#!/bin/sh
# wac-turbostack's duel page (two Tetris players, one self-taught network and turbostack's original model) through
# reckon and the extension, every build step sealed: nothing of turbostack's runs outside the machine.
#
#     WASMTIME_WAC=/path/to/native/wac WAC_SRC=/path/to/wac sh packages/reckon/tools/turbostack.sh WORKDIR [COMMIT]
#
# 1. The source: turbostack at COMMIT (default a7fb02f), from git.voltrevo.com, by `git archive`, with its manifest's
#    and lock's wac-web moved to the commit wac-eth pins (1862171, whose builder has the halves that start no
#    process; turbostack pins one before them). That one change is the source's own, reviewed with it.
# 2. Inside the sealed machine on V8 and on wasmtime, each runner signing: cmd/pagebuild.wac and cmd/gather.wac
#    (tools/builddeps.sh, from wac-eth's HEAD); then, each a derivation on both runners:
#    a. `pagebuild --module-only`: wac-web's builder writes the page's module for web/play.wac;
#    b. the compiler builds it, from turbostack's source with that page.wac added and its locked dependencies;
#    c. `pagebuild --wrap`: the page, index.html (in-page: the program on the page's thread, whose site requests the
#       loader answers from the tree);
#    d. `gather`: the site, index.html beside the two models' weights it loads.
# 3. A reviewer endorses the sources and arguments; a policy admits the site through (d), (c), (b), the builder and
#    the gatherer, back to the compiler as the root.
# 4. A wacuum devnet, the registry v2, the site claimed as `turbostack`; a mirror, and a manifest naming it
#    (docs/discovery.md), from which both the command line and the extension find it (--mirrors-from).
# 5. Admitted by name on the command line, then opened in the extension: the name by proof, the site fetched and
#    checked, run in the sandbox loader, where both players load their weights and play. Screenshots in WORKDIR/shots.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:?WORKDIR}; rm -rf "$work"; mkdir -p "$work"; work=$(cd "$work" && pwd)
commit=${2:-a7fb02f}
: "${WASMTIME_WAC:?set WASMTIME_WAC to the wac of the native host}"
: "${WAC_SRC:?set WAC_SRC to a wac checkout at the pinned commit (for the extension)}"
port=${PORT:-8950}; proxy=$((port + 1)); mport=$((port + 2)); fport=$((port + 3))
wacuum=${WACUUM:-$root/packages/wacuum/dist/wacuum.wasm}
cache="${WAC_HOME:-$HOME/.wac}/cache/git"
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
quote() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
[ -z "$(git -C "$root" status --porcelain)" ] || { echo "turbostack: commit first: the builders are built from HEAD" >&2; exit 2; }
web=$(sed -n 's/.*"web": {[^}]*"commit": "\([0-9a-f]\{40\}\)".*/\1/p' "$root/wac.lock")
TITLE="Tetris, learned from nothing"

step "1. turbostack's source, at $commit"
cd "$work"
git init -q ts && git -C ts fetch -q --depth 1 https://git.voltrevo.com/wac-turbostack.git "$commit" 2>/dev/null \
  || git -C ts fetch -q https://git.voltrevo.com/wac-turbostack.git
# The commit asked for, not FETCH_HEAD: when the shallow fetch of a short hash fails, the fallback fetches the default
# branch, whose head is not the commit.
full=$(git -C ts rev-parse "$commit^{commit}")
mkdir -p src/in src/home/cache/git && git -C ts archive "$full" | tar -x -C src/in
for f in wac.json5 wac.lock; do
  sed -i "s|https://github.com/voltrevo/wac-web.git|https://git.voltrevo.com/wac-web.git|g; s|a14793f5e55af55b1ef9973715d31087e6d0c1f8|$web|g" "src/in/$f"
done
grep -q "$web" src/in/wac.lock && ok "turbostack $(echo "$full" | cut -c1-9), its wac-web moved to $(echo "$web" | cut -c1-9)" || { bad "the lock override"; exit 1; }
# Its dependencies, as wac's cache holds them: what its lock pins, and what tensor's own manifest names.
sed -n 's/.*"git": "\([^"]*\)".*"commit": "\([0-9a-f]\{40\}\)".*/\1 \2/p' src/in/wac.lock | sort -u > deps.txt
echo "https://github.com/voltrevo/wac-web.git a14793f5e55af55b1ef9973715d31087e6d0c1f8" >> deps.txt
while read -r g c; do
  d="$(quote "$g")/$c"
  [ -d "$cache/$d" ] || { (cd "$root" && LOCK=/dev/stdin sh tools/deps.sh) <<LOCK >/dev/null 2>&1
{ "imports": { "x": { "git": "$g", "ref": "$c", "commit": "$c" } } }
LOCK
  }
  [ -d "$cache/$d" ] || { bad "not in the package cache: $g at $c"; exit 1; }
  mkdir -p "src/home/cache/git/$d" && cp -r "$cache/$d/." "src/home/cache/git/$d/"
done < deps.txt
ok "its dependencies, $(wc -l < deps.txt) checkouts, laid out as wac's cache"

step "2. the builder and the gatherer, derived on two runners"
mkdir -p keys
for k in v8 wt reviewer publisher; do openssl rand -hex 32 | tr -d '\n' > "keys/$k.key"; done
RUNNER_KEYS="$work/keys" sh "$here/tools/builddeps.sh" "$work/builds" packages/reckon/cmd/pagebuild.wac:read,write \
  packages/reckon/cmd/gather.wac:read,write > builds.log 2>&1 || { tail -8 builds.log; exit 1; }
grep -E "^(ok|FAIL)" builds.log
out() { sed -n "s/^ok    $1: V8 and wasmtime derive the same output (\([a-z0-9]*\)).*/\1/p" builds.log; }
builderOut=$(out pagebuild); gatherOut=$(out gather)
[ -n "$builderOut" ] && [ -n "$gatherOut" ] && ok "builder $builderOut, gatherer $gatherOut" || { bad "the builds"; exit 1; }
B="$work/builds"; st="--store $B/store"
O="wac $B/obj.wasm"; D="wac $B/derive.wasm"
(cd "$root" && wac build --quiet --allow-read --allow-write --allow-net --allow-env "$here/cmd/claim.wac" -o "$work/claim")
CL="wac $work/claim.wasm"
$O cat "$builderOut" out/pagebuild.wasm $st > pagebuild.wasm
$O cat "$gatherOut" out/gather.wasm $st > gather.wasm
derive2() {
  name=$1; argsf=$2; prog=$3; shift 3
  recipe=$($D recipe --program "$prog" --args "$argsf" "$@" $st 2>/dev/null)
  echo "$recipe" > "$name.recipe"
  a=$($D run "$recipe" $st --timeout 3600000 --key keys/v8.key --runner "reckon-derive/2 v8" 2>/dev/null | sed -n 1p)
  b=$($WASMTIME_WAC "$B/derive.wasm" run "$recipe" $st --timeout 3600000 --key keys/wt.key --runner "reckon-derive/2 wasmtime" 2>/dev/null | sed -n 1p)
  if [ -n "$a" ] && [ "$a" = "$b" ] && [ "$($O cat "$a" status $st)" = "exit 0" ]; then echo "$a"; return 0; fi
  echo "$name: V8 ${a:-nothing}, wasmtime ${b:-nothing}: $($O cat "${a:-$b}" log $st 2>/dev/null | tail -3)" >&2
  return 1
}
export_tree() {
  mkdir -p "$2"
  $O ls "$1" $st | while IFS="$(printf '\t')" read -r p size; do mkdir -p "$2/$(dirname "$p")"; $O cat "$1" "$p" $st > "$2/$p"; done
  [ "$($O add "$2" --store "$work/scratch")" = "$1" ] || { echo "export: $2 is not $1" >&2; return 1; }
}

step "3. the site, in four derivations"
mkdir -p empty
printf '%s\n' web/play.wac dist/site-play --in-page --title "$TITLE" --module-only > module.args
moduleOut=$(derive2 module module.args pagebuild.wasm --in empty) || { bad "(a) --module-only"; exit 1; }
$O cat "$moduleOut" out/dist/site-play/page.wac $st > page.wac
ok "(a) the builder wrote page.wac for web/play.wac"
mkdir -p src/in/dist/site-play && cp page.wac src/in/dist/site-play/page.wac
printf 'build\n--wac-home\n/in/in/home\nin/in/in/dist/site-play/page.wac\n-o\n/out/page\n' > compile.args
compiled=$(derive2 compile compile.args "$B/wac.wasm" --in src) || { bad "(b) the compile"; exit 1; }
compileRecipe=$(cat compile.recipe)
ok "(b) the compiler built the page's module, the tensor library and both players with it ($compiled)"
export_tree "$compiled" compiled
printf '%s\n' web/play.wac out --in-page --title "$TITLE" --wrap > wrap.args
pageOut=$(derive2 wrap wrap.args pagebuild.wasm --in compiled) || { bad "(c) --wrap"; exit 1; }
wrapRecipe=$(cat wrap.recipe)
export_tree "$pageOut" page
mkdir -p models && cp src/in/models/self-taught.weights src/in/models/turbostack.weights models/
printf '%s\n' page/out/out/index.html=index.html models/self-taught.weights=self-taught.weights models/turbostack.weights=turbostack.weights > gather.args
siteOut=$(derive2 gather gather.args gather.wasm --slot page page --slot models models) || { bad "(d) gather"; exit 1; }
gatherRecipe=$(cat gather.recipe)
ok "(c) --wrap, the page ($pageOut); (d) the site, the page beside the weights ($siteOut)"
mkdir -p site && for f in index.html self-taught.weights turbostack.weights; do $O cat "$siteOut" "out/$f" $st > "site/$f"; done
cmp -s site/self-taught.weights src/in/models/self-taught.weights && ok "the weights are turbostack's, byte for byte" || bad "the weights"
appCid=$($O add site $st)
echo "   the site: $appCid ($(du -sh site | cut -f1))"

step "4. the reviewer, and the policy"
slot() { $CL slots "$1" $st | sed -n "s/^$2 //p"; }
origin() { $CL origins "$1" $st | sed -n '1s/^recipe \([a-z0-9]*\) .*/\1/p'; }
builderRecipe=$(origin "$builderOut"); gathererRecipe=$(origin "$gatherOut")
for c in "$(slot "$builderRecipe" in)" "$(slot "$builderRecipe" args)" "$(slot "$gathererRecipe" args)" \
         "$(slot "$compileRecipe" in)" "$(slot "$compileRecipe" args)" "$(slot "$wrapRecipe" args)" \
         "$(slot "$gatherRecipe" models)" "$(slot "$gatherRecipe" args)"; do
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
    app: [{ within: { role: "gathered", path: "out" } }],   // the extension admits what it opens as `app`
    gathered: [{ derived: { by: ["v8", "wasmtime"], at_least: 2, runners: 2,
                            slots: { program: "gatherer", args: "reviewed", page: "page", models: "reviewed" } } }],
    gatherer: [{ within: { role: "build", path: "out/gather.wasm" } }],
    page: [{ derived: { by: ["v8", "wasmtime"], at_least: 2, runners: 2, slots: { program: "builder", args: "reviewed", in: "module" } } }],
    builder: [{ within: { role: "build", path: "out/pagebuild.wasm" } }],
    module: [{ derived: { by: ["v8", "wasmtime"], at_least: 2, runners: 2, slots: { program: "compiler", in: "reviewed", args: "reviewed" } } }],
    build: [{ derived: { by: ["v8", "wasmtime"], at_least: 2, runners: 2, slots: { program: "compiler", in: "reviewed", args: "reviewed" } } }],
    compiler: ["root"],
    reviewed: [{ endorsed: { by: ["reviewer"], at_least: 1 } }],
  },
}
POLICY
ok "the reviewer endorsed the sources, arguments and weights; policy.json5"

step "5. a devnet, the registry, the name; a mirror"
mkdir -p devnet && ( cd devnet && exec wac "$wacuum" --dev --datadir data --port "$port" > node.log 2>&1 ) & pids="$pids $!"
until [ -n "$(rpc eth_blockNumber '[]' | sed -n 's/.*"result":"0x\([0-9a-f]*\)".*/\1/p')" ] && [ "$(rpc eth_blockNumber '[]' | sed -n 's/.*"result":"0x\([0-9a-f]*\)".*/\1/p')" != 0 ]; do sleep 0.5; done
export RPC="http://127.0.0.1:$port"
wallet="node $here/tools/registry2/wallet.mjs"
printf '1111111111111111111111111111111111111111111111111111111111111111' > keys/dev
$wallet fund keys/dev "$($wallet address keys/publisher.key)" 10 >/dev/null
set -- $($wallet deploy keys/dev); registry=$1; codehash=$2
$wallet claim keys/publisher.key "$registry" turbostack "$appCid" 0 >/dev/null
pub=$($wallet address keys/publisher.key)
ok "turbostack@$pub → $appCid"
node "$here/tools/browser/serve.mjs" $mport "$B/store" & pids="$pids $!"
node "$here/tools/browser/cors-proxy.mjs" $proxy $port & pids="$pids $!"
# The mirror is found as a reader would find it: from a manifest a site publishes (docs/discovery.md), on its own port.
mkdir -p manifest && $CL manifest manifest/reckon-mirrors.json --lists "http://127.0.0.1:$mport" >/dev/null
node "$here/tools/browser/serve.mjs" $fport manifest & pids="$pids $!"
until curl -s -m1 -o /dev/null "http://127.0.0.1:$mport/" && curl -s -m1 -o /dev/null -X OPTIONS "http://127.0.0.1:$proxy/" \
  && curl -s -m1 -o /dev/null "http://127.0.0.1:$fport/reckon-mirrors.json"; do sleep 0.2; done
manifest="http://127.0.0.1:$fport/reckon-mirrors.json"

step "6. admitted by name, and played in the extension"
out=$($CL admit "name:turbostack@$pub" app --policy policy.json5 --store fresh --mirrors-from "$manifest" \
  --rpc 127.0.0.1:$port --registry "$registry" --code-hash "$codehash" 2>&1) && code=0 || code=$?
printf '%s\n' "$out" | sed 's/^/   | /'
[ $code -eq 0 ] && printf '%s' "$out" | grep -q "^ADMITTED" && ok "claim admit name:turbostack@…: admitted through the derivations" || bad "claim admit: exit $code"
sh "$here/extension/build.sh" > ext-build.log 2>&1 || { tail -5 ext-build.log; exit 1; }
POLICY_TEXT=$(cat policy.json5) python3 - > settings.json <<PY
import json, os
print(json.dumps({ "rpc": "127.0.0.1:$proxy", "registry": "$registry", "codeHash": "$codehash", "mirrorsFrom": "$manifest",
  "policy": os.environ["POLICY_TEXT"], "recheck": "0" }))
PY
mkdir -p shots
node "$here/extension/test/turbostack.cjs" settings.json "name:turbostack@$pub" "$appCid" shots > ext.log 2>&1 && code=0 || code=$?
cat ext.log
[ $code -eq 0 ] && ok "the extension: $(grep -c '^ok' ext.log) checks" || bad "the extension: $(grep -c '^FAIL' ext.log) failed"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
