#!/bin/sh
# Decision D, milestone 2 (docs/l0-machine.md): wac-L0 as a machine. `wac-l0/1` assembles one L0 text into one wasm
# module, by the written rule in wac's bootstrap/spec/l0.md. Its two runners are wac's two assemblers, written apart
# and required to agree: Rust (`wax`) and JavaScript (`bootstrap/js/assemble.js`, under node). Each signs what it
# got. Checked:
#   - both runners give one output, every L0 text wac's tests have and boot/l1.l0 (the ladder's first rung); with
#     LADDER, also the largest L0 the ladder makes, wacc's;
#   - the modules compute what wac's bootstrap/tests/expect.json says;
#   - a text that is not L0 is refused by both, as one output; an assembler that crashes gives no output and no claim;
#   - admission: the L1 interpreter (l1.l0's module) is admitted only when both runners witness it and its source is
#     endorsed, not on one runner, not on a lying assembler's word, and not after a runner revokes.
#
#     sh packages/reckon/tools/l0.sh [WORKDIR]
#     LADDER=/path/to/bootstrap/rust-ladder/target/release/ladder …   add wacc's L0, as the ladder's L5 compiler makes it
#
# Needs wac on PATH, node, cargo (to build `wax` from the pinned source) and python3. A few minutes; with LADDER, ten.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:-$(mktemp -d)}
mkdir -p "$work"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok    $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }

commit=$(sed -n 's/.*"wac": {.*"commit": "\([0-9a-f]\{40\}\)".*/\1/p' "$root/wac.lock" | head -1)
src=${WACSRC:-$HOME/.wac/cache/git/https%3A%2F%2Fgit.voltrevo.com%2Fwac.git/$commit}
[ -d "$src/bootstrap" ] || { echo "no wac source at $src: run sh tools/deps.sh" >&2; exit 1; }
short=$(echo "$commit" | cut -c1-9)

cd "$root"
wac build --quiet --allow-read --allow-write --allow-run packages/reckon/cmd/boot.wac -o "$work/boot"
wac build --quiet --allow-read --allow-write packages/reckon/cmd/claim.wac -o "$work/claim"
wac build --quiet --allow-read --allow-write packages/ipfs/cmd/obj.wac -o "$work/obj"
echo "building wax, the Rust assembler, from $short (no dependencies)"
(cd "$src/bootstrap/rust" && cargo build --release --quiet --target-dir "$work/wax-target")
cd "$work"
rm -rf store texts && mkdir texts
st="--store $work/store"
claim() { wac claim.wasm "$@" $st 2>/dev/null; }
RUST="$work/wax-target/release/wax"
JS="node $here/tools/boot/assemble.mjs $src/bootstrap/js/assemble.js"
printf '%s\n' 4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318 > rust.key
printf '%s\n' 646f1ce2fdad0e6deeeb5c7e8e5543bdde65e86029e2fd9fc169899c440a7913 > js.key
printf '%s\n' add2f9f8b6e2bff7d0b6e7d1bbcd8fe16c3fbd8b5b1fbb1c0a63e5a0e7a2c3b1 > reviewer.key
printf '%s\n' 8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba > liar.key
RUST_NAME="wax (Rust) at wac $short"
JS_NAME="wax.js (node) at wac $short"

# assemble NAME FILE: one recipe, run by both runners; both outputs must be one CID. Sets $recipe and $out.
assemble() {
  recipe=$(wac boot.wasm recipe --source "$2" $st 2>/dev/null)
  a=$(wac boot.wasm run "$recipe" $st --work w-rust --tool "$RUST" --key rust.key --runner "$RUST_NAME" 2>/dev/null | sed -n 1p)
  b=$(wac boot.wasm run "$recipe" $st --work w-js --tool "$JS" --key js.key --runner "$JS_NAME" 2>/dev/null | sed -n 1p)
  out=$a
  [ -n "$a" ] && [ "$a" = "$b" ] && [ "$(wac obj.wasm cat "$a" status $st)" = "${3:-ok}" ] \
    && ok "$1: both assemblers give one output, ${3:-ok} ($a)" || bad "$1: rust $a, js $b"
}

