#!/bin/sh
# Milestone 4 of docs/browser-extension.md: each open is a fresh admission, so a revocation on chain takes effect at
# the next open, and the page says what the decision is as of. On a wacuum devnet with the registry v2: a reviewed app
# is admitted in the extension, the registry's revocations proved at the node's block (a devnet has no beacon chain,
# so no light client: the settings name no checkpoint); then the endorser revokes the endorsement on chain, and the
# same app opened again is refused, the revocation proved, as of a later block. See revoke.cjs.
#
#     WAC_SRC=/path/to/wac sh packages/reckon/extension/test/revoke.sh WORKDIR    (PORT defaults to 8910, and 3 more)
#
# Needs packages/wacuum/dist/wacuum.wasm and tools/oracle's node modules (the wallet), as tools/registry2.sh does.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
reckon=$(cd "$here/.." && pwd)
root=$(cd "$reckon/../.." && pwd)
work=$1; rm -rf "$work"; mkdir -p "$work"; work=$(cd "$work" && pwd)
port=${PORT:-8910}; proxy=$((port + 1)); mport=$((port + 2))
wacuum=${WACUUM:-$root/packages/wacuum/dist/wacuum.wasm}
pids=""
cleanup() { [ -n "$pids" ] && kill $pids 2>/dev/null || true; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM HUP
rpc() { curl -s -m2 -X POST -H 'content-type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" "http://127.0.0.1:$port/"; }

sh "$here/build.sh" > "$work/build.log" 2>&1 || { tail -5 "$work/build.log"; exit 1; }
cd "$root"
wac build --quiet --allow-read --allow-write --allow-net --allow-env "$reckon/cmd/claim.wac" -o "$work/claim"
wac build --quiet --allow-read --allow-write --allow-net packages/ipfs/cmd/obj.wac -o "$work/obj"
cd "$work"
CL="wac $work/claim.wasm"; O="wac $work/obj.wasm"
wallet="node $reckon/tools/registry2/wallet.mjs"
export RPC="http://127.0.0.1:$port"

mkdir -p devnet && ( cd devnet && exec wac "$wacuum" --dev --datadir data --port "$port" > node.log 2>&1 ) & pids="$pids $!"
until [ "$(rpc eth_blockNumber '[]' | sed -n 's/.*"result":"0x\([0-9a-f]*\)".*/\1/p')" != "" ] \
  && [ "$(rpc eth_blockNumber '[]' | sed -n 's/.*"result":"0x\([0-9a-f]*\)".*/\1/p')" != 0 ]; do sleep 0.5; done
mkdir -p keys
printf '1111111111111111111111111111111111111111111111111111111111111111' > keys/dev
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > keys/endorser
$wallet fund keys/dev "$($wallet address keys/endorser)" 10 >/dev/null
set -- $($wallet deploy keys/dev); registry=$1; codehash=$2
node "$reckon/tools/browser/cors-proxy.mjs" $proxy $port & pids="$pids $!"

mkdir -p app && printf '<!doctype html><meta charset=utf-8><title>reviewed</title><p id=p>an app</p>\n' > app/index.html
appCid=$($O add app --store pub)
statement=$($CL endorse "$appCid" reviewed --key keys/endorser --store pub 2>/dev/null)
$CL publish pub --store pub >/dev/null 2>&1
node "$reckon/tools/browser/serve.mjs" $mport pub & pids="$pids $!"
until curl -s -m1 -o /dev/null "http://127.0.0.1:$mport/" && curl -s -m1 -o /dev/null -X OPTIONS "http://127.0.0.1:$proxy/"; do sleep 0.2; done

policy="{ signers: { endorser: \"$($wallet address keys/endorser)\" }, roles: { app: [{ endorsed: { by: [\"endorser\"], at_least: 1 } }] } }"
cat > settings.json <<JSON
{ "rpc": "127.0.0.1:$proxy", "registry": "$registry", "codeHash": "$codehash", "mirrors": "http://127.0.0.1:$mport",
  "policy": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$policy") }
JSON
printf '#!/bin/sh\nRPC=%s %s revoke %s %s %s\n' "$RPC" "$wallet" "$work/keys/endorser" "$registry" "$statement" > revoke-now.sh
node "$here/test/revoke.cjs" "$work/settings.json" "$appCid" "sh $work/revoke-now.sh"
