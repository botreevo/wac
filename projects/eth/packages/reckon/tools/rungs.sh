#!/bin/sh
# Decision D, milestone 3 (docs/seam-machine.md): wac's bootstrap ladder, every step a signed derivation. From the
# hand-written rungs to wacc, with no compiler binary anywhere:
#
#     boot/l1.l0 ──wac-l0/1──▶ L1 (an interpreter)
#     L1 runs boot/l2.l1 compiling boot/l3.l2 ──wasm-seam/1──▶ L0 text ──wac-l0/1──▶ the L3 compiler
#     L3 compiles boot/l4.l3 ──wasm-seam/1──▶ L0 ──wac-l0/1──▶ the L4 compiler
#     L4 compiles boot/l5.l4 ──wasm-seam/1──▶ L0 ──wac-l0/1──▶ the L5 compiler
#     packages/wacc/src ──wac-flatten/1──▶ one program; L5 compiles it ──wasm-seam/1──▶ L0 ──wac-l0/1──▶ wacc
#
# Each machine has two runners written apart, and each signs: wac-l0/1 wac's Rust and JavaScript assemblers;
# wac-flatten/1 its JavaScript flattener and the ladder's Rust one; wasm-seam/1 V8 (node) and wasmtime
# (tools/seam/wasmtime). Checked: both runners agree at every step; wacc's L0 is byte for byte what wac's own ladder
# makes; and a policy admits wacc's module only through the whole chain, back to the reviewed sources, refusing it when
# a step's second runner is withdrawn or a rung's source is not reviewed.
#
#     LADDER=/path/to/bootstrap/rust-ladder/target/release/ladder sh packages/reckon/tools/rungs.sh [WORKDIR]
#
# Needs wac on PATH, node, cargo (offline, for wax and the wasmtime seam runner) and the pinned wac in the package
# cache. A few minutes.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:-$(mktemp -d)}
mkdir -p "$work"; work=$(cd "$work" && pwd)
LADDER=${LADDER:?set LADDER to the ladder binary of wac: bootstrap/rust-ladder/target/release/ladder}
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok    $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }
step() { printf '\n== %s\n' "$*"; }

commit=$(sed -n 's/.*"wac": {.*"commit": "\([0-9a-f]\{40\}\)".*/\1/p' "$root/wac.lock" | head -1)
src=${WACSRC:-$HOME/.wac/cache/git/https%3A%2F%2Fgit.voltrevo.com%2Fwac.git/$commit}
[ -d "$src/bootstrap" ] || { echo "no wac source at $src: run sh tools/deps.sh" >&2; exit 1; }
short=$(echo "$commit" | cut -c1-9)
boot=$src/bootstrap/boot

cd "$root"
wac build --quiet --allow-read --allow-write --allow-run packages/reckon/cmd/boot.wac -o "$work/boot"
wac build --quiet --allow-read --allow-write packages/reckon/cmd/claim.wac -o "$work/claim"
wac build --quiet --allow-read --allow-write packages/ipfs/cmd/obj.wac -o "$work/obj"
echo "building wax (Rust assembler) and the wasmtime seam runner, offline"
(cd "$src/bootstrap/rust" && cargo build --release --quiet --offline --target-dir "$work/wax-target")
(cd "$here/tools/seam/wasmtime" && cargo build --release --quiet --offline --target-dir "$work/seam-target")
cd "$work"
rm -rf store w-* t && mkdir -p t
st="--store $work/store"
claim() { wac claim.wasm "$@" $st 2>/dev/null; }
printf '%s\n' 4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318 > js.key       # the V8/JavaScript side
printf '%s\n' 646f1ce2fdad0e6deeeb5c7e8e5543bdde65e86029e2fd9fc169899c440a7913 > rust.key     # the Rust/wasmtime side
printf '%s\n' add2f9f8b6e2bff7d0b6e7d1bbcd8fe16c3fbd8b5b1fbb1c0a63e5a0e7a2c3b1 > reviewer.key
L0_JS="node $here/tools/boot/assemble.mjs $src/bootstrap/js/assemble.js";   L0_RUST="$work/wax-target/release/wax"
FL_JS="node $here/tools/boot/flatten.mjs $src/bootstrap/js/flatten.js";     FL_RUST="sh $here/tools/boot/flatten-rust.sh $LADDER"
SE_JS="node $here/tools/seam/node.mjs";                                       SE_RUST="$work/seam-target/release/seam-wasmtime"

