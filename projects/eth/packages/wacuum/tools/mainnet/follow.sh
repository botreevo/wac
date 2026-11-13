#!/bin/sh
# Shadow mainnet's head: each new block, replayed here (replay.sh) as soon as the node has it, and one line
# a block appended to the log — its number, its gas, how fast, and whether it matched its header. This is
# wacuum checking every block of the live chain against a client that is synced, before it can sync itself.
#
#     WACUUM_RPC=http://127.0.0.1:8545 sh tools/mainnet/follow.sh [LOG]
#
# The node is best a local geth or reth (WACUUM_PRESTATE=1, the default here, names each block's reads with
# its prestateTracer in one call); a hosted endpoint works, slowly and within its rate limit, with
# WACUUM_PRESTATE= (empty). A block that matched leaves nothing behind; one that did not keeps its
# directory under scratch/follow/ with every answer, so it can be replayed again by hand.
set -u
cd "$(dirname "$0")/../.."
: "${WACUUM_RPC:=http://127.0.0.1:8545}"
WACUUM_PRESTATE=${WACUUM_PRESTATE-1}
export WACUUM_RPC WACUUM_PRESTATE
log=${1:-scratch/follow.log}
mkdir -p scratch/follow dist
wac build --allow-net --allow-env --allow-read --allow-write tools/mainnet/fetch.wac -o dist/mainnet-fetch.wasm >/dev/null || exit 1
last=$(tail -n 1 "$log" 2>/dev/null | cut -d' ' -f1)
case "$last" in ''|*[!0-9]*) last=0 ;; esac
while :; do
  head=$(wac dist/mainnet-fetch.wasm --head 2>/dev/null)
  case "$head" in ''|*[!0-9]*) sleep 12; continue ;; esac
  # A first start, or one after a long stop, begins at the head rather than replaying the gap.
  if [ "$last" -eq 0 ] || [ $((head - last)) -gt 64 ]; then last=$((head - 1)); fi
  while [ "$last" -lt "$head" ]; do
    n=$((last + 1))
    dir=scratch/follow/$n
    out=$(sh tools/mainnet/replay.sh "$n" 1 "$dir" 2>&1)
    status=$?
    speed=$(printf '%s\n' "$out" | grep 'recovering every sender' | sed 's/.*Mgas in \([0-9]*\) ms.*: \([0-9]*\) Mgas\/s/\1 ms \2 Mgas\/s/')
    if [ $status -eq 0 ]; then
      echo "$n ok $speed" >> "$log"
      rm -rf "$dir"
    else
      echo "$n DIFFERS $speed — $(printf '%s\n' "$out" | grep -E '^block |differ|cannot|error' | head -3 | tr '\n' ' ')" >> "$log"
    fi
    last=$n
  done
  sleep 6
done
