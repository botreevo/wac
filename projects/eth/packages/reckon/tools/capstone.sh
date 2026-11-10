#!/bin/sh
# The motivating case, end to end, in one run (docs/capstone.md): from source to a compiler to an app to its run, each a
# derivation signed by two runners on two engines; claims published to a mirror; a name pointing at the app; and a
# fresh client, with an empty store and nothing but a policy (keys and trust roots) and an anchor, that resolves the
# name by proof, takes the claims from the mirror, fetches the app with every block checked, admits it, and runs it.
# Then the ways it must refuse.
#
#     WASMTIME_WAC=/path/to/native/wac sh packages/reckon/tools/capstone.sh WORKDIR
#     QUICK=1 …   the compiler that builds the app is the seed itself, not one it built (minutes instead of tens)
#
# Ports from PORT (8830): the devnet, the mirror over HTTP, the recorded beacon and execution nodes. 4b fetches
# vitalik.eth's content from a public trustless gateway (GATEWAY, default https://trustless-gateway.link; GATEWAY= to
# skip), and says so, counting nothing, when the gateway does not answer.
# Needs: wac on PATH, node with tools/oracle's packages installed, python3, curl, git.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=$1; rm -rf "$work"; mkdir -p "$work"; work=$(cd "$work" && pwd)
WT=${WASMTIME_WAC:?set WASMTIME_WAC to the wac of the native host}
wacuum=${WACUUM:-$root/packages/wacuum/dist/wacuum.wasm}
[ -f "$wacuum" ] || { echo "capstone: build wacuum first: wac task wacuum:build" >&2; exit 2; }
port=${PORT:-8830}; web=$((port + 1)); bport=$((port + 2)); eport=$((port + 3))
for p in $port $web $bport $eport; do
  if curl -s -m1 -o /dev/null "http://127.0.0.1:$p/" 2>/dev/null; then echo "capstone: port $p is taken; set PORT" >&2; exit 2; fi
