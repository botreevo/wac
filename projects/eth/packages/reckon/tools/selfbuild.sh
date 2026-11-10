#!/bin/sh
# Builds as derivations: the wac compiler, run by the deterministic machine, compiling a program, and then the program
# it produced, run by the machine in turn. Source to compiler to app to output, every step a recipe whose output is a
# CID, run on V8 and on wasmtime, and admitted only through the derivation graph.
#
#     WASMTIME_WAC=/path/to/native/wac sh packages/reckon/tools/selfbuild.sh [WORKDIR]
#
# The compiler is wac's own `wac` command at the commit wac-eth pins, built to a plain module. Checked:
#   - the compiler, inside the machine, gives the same bytes as the same compiler run natively;
#   - V8 and wasmtime derive the same app (one CID), and the app's own run agrees too;
#   - with SELF=1 (about 4 minutes more), the compiler builds itself from its 4,050-file source inside the machine on both
#     engines, and that compiler builds itself again, byte for byte: a fixed point, witnessed;
#   - admission: the app is admitted only when the build is witnessed by both runners, the compiler is a trust root
#     (or, with SELF=1, is itself derived from endorsed source), and the source is endorsed.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:-$(mktemp -d)}
WT=${WASMTIME_WAC:?set WASMTIME_WAC to the wac of the native host}
WACSRC=${WACSRC:-}
mkdir -p "$work"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok    $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }

# The pinned wac commit, from wac-eth's lock, and its source as wac's package cache holds it (`sh tools/deps.sh`), less
# the cache's own `pack.pack` marker. WACSRC may name a directory holding that tree instead.
commit=$(sed -n 's/.*"wac": {.*"commit": "\([0-9a-f]\{40\}\)".*/\1/p' "$root/wac.lock" | head -1)
src=${WACSRC:-$HOME/.wac/cache/git/https%3A%2F%2Fgit.voltrevo.com%2Fwac.git/$commit}
[ -d "$src" ] || { echo "no wac source at $src: run sh tools/deps.sh" >&2; exit 1; }
cd "$work"
rm -rf wacsrc && mkdir -p wacsrc/in && cp -r "$src/." wacsrc/in/ && rm -f wacsrc/in/pack.pack

cd "$root"
wac build --quiet --allow-read --allow-write --allow-run packages/reckon/cmd/derive.wac -o "$work/derive"
wac build --quiet --allow-read --allow-write packages/reckon/cmd/claim.wac -o "$work/claim"
wac build --quiet --allow-read --allow-write packages/ipfs/cmd/obj.wac -o "$work/obj"
cd "$work/wacsrc/in"
wac build --quiet --allow-read --allow-write --allow-run --allow-net --allow-env packages/wac/src/wac.wac -o "$work/wac"
cd "$work"
st="--store $work/store"
objcat() { wac obj.wasm cat "$@" $st; }
claim() { wac claim.wasm "$@" $st 2>/dev/null; }
printf '%s\n' 4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318 > v8.key
printf '%s\n' 646f1ce2fdad0e6deeeb5c7e8e5543bdde65e86029e2fd9fc169899c440a7913 > wt.key
printf '%s\n' add2f9f8b6e2bff7d0b6e7d1bbcd8fe16c3fbd8b5b1fbb1c0a63e5a0e7a2c3b1 > reviewer.key

# A program to build: imports std only, so the input is just its source.
rm -rf app && mkdir -p app/in && cat > app/in/hello.wac <<'EOF'
import { Sys } from "std";
export i32 main(Sys sys) { sys.log("hello from a derived build"); return 0; }
EOF
# The program starts at `/` with the input tree at `/in`, and `--in DIR` puts DIR under `in/`: app/in/hello.wac is in/in/hello.wac.
printf 'build\nin/in/hello.wac\n-o\n/out/hello\n' > app.args
build=$(wac derive.wasm recipe --program wac.wasm --args app.args --in app/in $st 2>/dev/null)
o1=$(wac derive.wasm run "$build" $st --timeout 600000 --key v8.key --runner "reckon-derive/1 v8" 2>/dev/null | sed -n 1p)
o2=$($WT derive.wasm run "$build" $st --timeout 600000 --key wt.key --runner "reckon-derive/1 wasmtime" 2>/dev/null | sed -n 1p)
[ "$(objcat "$o1" status)" = "exit 0" ] && ok "the compiler, as a derivation, builds the app" || bad "the build: $(objcat "$o1" status)"
[ "$o1" = "$o2" ] && ok "V8 and wasmtime derive the same app ($o1)" || bad "the engines built different apps: $o1, $o2"
objcat "$o1" out/hello.wasm > derived.wasm
rm -rf native && mkdir -p native/in && cp -r app/in native/in/   # the same relative entry path, in/in/hello.wac
(cd native && wac ../wac.wasm build in/in/hello.wac -o hello >/dev/null 2>&1)
cmp -s derived.wasm native/hello.wasm && ok "byte-identical to the same compiler run natively" || bad "differs from a native run"

