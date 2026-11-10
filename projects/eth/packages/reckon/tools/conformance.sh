#!/bin/sh
# Runner conformance as derivations (docs/conformance.md). A conformance suite for `wasm-gc/wac-host/3` is an object: a
# tree whose `cases` file lists recipes from the machine's corpus (corpus/, the programs tools/machine.sh checks) and the
# output each must give, or `none` where the machine gives none (a run past its floor). A runner shows it implements
# the machine by witnessing the suite, signing each case as it would anything else; a policy naming the suite
# (`conformance: { MACHINE: SUITE }`) then counts a runner's witness to anything only once that runner has. Checked:
#   - the suite: every case gives the ending machine.sh expects, V8 and wasmtime agree on each, and it is one object;
#   - two runners (V8, wasmtime) witness the suite, then an app; the app is admitted, each witness counted;
#   - a runner that has not witnessed the suite is not counted, however honest its claim about the app;
#   - a runner that gives one case another output (a NaN its engine chose, say) is not counted;
#   - a runner that claims an output where the machine gives none is not counted;
#   - a runner that revokes one of its suite derivations stops counting.
#
#     WASMTIME_WAC=/path/to/native/wac sh packages/reckon/tools/conformance.sh [WORKDIR]
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:-$(mktemp -d)}
WT=${WASMTIME_WAC:?set WASMTIME_WAC to the wac of the native host}
mkdir -p "$work"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok    $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }

cd "$root"
wac build --quiet --allow-read --allow-write --allow-run packages/reckon/cmd/derive.wac -o "$work/derive"
wac build --quiet --allow-read --allow-write packages/reckon/cmd/claim.wac -o "$work/claim"
wac build --quiet --allow-read --allow-write packages/ipfs/cmd/obj.wac -o "$work/obj"
for p in "$here"/corpus/*.wac; do wac build --quiet "$p" -o "$work/$(basename "$p" .wac)"; done
machine=$(sed -n 's/.*MACHINE() { return "\(.*\)"; }.*/\1/p' "$here/src/machine.wac")
commit=$(git -C "$root" rev-parse --short HEAD)

cd "$work"
rm -rf store in suite names && mkdir -p in/sub in/empty suite && printf 'hello\n' > in/sub/a.txt && printf 'x\ny\n' > args
st="--store $work/store"
claim() { wac claim.wasm "$@" $st 2>/dev/null; }
status() { [ -z "$1" ] && echo abort || wac obj.wasm cat "$1" status $st; }
for k in v8:4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318 \
         wt:646f1ce2fdad0e6deeeb5c7e8e5543bdde65e86029e2fd9fc169899c440a7913 \
         fresh:add2f9f8b6e2bff7d0b6e7d1bbcd8fe16c3fbd8b5b1fbb1c0a63e5a0e7a2c3b1 \
         nan:8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba \
         over:59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d; do
  printf '%s\n' "${k#*:}" > "${k%%:*}.key"
done
V8_NAME="reckon-derive/1 v8"; WT_NAME="reckon-derive/1 wasmtime"

echo; echo "## the suite: the corpus, with the endings machine.sh expects, V8 and wasmtime agreeing"
printf '# Conformance suite for %s, from wac-eth packages/reckon/corpus at %s (tools/conformance.sh).\n# RECIPE OUTPUT, or RECIPE none where the machine gives no output.\n' "$machine" "$commit" > suite/cases
# case PROGRAM ARGSFILE WANT [TIMEOUT]: a recipe, run unsigned on both engines; its line in the suite.
case_() {
  r=$(wac derive.wasm recipe --program "$1.wasm" --args "$2" ${5:+--in in} $st 2>/dev/null)
  a=$(wac derive.wasm run "$r" $st --timeout "${4:-3000}" 2>/dev/null | sed -n 1p || true)
  b=$($WT derive.wasm run "$r" $st --timeout "${4:-3000}" 2>/dev/null | sed -n 1p || true)
  if [ "$(status "$a")" = "$3" ] && [ "$a" = "$b" ]; then
    echo "$r ${a:-none}" >> suite/cases; echo "$1 $r" >> names; n=$((n + 1))
  else
    bad "$1 $(cat "$2" | tr '\n' ' '): V8 '$(status "$a")', wasmtime '$(status "$b")', want '$3'"
  fi
}
n=0
for c in "files:exit 0" "fail:exit 7" "oob:trap memory-bounds" "div:trap divide-by-zero" "ovf:trap integer-overflow" \
         "nul:trap null-reference" "unwrap:trap unreachable-code" "conv:trap bad-conversion" "explicit:trap explicit" \
         "floats:exit 0" "nanpaths:exit 0" "nbody:exit 0" "probe:exit 0" "deep:abort" "big:abort" "loop:abort"; do
  case_ "${c%%:*}" args "${c#*:}" 3000 in
done
printf '10000\n' > depth.args; printf '1024\n' > heap.args; printf '1000000\n' > deeper.args
case_ depth depth.args "exit 0" 300000
case_ heap heap.args "exit 0" 300000
case_ depth deeper.args abort 300000
suite=$(wac obj.wasm add suite $st 2>/dev/null | tail -1)
nones=$(grep -c ' none$' suite/cases || true)
[ "$n" -eq 19 ] && ok "the suite: $n cases ($nones that give nothing), one object: $suite" || bad "the suite has $n cases"
sed -n '3,$p' suite/cases | sed 's/^/   | /' | cut -c1-120

