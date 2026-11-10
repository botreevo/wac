#!/bin/sh
# A differential check of the NaN rewrite's stack model (src/canon.wac). The rewrite leaves out the check after a
# producing operation when its model of the stack and locals shows no one can see that NaN's bits. A mistake in that
# model would let an engine's own NaN through, silently. So every module here is rewritten twice — as the runner does
# (elided) and with every producing operation checked (`canon --all`, the reference) — and each version is run on V8 and
# on wasmtime. All four runs must print the same thing.
#
#     WASMTIME_WAC=/path/to/native/wac sh packages/reckon/tools/canonfuzz.sh [WORKDIR] [COUNT] [FIRST_SEED]
#
# The modules: COUNT (default 60) random float-heavy programs from tools/canonfuzz.py, and the corpus's own float
# programs. The run also counts how many programs print something different with no rewrite at all, which is how many
# of them a model that elided every check would have been caught by: a measure of what the check can see.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:-$(mktemp -d)}
count=${2:-60}
first=${3:-1}
WT=${WASMTIME_WAC:?set WASMTIME_WAC to the wac of the native host}
mkdir -p "$work"
pass=0; fail=0; exposed=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }

cd "$root"
wac build --quiet --allow-read --allow-write packages/reckon/cmd/canon.wac -o "$work/canon"
cd "$work"

# compare NAME MODULE: rewrite both ways, run each on both engines, demand one output.
compare() {
  name=$1; m=$2
  wac canon.wasm "$m" "$name.elided.wasm" 2>/dev/null || { bad "$name: the rewrite refused it"; return; }
  wac canon.wasm "$m" "$name.full.wasm" --all 2>/dev/null || { bad "$name: the full rewrite refused it"; return; }
  wac "$name.full.wasm" > "$name.v8.full" 2>&1 || true
  wac "$name.elided.wasm" > "$name.v8.elided" 2>&1 || true
  "$WT" "$name.full.wasm" > "$name.wt.full" 2>&1 || true
  "$WT" "$name.elided.wasm" > "$name.wt.elided" 2>&1 || true
  wac "$m" > "$name.v8.raw" 2>&1 || true
  [ -s "$name.v8.full" ] || { bad "$name: no output"; return; }
  if cmp -s "$name.v8.full" "$name.v8.elided" && cmp -s "$name.v8.full" "$name.wt.full" && cmp -s "$name.v8.full" "$name.wt.elided"; then
    ok
  else
    bad "$name: the four runs differ (elided vs full, V8 vs wasmtime): see $work/$name.*"
    diff "$name.v8.full" "$name.v8.elided" | head -4 || true
  fi
  cmp -s "$name.v8.raw" "$name.v8.full" || exposed=$((exposed + 1))
}

seed=$first
while [ "$seed" -lt $((first + count)) ]; do
  python3 "$here/tools/canonfuzz.py" "$seed" > "fuzz$seed.wac"
  if wac build --quiet "fuzz$seed.wac" -o "fuzz$seed" 2>/dev/null; then
    compare "fuzz$seed" "fuzz$seed.wasm"
  else
    bad "fuzz$seed: the generator wrote a program wac does not compile"
  fi
  seed=$((seed + 1))
done
for p in floats nanpaths; do
  wac build --quiet "$here/corpus/$p.wac" -o "$p"
  compare "$p" "$p.wasm"
done
echo
echo "$pass agreed, $fail failed; $exposed of them print otherwise with no rewrite at all (what eliding every check would have shown)"
[ "$fail" -eq 0 ]
