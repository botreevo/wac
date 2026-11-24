#!/bin/sh
# Conformance suites for the bootstrap's host-run machines, `wac-l0/1` and `wac-flatten/1` (docs/conformance.md,
# "The bootstrap's machines"). As for `wasm-gc/wac-host/3`, a suite is an object whose `cases` file lists recipes and
# the output each must give; a policy naming it counts a runner's witness under that machine only once the runner has
# witnessed the whole suite with those outputs. Checked:
#   - each suite: every case gives the status it should (a module or a program, or a refusal), both runners agree on
#     each, and it is one object;
#   - the four runners (wax and wax.js; flatten.rs and flatten.js) witness their suites; then an assembled module and a
#     flattened program, neither in a suite, are admitted with every witness counted;
#   - a runner that has not witnessed the suite is not counted, however honest its claim;
#   - a runner that gives one case another output is not counted (an assembler that pads a module; a flattener that
#     renames one name differently);
#   - a runner that revokes one of its suite derivations stops counting.
#
#     LADDER=/path/to/bootstrap/rust-ladder/target/release/ladder sh packages/reckon/tools/bootconf.sh [WORKDIR]
#
# Needs wac on PATH, node, cargo (offline, for wax) and the pinned wac in the package cache. A few minutes.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:-$(mktemp -d)}
mkdir -p "$work"; work=$(cd "$work" && pwd)
LADDER=${LADDER:?set LADDER to the ladder binary of wac: bootstrap/rust-ladder/target/release/ladder}
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok    $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }

commit=$(sed -n 's/.*"wac": {.*"commit": "\([0-9a-f]\{40\}\)".*/\1/p' "$root/wac.lock" | head -1)
src=${WACSRC:-$HOME/.wac/cache/git/https%3A%2F%2Fgit.voltrevo.com%2Fwac.git/$commit}
[ -d "$src/bootstrap" ] || { echo "no wac source at $src: run sh tools/deps.sh" >&2; exit 1; }
short=$(echo "$commit" | cut -c1-9)
tests=$src/bootstrap/tests

cd "$root"
wac build --quiet --allow-read --allow-write --allow-run packages/reckon/cmd/boot.wac -o "$work/boot"
wac build --quiet --allow-read --allow-write packages/reckon/cmd/claim.wac -o "$work/claim"
wac build --quiet --allow-read --allow-write packages/ipfs/cmd/obj.wac -o "$work/obj"
(cd "$src/bootstrap/rust" && cargo build --release --quiet --offline --target-dir "$work/wax-target")
cd "$work"
rm -rf store w-* inputs suites names && mkdir -p inputs suites/l0 suites/flatten
st="--store $work/store"
claim() { wac claim.wasm "$@" $st 2>/dev/null; }
printf '%s\n' 4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318 > js.key
printf '%s\n' 646f1ce2fdad0e6deeeb5c7e8e5543bdde65e86029e2fd9fc169899c440a7913 > rust.key
printf '%s\n' add2f9f8b6e2bff7d0b6e7d1bbcd8fe16c3fbd8b5b1fbb1c0a63e5a0e7a2c3b1 > fresh.key
printf '%s\n' 8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba > odd.key
L0_JS="node $here/tools/boot/assemble.mjs $src/bootstrap/js/assemble.js";   L0_RUST="$work/wax-target/release/wax"
FL_JS="node $here/tools/boot/flatten.mjs $src/bootstrap/js/flatten.js";     FL_RUST="sh $here/tools/boot/flatten-rust.sh $LADDER"
L0_JS_NAME="wax.js (node) at wac $short";                   L0_RUST_NAME="wax (Rust) at wac $short"
FL_JS_NAME="flatten.js (node) at wac $short";               FL_RUST_NAME="flatten.rs (ladder --dump-flat) at wac $short"
status() { wac obj.wasm cat "$1" status $st 2>/dev/null; }

