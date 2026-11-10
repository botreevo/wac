#!/bin/sh
# One command from a checkpoint to a decision (docs/admit.md), offline, on recorded mainnet data:
#
#     claim admit ens:vitalik.eth app --policy P --checkpoint ROOT --beacon DIR --rpc NODE [--mirror …]
#
# The light client proves the finalized execution block from the checkpoint; the name's content is read by proof at
# that block from a node that replays what was recorded (tools/replay.mjs); the claims are the local ones and a
# mirror's; the policy decides. Then each way it must refuse: no endorsement, another checkpoint, a node that lies
# about the header or a proof, a name it has no record of, and two anchors at once.
#
#     sh packages/reckon/tools/admit-by-name.sh WORKDIR      (PORT defaults to 8800)
#
# Needs: wac on PATH, node, curl.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=$1; rm -rf "$work"; mkdir -p "$work"; work=$(cd "$work" && pwd)
port=${PORT:-8800}
if curl -s -m1 -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then echo "admit-by-name: port $port is taken; set PORT" >&2; exit 2; fi
pid=""
cleanup() { [ -n "$pid" ] && kill $pid 2>/dev/null || true; }
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
replay() {
  cleanup; pid=""; sleep 0.3
  node "$here/tools/replay.mjs" $port "$1" & pid=$!
  until curl -s -m1 -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "http://127.0.0.1:$port/" >/dev/null; do sleep 0.2; done
}

cd "$root"
wac build --quiet --allow-read --allow-write --allow-net "$here/cmd/claim.wac" -o "$work/claim"
CL="wac $work/claim.wasm"
cd "$work"
beacon="$root/packages/lightclient/test/mainnet"
checkpoint=0xa8356934e2fba13cb82917ea04203c75ca84bb735cefe3cf2f35976628e1e937
content=bafybeia5eyombgegdwmvfzwisveadaaok2vdjkv5rklfdmcljysjrjc4km      # what vitalik.eth points at, recorded
printf '%s\n' c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3 > reviewer.key
cat > policy.json5 <<POLICY
{ signers: { reviewer: "$($CL address --key reviewer.key)" }, roles: { app: [{ endorsed: { by: ["reviewer"], at_least: 1 } }] } }
POLICY
A="--policy policy.json5 --checkpoint $checkpoint --beacon $beacon --now 15630000 --rpc 127.0.0.1:$port"

step "a reviewer has endorsed what vitalik.eth points at"
$CL endorse "$content" "reviewed the site" --key reviewer.key --store local >/dev/null 2>&1
replay honest
expect ok "one command: checkpoint → light client → anchored name → claims → policy" "ADMITTED" -- $CL admit ens:vitalik.eth app $A --store local
out=$($CL admit ens:vitalik.eth app $A --store local 2>&1 || true)
for line in "bootstrap proven against checkpoint $checkpoint" "finalized execution block 0xe6343fc3" "name: vitalik.eth → ipfs://$content" "proved at block 26382137 0xe6343fc3d0632523…;"; do
  if printf '%s' "$out" | grep -qF -- "$line"; then pass=$((pass+1)); echo "   PASS (it says: $line)"; else fail=$((fail+1)); echo "   FAIL (it does not say: $line)"; fi
done
expect refused "nobody has endorsed it in an empty store" "endorsed by nobody" -- $CL admit ens:vitalik.eth app $A --store empty
$CL publish mirror --store local >/dev/null 2>&1
expect ok "the endorsement from a mirror, into an empty store" "ADMITTED" -- $CL admit ens:vitalik.eth app $A --store empty2 --mirror mirror
expect ok "the CID itself, under the same anchor" "ADMITTED" -- $CL admit "$content" app $A --store local

step "what it refuses"
expect refused "a checkpoint the bootstrap is not for" "not the checkpoint's" -- $CL admit ens:vitalik.eth app --policy policy.json5 --checkpoint 0x$(printf 'ab%.0s' $(seq 32)) --beacon "$beacon" --now 15630000 --rpc 127.0.0.1:$port --store local
expect refused "a name the node has no record of" "not recorded" -- $CL admit ens:nick.eth app $A --store local
expect refused "--checkpoint and --anchor at once" "not both" -- $CL admit ens:vitalik.eth app $A --anchor 0x$(printf '12%.0s' $(seq 32)) --store local
replay header
expect refused "a node that answers the anchor with another header" "re-encodes to a different hash" -- $CL admit ens:vitalik.eth app $A --store local
replay proof
expect refused "a node that changes a storage proof" "the name:" -- $CL admit ens:vitalik.eth app $A --store local

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