# The app, run by the machine: a second derivation whose program is the file the first one produced.
rm -rf none && mkdir none
run=$(wac derive.wasm recipe --program derived.wasm $st 2>/dev/null)
r1=$(wac derive.wasm run "$run" $st --key v8.key --runner "reckon-derive/1 v8" 2>/dev/null | sed -n 1p)
r2=$($WT derive.wasm run "$run" $st --key wt.key --runner "reckon-derive/1 wasmtime" 2>/dev/null | sed -n 1p)
[ "$(objcat "$r1" log)" = "hello from a derived build" ] && ok "the derived app runs: \"$(objcat "$r1" log)\"" || bad "the app's run"
[ "$r1" = "$r2" ] && ok "and both engines agree on its run" || bad "the engines ran it differently"

# Admission over the chain: the run's result is admitted only through the build that made its program.
compiler=$(claim slots "$build" | sed -n 's/^program //p')
source=$(claim slots "$build" | sed -n 's/^in //p')
args=$(claim slots "$build" | sed -n 's/^args //p')
cat > policy.json5 <<EOF2
{
  signers: { v8: "$(claim address --key v8.key)", wasmtime: "$(claim address --key wt.key)",
             reviewer: "$(claim address --key reviewer.key)" },
  roots: ["$compiler"],
  machines: ["$(sed -n 's/.*MACHINE() { return "\(.*\)"; }.*/\1/p' "$here/src/machine.wac")"],
  formats: ["unixfs-v1-2025+hidden"],
  roles: {
    result: [{ derived: { by: ["v8", "wasmtime"], at_least: 2, runners: 2, slots: { program: "app" } } }],
    app: [{ within: { role: "build", path: "out/hello.wasm" } }],
    build: [{ derived: { by: ["v8", "wasmtime"], at_least: 2, runners: 2,
                         slots: { program: "compiler", in: "source", args: "source" } } }],
    compiler: ["root"],
    source: [{ endorsed: { by: ["reviewer"], at_least: 1 } }],
  },
}
EOF2
admit() { wac claim.wasm admit "$r1" result --policy policy.json5 $st > admit.log 2>/dev/null && echo yes || echo no; }
[ "$(admit)" = no ] && grep -q "endorsed by nobody" admit.log && ok "refused while nobody has reviewed the source" || bad "admitted unreviewed: $(cat admit.log)"
claim endorse "$source" reviewed --key reviewer.key >/dev/null
claim endorse "$args" reviewed --key reviewer.key >/dev/null
[ "$(admit)" = yes ] && ok "admitted: run, app, build, compiler and source each accounted for" || bad "refused: $(cat admit.log)"
cat admit.log

if [ -n "${SELF:-}" ]; then
  # The compiler building itself from its own source inside the machine, twice: A (built natively) builds B, then B
  # builds C. The program starts at `/`, so B and C record their entry as `in/in/packages/…` where A recorded
  # `packages/…`; B and C must still be byte-identical: a fixed point, witnessed.
  printf 'build\nin/in/packages/wac/src/wac.wac\n-o\n/out/wac\n--allow-read\n--allow-write\n--allow-run\n--allow-net\n--allow-env\n' > self.args
  self=$(wac derive.wasm recipe --program wac.wasm --args self.args --in wacsrc/in $st 2>/dev/null)
  sb=$(wac derive.wasm run "$self" $st --timeout 7200000 --key v8.key --runner "reckon-derive/1 v8" 2>/dev/null | sed -n 1p)
  objcat "$sb" out/wac.wasm > b.wasm
  [ -s b.wasm ] && ok "A built B, the compiler, from its source inside the machine ($(wc -c < b.wasm) bytes)" || bad "A could not build B: $(objcat "$sb" status)"
  sb2=$($WT derive.wasm run "$self" $st --timeout 7200000 --key wt.key --runner "reckon-derive/1 wasmtime" 2>/dev/null | sed -n 1p)
  [ "$sb" = "$sb2" ] && ok "wasmtime derives the same compiler" || bad "the engines built different compilers"
  self2=$(wac derive.wasm recipe --program b.wasm --args self.args --in wacsrc/in $st 2>/dev/null)
  sc=$(wac derive.wasm run "$self2" $st --timeout 7200000 --key v8.key --runner "reckon-derive/1 v8" 2>/dev/null | sed -n 1p)
  objcat "$sc" out/wac.wasm > c.wasm
  cmp -s b.wasm c.wasm && ok "B built C, and C is B byte for byte: the compiler reproduces itself" || bad "B and C differ"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