# case SUITE NAME WANT RECIPE…: run unsigned by both runners of SUITE; both give one output whose status is WANT, or
# FAIL. The case's line in the suite. Sets $out.
case_() {
  if [ "$1" = l0 ]; then t1=$L0_JS; t2=$L0_RUST; else t1=$FL_JS; t2=$FL_RUST; fi
  a=$(wac boot.wasm run "$4" $st --work w-a --tool "$t1" 2>/dev/null | sed -n 1p)
  b=$(wac boot.wasm run "$4" $st --work w-b --tool "$t2" 2>/dev/null | sed -n 1p)
  out=$a
  if [ -n "$a" ] && [ "$a" = "$b" ] && [ "$(status "$a")" = "$3" ]; then
    echo "$4 $a" >> "suites/$1/cases"; echo "$1 $2 $4 $a" >> names
  else
    bad "$1 case $2: $a ($(status "$a")), $b ($(status "$b")), want one output, $3"
  fi
}
l0case() { case_ l0 "$1" "$2" "$(wac boot.wasm recipe --source "$3" $st 2>/dev/null)"; }
flcase() { case_ flatten "$1" "$2" "$(wac boot.wasm recipe --tree "$3" --entry "$4" $st 2>/dev/null)"; }

echo; echo "## the wac-l0/1 suite: wac's own L0 tests, the hand-written first rung, and texts that are not L0"
printf '# Conformance suite for wac-l0/1, at wac %s (wac-eth tools/bootconf.sh).\n# RECIPE OUTPUT\n' "$short" > suites/l0/cases
for f in "$tests"/l0/*.l0; do l0case "$(basename "$f" .l0)" ok "$f"; done
l0case l1 ok "$src/bootstrap/boot/l1.l0"
mkdir -p inputs/l0
printf '' > inputs/l0/empty.l0
l0case empty ok inputs/l0/empty.l0                                        # no functions: a module with nothing in it
printf 'garbage here\n' > inputs/l0/directive.l0
l0case unknown-directive refused inputs/l0/directive.l0
printf 'func $f -> i32\n  i32.frobnicate\nend\n' > inputs/l0/instr.l0
l0case unknown-instruction refused inputs/l0/instr.l0
printf 'func $f -> i32\n  call $nowhere\nend\n' > inputs/l0/name.l0
l0case unknown-name refused inputs/l0/name.l0
l0suite=$(wac obj.wasm add suites/l0 $st 2>/dev/null | tail -1)
n=$(grep -c '^bafy' suites/l0/cases || true)
refusals=$(awk '$1 == "l0" { print $4 }' names | while read -r o; do echo "$(status "$o")"; done | grep -c refused || true)
[ "$n" -eq 14 ] && ok "the wac-l0/1 suite: $n cases ($refusals refusals), one object: $l0suite" \
  || bad "the wac-l0/1 suite has $n cases"

echo; echo "## the wac-flatten/1 suite: wac's L5 tests, the imports fixture, renaming, wacc's own sources, and a refusal"
printf '# Conformance suite for wac-flatten/1, at wac %s (wac-eth tools/bootconf.sh).\n# RECIPE OUTPUT\n' "$short" > suites/flatten/cases
mkdir -p inputs/l5 && cp -r "$tests/l5/." inputs/l5/
for f in inputs/l5/*.l5; do flcase "$(basename "$f" .l5)" ok inputs/l5 "$(basename "$f")"; done
# Two modules declaring one private name, and an import renamed with `as`: the renaming rules (the second module's
# `helper` becomes `helper_b`, and `two as deux` is undone).
mkdir -p inputs/clash/util
printf 'i32 helper() { return 1; }\nexport i32 one() { return helper(); }\n' > inputs/clash/util/a.wac
printf 'i32 helper() { return 2; }\nexport i32 two() { return helper(); }\n' > inputs/clash/util/b.wac
printf 'import { one } from "./util/a.wac";\nimport { two as deux } from "./util/b.wac";\nexport i32 main() { return one() + deux(); }\n' > inputs/clash/main.wac
flcase clash ok inputs/clash main.wac
mkdir -p inputs/wacc && cp -r "$src/packages/wacc/src/." inputs/wacc/
flcase wacc ok inputs/wacc api.wac
mkdir -p inputs/broken && printf 'import { f } from "./missing.wac";\nexport i32 main() { return f(); }\n' > inputs/broken/main.wac
flcase missing-import refused inputs/broken main.wac
flsuite=$(wac obj.wasm add suites/flatten $st 2>/dev/null | tail -1)
n=$(grep -c '^bafy' suites/flatten/cases || true)
[ "$n" -eq 6 ] && ok "the wac-flatten/1 suite: $n cases, one object: $flsuite" || bad "the wac-flatten/1 suite has $n cases"

# witness SUITE KEY TOOL NAME: a runner signing every case of SUITE.
witness() {
  sed -n '/^bafy/p' "suites/$1/cases" | while read -r r want; do
    wac boot.wasm run "$r" $st --work w-wit --tool "$3" --key "$2.key" --runner "$4" >/dev/null 2>&1 || true
  done
}
echo; echo "## the four runners witness their suites"
witness l0 js "$L0_JS" "$L0_JS_NAME";      witness l0 rust "$L0_RUST" "$L0_RUST_NAME"
witness flatten js "$FL_JS" "$FL_JS_NAME"; witness flatten rust "$FL_RUST" "$FL_RUST_NAME"
ok "wax.js, wax, flatten.js and flatten.rs have signed their suites' cases"

echo; echo "## subjects in neither suite, and a policy that counts only conforming runners"
# An L0 text no case has: add.l0 with a comment of its own, so its source is another object and its module the same.
{ printf '; a subject, not a case\n'; cat "$tests/l0/add.l0"; } > inputs/l0/subject.l0
l0r=$(wac boot.wasm recipe --source inputs/l0/subject.l0 $st 2>/dev/null)
l0out=$(wac boot.wasm run "$l0r" $st --work w-a --tool "$L0_JS" --key js.key --runner "$L0_JS_NAME" 2>/dev/null | sed -n 1p)
wac boot.wasm run "$l0r" $st --work w-b --tool "$L0_RUST" --key rust.key --runner "$L0_RUST_NAME" >/dev/null 2>&1
# A program no case has, and with no clash in it, so a flattener that renames clashes its own way agrees on it.
mkdir -p inputs/subject/util && cp inputs/clash/util/a.wac inputs/subject/util/
printf '// a subject, not a case\nimport { one } from "./util/a.wac";\nexport i32 main() { return one(); }\n' > inputs/subject/main.wac
flr=$(wac boot.wasm recipe --tree inputs/subject --entry main.wac $st 2>/dev/null)
flout=$(wac boot.wasm run "$flr" $st --work w-a --tool "$FL_JS" --key js.key --runner "$FL_JS_NAME" 2>/dev/null | sed -n 1p)
wac boot.wasm run "$flr" $st --work w-b --tool "$FL_RUST" --key rust.key --runner "$FL_RUST_NAME" >/dev/null 2>&1
policy() {   # policy BY…: each subject derived by two of BY on two runners, its inputs roots, under both suites
  by=$(for w in "$@"; do printf '"%s", ' "$w"; done)
  roots=$( (claim slots "$l0r"; claim slots "$flr") | awk '{printf "\"%s\", ", $2}')
  cat > policy.json5 <<EOF
{
  signers: { js: "$(claim address --key js.key)", rust: "$(claim address --key rust.key)",
             fresh: "$(claim address --key fresh.key)", odd: "$(claim address --key odd.key)" },
  roots: [$roots],
  machines: ["wac-l0/1", "wac-flatten/1"],
  formats: ["unixfs-v1-2025+hidden"],
  conformance: { "wac-l0/1": "$l0suite", "wac-flatten/1": "$flsuite" },
  roles: {
    assembled: [{ derived: { by: [$by], at_least: 2, runners: 2, other: "input" } }],
    flattened: [{ derived: { by: [$by], at_least: 2, runners: 2, other: "input" } }],
    input: ["root"],
  },
}
EOF
}
admit() { wac claim.wasm admit "$1" "$2" --policy policy.json5 $st > admit.log 2>/dev/null && echo yes || echo no; }
policy js rust
[ "$(admit "$l0out" assembled)" = yes ] && ok "admitted: the module, witnessed by wax and wax.js, both conforming" || bad "module refused: $(cat admit.log)"
[ "$(admit "$flout" flattened)" = yes ] && ok "admitted: the program, witnessed by flatten.rs and flatten.js, both conforming" || bad "program refused: $(cat admit.log)"

echo; echo "## runners that do not count"
wac boot.wasm run "$l0r" $st --work w-c --tool "$L0_RUST" --key fresh.key --runner "wax (Rust) at wac $short, another host" >/dev/null 2>&1
policy js fresh
[ "$(admit "$l0out" assembled)" = no ] && grep -q "fresh on .*: it has witnessed 0 of the suite's 14 cases with an output" admit.log \
  && ok "an assembler that never witnessed the suite is not counted, though its module is right" || bad "fresh: $(cat admit.log)"
grep -o "not counted: .*" admit.log | sort -u | sed 's/^not counted: /   | /'
# An assembler that pads every module with a byte: its suite outputs are other trees.
cat > pad.sh <<EOF
#!/bin/sh
$L0_RUST "\$1" "\$2" && [ -f "\$2" ] && printf '\\000' >> "\$2"
EOF
witness l0 odd "sh $work/pad.sh" "wax (Rust), padded"
wac boot.wasm run "$l0r" $st --work w-c --tool "$L0_RUST" --key odd.key --runner "wax (Rust), padded" >/dev/null 2>&1
policy js odd
[ "$(admit "$l0out" assembled)" = no ] && grep -q "odd on .*: it gave .* where the suite says" admit.log \
  && ok "an assembler that gives the suite's cases other modules is not counted, even where its claim is right" || bad "odd l0: $(cat admit.log)"
grep -o "not counted: .*" admit.log | sort -u | head -1 | sed 's/^not counted: /   | /'
# A flattener that renames a clashing private name its own way: right on every case but the clash.
cat > rename.sh <<EOF
#!/bin/sh
$FL_RUST "\$1" "\$2" || exit \$?
[ -f "\$2" ] && sed -i 's/helper_b/helper__b/g' "\$2"
exit 0
EOF
witness flatten odd "sh $work/rename.sh" "flatten.rs, its own renaming"
oddout=$(wac boot.wasm run "$flr" $st --work w-c --tool "sh $work/rename.sh" --key odd.key --runner "flatten.rs, its own renaming" 2>/dev/null | sed -n 1p)
[ "$oddout" = "$flout" ] && ok "the renaming flattener's claim about the subject is true: $oddout" || bad "the renaming flattener gave $oddout for the subject"
[ "$(admit "$flout" flattened)" = no ] && grep -q "odd on .*: it gave .* where the suite says" admit.log \
  && ok "a flattener that renames one clash its own way is not counted, even on a program where it agrees" || bad "odd flatten: $(cat admit.log)"
grep -o "not counted: .*" admit.log | sort -u | head -1 | sed 's/^not counted: /   | /'

echo; echo "## a revocation"
first=$(awk '$1 == "l0" && $2 == "add" { print $3 }' names)
d=$(wac boot.wasm run "$first" $st --work w-d --tool "$L0_RUST" --key rust.key --runner "$L0_RUST_NAME" 2>/dev/null | sed -n 2p)
claim revoke "$d" --key rust.key >/dev/null
policy js rust
[ "$(admit "$l0out" assembled)" = no ] && grep -q "rust on .*: it has witnessed 13 of the suite's 14 cases with an output" admit.log \
  && ok "wax revokes one suite case: it no longer counts" || bad "after a revocation: $(cat admit.log)"
[ "$(admit "$flout" flattened)" = yes ] && ok "and the flattener's suite is another: flatten.rs still counts" || bad "flatten after the l0 revocation: $(cat admit.log)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