done
pids=""
cleanup() { [ -n "$pids" ] && kill $pids 2>/dev/null || true; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM HUP
pass=0; fail=0
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok() { pass=$((pass + 1)); echo "   PASS ($*)"; }
bad() { fail=$((fail + 1)); echo "   FAIL ($*)"; }
expect() {  # expect ok|refused DESCRIPTION [BECAUSE] -- command…
  want=$1; what=$2; because=""; shift 2
  if [ "$1" != "--" ]; then because=$1; shift; fi
  shift
  if out=$("$@" 2>&1); then got=ok; else got=refused; fi
  printf '%s\n' "$out" | sed 's/^/   | /'
  if [ "$got" != "$want" ]; then bad "$what: wanted $want, got $got"
  elif [ -n "$because" ] && ! printf '%s' "$out" | grep -qF -- "$because"; then bad "$what: $got, but not because \"$because\""
  else ok "$what: $got${because:+, because \"$because\"}"; fi
}
rpc() { curl -s -m2 -X POST -H 'content-type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}" "http://127.0.0.1:$1/"; }
up() { until curl -s -m1 -o /dev/null "http://127.0.0.1:$1/"; do sleep 0.3; done; }

step "tools, and the seed: wac's compiler at the pinned commit, built natively"
cd "$root"
wac build --quiet --allow-read --allow-write --allow-run "$here/cmd/derive.wac" -o "$work/derive"
wac build --quiet --allow-read --allow-write --allow-net --allow-env --allow-run "$here/cmd/claim.wac" -o "$work/claim"
wac build --quiet --allow-read --allow-write --allow-net packages/ipfs/cmd/obj.wac -o "$work/obj"
commit=$(sed -n 's/.*"wac": {.*"commit": "\([0-9a-f]\{40\}\)".*/\1/p' "$root/wac.lock" | head -1)
src=${WACSRC:-$HOME/.wac/cache/git/https%3A%2F%2Fgit.voltrevo.com%2Fwac.git/$commit}
[ -d "$src" ] || { echo "capstone: no wac source at $src: run sh tools/deps.sh" >&2; exit 2; }
cd "$work"
mkdir -p wacsrc/in && cp -r "$src/." wacsrc/in/ && rm -f wacsrc/in/pack.pack
(cd wacsrc/in && wac build --quiet --allow-read --allow-write --allow-run --allow-net --allow-env packages/wac/src/wac.wac -o "$work/seed")
st="--store $work/builder"
D="wac derive.wasm"; CL="wac claim.wasm"; O="wac obj.wasm"
printf '%s\n' 4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318 > v8.key
printf '%s\n' 646f1ce2fdad0e6deeeb5c7e8e5543bdde65e86029e2fd9fc169899c440a7913 > wt.key
printf '%s\n' add2f9f8b6e2bff7d0b6e7d1bbcd8fe16c3fbd8b5b1fbb1c0a63e5a0e7a2c3b1 > reviewer.key
# derive2 RECIPE: the output on V8 and on wasmtime, each signed by its runner; prints "OUTPUT V8DERIVATION WTDERIVATION".
derive2() {
  a=$($D run "$1" $st --timeout 7200000 --key v8.key --runner "reckon-derive/2 v8" 2>/dev/null)
  b=$($WT derive.wasm run "$1" $st --timeout 7200000 --key wt.key --runner "reckon-derive/2 wasmtime" 2>/dev/null)
  [ "$(echo "$a" | sed -n 1p)" = "$(echo "$b" | sed -n 1p)" ] || { echo "ENGINES-DIFFER"; return; }
  echo "$(echo "$a" | sed -n 1p) $(echo "$a" | sed -n 2p) $(echo "$b" | sed -n 2p)"
}

if [ -z "${QUICK:-}" ]; then
  step "1a. the compiler, built from its own source inside the machine by the seed, on both engines"
  printf 'build\nin/in/packages/wac/src/wac.wac\n-o\n/out/wac\n--allow-read\n--allow-write\n--allow-run\n--allow-net\n--allow-env\n' > self.args
  selfbuild=$($D recipe --program seed.wasm --args self.args --in wacsrc/in $st 2>/dev/null)
  set -- $(derive2 "$selfbuild"); compilerTree=$1
  [ "$compilerTree" != ENGINES-DIFFER ] && ok "V8 and wasmtime derive the same compiler ($compilerTree)" || bad "the engines built different compilers"
  $O cat "$compilerTree" out/wac.wasm $st > compiler.wasm
  [ -s compiler.wasm ] && ok "the compiler: $(wc -c < compiler.wasm) bytes" || bad "no compiler: $($O cat "$compilerTree" status $st)"
else
  step "1a. QUICK: the seed is the compiler"
  cp seed.wasm compiler.wasm
fi

step "1b. the app, built from its source by that compiler, on both engines"
mkdir -p app/in && cat > app/in/capstone.wac <<'EOF'
// The app the capstone builds, names and admits: what it prints is the whole of what it does.
import { Sys } from "std";
export i32 main(Sys sys) {
  sys.log("capstone: built from reviewed source by a witnessed compiler, named by proof, admitted, run");
  return 0;
}
EOF
printf 'build\nin/in/capstone.wac\n-o\n/out/capstone\n' > app.args
build=$($D recipe --program compiler.wasm --args app.args --in app/in $st 2>/dev/null)
set -- $(derive2 "$build"); buildTree=$1; buildWt=$3
[ "$buildTree" != ENGINES-DIFFER ] && ok "V8 and wasmtime derive the same app ($buildTree)" || bad "the engines built different apps"
$O cat "$buildTree" out/capstone.wasm $st > capstone.wasm
# The app's own CID: under 1 MiB, a file is one raw block, so its CID is the raw CID of its bytes; the check below asks
# the store for those bytes under that CID.
appCid=$(python3 -c "import sys,hashlib,base64; d=hashlib.sha256(open(sys.argv[1],'rb').read()).digest(); print('b'+base64.b32encode(bytes([1,0x55,0x12,0x20])+d).decode().lower().rstrip('='))" capstone.wasm)
[ -n "$appCid" ] && [ "$($O cat "$appCid" $st | cmp - capstone.wasm && echo same)" = same ] && ok "the app is $appCid" || bad "no CID for the app"
echo "   the app: $(wc -c < capstone.wasm) bytes"

step "1c. the app, run by the machine, on both engines"
run=$($D recipe --program capstone.wasm $st 2>/dev/null)
set -- $(derive2 "$run"); runTree=$1
[ "$runTree" != ENGINES-DIFFER ] && ok "V8 and wasmtime derive the same run ($runTree)" || bad "the engines ran it differently"
[ "$($O cat "$runTree" status $st)" = "exit 0" ] && ok "it ran: \"$($O cat "$runTree" log $st)\"" || bad "the run: $($O cat "$runTree" status $st)"

step "2. the policy, the reviewer's endorsements, and the builder's store published as a mirror"
cp -r builder mirror-unreviewed                                  # for 5b: a mirror carrying no endorsement
seed=$($CL slots "$build" $st 2>/dev/null | sed -n 's/^program //p')
endorse() { for slot in in args; do $CL endorse "$($CL slots "$1" $st 2>/dev/null | sed -n "s/^$slot //p")" reviewed --key reviewer.key $st >/dev/null 2>&1; done; }
endorse "$build"
if [ -z "${QUICK:-}" ]; then
  seed=$($CL slots "$selfbuild" $st 2>/dev/null | sed -n 's/^program //p')
  endorse "$selfbuild"
  compilerRole='[{ within: { role: "selfbuild", path: "out/wac.wasm" } }]'
else
  compilerRole='["root"]'
fi
cat > policy.json5 <<POLICY
{
  // Trusted: these three keys, and the seed compiler (wac's, built natively at the pinned commit) as a root.
  signers: { v8: "$($CL address --key v8.key)", wasmtime: "$($CL address --key wt.key)", reviewer: "$($CL address --key reviewer.key)" },
  roots: ["$seed"],
  machines: ["$(sed -n 's/.*MACHINE() { return "\([^"]*\)".*/\1/p' "$here/src/machine.wac")"],
  formats: ["unixfs-v1-2025+hidden"],
  roles: {
    app: [{ within: { role: "build", path: "out/capstone.wasm" } }],
    build: [{ derived: { by: ["v8", "wasmtime"], at_least: 2, runners: 2, slots: { program: "compiler", in: "source", args: "source" } } }],
    compiler: $compilerRole,
    selfbuild: [{ derived: { by: ["v8", "wasmtime"], at_least: 2, runners: 2, slots: { program: "seed", in: "source", args: "source" } } }],
    seed: ["root"],
    source: [{ endorsed: { by: ["reviewer"], at_least: 1 } }],
  },
}
POLICY
expect ok "the builder admits the app from its own store" "ADMITTED" -- $CL admit "$appCid" app --policy policy.json5 $st
cp -r builder mirror
expect ok "everything the builder holds is in the mirror's index" "statement(s)" -- $CL publish mirror $st
( cd mirror && exec python3 -m http.server "$web" --bind 127.0.0.1 >/dev/null 2>&1 ) & pids="$pids $!"; up $web
M="--mirror http://127.0.0.1:$web"

step "3. a devnet with ENS's layout and the registry; the name capstone.reckon.eth points at the app"
mkdir -p devnet
( cd devnet && exec wac "$wacuum" --dev --datadir data --port "$port" > node.log 2>&1 ) & pids="$pids $!"
until rpc $port eth_blockNumber '[]' >/dev/null; do sleep 0.5; done
export RPC="http://127.0.0.1:$port"
ens="node $here/tools/byname/wallet.mjs"; reg="node $here/tools/registry2/wallet.mjs"
printf '1111111111111111111111111111111111111111111111111111111111111111' > dev.key
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > publisher.key
$ens fund dev.key "$($ens address publisher.key)" 10 >/dev/null
$ens fund dev.key "$($ens address wt.key)" 10 >/dev/null
set -- $($ens deploy dev.key); ensReg=$1; ensRegCode=$2; resolver=$3; resolverCode=$4
set -- $($reg deploy dev.key); registry=$1; registryCode=$2
name=capstone.reckon.eth
expect ok "the publisher claims $name" -- $ens claim publisher.key "$ensReg" $name "$resolver"
expect ok "and points it at the app, $appCid" -- $ens set-contenthash publisher.key "$resolver" $name "$appCid"
anchor=$(rpc $port eth_getBlockByNumber '["latest",false]' | sed -n 's/.*"hash":"\(0x[0-9a-f]*\)".*/\1/p')
echo "   the anchor: $anchor (a devnet has no beacon chain: docs/capstone.md)"
CHAIN="--rpc 127.0.0.1:$port --ens-registry $ensReg --ens-registry-code $ensRegCode --resolver-code $resolverCode --registry $registry --code-hash $registryCode"

step "4. a fresh client: an empty store, the policy, an anchor. Name → proof → claims → bytes → admitted → run"
A="--policy policy.json5 $CHAIN"
expect ok "claim admit ens:$name: resolved by proof, claims from the mirror, every step accounted for" "ADMITTED" -- $CL admit "ens:$name" app $A --anchor "$anchor" --store client $M
out=$($CL admit "ens:$name" app $A --anchor "$anchor" --store client $M 2>&1 || true)
printf '%s' "$out" | grep -qF "name: $name → ipfs://$appCid" && ok "the name proves to the app's CID" || bad "the name did not prove to $appCid"
expect ok "the app's bytes from the mirror, each block checked against its CID" -- sh -c "$O cat $appCid --store client $M > fetched.wasm"
cmp -s fetched.wasm capstone.wasm && ok "the bytes are the build's" || bad "the fetched bytes differ"
expect ok "and it runs" "capstone: built from reviewed source" -- wac fetched.wasm

step "4b. the same entry point on recorded mainnet: the anchor from a checkpoint, through the light client"
vitalik=bafybeia5eyombgegdwmvfzwisveadaaok2vdjkv5rklfdmcljysjrjc4km
mkdir -p mainnet && cat > mainnet/policy.json5 <<POLICY
{ signers: { reviewer: "$($CL address --key reviewer.key)" }, roles: { site: [{ endorsed: { by: ["reviewer"], at_least: 1 } }] } }
POLICY
$CL endorse "$vitalik" "reviewed the site" --key reviewer.key --store mainnet/store >/dev/null 2>&1
$CL publish mirror --store mainnet/store >/dev/null 2>&1
node "$here/tools/beacon-replay.mjs" $bport & pids="$pids $!"; node "$here/tools/replay.mjs" $eport & pids="$pids $!"; up $bport
expect ok "claim admit ens:vitalik.eth --checkpoint …: light client → anchor → name → mirror's claims" "ADMITTED" -- \
  $CL admit ens:vitalik.eth site --policy mainnet/policy.json5 --store client-mainnet $M \
    --checkpoint 0xa8356934e2fba13cb82917ea04203c75ca84bb735cefe3cf2f35976628e1e937 --beacon-url http://127.0.0.1:$bport --now 15630000 --rpc 127.0.0.1:$eport
expect refused "the claims mirror does not hold its content" "no source has" -- $O cat "$vitalik" --store client-mainnet $M
# The content from a public trustless gateway (decision G): `claim run --out`, so the same command admits it and fetches
# it, every block from the gateway checked against its CID, and writes the tree out. The gateway is trusted for nothing
# but being there; a gateway that is not there is reported, and counts neither way.
gateway=${GATEWAY-https://trustless-gateway.link}
if [ -n "$gateway" ]; then
  code=$(curl -s -m 30 -o /dev/null -w '%{http_code}' -H 'Accept: application/vnd.ipld.raw' "$gateway/ipfs/$vitalik?format=raw" || true)
  if [ "$code" = 200 ]; then
    expect ok "claim run ens:vitalik.eth --out: admitted, then its content from $gateway, every block checked" "ADMITTED" -- \
      $CL run ens:vitalik.eth site --policy mainnet/policy.json5 --store client-mainnet $M --mirror "$gateway" --out mainnet/site \
        --checkpoint 0xa8356934e2fba13cb82917ea04203c75ca84bb735cefe3cf2f35976628e1e937 --beacon-url http://127.0.0.1:$bport --now 15630000 --rpc 127.0.0.1:$eport
    n=$(find mainnet/site -type f 2>/dev/null | wc -l)
    [ "$n" -gt 0 ] && ok "the site written out from checked blocks: $n file(s), $(du -sh mainnet/site | cut -f1)" || bad "nothing written out"
    expect ok "and now the client's own store has it: no mirror needed" -- $O ls "$vitalik" --store client-mainnet
  else
    echo "   SKIP ($gateway answered HTTP ${code:-nothing} for the raw block: content not fetched, nothing counted)"
  fi
fi

step "5. what it refuses"
# 5a. A tampered build output: the app's block, and then the build's tree, changed on a mirror.
cp -r mirror mirror-bad-app; printf 'not the app' > "mirror-bad-app/ipfs/$appCid"
expect refused "a mirror serving other bytes for the app: fetched and refused" "does not hash" -- $O cat "$appCid" --store client-5a --mirror mirror-bad-app
cp -r mirror mirror-bad-tree; printf 'not the tree' > "mirror-bad-tree/ipfs/$buildTree"
expect refused "a mirror whose build output tree is not what the derivations name" "no derived output has it at out/capstone.wasm" -- $CL admit "ens:$name" app $A --anchor "$anchor" --store client-5a2 --mirror mirror-bad-tree
# 5b. A missing endorsement: a mirror whose claims never included the reviewer's.
expect refused "a mirror without the reviewer's endorsement of the source" "endorsed by nobody" -- $CL admit "ens:$name" app $A --anchor "$anchor" --store client-5b --mirror mirror-unreviewed
# 5c. A lying mirror: wasmtime's derivation of the build swapped for other bytes under its name.
cp -r mirror mirror-lying
for c in $(sed -n 's/^signed //p' mirror-lying/claims/index); do other=$c; done
first=$(sed -n 's/^signed //p' mirror-lying/claims/index | head -1)
cp "mirror-lying/ipfs/$other" "mirror-lying/ipfs/$first"
expect refused "a mirror serving a forged statement: it is left out, and the rest decides" "left out: mirror 0" -- $CL admit "ens:$name" app $A --anchor "$anchor" --store client-5c --mirror mirror-lying
# 5d. A revoked runner: wasmtime's runner withdraws its derivation of the build, on chain.
expect ok "wasmtime's runner revokes its derivation of the app's build, on chain" -- $reg revoke wt.key "$registry" "$buildWt"
after=$(rpc $port eth_getBlockByNumber '["latest",false]' | sed -n 's/.*"hash":"\(0x[0-9a-f]*\)".*/\1/p')
expect refused "anchored after it: one runner of the two left" "on 1 runner" -- $CL admit "ens:$name" app $A --anchor "$after" --store client-5d $M
expect ok "anchored before it, the same read is that block's: admitted" "ADMITTED" -- $CL admit "ens:$name" app $A --anchor "$anchor" --store client-5d $M

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
