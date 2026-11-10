#!/bin/sh
# Attested derivations end to end, with no chain: one recipe run by two runners on two engines, each signing what it
# got; a reviewer endorsing the inputs; and a policy that admits the output only when both runners agree and every
# input is endorsed. Then the ways that admission is taken away again, each refused for the reason it claims.
#
#     WASMTIME_WAC=/path/to/native/wac sh tools/demo.sh [WORKDIR]
#
# Needs the native host for the second engine: without it there is one runner, and the quorum below cannot form.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:-$(mktemp -d)}
WT=${WASMTIME_WAC:?set WASMTIME_WAC to the wac of the native host}
mkdir -p "$work"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok    $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }
step() { echo; echo "## $*"; }

cd "$root"
wac build --quiet --allow-read --allow-write --allow-run packages/reckon/cmd/derive.wac -o "$work/derive"
wac build --quiet --allow-read --allow-write packages/reckon/cmd/claim.wac -o "$work/claim"
wac build --quiet packages/reckon/corpus/files.wac -o "$work/files"

cd "$work"
rm -rf store in && mkdir -p in/sub && printf 'hello\n' > in/sub/a.txt && printf 'x\n' > args
st="--store $work/store"
claim() { wac claim.wasm "$@" $st 2>/dev/null; }
printf '%s\n' 4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318 > v8.key
printf '%s\n' 646f1ce2fdad0e6deeeb5c7e8e5543bdde65e86029e2fd9fc169899c440a7913 > wt.key
printf '%s\n' add2f9f8b6e2bff7d0b6e7d1bbcd8fe16c3fbd8b5b1fbb1c0a63e5a0e7a2c3b1 > reviewer.key

step "a recipe: the program, its arguments and its input, as one tree"
recipe=$(wac derive.wasm recipe --program files.wasm --args args --in in $st 2>/dev/null)
echo "recipe $recipe"
claim slots "$recipe"

step "two runners on two engines, each signing what it got"
out1=$(wac derive.wasm run "$recipe" $st --key v8.key --runner "reckon-derive/0 v8" 2>/dev/null)
out2=$($WT derive.wasm run "$recipe" $st --key wt.key --runner "reckon-derive/0 wasmtime" 2>/dev/null)
o1=$(echo "$out1" | sed -n 1p); d1=$(echo "$out1" | sed -n 2p)
o2=$(echo "$out2" | sed -n 1p); d2=$(echo "$out2" | sed -n 2p)
echo "V8       output $o1, derivation $d1"
echo "wasmtime output $o2, derivation $d2"
[ "$o1" = "$o2" ] && ok "both engines derived the same output" || bad "the engines disagree"
output=$o1
[ "$(claim origins "$output" | wc -l)" -eq 2 ] && ok "the index knows two origins for it" || bad "origins: $(claim origins "$output")"
[ "$(claim dependents "$(claim slots "$recipe" | sed -n 's/^program //p')")" = "$output" ] \
  && ok "and it is a dependent of the program" || bad "dependents of the program"

step "a policy: both runners must agree, and every input must be endorsed by the reviewer"
cat > policy.json5 <<EOF
{
  signers: { v8: "$(claim address --key v8.key)", wasmtime: "$(claim address --key wt.key)",
             reviewer: "$(claim address --key reviewer.key)" },
  machines: ["wasm-gc/wac-host/3"],
  formats: ["unixfs-v1-2025+hidden"],
  roles: {
    result: [{ derived: { by: ["v8", "wasmtime"], at_least: 2, runners: 2, slots: { program: "program" }, other: "input" } }],
    program: [{ endorsed: { by: ["reviewer"], at_least: 1 } }],
    input: [{ endorsed: { by: ["reviewer"], at_least: 1 } }],
  },
}
EOF
admit() { wac claim.wasm admit "$output" result --policy policy.json5 $st 2>/dev/null > admit.log && echo yes || echo no; }
[ "$(admit)" = no ] && grep -q "endorsed by nobody" admit.log && ok "refused while nobody has reviewed the inputs" \
  || bad "admitted unreviewed inputs: $(cat admit.log)"

step "the reviewer endorses the program and the inputs"
for slot in program args in; do
  cid=$(claim slots "$recipe" | sed -n "s/^$slot //p")
  e=$(claim endorse "$cid" reviewed --key reviewer.key)
  [ "$slot" = program ] && program_endorsement=$e
  echo "endorsed $slot $cid"
done
[ "$(admit)" = yes ] && ok "admitted: two runners agree and every input is endorsed" || bad "refused: $(cat admit.log)"
cat admit.log

step "taking it away, each on its own copy of the store"
cp -r store store-endorsement

claim revoke "$d1" --key wt.key >/dev/null
[ "$(admit)" = yes ] && ok "wasmtime's key \"revoking\" v8's derivation counts for nothing: only a signer revokes its own" \
  || bad "a stranger's revocation took effect: $(cat admit.log)"
claim revoke "$d2" --key wt.key >/dev/null
[ "$(admit)" = no ] && grep -q "witnessed by v8 on 1 runner" admit.log \
  && ok "wasmtime's runner revokes its own derivation: v8 alone is not a quorum" || bad "after a revocation: $(cat admit.log)"

st="--store $work/store-endorsement"
claim revoke "$program_endorsement" --key reviewer.key >/dev/null
[ "$(admit)" = no ] && grep -A1 "refused as program" admit.log | grep -q "endorsed by nobody" \
  && ok "the reviewer takes back the program's endorsement: refused at the program" || bad "after the endorsement was revoked: $(cat admit.log)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
