#!/bin/sh
# The deterministic WebAssembly machine (src/machine.wac), run by cmd/derive.wac on two engines: V8, through the
# Node host's `wac`, and wasmtime, through the native host's (WASMTIME_WAC=path; the comparison is skipped without
# one). Every program in corpus/ is made into a recipe once, then run by each, and checked for
#
#   - the ending this machine gives it (an exit status, a named trap, or an abort that yields nothing);
#   - the same output CID on both engines, where the machine promises one;
#   - the same output CID twice on one engine.
#
# probe.wac asks for what the machine does not give: a host file, the environment, a clock (wall and monotonic) and
# random bytes. Version 2 runs the program sealed, so it is refused all of them, and its output is the same on both
# engines like everyone else's. floats.wac used to be the other disagreement (V8 and wasmtime choose different NaNs)
# until the runner made NaNs canonical (src/canon.wac); it must agree too.
#
#     sh tools/machine.sh [WORKDIR]
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:-$(mktemp -d)}
mkdir -p "$work"
V8="wac"
WT=${WASMTIME_WAC:-}
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok    $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }
known() { echo "known $*"; }

cd "$root"
wac build --quiet --allow-read --allow-write --allow-run packages/reckon/cmd/derive.wac -o "$work/derive"
wac build --quiet --allow-read --allow-write packages/ipfs/cmd/obj.wac -o "$work/obj"
for p in "$here"/corpus/*.wac; do wac build --quiet "$p" -o "$work/$(basename "$p" .wac)"; done

cd "$work"
rm -rf store in && mkdir -p in/sub in/empty && printf 'hello\n' > in/sub/a.txt && printf 'x\ny\n' > args
store="--store $work/store"
recipe() { wac derive.wasm recipe --program "$1.wasm" --args args --in in $store 2>/dev/null; }
# run HOST RECIPE: the output CID, or "abort"
run() {
  out=$($1 derive.wasm run "$2" $store --timeout 3000 2>"$work/err") || true
  [ -n "$out" ] && echo "$out" || echo "abort"
}
status() { [ "$1" = abort ] && echo abort || wac obj.wasm cat "$1" status $store; }

check() {   # check PROGRAM EXPECTED [agrees|differs]
  r=$(recipe "$1")
  a=$(run "$V8" "$r")
  got=$(status "$a")
  [ "$got" = "$2" ] && ok "$1: $2 on V8" || bad "$1: V8 gave '$got', want '$2' ($(tail -1 "$work/err"))"
  a2=$(run "$V8" "$r")
  if [ "${3:-agrees}" = agrees ]; then
    [ "$a" = "$a2" ] && ok "$1: the same output twice" || bad "$1: two runs on V8 gave $a and $a2"
  fi
  [ -n "$WT" ] || return 0
  b=$(run "$WT" "$r")
  gotb=$(status "$b")
  [ "$gotb" = "$2" ] && ok "$1: $2 on wasmtime" || bad "$1: wasmtime gave '$gotb', want '$2' ($(tail -1 "$work/err"))"
  if [ "${3:-agrees}" = agrees ]; then
    [ "$a" = "$b" ] && ok "$1: V8 and wasmtime agree ($a)" || bad "$1: V8 gave $a, wasmtime $b"
  elif [ "$a" != "$b" ]; then
    wac obj.wasm cat "$a" log $store > v8.log; wac obj.wasm cat "$b" log $store > wt.log
    known "$1: V8 and wasmtime differ, as expected:"
    diff v8.log wt.log | sed -n 's/^[<>] /        /p' || true
  else
    known "$1: V8 and wasmtime happened to agree"
  fi
}

check files "exit 0"
check fail "exit 7"
check oob "trap array-out-of-bounds"
check div "trap divide-by-zero"
check ovf "trap integer-overflow"
check nul "trap null"
check unwrap "trap unreachable"
check deep abort
check big abort
check loop abort
check floats "exit 0"
# Every way a produced NaN can leave its arithmetic, each checked canonical by the program itself (exit 1 otherwise):
# the test that the rewrite's skipped checks (src/canon.wac) never let a payload out.
check nanpaths "exit 0"
check nbody "exit 0"
check probe "exit 0"

# The minimums every runner of this machine must provide (docs/runner.md): 10,000 frames of depth.wac's recursion and
# 1 GiB of heap held live by heap.wac. Within them a run must complete on both engines; past what an engine allows it
# aborts and yields nothing, which is correct.
limit() {   # limit PROGRAM ARG WANT HOST
  printf '%s\n' "$2" > limit.args
  r=$(wac derive.wasm recipe --program "$1.wasm" --args limit.args $store 2>/dev/null)
  out=$($4 derive.wasm run "$r" $store --timeout 300000 2>/dev/null) || true
  got=$([ -n "$out" ] && echo "completes" || echo "aborts")
  [ "$got" = "$3" ] && ok "$1 $2: $3 on $5" || bad "$1 $2: $got on $5, want $3"
}
limit depth 10000 completes "$V8" V8
limit heap 1024 completes "$V8" V8
limit depth 1000000 aborts "$V8" V8
if [ -n "$WT" ]; then
  limit depth 10000 completes "$WT" wasmtime
  limit heap 1024 completes "$WT" wasmtime
  limit depth 1000000 aborts "$WT" wasmtime
fi

# What the program could and could not reach, from its own log.
p=$(run "$V8" "$(recipe probe)")
wac obj.wasm cat "$p" log $store > probe.log
grep -q "read /etc/hostname: refused" probe.log && ok "probe: no host file" || bad "probe: read a host file"
grep -q "env HOME: refused" probe.log && ok "probe: no environment" || bad "probe: read the environment"
grep -q "^cwd: /$" probe.log && ok "probe: starts at /" || bad "probe: $(grep cwd probe.log)"
grep -q "^clock: refused" probe.log && ok "probe: no clock" || bad "probe: $(grep '^clock' probe.log)"
grep -q "^monotonic: refused" probe.log && ok "probe: no monotonic clock" || bad "probe: $(grep '^monotonic' probe.log)"
grep -q "^random: refused" probe.log && ok "probe: no random bytes" || bad "probe: $(grep '^random' probe.log)"
f=$(run "$V8" "$(recipe files)")
wac obj.wasm cat "$f" log $store > files.log
grep -q "refused /in/x" files.log && ok "files: the input is read-only" || bad "files: wrote to its input"
grep -q "refused climbing out" files.log && ok "files: cannot climb out of the root" || bad "files: climbed out"
[ "$(wac obj.wasm cat "$f" out/streamed $store)" = "one two" ] && ok "files: a streamed write lands" || bad "files: streamed write"

# The NaN rewrite against wasmparser (tools/wasmscan, built offline when cargo is here): the same operators at the same
# offsets in every function, and every rewritten module valid.
if command -v cargo >/dev/null 2>&1 && (cd "$here/tools/wasmscan" && cargo build --offline --release -q 2>/dev/null); then
  scan="$here/tools/wasmscan/target/release/wasmscan"
  for m in derive obj floats files probe nanpaths nbody; do
    wac derive.wasm canon "$m.wasm" "$m.canon.wasm" --scan "$m.mine" 2>/dev/null
    "$scan" scan "$m.wasm" | awk '{print $2" "$3}' | sed 's/ $//' > "$m.oracle"
    sed 's/ $//' "$m.mine" > "$m.mine2"
    cmp -s "$m.mine2" "$m.oracle" && ok "canon: $m's $(wc -l < "$m.oracle") functions read as wasmparser reads them" \
      || bad "canon: $m read differently from wasmparser"
    [ "$("$scan" validate "$m.canon.wasm")" = valid ] && ok "canon: $m rewritten is valid" || bad "canon: $m rewritten is invalid"
  done
else
  known "canon: no cargo here, so the rewrite was not checked against wasmparser"
fi

# A derivation signed over the recipe and the output.
printf '%s\n' 4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318 > key
s=$(wac derive.wasm run "$(recipe files)" $store --key key --runner "reckon-derive/0 v8" 2>/dev/null | sed -n 2p)
[ -n "$s" ] && ok "a signed derivation: $s" || bad "no signed derivation"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
