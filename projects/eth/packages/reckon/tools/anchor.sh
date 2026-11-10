#!/bin/sh
# Anchored chain reads (docs/anchoring.md): proofs checked against a header fixed by a block hash, and that hash, on
# mainnet, proved by the light client from a checkpoint.
#
#   1. Mainnet, offline: `lc` proves the finalized execution block's hash from the recorded checkpoint, and
#      `name resolve vitalik.eth --anchor <it>` reads the ENS registry and resolver through a node that replays the
#      recorded block and proofs (tools/replay.mjs). The same CID as lc's own; then a node that answers the anchor with
#      another header, one that changes a proof, and anchors lc did not prove, each refused.
#   2. A wacuum devnet, where no light client can supply an anchor: a block hash taken at a moment you choose fixes
#      every later anchored read to that block's state. A revocation written after it is not seen through it, and a
#      block whose state the node no longer keeps is refused rather than answered from another.
#
#     sh packages/reckon/tools/anchor.sh WORKDIR     (PORT defaults to 8795: the replaying node; the devnet is PORT+1)
#
# Needs: wac on PATH, node with tools/oracle's packages installed, curl.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=$1; rm -rf "$work"; mkdir -p "$work"; work=$(cd "$work" && pwd)
wacuum=${WACUUM:-$root/packages/wacuum/dist/wacuum.wasm}
port=${PORT:-8795}; devport=$((port + 1))
[ -f "$wacuum" ] || { echo "anchor: build wacuum first: wac task wacuum:build" >&2; exit 2; }
for p in $port $devport; do
  if curl -s -m1 -o /dev/null "http://127.0.0.1:$p/" 2>/dev/null; then echo "anchor: port $p is taken; set PORT" >&2; exit 2; fi
