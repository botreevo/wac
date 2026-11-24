#!/bin/sh
# Run every engine test for a fork (Cancun by default), four processes at a time, and print the totals.
# Each failure is printed with its test name; pass a directory or file after the fork to narrow it.
#
#     sh tools/enginetests.sh                       # every Cancun engine test
#     sh tools/enginetests.sh Prague fixtures/blockchain_tests_engine/prague
#     COLD=1 sh tools/enginetests.sh                # the engine on a store, every call prepared first
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
fork=${1:-Cancun}
# A fork's own directory (fixtures/blockchain_tests_engine/for_cancun, as execution-specs lays them out) when there is one.
lower=$(echo "$fork" | tr 'A-Z' 'a-z')
default="$root/fixtures/blockchain_tests_engine"
[ -d "$default/for_$lower" ] && default="$default/for_$lower"
where=${2:-$default}
wac build --allow-read "$root/tools/enginetest.wac" -o "$root/dist/enginetest" >/dev/null
find "$where" -name '*.json' | sort | xargs -n 50 -P 4 wac "$root/dist/enginetest.wasm" --fork "$fork" ${COLD:+--cold} > "$root/dist/enginetests.log" 2>&1 || true
grep '^FAIL' "$root/dist/enginetests.log" || true
grep 'passed,' "$root/dist/enginetests.log" | awk '{p += $1; f += $3} END {print p " passed, " f " failed"}'
