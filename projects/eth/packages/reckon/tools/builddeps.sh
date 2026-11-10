#!/bin/sh
# A build with dependencies as a derivation: wac-eth's own `obj` command (packages/ipfs/cmd/obj.wac, which imports wac's
# library), compiled by wac's compiler inside the machine, from an input tree holding wac-eth's source and, laid out as
# wac's package cache, every dependency wac.lock pins.
#
#     WASMTIME_WAC=/path/to/native/wac sh packages/reckon/tools/builddeps.sh [WORKDIR] [ENTRY]
#
# **This steps outside the machine, and says so.** The compiler finds its package cache through $WAC_HOME, and the
# machine gives a program no environment. Until wac lets a runner serve a fixed environment, the runner hands the
# program its own (`derive --env-from-runner`), started under `env -i` with WAC_HOME alone; such a run is never signed.
# What it shows is that nothing else stands in the way: the build reproduces on both engines and is byte-identical to
# the same compiler run natively, although the cache sits at different absolute paths in the two.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:-$(mktemp -d)}
entry=${2:-packages/ipfs/cmd/obj.wac}
WT=${WASMTIME_WAC:?set WASMTIME_WAC to the wac of the native host}
mkdir -p "$work"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok    $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }
node=$(command -v node)

cd "$root"
wac build --quiet --allow-read --allow-write --allow-run --allow-env packages/reckon/cmd/derive.wac -o "$work/derive"
wac build --quiet --allow-read --allow-write packages/ipfs/cmd/obj.wac -o "$work/obj"

# The compiler: the `wac` command at the commit wac.lock pins, built natively (selfbuild.sh shows it can build itself).
commit=$(sed -n 's/.*"wac": {.*"commit": "\([0-9a-f]\{40\}\)".*/\1/p' wac.lock | head -1)
quote() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
cache="$HOME/.wac/cache/git"
(cd "$cache/$(quote https://git.voltrevo.com/wac.git)/$commit" &&
  wac build --quiet --allow-read --allow-write --allow-run --allow-net --allow-env packages/wac/src/wac.wac -o "$work/wac")

# The input tree: wac-eth at HEAD under in/, and under home/cache/git/ every locked dependency as the cache holds it.
cd "$work"
rm -rf tree && mkdir -p tree/in tree/home/cache/git
git -C "$root" archive HEAD | tar -x -C tree/in
sed -n 's/.*"git": "\([^"]*\)".*"commit": "\([0-9a-f]\{40\}\)".*/\1 \2/p' "$root/wac.lock" | while read -r git c; do
  d="$(quote "$git")/$c"
  [ -d "$cache/$d" ] || { echo "not in the package cache: $git at $c (sh tools/deps.sh)" >&2; exit 1; }
  mkdir -p "tree/home/cache/git/$d" && cp -r "$cache/$d/." "tree/home/cache/git/$d/"
done
st="--store $work/store"
stem=$(basename "$entry" .wac)
# `--in tree` puts the tree at /in/in/ for a program that starts at /.
printf 'build\nin/in/in/%s\n-o\n/out/%s\n--allow-read\n--allow-write\n' "$entry" "$stem" > args
recipe=$(wac derive.wasm recipe --program wac.wasm --args args --in tree $st 2>/dev/null)
clean() { env -i PATH="$PATH" WAC_HOME=/in/in/home "$@"; }
o1=$(clean "$node" "$(command -v wac)" derive.wasm run "$recipe" $st --env-from-runner --timeout 1800000 2>/dev/null)
o2=$(clean "$WT" derive.wasm run "$recipe" $st --env-from-runner --timeout 1800000 2>/dev/null)
[ "$(wac obj.wasm cat "$o1" status $st)" = "exit 0" ] && ok "the compiler builds $entry, dependencies and all, inside the machine" \
  || bad "the build: $(wac obj.wasm cat "$o1" log $st | tail -3)"
[ "$o1" = "$o2" ] && ok "V8 and wasmtime derive the same output ($o1)" || bad "the engines differ: $o1, $o2"
wac obj.wasm cat "$o1" "out/$stem.wasm" $st > derived.wasm

# The same compiler, natively, on the same relative entry path, with the cache at another absolute path.
rm -rf native && mkdir -p native/in/in && cp -r tree/in tree/home native/in/in/
(cd native && env -i PATH="$PATH" WAC_HOME="$work/native/in/in/home" "$node" "$(command -v wac)" ../wac.wasm build \
  "in/in/in/$entry" -o "$stem" --allow-read --allow-write >/dev/null 2>&1)
cmp -s derived.wasm "native/$stem.wasm" && ok "byte-identical to the same compiler run natively ($(wc -c < derived.wasm) bytes)" \
  || bad "differs from the native build"
if [ "$stem" = obj ]; then
  wac derived.wasm ls "$o1" $st > listed.txt 2>/dev/null || true
  [ "$(head -1 listed.txt | cut -f1)" = log ] && ok "and the derived obj works: it lists its own build's output" \
    || bad "the derived obj does not run"
fi
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
