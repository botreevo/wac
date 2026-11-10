#!/bin/sh
# A name, to content, to a decision: an ENS name resolved by proof to a CID, the tree under that CID fetched from a
# mirror with every block re-hashed, and the tree admitted (or not) under a policy. Offline, in two halves.
#
#   1. Mainnet, recorded: vitalik.eth from a trusted beacon root alone. `lc` (packages/lightclient) verifies the sync
#      committee's signatures, the execution block, then the ENS registry and resolver proofs, using the data
#      packages/lightclient/test/mainnet keeps. That ends at a proven CID. Its content is not here, so nothing is
#      fetched or admitted for it: the second half shows that part.
#   2. A wacuum devnet: contracts/DevENS.sol, a registry and resolver with mainnet's storage layout, so that the same
#      packages/ens code reads them (through cmd/name.wac). A name is pointed at a tree built here and kept in a mirror;
#      `name resolve` proves the CID, `obj` fetches the tree from the mirror (a directory, then over HTTP), and
#      `claim admit` decides it.
#
# **The devnet half is anchored differently, and weaker.** A devnet has no beacon chain, so no light client can prove
# its headers. The header is the node's latest block, checked only against its own hash, and what is checked beyond
# the proofs is that the registry and resolver accounts run the code deployed here (their code hashes), as
# registry2.wac does. That proves the node consistent with itself and with those contracts, not that its chain is
# anyone else's. On mainnet the first half's light client is what supplies the header.
#
#     sh packages/reckon/tools/byname.sh WORKDIR      (PORT defaults to 8575; the lying node is PORT+1, the mirror PORT+2)
#
# Needs: wac on PATH, node with tools/oracle's packages installed, python3 and curl.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=$1; rm -rf "$work"; mkdir -p "$work"; work=$(cd "$work" && pwd)
wacuum=${WACUUM:-$root/packages/wacuum/dist/wacuum.wasm}
port=${PORT:-8575}; liar=$((port + 1)); web=$((port + 2))
[ -f "$wacuum" ] || { echo "byname: build wacuum first: wac task wacuum:build" >&2; exit 2; }
for p in $port $liar $web; do
  if curl -s -m1 -o /dev/null "http://127.0.0.1:$p/" 2>/dev/null; then echo "byname: port $p is taken; set PORT" >&2; exit 2; fi
