#!/bin/sh
# wacuum on mainnet, as wacuum-mainnet.service runs it, for the all-wac mode: on its store, snap-syncing to the head the
# light-client driver names (mainnet's genesis is before Cancun, so it starts from a snapped state, never from block
# 1), mainnet's execution bootnodes for peers, and the settings in /etc/eth/mainnet-wac.env.
set -eu
. /etc/eth/mainnet-wac.env
export WAC_MAX_HEAP
cd /opt/wac-eth/packages/wacuum
args="--genesis test/chain/mainnet-genesis.json --jwt-secret /etc/eth/jwt-wacuum.hex --datadir /data/wacuum"
args="$args --store --snap --cache-mb $CACHE_MB --history $HISTORY --port 8551 --p2p-port 30304"
for b in $BOOTNODES; do args="$args --bootnode $b"; done
# The address peers dial back: without it the node advertises 127.0.0.1, and only its own outbound dials connect.
if [ -n "${PUBLIC_IP:-}" ]; then args="$args --ip $PUBLIC_IP"; else echo "run-wacuum-mainnet.sh: PUBLIC_IP is not set in /etc/eth/mainnet-wac.env: no peer can dial this node" >&2; fi
args="$args --max-peers ${MAX_PEERS:-25}"
# shellcheck disable=SC2086
exec dist/wacuum $args
