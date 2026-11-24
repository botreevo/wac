#!/bin/sh
# Decision D, milestone 1 (docs/bootstrap-derivations.md): the compiler reached from wac's hand-written bootstrap
# ladder meets the compiler reached from the seed. The ladder (five rungs from wasm assembly text up to wacc) builds
# the `wac` command from the pinned commit's source, outside the machine. That command, as a derivation inside
# `wasm-gc/wac-host/2` on V8 and on wasmtime, compiles the same source. So does the seed (wac's compiler built
# natively), as in selfbuild.sh. Checked: both give the same compiler, byte for byte, so the compiler has two origins
# whose only shared input is the source.
#
#     WASMTIME_WAC=/path/to/native/wac sh packages/reckon/tools/ladder.sh [WORKDIR]
#     LADDER=/path/to/bootstrap/rust-ladder/target/release/ladder …    (default: built here with cargo from the source)
#
# The ladder step is not yet a derivation, and nothing signs it. Milestones 2–4 make it one. About 15 minutes.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:-$(mktemp -d)}
WT=${WASMTIME_WAC:?set WASMTIME_WAC to the wac of the native host}
mkdir -p "$work"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok    $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }

commit=$(sed -n 's/.*"wac": {.*"commit": "\([0-9a-f]\{40\}\)".*/\1/p' "$root/wac.lock" | head -1)
src=${WACSRC:-$HOME/.wac/cache/git/https%3A%2F%2Fgit.voltrevo.com%2Fwac.git/$commit}
[ -d "$src" ] || { echo "no wac source at $src: run sh tools/deps.sh" >&2; exit 1; }
cd "$work"
rm -rf wacsrc && mkdir -p wacsrc/in && cp -r "$src/." wacsrc/in/ && rm -f wacsrc/in/pack.pack
if [ -z "${LADDER:-}" ]; then
  echo "building the ladder (cargo, V8)"
  (cd "$src/bootstrap/rust-ladder" && cargo build --release --quiet --target-dir "$work/ladder-target")
  LADDER=$work/ladder-target/release/ladder
fi

cd "$root"
wac build --quiet --allow-read --allow-write --allow-run packages/reckon/cmd/derive.wac -o "$work/derive"
wac build --quiet --allow-read --allow-write packages/reckon/cmd/claim.wac -o "$work/claim"
wac build --quiet --allow-read --allow-write packages/ipfs/cmd/obj.wac -o "$work/obj"
grants="--allow-read --allow-write --allow-run --allow-net --allow-env"

echo; echo "## the ladder: boot/l1.l0 … l5.l4 build wacc from source, and wacc builds the wac command"
cd "$work/wacsrc/in"
wc -l bootstrap/boot/* | sed 's/^/   /'
"$LADDER" packages/wacc/src/api.wac --with-wacc packages/wac/src/wac.wac $grants -o "$work/ladder.wasm" 2>&1 | tail -2 | sed 's/^/   | /'
[ -s "$work/ladder.wasm" ] && ok "the ladder built a wac command ($(wc -c < "$work/ladder.wasm") bytes), from no binary but its engine" \
  || bad "the ladder built nothing"

echo; echo "## the seed: wac's compiler at the same commit, built natively"
wac build --quiet $grants packages/wac/src/wac.wac -o "$work/seed"
cmp -s "$work/seed.wasm" "$work/ladder.wasm" && echo "   (the same bytes as the ladder's)" \
  || echo "   $(wc -c < "$work/seed.wasm") bytes: not the ladder's bytes, as expected (each records how it was built)"

cd "$work"
st="--store $work/store"
objcat() { wac obj.wasm cat "$@" $st; }
claim() { wac claim.wasm "$@" $st 2>/dev/null; }
printf '%s\n' 4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318 > v8.key
printf '%s\n' 646f1ce2fdad0e6deeeb5c7e8e5543bdde65e86029e2fd9fc169899c440a7913 > wt.key
printf 'build\nin/in/packages/wac/src/wac.wac\n-o\n/out/wac\n--allow-read\n--allow-write\n--allow-run\n--allow-net\n--allow-env\n' > self.args

echo; echo "## each compiles the source inside the machine, on V8 and on wasmtime"
# run NAME PROGRAM: derive on both engines; the V8 output's CID in $out (not a $(…): the tally would stay in the subshell).
run() {
  r=$(wac derive.wasm recipe --program "$2" --args self.args --in wacsrc/in $st 2>/dev/null)
  a=$(wac derive.wasm run "$r" $st --timeout 7200000 --key v8.key --runner "reckon-derive/1 v8" 2>/dev/null | sed -n 1p)
  b=$($WT derive.wasm run "$r" $st --timeout 7200000 --key wt.key --runner "reckon-derive/1 wasmtime" 2>/dev/null | sed -n 1p)
  [ "$a" = "$b" ] && [ "$(objcat "$a" status)" = "exit 0" ] && ok "$1: V8 and wasmtime derive one output ($a)" \
    || bad "$1: the engines disagree or it failed: $a $b $(objcat "$a" status)"
  out=$a
}
run "the ladder's compiler builds wac" ladder.wasm; fromladder=$out
run "the seed builds wac" seed.wasm; fromseed=$out
objcat "$fromladder" out/wac.wasm > l1.wasm
objcat "$fromseed" out/wac.wasm > b.wasm
cmp -s l1.wasm b.wasm && ok "the same compiler, byte for byte ($(wc -c < b.wasm) bytes), from the ladder and from the seed" \
  || bad "the ladder's compiler and the seed's build different compilers"
[ "$fromladder" = "$fromseed" ] && ok "the whole output trees are one CID: two recipes, one result" \
  || bad "the output trees differ: $fromladder, $fromseed"
n=$(claim origins "$fromseed" | grep -c . || true)
[ "$n" -ge 2 ] && ok "the index knows $n origins for it" || bad "origins: $(claim origins "$fromseed")"
claim origins "$fromseed" | sed 's/^/   | /'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