done
pass=0; fail=0
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
expect() {  # expect ok|refused DESCRIPTION [BECAUSE] -- command…   (BECAUSE: a phrase the output must contain)
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

cd "$root"
mkdir -p "$work/bin"
wac build --quiet --allow-read packages/lightclient/cmd/lc.wac -o "$work/bin/lc"
wac build --quiet --allow-read --allow-write --allow-net "$here/cmd/name.wac" -o "$work/bin/name"
wac build --quiet --allow-read --allow-write --allow-net packages/ipfs/cmd/obj.wac -o "$work/bin/obj"
wac build --quiet --allow-read --allow-write "$here/cmd/claim.wac" -o "$work/bin/claim"
LC="wac $work/bin/lc.wasm"; N="wac $work/bin/name.wasm"; O="wac $work/bin/obj.wasm"; CL="wac $work/bin/claim.wasm"

step "1. mainnet, recorded: vitalik.eth from a trusted beacon root"
D=packages/lightclient/test/mainnet
trusted=0xa8356934e2fba13cb82917ea04203c75ca84bb735cefe3cf2f35976628e1e937
lc() { $LC --trusted "$1" --fork fulu --bootstrap $D/bootstrap.ssz --updates $D/updates.ssz --finality $D/finality.ssz \
         --optimistic $D/optimistic.ssz --now 15630000 --block $D/block.json --proof $D/proof.json --ens vitalik.eth \
         --contenthash $D/contenthash.json; }
expect ok "vitalik.eth's content, proved from the trusted root alone" "vitalik.eth → ipfs://" -- lc "$trusted"
mainnet=$(lc "$trusted" 2>/dev/null | sed -n 's|^content .* → ipfs://||p')
same "a CID" "$(printf '%s' "$mainnet" | cut -c1-4)" "bafy"
expect refused "any other root: the bootstrap is not its block's" "not the trusted block's" -- lc 0x$(printf 'ab%.0s' $(seq 32))
echo "   (the content of $mainnet is not kept here, so the rest is shown on a devnet)"

step "2. a devnet with ENS's storage layout: wacuum --dev on $port"
mkdir -p "$work/devnet"
( cd "$work/devnet" && exec wac "$wacuum" --dev --datadir data --port "$port" > node.log 2>&1 ) &
node_pid=$!
trap 'kill $node_pid ${liar_pid:-} ${web_pid:-} 2>/dev/null || true' EXIT INT TERM
until curl -s -m1 -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "http://127.0.0.1:$port/" >/dev/null; do sleep 0.5; done
# A wacuum built before it kept recent states (1fd0013) proves only its head, so a proof can lose the race with the
# next block. dist/ is not in git: refuse a stale one, with the fix, rather than flake on it.
_n() { curl -s -m2 -X POST -H 'content-type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}" "http://127.0.0.1:$1/"; }
until [ "$(_n $port eth_blockNumber '[]' | sed -n 's/.*"result":"0x\([0-9a-f]*\)".*/\1/p')" != 0 ]; do sleep 0.5; done
sleep 2.5
_b=$(_n $port eth_blockNumber '[]' | sed -n 's/.*"result":"\(0x[0-9a-f]*\)".*/\1/p')
if _n $port eth_getBalance "[\"0x0000000000000000000000000000000000000000\",\"$(printf '0x%x' $((_b - 1)))\"]" | grep -q "not available"; then
  echo "byname: $wacuum keeps only its head's state; rebuild it (wac task wacuum:build)" >&2; exit 2
fi
export RPC="http://127.0.0.1:$port"
wallet="node $here/tools/byname/wallet.mjs"
keys=$work/keys; mkdir -p "$keys"
printf '1111111111111111111111111111111111111111111111111111111111111111' > "$keys/dev"
for k in publisher reviewer stranger; do
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$keys/$k"
  eval "addr_$k=\$($wallet address $keys/$k)"
  $wallet fund "$keys/dev" "$($wallet address $keys/$k)" 10 >/dev/null
done
set -- $($wallet deploy "$keys/dev"); registry=$1; regcode=$2; resolver=$3; rescode=$4
echo "registry $registry ($regcode)"; echo "resolver $resolver ($rescode)"
C="--rpc 127.0.0.1:$port --registry $registry --registry-code $regcode --resolver-code $rescode"
name=app.reckon.eth

step "3. a tree, kept in a mirror; the name pointed at it"
mkdir -p "$work/app/js" "$work/other"
printf '<!doctype html><title>app</title><script src="js/app.js"></script>\n' > "$work/app/index.html"
printf 'console.log("from a name, by proof");\n' > "$work/app/js/app.js"
head -c 2500000 /dev/zero | tr '\0' 'a' > "$work/app/data.bin"                       # three blocks of a file
printf 'something else\n' > "$work/other/index.html"
tree=$($O add "$work/app" --store "$work/mirror"); other=$($O add "$work/other" --store "$work/mirror")
echo "tree $tree"; echo "other $other"
expect refused "before it is claimed, the name has no owner, proved absent" "has no owner, proved absent" -- $N resolve $name $C
expect ok "the publisher claims $name with the resolver" -- $wallet claim "$keys/publisher" "$registry" $name "$resolver"
expect refused "claimed, with no contenthash yet: proved empty" "has no contenthash" -- $N resolve $name $C
expect ok "the publisher sets its contenthash to the tree (EIP-1577, 38 bytes: the long-bytes path)" -- $wallet set-contenthash "$keys/publisher" "$resolver" $name "$tree"
expect refused "a stranger cannot set it" "not the node's owner" -- $wallet set-contenthash "$keys/stranger" "$resolver" $name "$other"

step "4. name → proven CID → fetched tree → admission"
expect ok "the name resolves by proof" "ipfs://$tree" -- $N resolve $name $C
cid=$($N resolve $name $C 2>/dev/null | sed -n 's|^ipfs://||p')
same "the proven CID is the tree's" "$cid" "$tree"
expect ok "fetched from the mirror directory into an empty store, every block re-hashed" -- $O ls "$cid" --store "$work/store" --mirror "$work/mirror"
( cd "$work/mirror" && exec python3 -m http.server "$web" --bind 127.0.0.1 >/dev/null 2>&1 ) & web_pid=$!
until curl -s -m1 -o /dev/null "http://127.0.0.1:$web/"; do sleep 0.2; done
expect ok "and over HTTP, as a trustless gateway, into another" "from a name, by proof" -- $O cat "$cid" js/app.js --store "$work/store-http" --mirror "http://127.0.0.1:$web"
same "every file the same as built" "$($O cat "$cid" data.bin --store "$work/store" | cmp - "$work/app/data.bin" && echo same)" "same"
$CL endorse "$cid" "reviewed the app" --key "$keys/reviewer" --store "$work/store" >/dev/null 2>&1
cat > "$work/policy.json5" <<POLICY
{ signers: { reviewer: "$addr_reviewer" }, roles: { app: [{ endorsed: { by: ["reviewer"], at_least: 1 } }] } }
POLICY
expect ok "admitted: the reviewer endorsed what the name proves" "ADMITTED" -- $CL admit "$cid" app --policy "$work/policy.json5" --store "$work/store"
byname() { c=$($N resolve "$1" $C 2>/dev/null | sed -n 's|^ipfs://||p') && [ -n "$c" ] && $O ls "$c" --store "$work/store" --mirror "$work/mirror" >/dev/null \
           && $CL admit "$c" app --policy "$work/policy.json5" --store "$work/store"; }
expect ok "the three as one: by name" "ADMITTED" -- byname $name

step "5. what it refuses"
expect ok "the publisher points the name at another tree" -- $wallet set-contenthash "$keys/publisher" "$resolver" $name "$other"
expect refused "by name now: the new tree is fetched, but nobody reviewed it" "endorsed by nobody" -- byname $name
cp -r "$work/mirror" "$work/mirror-bad"
leaf=$(basename "$(grep -lx 'something else' "$work/mirror-bad"/ipfs/* | head -1)")
printf 'something worse\n' > "$work/mirror-bad/ipfs/$leaf"
expect refused "a mirror whose copy was tampered with" "does not hash to" -- $O cat "$other" index.html --store "$work/store-bad" --mirror "$work/mirror-bad"
expect ok "the publisher clears its records: the next version" -- $wallet clear "$keys/publisher" "$resolver" $name
expect refused "the old version's bytes are still in storage, and not read: no contenthash" "has no contenthash" -- $N resolve $name $C
node "$here/tools/liar.mjs" "$liar" "$port" & liar_pid=$!
until curl -s -m1 -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "http://127.0.0.1:$liar/" >/dev/null; do sleep 0.2; done
expect refused "a node hiding the registry's record: its storage proof does not verify" "the registry's proof" -- $N resolve $name --rpc "127.0.0.1:$liar" --registry "$registry" --registry-code "$regcode" --resolver-code "$rescode"
expect refused "a resolver code hash that is not the one deployed" "runs other code" -- $N resolve $name --rpc "127.0.0.1:$port" --registry "$registry" --registry-code "$regcode" --resolver-code "$regcode"
expect refused "a registry address that is the resolver's" "runs other code" -- $N resolve $name --rpc "127.0.0.1:$port" --registry "$resolver" --registry-code "$regcode" --resolver-code "$rescode"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