# both NAME RECIPE JSTOOL JSNAME RUSTTOOL RUSTNAME: run by both runners, each signing; one output, or FAIL. Sets $out.
both() {
  a=$(wac boot.wasm run "$2" $st --work w-js --tool "$3" --key js.key --runner "$4" 2>/dev/null | sed -n 1p)
  b=$(wac boot.wasm run "$2" $st --work w-rust --tool "$5" --key rust.key --runner "$6" 2>/dev/null | sed -n 1p)
  out=$a
  [ -n "$a" ] && [ "$a" = "$b" ] && ok "$1: both runners give one output ($a)" || { bad "$1: $a, $b"; exit 1; }
}
# assemble NAME FILE: wac-l0/1 on FILE; the module in t/NAME.wasm. Sets $out.
assemble() {
  r=$(wac boot.wasm recipe --source "$2" $st 2>/dev/null)
  both "assemble $1" "$r" "$L0_JS" "wax.js (node) at wac $short" "$L0_RUST" "wax (Rust) at wac $short"
  wac obj.wasm cat "$out" out/module.wasm $st > "t/$1.wasm"
}
# seam NAME MODULE SOURCE [SUBJECT]: wasm-seam/1; the answer in t/NAME.l0. Sets $out.
seam() {
  r=$(wac boot.wasm recipe --module "$2" --source "$3" ${4:+--subject "$4"} $st 2>/dev/null)
  both "run $1" "$r" "$SE_JS" "seam (node, V8) at wac $short" "$SE_RUST" "seam (wasmtime) at wac $short"
  wac obj.wasm cat "$out" out/answer.l0 $st > "t/$1.l0"
}

step "the rungs, from hand-written L0 up"
echo "   $(cat "$boot"/l1.l0 "$boot"/l2.l1 "$boot"/l3.l2 "$boot"/l4.l3 "$boot"/l5.l4 | wc -l) lines of hand-written source"
assemble l1 "$boot/l1.l0"
seam l3 t/l1.wasm "$boot/l2.l1" "$boot/l3.l2"; assemble l3 t/l3.l0
seam l4 t/l3.wasm "$boot/l4.l3";               assemble l4 t/l4.l0
seam l5 t/l4.wasm "$boot/l5.l4";               assemble l5 t/l5.l0

step "wacc: flattened, compiled by L5, assembled"
rm -rf inputs && mkdir -p inputs && cp -r "$src/packages/wacc/src" inputs/wacc
fr=$(wac boot.wasm recipe --tree inputs/wacc --entry api.wac $st 2>/dev/null)
both "flatten wacc ($(ls inputs/wacc | wc -l | tr -d ' ') modules)" "$fr" "$FL_JS" "flatten.js (node) at wac $short" "$FL_RUST" "flatten.rs (ladder --dump-flat) at wac $short"
wac obj.wasm cat "$out" out/flat.wac $st > t/wacc.flat.wac
seam wacc t/l5.wasm t/wacc.flat.wac
(cd "$src" && "$LADDER" packages/wacc/src/api.wac --l0) > ladder-wacc.l0
cmp -s t/wacc.l0 ladder-wacc.l0 && ok "wacc's L0, $(wc -c < t/wacc.l0) bytes, is byte for byte what wac's own ladder makes" \
  || bad "wacc's L0 differs from wac's own ladder's"
assemble wacc t/wacc.l0
wacc=$out

