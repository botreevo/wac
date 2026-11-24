#!/bin/sh
# Decision D, milestone 2b (docs/flatten-machine.md): the flattener as a machine. wac-L5 ignores `import`, so wac's
# bootstrap turns a module graph into one program before the L5 compiler sees it, renaming the private names two
# modules share. `wac-flatten/1` is that rule. Its two runners are wac's two flatteners, written apart and required to
# agree: JavaScript (`bootstrap/js/flatten.js`, under node) and Rust (`bootstrap/rust-ladder/src/flatten.rs`, through
# the ladder's `--dump-flat`). Each signs what it got. Checked:
#   - both give one output for wacc's source (the program the L5 compiler builds), and for wac's imports fixture,
#     which resolves a bare specifier up the directory chain;
#   - inside the runner, the tree written under a work directory, wacc flattens to the same bytes as the ladder makes
#     from wac's own checkout: where the tree sits does not change the program;
#   - an import of a file the tree lacks is refused by both, as one output; an entry outside the tree is not a recipe;
#   - admission: flattened wacc is admitted only when both runners witness it and its source is endorsed.
#
#     LADDER=/path/to/bootstrap/rust-ladder/target/release/ladder sh packages/reckon/tools/flatten.sh [WORKDIR]
#
# Without LADDER, the ladder is built with cargo from the pinned source (V8: long). Needs wac on PATH, node, python3.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:-$(mktemp -d)}
mkdir -p "$work"
work=$(cd "$work" && pwd)
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok    $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }

commit=$(sed -n 's/.*"wac": {.*"commit": "\([0-9a-f]\{40\}\)".*/\1/p' "$root/wac.lock" | head -1)
src=${WACSRC:-$HOME/.wac/cache/git/https%3A%2F%2Fgit.voltrevo.com%2Fwac.git/$commit}
[ -d "$src/bootstrap" ] || { echo "no wac source at $src: run sh tools/deps.sh" >&2; exit 1; }
short=$(echo "$commit" | cut -c1-9)
if [ -z "${LADDER:-}" ]; then
  echo "building the ladder (cargo, V8) from $short"
  (cd "$src/bootstrap/rust-ladder" && cargo build --release --quiet --target-dir "$work/ladder-target")
  LADDER=$work/ladder-target/release/ladder
fi

cd "$root"
wac build --quiet --allow-read --allow-write --allow-run packages/reckon/cmd/boot.wac -o "$work/boot"
wac build --quiet --allow-read --allow-write packages/reckon/cmd/claim.wac -o "$work/claim"
wac build --quiet --allow-read --allow-write packages/ipfs/cmd/obj.wac -o "$work/obj"
cd "$work"
rm -rf store w-* && mkdir -p inputs
st="--store $work/store"
claim() { wac claim.wasm "$@" $st 2>/dev/null; }
JS="node $here/tools/boot/flatten.mjs $src/bootstrap/js/flatten.js"
RUST="sh $here/tools/boot/flatten-rust.sh $LADDER"
printf '%s\n' 4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318 > rust.key
printf '%s\n' 646f1ce2fdad0e6deeeb5c7e8e5543bdde65e86029e2fd9fc169899c440a7913 > js.key
printf '%s\n' add2f9f8b6e2bff7d0b6e7d1bbcd8fe16c3fbd8b5b1fbb1c0a63e5a0e7a2c3b1 > reviewer.key
RUST_NAME="flatten.rs (ladder --dump-flat) at wac $short"
JS_NAME="flatten.js (node) at wac $short"

# flatten NAME DIR ENTRY [WANT]: one recipe, run by both runners; both outputs must be one CID. Sets $recipe and $out.
flatten() {
  recipe=$(wac boot.wasm recipe --tree "$2" --entry "$3" $st 2>/dev/null)
  a=$(wac boot.wasm run "$recipe" $st --work w-rust --tool "$RUST" --key rust.key --runner "$RUST_NAME" 2>/dev/null | sed -n 1p)
  b=$(wac boot.wasm run "$recipe" $st --work w-js --tool "$JS" --key js.key --runner "$JS_NAME" 2>/dev/null | sed -n 1p)
  out=$a
  [ -n "$a" ] && [ "$a" = "$b" ] && [ "$(wac obj.wasm cat "$a" status $st)" = "${4:-ok}" ] \
    && ok "$1: both flatteners give one output, ${4:-ok} ($a)" || bad "$1: rust $a, js $b"
}

