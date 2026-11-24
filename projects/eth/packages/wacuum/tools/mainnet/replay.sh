#!/bin/sh
# Replay mainnet blocks FROM .. FROM+COUNT-1 against the state a JSON-RPC node reports: fetch.wac asks the
# node, replay.wac runs the blocks and says what else it needs, until it needs nothing; then replay.wac
# imports them, timed. See replay.wac's header.
#
#     WACUUM_RPC=https://... sh tools/mainnet/replay.sh FROM COUNT [DIR]
#
# With WACUUM_PRESTATE=1 the reads are named by the node's prestateTracer (a local geth or reth) instead of
# access lists, and the first run needs no second.
#
# DIR (scratch/mainnet-FROM-COUNT by default) keeps every answer, so a second run fetches nothing. The URL
# is read from the environment only; keep it, and any key in it, out of the repository.
set -eu
cd "$(dirname "$0")/../.."
from=$1
count=$2
dir=${3:-scratch/mainnet-$from-$count}
[ -n "${WACUUM_RPC:-}" ] || { echo "replay.sh: set WACUUM_RPC to a mainnet JSON-RPC URL" >&2; exit 2; }
mkdir -p "$dir" dist
wac build --allow-net --allow-env --allow-read --allow-write tools/mainnet/fetch.wac -o dist/mainnet-fetch.wasm >/dev/null
wac build --allow-read --allow-write tools/mainnet/replay.wac -o dist/mainnet-replay.wasm >/dev/null
round=0
while :; do
  wac dist/mainnet-fetch.wasm --from "$from" --count "$count" --dir "$dir" ${WACUUM_PRESTATE:+--prestate}
  set +e
  wac dist/mainnet-replay.wasm --dir "$dir"
  status=$?
  set -e
  [ $status -eq 3 ] || exit $status
  round=$((round + 1))
  [ $round -lt 400 ] || { echo "replay.sh: still missing state after 400 rounds" >&2; exit 1; }
done
