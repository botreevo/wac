#!/bin/sh
# The light client against Ethereum mainnet, live: fetch light-client data from a beacon node, then have `lc` verify it.
#
#     sh packages/lightclient/tools/mainnet.sh [WORKDIR] [TRUSTED_ROOT]
#     ETH_RPC=https://… ENS=vitalik.eth sh packages/lightclient/tools/mainnet.sh …
#
# With ETH_RPC (an execution node's JSON-RPC URL, read from the environment and never written down: it may hold a
# key), it carries on to state. It fetches the finalized execution block and an eth_getProof of ENS's owner and
# resolver slots for $ENS at that block, and `lc` believes both only as far as the light client's proven block hash
# and state root carry them.
#
# The node is only a source of bytes. `lc` believes nothing it says beyond what the sync committee signed and Merkle
# branches prove — except the trusted root. Pass TRUSTED_ROOT from somewhere you trust (a checkpoint you hold, a
# friend, a second node). Without one, this takes the node's own finalized checkpoint, and says so.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:-$(mktemp -d)}
NODE=${BEACON:-https://lodestar-mainnet.chainsafe.io}
mkdir -p "$work"
get() { curl -sSf -m 120 -H 'Accept: application/octet-stream' "$NODE$1" -o "$work/$2" -D "$work/$2.h"; }
json() { curl -sSf -m 60 "$NODE$1"; }

final=$(json /eth/v1/beacon/headers/finalized | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["header"]["message"]["slot"])')
period=$((final / 8192))
trusted=${2:-}
if [ -z "$trusted" ]; then
  # The finalized checkpoint, from the node itself. Older roots would exercise committee rotation, but a node that keeps
  # no history (lodestar-mainnet answers 404 for blocks a period back) cannot serve their bootstraps.
  trusted=$(json /eth/v1/beacon/headers/finalized | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["root"])')
  echo "trusted root $trusted, the node's finalized checkpoint on the node's word: pass one you trust as the second argument"
fi

get "/eth/v1/beacon/light_client/bootstrap/$trusted" bootstrap.ssz
bslot=$(json "/eth/v1/beacon/headers/$trusted" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["header"]["message"]["slot"])')
bperiod=$((bslot / 8192))
get "/eth/v1/beacon/light_client/updates?start_period=$bperiod&count=$((period - bperiod + 1))" updates.ssz
get /eth/v1/beacon/light_client/finality_update finality.ssz
get /eth/v1/beacon/light_client/optimistic_update optimistic.ssz
fork=$(grep -i '^eth-consensus-version' "$work/finality.ssz.h" | tr -d '\r' | awk '{print $2}')
for f in bootstrap updates optimistic; do
  v=$(grep -i '^eth-consensus-version' "$work/$f.ssz.h" | tr -d '\r' | awk '{print $2}')
  [ "$v" = "$fork" ] || { echo "the node answered $f as $v and finality as $fork: this tool reads one fork at a time" >&2; exit 1; }
done
now=$((($(date +%s) - 1606824023) / 12))
echo "node $NODE, $fork, finalized slot $final (period $period), clock slot $now"

cd "$root"
wac build --quiet --allow-read packages/lightclient/cmd/lc.wac -o "$work/lc"
lc() {
  wac "$work/lc.wasm" --trusted "$trusted" --fork "$fork" --bootstrap "$work/bootstrap.ssz" --updates "$work/updates.ssz" \
    --finality "$work/finality.ssz" --optimistic "$work/optimistic.ssz" --now "$now" "$@"
}
if [ -z "${ETH_RPC:-}" ]; then lc; exit; fi

lc | tee "$work/lc.out"
number=$(sed -n "s/^finalized *execution block \([0-9]*\) .*/\1/p" "$work/lc.out")
[ -n "$number" ] || { echo "lc named no finalized execution block" >&2; exit 1; }
name=${ENS:-vitalik.eth}
slots=$(wac "$work/lc.wasm" ens-slots "$name" | tr '\n' ' ')
owner=$(echo $slots | cut -d' ' -f1); resolver=$(echo $slots | cut -d' ' -f2)
rpc() { curl -sSf -m 60 -X POST -H 'content-type: application/json' --data "$1" "$ETH_RPC" -o "$work/$2"; }
rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBlockByNumber\",\"params\":[\"$(printf '0x%x' "$number")\",false]}" block.json
rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getProof\",\"params\":[\"0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e\",[\"$owner\",\"$resolver\"],\"$(printf '0x%x' "$number")\"]}" proof.json
echo "execution node: block $number and the ENS proofs for $name fetched"
lc --block "$work/block.json" --proof "$work/proof.json" --ens "$name" | grep -E '^(block|ens|  )' 
