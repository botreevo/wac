#!/bin/sh
# wacuum on Hoodi, as wacuum-hoodi.service runs it: the local geth as a peer (it serves snap/1, the state wacuum
# fetches), Hoodi's bootnodes for the rest, the store with snap sync, and the settings in /etc/eth/hoodi.env.
set -eu
. /etc/eth/hoodi.env
export WAC_MAX_HEAP
args="--genesis /etc/eth/hoodi-genesis.json --jwt-secret /etc/eth/jwt-wacuum.hex --datadir /data/wacuum"
args="$args --store --snap --cache-mb $CACHE_MB --history $HISTORY --public-rpc --port 8552 --p2p-port 30304"
# The local geth's enode, from its admin API; waited for, since it may be starting too.
enode=""
for i in $(seq 1 60); do
  enode=$(curl -s -X POST -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"admin_nodeInfo","params":[]}' http://127.0.0.1:8545 |
    sed -n 's/.*"enode":"\(enode:[^"?]*\).*/\1/p')
  [ -n "$enode" ] && break
  sleep 5
done
[ -n "$enode" ] && args="$args --peer $enode" || echo "run-wacuum.sh: no local geth answered; going on without it" >&2
if [ -f /etc/eth/hoodi-bootnodes.txt ]; then
  for b in $(grep '^enode://' /etc/eth/hoodi-bootnodes.txt); do args="$args --bootnode $b"; done
fi
# The address peers dial back, and how many peers to keep.
if [ -n "${PUBLIC_IP:-}" ]; then args="$args --ip $PUBLIC_IP"; else echo "run-wacuum.sh: PUBLIC_IP is not set in /etc/eth/hoodi.env: no peer can dial this node" >&2; fi
args="$args --max-peers ${MAX_PEERS:-25}"
cd /opt/wac-eth/packages/wacuum
# shellcheck disable=SC2086
exec dist/wacuum $args