echo; echo "## wacc, the program the L5 compiler builds"
cp -r "$src/packages/wacc/src" inputs/wacc
flatten "wacc ($(ls inputs/wacc | wc -l | tr -d ' ') modules, entry api.wac)" inputs/wacc api.wac
wacc=$out; waccRecipe=$recipe
wac obj.wasm cat "$wacc" out/flat.wac $st > flat.wac
(cd "$src" && "$LADDER" packages/wacc/src/api.wac --dump-flat) > ladder-flat.wac
cmp -s flat.wac ladder-flat.wac && ok "the same $(wc -c < flat.wac) bytes the ladder flattens from wac's checkout" \
  || bad "the machine's flattening differs from the ladder's own"

echo; echo "## wac's imports fixture: a bare specifier, found up the directory chain"
cp -r "$src/bootstrap/tests/l5" inputs/l5
flatten "bootstrap/tests/l5/imports.l5" inputs/l5 imports.l5
wac obj.wasm cat "$out" out/flat.wac $st | grep -q "scaled" && ok "and the flattened program carries what lib/scale.l5 declares" \
  || bad "the fixture's imports are missing"

echo; echo "## what is not an answer"
mkdir -p inputs/broken && printf 'import { f } from "./missing.wac";\nexport i32 main() { return f(); }\n' > inputs/broken/main.wac
flatten "an import of a file the tree lacks" inputs/broken main.wac refused
escape=$(wac boot.wasm recipe --tree inputs/broken --entry ../../outside.wac $st 2>/dev/null)
r=$(wac boot.wasm run "$escape" $st --work w-esc --tool "$JS" 2>esc.log | sed -n 1p || true)
[ -z "$r" ] && grep -q "names its entry, within tree/" esc.log && ok "an entry outside the tree is not a recipe for this machine" \
  || bad "an escaping entry gave $r: $(cat esc.log)"

echo; echo "## admission: flattened wacc, through both runners and its reviewed source"
cat > policy.json5 <<EOF
{
  signers: { rust: "$(claim address --key rust.key)", js: "$(claim address --key js.key)",
             reviewer: "$(claim address --key reviewer.key)" },
  machines: ["wac-flatten/1"],
  formats: ["unixfs-v1-2025+hidden"],
  roles: {
    flattened: [{ derived: { by: ["rust", "js"], at_least: 2, runners: 2, other: "source" } }],
    source: [{ endorsed: { by: ["reviewer"], at_least: 1 } }],
  },
}
EOF
admit() { wac claim.wasm admit "$wacc" flattened --policy policy.json5 $st > admit.log 2>/dev/null && echo yes || echo no; }
[ "$(admit)" = no ] && grep -q "endorsed by nobody" admit.log && ok "refused while nobody has reviewed wacc's source" \
  || bad "admitted unreviewed: $(cat admit.log)"
claim slots "$waccRecipe" | while read -r slot cid; do claim endorse "$cid" reviewed --key reviewer.key >/dev/null; done
[ "$(admit)" = yes ] && ok "admitted: flattened by both runners from reviewed source" || bad "refused: $(cat admit.log)"
sed 's/^/   | /' admit.log
d=$(wac boot.wasm run "$waccRecipe" $st --work w-js --tool "$JS" --key js.key --runner "$JS_NAME" 2>/dev/null | sed -n 2p)
claim revoke "$d" --key js.key >/dev/null
[ "$(admit)" = no ] && grep -q "on 1 runner" admit.log && ok "the JavaScript runner revokes its derivation: the Rust one alone is not enough" \
  || bad "after a revocation: $(cat admit.log)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
