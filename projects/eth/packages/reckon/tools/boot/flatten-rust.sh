#!/bin/sh
# wac's Rust flattener (bootstrap/rust-ladder/src/flatten.rs, through the ladder's `--dump-flat`) in the runner's
# shape: `TOOL ENTRY OUT`.
#
#     sh tools/boot/flatten-rust.sh LADDER ENTRY OUT
#
# Exit 0 with OUT written: the flattened program. Exit 1: an import names a file that is not there. The ladder panics
# on any error, so that one is told apart by its message; any other failure is the command's, not an answer.
set -u
ladder=$1; entry=$2; out=$3
err=$(mktemp)
if "$ladder" "$entry" --dump-flat > "$out" 2> "$err"; then rm -f "$err"; exit 0; fi
rm -f "$out"
if grep -q "No such file or directory" "$err"; then sed -n 2p "$err" >&2; rm -f "$err"; exit 1; fi
cat "$err" >&2; rm -f "$err"; exit 2