# witness KEY NAME HOST: a runner witnessing the suite: every case with an output, run and signed. A case that gives
# none needs nothing from a conforming runner but to claim nothing.
witness() {
  sed -n '/^bafy/p' suite/cases | grep -v ' none$' | while read -r r want; do
    $3 derive.wasm run "$r" $st --timeout 300000 --key "$1.key" --runner "$2" >/dev/null 2>&1 || true
  done
}
echo; echo "## two runners witness the suite"
witness v8 "$V8_NAME" wac
witness wt "$WT_NAME" "$WT"
ok "V8's and wasmtime's runners have signed the suite's cases"

echo; echo "## an app, and a policy that counts only conforming runners"
printf 'app\n' > app.args
app=$(wac derive.wasm recipe --program files.wasm --args app.args --in in $st 2>/dev/null)
out=$(wac derive.wasm run "$app" $st --key v8.key --runner "$V8_NAME" 2>/dev/null | sed -n 1p)
$WT derive.wasm run "$app" $st --key wt.key --runner "$WT_NAME" >/dev/null 2>&1
policy() {   # policy BY…: the app derived by two of BY on two runners, its inputs roots, under the suite
  by=$(for w in "$@"; do printf '"%s", ' "$w"; done)
  roots=$(claim slots "$app" | awk '{printf "\"%s\", ", $2}')
  cat > policy.json5 <<EOF
{
  signers: { v8: "$(claim address --key v8.key)", wt: "$(claim address --key wt.key)", fresh: "$(claim address --key fresh.key)",
             nan: "$(claim address --key nan.key)", over: "$(claim address --key over.key)" },
  roots: [$roots],
  machines: ["$machine"],
  formats: ["unixfs-v1-2025+hidden"],
  conformance: { "$machine": "$suite" },
  roles: {
    app: [{ derived: { by: [$by], at_least: 2, runners: 2, other: "input" } }],
    input: ["root"],
  },
}
EOF
}
admit() { wac claim.wasm admit "$out" app --policy policy.json5 $st > admit.log 2>/dev/null && echo yes || echo no; }
policy v8 wt
[ "$(admit)" = yes ] && ok "admitted: witnessed by V8's and wasmtime's runners, both conforming" || bad "refused: $(cat admit.log)"
sed 's/^/   | /' admit.log

echo; echo "## runners that do not count"
wac derive.wasm run "$app" $st --key fresh.key --runner "reckon-derive/1 v8, another host" >/dev/null 2>&1
policy v8 fresh
[ "$(admit)" = no ] && grep -q "fresh on .*: it has witnessed 0 of the suite's 15 cases with an output" admit.log \
  && ok "a runner that never witnessed the suite is not counted, though its claim about the app is true" || bad "fresh: $(cat admit.log)"
grep -o "not counted: .*" admit.log | sort -u | sed 's/^not counted: /   | /'

# A runner on an engine that lets its own NaN through: honest about the app, wrong on the suite's floats case.
witness nan "reckon-derive/1 nan-leaking" wac
floats=$(awk '$1 == "floats" { print $2 }' names)
claim revoke "$(wac derive.wasm run "$floats" $st --key nan.key --runner "reckon-derive/1 nan-leaking" 2>/dev/null | sed -n 2p)" --key nan.key >/dev/null
claim derivation "$floats" "$out" --runner "reckon-derive/1 nan-leaking" --key nan.key >/dev/null
wac derive.wasm run "$app" $st --key nan.key --runner "reckon-derive/1 nan-leaking" >/dev/null 2>&1
policy wt nan
[ "$(admit)" = no ] && grep -q "nan on .*: it gave .* where the suite says" admit.log \
  && ok "a runner that gives a suite case another output is not counted" || bad "nan: $(cat admit.log)"
grep -o "not counted: .*" admit.log | sort -u | sed 's/^not counted: /   | /'

# A runner with no floor: it signs an output for a run the machine aborts.
witness over "reckon-derive/1 unbounded" wac
deep=$(awk '$1 == "deep" { print $2 }' names)
claim derivation "$deep" "$out" --runner "reckon-derive/1 unbounded" --key over.key >/dev/null
wac derive.wasm run "$app" $st --key over.key --runner "reckon-derive/1 unbounded" >/dev/null 2>&1
policy v8 over
[ "$(admit)" = no ] && grep -q "over on .*: it claimed an output for .* where the machine gives none" admit.log \
  && ok "a runner that claims an output where the machine gives none is not counted" || bad "over: $(cat admit.log)"
grep -o "not counted: .*" admit.log | sort -u | sed 's/^not counted: /   | /'

echo; echo "## a revocation"
first=$(awk '$1 == "files" { print $2 }' names)
s=$(wac derive.wasm run "$first" $st --key wt.key --runner "$WT_NAME" 2>/dev/null | sed -n 2p)
claim revoke "$s" --key wt.key >/dev/null
policy v8 wt
[ "$(admit)" = no ] && grep -q "wt on .*: it has witnessed 14 of the suite's 15 cases with an output" admit.log \
  && ok "wasmtime's runner revokes one suite case: it no longer counts" || bad "after a revocation: $(cat admit.log)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