echo; echo "## every L0 text wac's tests hold, and the ladder's first rung"
for f in "$src"/bootstrap/tests/l0/*.l0 "$src/bootstrap/boot/l1.l0"; do
  name=${f#"$src/bootstrap/"}
  assemble "$name" "$f"
  wac obj.wasm cat "$out" out/module.wasm $st > "texts/$(echo "$name" | tr / _).wasm"
  [ "$name" = boot/l1.l0 ] && { l1recipe=$recipe; l1out=$out; }
done
if [ -n "${LADDER:-}" ]; then
  echo "   wacc's L0, from the ladder's L5 compiler:"
  (cd "$src" && "$LADDER" packages/wacc/src/api.wac --l0 > "$work/texts/wacc.l0")
  echo "   $(wc -c < texts/wacc.l0) bytes, $(wc -l < texts/wacc.l0) lines"
  assemble "wacc.l0" texts/wacc.l0
fi

echo; echo "## the modules compute what wac's bootstrap/tests/expect.json says"
cat > run.mjs <<'EOF'
// node run.mjs EXPECT_JSON DIR: instantiate each module the machine made and call `main`.
import { readFileSync } from "node:fs";
const expect = JSON.parse(readFileSync(process.argv[2], "utf8"));
let good = 0, all = 0;
for (const [path, want] of Object.entries(expect)) {
  all++;
  const file = `${process.argv[3]}/${path.replace(/^tests\//, "tests_").replace(/^boot\//, "boot_").replaceAll("/", "_")}.wasm`;
  try {
    const { instance } = await WebAssembly.instantiate(readFileSync(file), {});
    const got = instance.exports.main();
    if (got === want) good++; else console.log(`   ${path}: main() gave ${got}, not ${want}`);
  } catch (e) { console.log(`   ${path}: ${e.message}`); }
}
console.log(`${good} ${all}`);
EOF
res=$(node run.mjs "$src/bootstrap/tests/expect.json" texts | tail -1)
[ "${res% *}" = "${res#* }" ] && ok "${res% *} of ${res#* } compute their expected main(), the L1 interpreter's 720 among them" \
  || bad "only ${res% *} of ${res#* }: $(node run.mjs "$src/bootstrap/tests/expect.json" texts)"

echo; echo "## what is not an answer"
printf 'func $f -> i32\n  i32.bogus\nend\n' > texts/bad.l0
assemble "a text that is not L0" texts/bad.l0 refused
[ "$(wac obj.wasm ls "$out" $st | grep -c module.wasm || true)" = 0 ] && ok "and a refusal holds no module" || bad "a refusal with a module"
crashed=$(wac boot.wasm run "$l1recipe" $st --work w-crash --tool "sh -c 'exit 2' --" --key rust.key --runner crash 2>crash.log | sed -n 1p || true)
[ -z "$crashed" ] && grep -q "abort: the tool failed" crash.log && ok "an assembler that fails gives no output and signs nothing" \
  || bad "a failed assembler gave $crashed: $(cat crash.log)"

echo; echo "## admission: the L1 interpreter, through both runners and a reviewed source"
cat > liar.sh <<'EOF'
#!/bin/sh
# The Rust assembler, then one byte changed: what a compromised runner would sign.
"$WAX" "$1" "$2" && python3 -c "import sys; b=bytearray(open(sys.argv[1],'rb').read()); b[-1]^=1; open(sys.argv[1],'wb').write(b)" "$2"
EOF
lied=$(WAX="$RUST" wac boot.wasm run "$l1recipe" $st --work w-liar --tool "WAX=$RUST sh $work/liar.sh" --key liar.key --runner "wax (Rust), altered" 2>/dev/null | sed -n 1p)
[ -n "$lied" ] && [ "$lied" != "$l1out" ] && ok "a lying assembler gets another output ($lied), and signs it" || bad "the liar: $lied"
n=$(claim origins "$l1out" | grep -c . || true)
[ "$n" = 2 ] && ok "the index has two derivations of the honest output" || bad "origins: $(claim origins "$l1out")"
source=$(claim slots "$l1recipe" | sed -n 's/^source //p')
wac obj.wasm cat "$l1out" out/module.wasm $st > l1.wasm
l1=$(python3 -c "import sys,hashlib,base64; d=hashlib.sha256(open(sys.argv[1],'rb').read()).digest(); print('b'+base64.b32encode(bytes([1,0x55,0x12,0x20])+d).decode().lower().rstrip('='))" l1.wasm)
liarl1=$(wac obj.wasm cat "$lied" out/module.wasm $st | python3 -c "import sys,hashlib,base64; d=hashlib.sha256(sys.stdin.buffer.read()).digest(); print('b'+base64.b32encode(bytes([1,0x55,0x12,0x20])+d).decode().lower().rstrip('='))")
cat > policy.json5 <<EOF
{
  signers: { rust: "$(claim address --key rust.key)", js: "$(claim address --key js.key)",
             liar: "$(claim address --key liar.key)", reviewer: "$(claim address --key reviewer.key)" },
  machines: ["wac-l0/1"],
  formats: ["unixfs-v1-2025+hidden"],
  roles: {
    interpreter: [{ within: { role: "assembled", path: "out/module.wasm" } }],
    assembled: [{ derived: { by: ["rust", "js", "liar"], at_least: 2, runners: 2, other: "source" } }],
    source: [{ endorsed: { by: ["reviewer"], at_least: 1 } }],
  },
}
EOF
admit() { wac claim.wasm admit "$1" interpreter --policy policy.json5 $st > admit.log 2>/dev/null && echo yes || echo no; }
[ "$(admit "$l1")" = no ] && grep -q "endorsed by nobody" admit.log && ok "refused while nobody has reviewed boot/l1.l0" \
  || bad "admitted unreviewed: $(cat admit.log)"
endorsement=$(claim endorse "$source" reviewed --key reviewer.key)
[ "$(admit "$l1")" = yes ] && ok "admitted: the interpreter's bytes, assembled by both runners from reviewed L0" || bad "refused: $(cat admit.log)"
cat admit.log | sed 's/^/   | /'
[ "$(admit "$liarl1")" = no ] && grep -q "on 1 runner" admit.log && ok "the liar's module is refused: one runner's word" \
  || bad "the liar's module: $(cat admit.log)"
d=$(wac boot.wasm run "$l1recipe" $st --work w-js --tool "$JS" --key js.key --runner "$JS_NAME" 2>/dev/null | sed -n 2p)
claim revoke "$d" --key js.key >/dev/null
[ "$(admit "$l1")" = no ] && grep -q "on 1 runner" admit.log && ok "the JavaScript runner revokes its derivation: the Rust one alone is not enough" \
  || bad "after a revocation: $(cat admit.log)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