done
pids=""
cleanup() { [ -n "$pids" ] && kill $pids 2>/dev/null || true; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM HUP
pass=0; fail=0
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
expect() {  # expect ok|refused DESCRIPTION [BECAUSE] -- command…
  want=$1; what=$2; because=""; shift 2
  if [ "$1" != "--" ]; then because=$1; shift; fi
  shift
  if out=$("$@" 2>&1); then got=ok; else got=refused; fi
  printf '%s\n' "$out" | sed 's/^/   | /'
  if [ "$got" != "$want" ]; then fail=$((fail+1)); echo "   FAIL ($what: wanted $want, got $got)"
  elif [ -n "$because" ] && ! printf '%s' "$out" | grep -qF -- "$because"; then fail=$((fail+1)); echo "   FAIL ($what: $got, but not because \"$because\")"
  else pass=$((pass+1)); echo "   PASS ($what: $got${because:+, because \"$because\"})"; fi
}
same() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "   PASS ($1: $2)"; else fail=$((fail+1)); echo "   FAIL ($1: '$2' ≠ '$3')"; fi; }
rpc() { curl -s -m2 -X POST -H 'content-type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}" "http://127.0.0.1:$1/"; }
up() { until rpc "$1" eth_blockNumber '[]' >/dev/null; do sleep 0.3; done; }

cd "$root"
wac build --quiet --allow-read packages/lightclient/cmd/lc.wac -o "$work/lc"
wac build --quiet --allow-read --allow-write --allow-net "$here/cmd/name.wac" -o "$work/name"
wac build --quiet --allow-read --allow-write --allow-net "$here/cmd/claim.wac" -o "$work/claim"
LC="wac $work/lc.wasm"; N="wac $work/name.wasm"; CL="wac $work/claim.wasm"

step "1. mainnet, offline: the anchor from the light client"
D=packages/lightclient/test/mainnet
checkpoint=0xa8356934e2fba13cb82917ea04203c75ca84bb735cefe3cf2f35976628e1e937
lc() { $LC --trusted "$1" --fork fulu --bootstrap $D/bootstrap.ssz --updates $D/updates.ssz --finality $D/finality.ssz \
         --optimistic $D/optimistic.ssz --now 15630000 "$@"; }
anchor=$(lc $checkpoint | sed -n 's/^finalized *execution block [0-9]* hash \(0x[0-9a-f]*\) .*/\1/p')
optimistic=$(lc $checkpoint | sed -n 's/^optimistic *execution block [0-9]* hash \(0x[0-9a-f]*\) .*/\1/p')
echo "   lc proves the finalized execution block $anchor from checkpoint $checkpoint"
lcCid=$(lc $checkpoint --block $D/block.json --proof $D/proof.json --ens vitalik.eth --contenthash $D/contenthash.json | sed -n 's|^content .* → ipfs://||p')
# The code hashes ENS's registry and vitalik.eth's resolver run, pinned (docs/anchoring.md); the run checks the proofs
# agree with them, at the anchored block.
regcode=0xd6bfd5d6f1384a1f6ea57b8a8412de5552f138d42021cf7c4941e33206f529e4
rescode=0x19257636fde18e27704b400659de2cbaab55488586c18cd5b6d67f6417c8c19a
M="--registry 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e --registry-code $regcode --resolver-code $rescode"
node "$here/tools/replay.mjs" $port honest & pids="$pids $!"; up $port
expect ok "vitalik.eth by proof, anchored to lc's block" "ipfs://$lcCid" -- $N resolve vitalik.eth --rpc 127.0.0.1:$port $M --anchor "$anchor"
got=$($N resolve vitalik.eth --rpc 127.0.0.1:$port $M --anchor "$anchor" 2>/dev/null | sed -n 's|^ipfs://||p')
same "the same CID lc proves on its own" "$got" "$lcCid"
expect ok "unanchored, it says so" "(no anchor)" -- $N resolve vitalik.eth --rpc 127.0.0.1:$port $M
expect refused "an anchor lc did not prove (the optimistic block, which this node does not hold)" "does not have the anchored block" -- \
  $N resolve vitalik.eth --rpc 127.0.0.1:$port $M --anchor "$optimistic"
expect refused "no anchor at all from a checkpoint lc does not accept" "not the trusted block's" -- lc 0x$(printf 'ab%.0s' $(seq 32))
kill $pids 2>/dev/null; pids=""; sleep 0.3
node "$here/tools/replay.mjs" $port header & pids="$pids $!"; up $port
expect refused "a node that answers the anchor with another header" "re-encodes to a different hash" -- $N resolve vitalik.eth --rpc 127.0.0.1:$port $M --anchor "$anchor"
kill $pids 2>/dev/null; pids=""; sleep 0.3
node "$here/tools/replay.mjs" $port proof & pids="$pids $!"; up $port
expect refused "a node that changes a storage proof under the right header" "proof" -- $N resolve vitalik.eth --rpc 127.0.0.1:$port $M --anchor "$anchor"
kill $pids 2>/dev/null; pids=""

step "2. a devnet: an anchor taken at a moment you choose"
mkdir -p "$work/devnet"
( cd "$work/devnet" && exec wac "$wacuum" --dev --datadir data --port "$devport" > node.log 2>&1 ) & pids="$!"
up $devport
sleep 2.5
n=$(rpc $devport eth_blockNumber '[]' | sed -n 's/.*"result":"\(0x[0-9a-f]*\)".*/\1/p')
if rpc $devport eth_getBalance "[\"0x0000000000000000000000000000000000000000\",\"$(printf '0x%x' $((n - 1)))\"]" | grep -q "not available"; then
  echo "anchor: $wacuum keeps only its head's state; rebuild it (wac task wacuum:build)" >&2; exit 2
fi
export RPC="http://127.0.0.1:$devport"
wallet="node $here/tools/registry2/wallet.mjs"
keys=$work/keys; mkdir -p "$keys"
printf '1111111111111111111111111111111111111111111111111111111111111111' > "$keys/dev"
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$keys/endorser"
$wallet fund "$keys/dev" "$($wallet address "$keys/endorser")" 10 >/dev/null
set -- $($wallet deploy "$keys/dev"); registry=$1; codehash=$2
subject=bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku
sid=$($CL endorse "$subject" reviewed --key "$keys/endorser" --store "$work/store" 2>/dev/null)
cat > "$work/policy.json5" <<POLICY
{ signers: { endorser: "$($wallet address "$keys/endorser")" }, roles: { app: [{ endorsed: { by: ["endorser"], at_least: 1 } }] } }
POLICY
A="--policy $work/policy.json5 --store $work/store --rpc 127.0.0.1:$devport --registry $registry --code-hash $codehash"
before=$(rpc $devport eth_getBlockByNumber '["latest",false]' | sed -n 's/.*"hash":"\(0x[0-9a-f]*\)".*/\1/p')
echo "   anchor taken: $before"
expect ok "anchored, before anything is revoked: admitted" "ADMITTED" -- $CL admit "$subject" app $A --anchor "$before"
expect ok "the endorser revokes on chain" -- $wallet revoke "$keys/endorser" "$registry" "$sid"
expect refused "unanchored, the node's latest block: the revocation is there" "endorsed by nobody" -- $CL admit "$subject" app $A
expect ok "anchored to the block before it: that block's state, admitted" "ADMITTED" -- $CL admit "$subject" app $A --anchor "$before"
expect refused "an anchor the node does not have" "does not have the anchored block" -- $CL admit "$subject" app $A --anchor 0x$(printf '12%.0s' $(seq 32))
echo "   waiting until the anchored block's state is more than 16 blocks old"
target=$(( $(rpc $devport eth_blockNumber '[]' | sed -n 's/.*"result":"\(0x[0-9a-f]*\)".*/\1/p') + 18 ))
until [ $(( $(rpc $devport eth_blockNumber '[]' | sed -n 's/.*"result":"\(0x[0-9a-f]*\)".*/\1/p') )) -ge $target ]; do sleep 1; done
expect refused "anchored to a block whose state the node no longer keeps: refused, not read from another" "not available" -- $CL admit "$subject" app $A --anchor "$before"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
