#!/bin/sh
# The registry v2 (contracts/Registry.sol, src/registry2.wac), end to end on a wacuum devnet: deploy it, write to it with
# an ordinary wallet, and read every answer back by proof — then the node lies, and the address runs other code.
#
#     sh packages/reckon/tools/registry2.sh WORKDIR     (from anywhere; WACUUM defaults to packages/wacuum/dist/wacuum.wasm,
#                                                        PORT to 8555, the lying node to PORT+1)
#
# Needs: wac on PATH, node with tools/oracle's packages installed (ethers, multiformats, solc), curl.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
work=$1; rm -rf "$work"; mkdir -p "$work"; work=$(cd "$work" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
wacuum=${WACUUM:-$root/packages/wacuum/dist/wacuum.wasm}
port=${PORT:-8555}; liar=$((port + 1))
[ -f "$wacuum" ] || { echo "registry2: build wacuum first: wac task wacuum:build" >&2; exit 2; }
wallet="node $here/tools/registry2/wallet.mjs"
keys=$work/keys; mkdir -p "$keys"
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
same() {  # same DESCRIPTION A B
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "   PASS ($1: $2)"; else fail=$((fail+1)); echo "   FAIL ($1: $2 ≠ $3)"; fi
}

step "the reader, and a devnet: wacuum --dev"
mkdir -p "$here/dist"
wac build --allow-read --allow-write --allow-net --allow-env "$here/cmd/registry2.wac" -o "$here/dist/registry2" >/dev/null
R="wac $here/dist/registry2.wasm"
wac build --quiet --allow-read --allow-write --allow-net "$here/cmd/claim.wac" -o "$here/dist/claim" >/dev/null
wac build --quiet --allow-read --allow-write --allow-run "$here/cmd/derive.wac" -o "$here/dist/derive" >/dev/null
wac build --quiet "$here/corpus/files.wac" -o "$here/dist/files" >/dev/null
CL="wac $here/dist/claim.wasm"
mkdir -p "$work/devnet"
( cd "$work/devnet" && exec wac "$wacuum" --dev --datadir data --port "$port" > node.log 2>&1 ) &
node_pid=$!
trap 'kill $node_pid ${liar_pid:-} 2>/dev/null || true' EXIT
until curl -s -m1 -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "http://127.0.0.1:$port/" >/dev/null; do sleep 0.5; done
export RPC="http://127.0.0.1:$port"
printf '1111111111111111111111111111111111111111111111111111111111111111' > "$keys/dev"
for k in endorser list otherlist publisher stranger relayer runner reviewer; do
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$keys/$k"
  eval "addr_$k=\$($wallet address $keys/$k)"
  $wallet fund "$keys/dev" "$($wallet address $keys/$k)" 10 >/dev/null
done
set -- $($wallet deploy "$keys/dev"); registry=$1; codehash=$2
echo "registry $registry, runtime code $codehash"
C="--rpc 127.0.0.1:$port --registry $registry --code-hash $codehash"
for n in 1 2 3 4; do head -c 64 /dev/urandom > "$work/app$n.bin"; done
set -- $($R endorse "$work/app1.bin" --key "$keys/endorser" --out "$work/e1"); app1=$1; s1=$2
set -- $($R endorse "$work/app2.bin" --key "$keys/endorser" --out "$work/e2"); app2=$1; s2=$2
set -- $($R endorse "$work/app3.bin" --key "$keys/endorser" --out "$work/e3"); app3=$1; s3=$2
A="--endorser $addr_endorser --list $addr_list --store $work/objects $C"
echo "app1 $app1 (endorsement $s1)"; echo "app2 $app2 (endorsement $s2)"; echo "app3 $app3 (endorsement $s3)"

step "1. endorsed, nothing on the chain: admitted, every slot proved absent"
expect ok "admit app1" "0 revocation(s), 0 rejection(s) set" -- $R admit "$work/app1.bin" --statement "$work/e1" $A

step "2. revocations"
expect ok "a stranger revokes the endorser's statement: that is a record under the stranger's address" -- $wallet revoke "$keys/stranger" "$registry" "$s1"
expect ok "app1 is still admitted" "0 revocation(s)" -- $R admit "$work/app1.bin" --statement "$work/e1" $A
slot=$($R slot revoked "$addr_endorser" "$s1")
same "before: eth_getStorageAt at the slot registry2.wac computes" "$($wallet storage "$keys/dev" "$registry" "$slot")" "0x0000000000000000000000000000000000000000000000000000000000000000"
expect ok "the endorser revokes it" -- $wallet revoke "$keys/endorser" "$registry" "$s1"
v=$($wallet storage "$keys/dev" "$registry" "$slot")
if [ "$v" != "0x0000000000000000000000000000000000000000000000000000000000000000" ]; then pass=$((pass+1)); echo "   PASS (after: the same slot holds the revocation's time, $v)"
else fail=$((fail+1)); echo "   FAIL (after: the slot registry2.wac computes is still empty: the slot math disagrees with Solidity)"; fi
expect refused "admit app1 after its only endorsement is revoked" "endorsed by nobody" -- $R admit "$work/app1.bin" --statement "$work/e1" $A
expect refused "a revocation is permanent: it cannot be written twice" "already revoked" -- $wallet revoke "$keys/endorser" "$registry" "$s1"
expect ok "a revocation signed by the endorser (EIP-712, by ethers), sent by a relayer" -- $wallet revoke-signed "$keys/endorser" "$keys/relayer" "$registry" "$s2"
expect refused "admit app2 after the relayed revocation" "endorsed by nobody" -- $R admit "$work/app2.bin" --statement "$work/e2" $A

step "3. rejection lists: on, by a list you do not follow, off"
expect ok "admit app3" -- $R admit "$work/app3.bin" --statement "$work/e3" $A
expect ok "another list rejects app3" -- $wallet reject "$keys/otherlist" "$registry" "$app3" "not ours to say"
expect ok "a list the policy does not follow changes nothing" "0 rejection(s) set" -- $R admit "$work/app3.bin" --statement "$work/e3" $A
expect ok "the followed list rejects app3" -- $wallet reject "$keys/list" "$registry" "$app3" "malware"
rslot=$($R slot rejected "$addr_list" "$app3")
reason=$(node -e "const s = BigInt(process.argv[1]) + 1n; console.log('0x' + s.toString(16).padStart(64, '0'))" "$rslot")
same "the reason is at since+1, keccak256(\"malware\")" "$($wallet storage "$keys/dev" "$registry" "$reason")" "$(node -e "import('$here/tools/oracle/node_modules/ethers/lib.esm/index.js').then(e=>console.log(e.keccak256(e.toUtf8Bytes('malware'))))")"
expect refused "admit app3 on a followed rejection list" "is on a rejection list you follow (on the chain)" -- $R admit "$work/app3.bin" --statement "$work/e3" $A
expect ok "the list takes it off again" -- $wallet unreject "$keys/list" "$registry" "$app3"
expect ok "admit app3 once more" "0 rejection(s) set" -- $R admit "$work/app3.bin" --statement "$work/e3" $A

step "4. delayed names"
nameA=$($R cid "$work/app1.bin"); nameB=$($R cid "$work/app4.bin")
P=$addr_publisher
expect refused "a name nobody claimed" "is not a name" -- $R resolve "hello@$P" $C
expect ok "claim hello → app1, changes to wait 8 s" -- $wallet claim "$keys/publisher" "$registry" hello "$nameA" 8
expect ok "it resolves at once" "$nameA delay 8s" -- $R resolve "hello@$P" $C
expect refused "a stranger cannot move someone else's name: under the stranger's address it is unclaimed" "not claimed" -- $wallet propose "$keys/stranger" "$registry" hello "$nameB"
expect refused "nor claim it again" "already claimed" -- $wallet claim "$keys/publisher" "$registry" hello "$nameB" 0
expect ok "the publisher proposes app4, and a delay of 1 s" -- sh -c "$wallet propose $keys/publisher $registry hello $nameB && $wallet propose-delay $keys/publisher $registry hello 1"
expect ok "during the delay: still app1, with app4 and the shorter delay visible as pending" "pending $nameB" -- $R resolve "hello@$P" $C
expect ok "…and the delay still 8 s" "$nameA delay 8s" -- $R resolve "hello@$P" $C
echo "   waiting out the 8 s delay"; sleep 9
expect ok "after it, with no write since: app4, and the new delay" "$nameB delay 1s" -- $R resolve "hello@$P" $C

step "5. claim admit, under a policy file, with --rpc: an endorsed object"
cs="--store $work/claims"
cid5=$($R cid "$work/app4.bin")
s5=$($CL endorse "$cid5" "reviewed" --key "$keys/endorser" $cs 2>/dev/null)
cat > "$work/policy.json5" <<POLICY
{
  signers: { endorser: "$addr_endorser" },
  reject_lists: ["$addr_list"],
  roles: { app: [{ endorsed: { by: ["endorser"], at_least: 1 } }] },
}
POLICY
CH="--rpc 127.0.0.1:$port --registry $registry --code-hash $codehash"
expect ok "claim admit with the chain: nothing set" "0 revocation(s), 0 rejection(s) set" -- $CL admit "$cid5" app --policy "$work/policy.json5" $cs $CH
expect ok "the followed list rejects it" -- $wallet reject "$keys/list" "$registry" "$cid5" "second thoughts"
expect refused "claim admit refuses it" "on a rejection list you follow (on the chain)" -- $CL admit "$cid5" app --policy "$work/policy.json5" $cs $CH
expect ok "unrejected" -- $wallet unreject "$keys/list" "$registry" "$cid5"
expect ok "the endorser revokes the endorsement on chain" -- $wallet revoke "$keys/endorser" "$registry" "$s5"
expect refused "claim admit refuses it" "endorsed by nobody" -- $CL admit "$cid5" app --policy "$work/policy.json5" $cs $CH
expect ok "without --rpc the chain is not asked, and it is admitted: the revocation lives only on chain" -- $CL admit "$cid5" app --policy "$work/policy.json5" $cs
expect refused "a chain asked for and unreachable refuses rather than admits" "ECONNREFUSED" -- $CL admit "$cid5" app --policy "$work/policy.json5" $cs --rpc 127.0.0.1:$((port + 40)) --registry "$registry" --code-hash "$codehash"

step "5b. claim admit with --rpc: a derivation, its program rejected on chain and then its derivation revoked"
ds="--store $work/dstore"
mkdir -p "$work/din/sub"; printf 'hello\n' > "$work/din/sub/a.txt"; printf 'x\n' > "$work/dargs"
recipe=$(wac "$here/dist/derive.wasm" recipe --program "$here/dist/files.wasm" --args "$work/dargs" --in "$work/din" $ds 2>/dev/null)
set -- $(wac "$here/dist/derive.wasm" run "$recipe" $ds --key "$keys/runner" --runner "reckon-derive/0 v8" 2>/dev/null); output=$1; deriv=$2
program=$($CL slots "$recipe" $ds 2>/dev/null | sed -n 's/^program //p')
for slot in program args in; do
  $CL endorse "$($CL slots "$recipe" $ds 2>/dev/null | sed -n "s/^$slot //p")" reviewed --key "$keys/reviewer" $ds >/dev/null 2>&1
done
echo "recipe $recipe → output $output (derivation $deriv); program $program"
cat > "$work/dpolicy.json5" <<POLICY
{
  signers: { runner: "$addr_runner", reviewer: "$addr_reviewer" },
  machines: ["wasm-gc/wac-host/0"],
  formats: ["unixfs-v1-2025+hidden"],
  reject_lists: ["$addr_list"],
  roles: {
    result: [{ derived: { by: ["runner"], at_least: 1, runners: 1, slots: { program: "program" }, other: "input" } }],
    program: [{ endorsed: { by: ["reviewer"], at_least: 1 } }],
    input: [{ endorsed: { by: ["reviewer"], at_least: 1 } }],
  },
}
POLICY
DA="$CL admit $output result --policy $work/dpolicy.json5 $ds $CH"
expect ok "the derivation is admitted: witnessed, and every input endorsed" "ADMITTED" -- $DA
expect ok "the followed list rejects the program it was derived with" -- $wallet reject "$keys/list" "$registry" "$program" "backdoored"
expect refused "the output is refused at its program" "on a rejection list you follow (on the chain)" -- $DA
expect ok "unrejected" -- $wallet unreject "$keys/list" "$registry" "$program"
expect ok "admitted again" "ADMITTED" -- $DA
expect ok "the runner revokes its derivation on chain" -- $wallet revoke "$keys/runner" "$registry" "$deriv"
expect refused "refused: no unrevoked witness" "witnessed by nobody" -- $DA

step "6. a node that hides storage"
node "$here/tools/liar.mjs" "$liar" "$port" & liar_pid=$!
until curl -s -m1 -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "http://127.0.0.1:$liar/" >/dev/null; do sleep 0.2; done
L=$(printf '%s' "$A" | sed "s/127.0.0.1:$port/127.0.0.1:$liar/")
expect refused "admit app1 through a node hiding its revocation: its storage proof does not verify" "registry2: slot 0x" -- $R admit "$work/app1.bin" --statement "$work/e1" $L
expect refused "resolve through a node hiding the name" "registry2: slot 0x" -- $R resolve "hello@$P" --rpc "127.0.0.1:$liar" --registry "$registry" --code-hash "$codehash"
expect ok "where every slot is empty the lie changes nothing, and app3 is admitted" -- $R admit "$work/app3.bin" --statement "$work/e3" $L

step "7. the registry's address running other code, or none"
other=0x$(printf 'ab%.0s' $(seq 32))
expect refused "a code hash that is not the registry's" "runs other code" -- $R admit "$work/app3.bin" --statement "$work/e3" --endorser "$addr_endorser" --list "$addr_list" --store "$work/objects" --rpc "127.0.0.1:$port" --registry "$registry" --code-hash "$other"
expect refused "an address with no account" "there is no account" -- $R resolve "hello@$P" --rpc "127.0.0.1:$port" --registry 0x00000000000000000000000000000000000000ee --code-hash "$codehash"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