step "admission: wacc, through every step, back to reviewed sources"
cid() { python3 -c "import sys,hashlib,base64; d=hashlib.sha256(open(sys.argv[1],'rb').read()).digest(); print('b'+base64.b32encode(bytes([1,0x55,0x12,0x20])+d).decode().lower().rstrip('='))" "$1"; }
# wacc's module is larger than one block, so the subject is the tree it was assembled into, admitted as such.
module=$wacc
cat > policy.json5 <<EOF
{
  signers: { js: "$(claim address --key js.key)", rust: "$(claim address --key rust.key)",
             reviewer: "$(claim address --key reviewer.key)" },
  machines: ["wac-l0/1", "wac-flatten/1", "wasm-seam/1"],
  formats: ["unixfs-v1-2025+hidden"],
  roles: {
    // A module: assembled by both assemblers, from L0 text that is either reviewed or a rung's answer.
    assembled: [{ derived: { by: ["js", "rust"], at_least: 2, runners: 2, slots: { source: "l0" } } }],
    l0: [{ endorsed: { by: ["reviewer"], at_least: 1 } }, { within: { role: "answer", path: "out/answer.l0" } }],
    // A rung's answer: run on V8 and wasmtime, by a module that is itself assembled, from text that is reviewed or
    // flattened from reviewed sources.
    answer: [{ derived: { by: ["js", "rust"], at_least: 2, runners: 2,
                          slots: { module: "rung", source: "text", subject: "text" } } }],
    rung: [{ within: { role: "assembled", path: "out/module.wasm" } }],
    text: [{ endorsed: { by: ["reviewer"], at_least: 1 } }, { within: { role: "flattened", path: "out/flat.wac" } }],
    flattened: [{ derived: { by: ["js", "rust"], at_least: 2, runners: 2, other: "reviewed" } }],
    reviewed: [{ endorsed: { by: ["reviewer"], at_least: 1 } }],
  },
}
EOF
admit() { wac claim.wasm admit "$module" assembled --policy policy.json5 $st > admit.log 2>/dev/null && echo yes || echo no; }
[ "$(admit)" = no ] && grep -q "endorsed by nobody" admit.log && ok "refused while nobody has reviewed the rungs" || bad "admitted unreviewed: $(tail -3 admit.log)"
for f in "$boot/l1.l0" "$boot/l2.l1" "$boot/l3.l2" "$boot/l4.l3" "$boot/l5.l4"; do
  claim endorse "$(cid "$f")" "reviewed: wac's bootstrap rung $(basename "$f") at $short" --key reviewer.key >/dev/null
done
claim slots "$fr" | while read -r slot c; do claim endorse "$c" "reviewed: wacc's source at $short" --key reviewer.key >/dev/null; done
[ "$(admit)" = yes ] && ok "admitted: wacc, through $(grep -c "admitted as" admit.log) admitted objects, back to the five rungs and wacc's source" \
  || bad "refused: $(grep -i "refused\|nobody" admit.log | head -5)"
depth=$(grep -o "admitted as [a-z0-9]*" admit.log | sort | uniq -c | tr '\n' ' ')
echo "   $depth"
# The second runner of one middle step withdrawn: the L4 compiler's answer, on wasmtime.
l4r=$(wac boot.wasm recipe --module t/l3.wasm --source "$boot/l4.l3" $st 2>/dev/null)
d=$(wac boot.wasm run "$l4r" $st --work w-rust --tool "$SE_RUST" --key rust.key --runner "seam (wasmtime) at wac $short" 2>/dev/null | sed -n 2p)
cp -r store store-revoked
wac claim.wasm revoke "$d" --key rust.key --store store-revoked >/dev/null 2>&1
wac claim.wasm admit "$module" assembled --policy policy.json5 --store store-revoked > admit2.log 2>/dev/null && r=yes || r=no
[ "$r" = no ] && grep -q "on 1 runner" admit2.log && ok "wasmtime withdraws the L4 rung's run: one runner is not enough, and wacc is refused" \
  || bad "after the revocation: $r"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
