#!/bin/sh
# The shadow's status, once: printed (`status.wac`), with the reference node's head for the lag; and, given PROM, also
# written there as Prometheus metrics — what wacuum-status.timer does each minute.
#
#     WACUUM_RPC=http://127.0.0.1:8545 sh tools/mainnet/status.sh [LOG] [PROM]
set -u
cd "$(dirname "$0")/../.."
: "${WACUUM_RPC:=http://127.0.0.1:8545}"
export WACUUM_RPC
log=${1:-scratch/follow.log}
mkdir -p dist
# Built each time: a build remembers what it built, so after the first this costs a lookup.
wac build --allow-net --allow-env --allow-read --allow-write tools/mainnet/fetch.wac -o dist/mainnet-fetch.wasm >/dev/null || exit 1
wac build --allow-read --allow-write tools/mainnet/status.wac -o dist/mainnet-status.wasm >/dev/null || exit 1
head=$(wac dist/mainnet-fetch.wasm --head 2>/dev/null)
# A node that does not answer leaves the lag unknown (-1 in the metrics) rather than the status unwritten.
case "$head" in ''|*[!0-9]*) head=0 ;; esac
if [ -n "${2:-}" ]; then exec wac dist/mainnet-status.wasm "$log" "$head" --prom "$2"; fi
exec wac dist/mainnet-status.wasm "$log" "$head"
