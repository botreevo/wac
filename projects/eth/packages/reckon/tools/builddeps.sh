#!/bin/sh
# A build with dependencies as a derivation: wac-eth's own `obj` command (packages/ipfs/cmd/obj.wac, which imports wac's
# library), compiled by wac's compiler inside the machine, from an input tree holding wac-eth's source and, laid out as
# wac's package cache, every dependency wac.lock pins.
#
#     WASMTIME_WAC=/path/to/native/wac sh packages/reckon/tools/builddeps.sh [WORKDIR] [ENTRY[:GRANTS]]…
#
# With no ENTRY it builds four of wac-eth's commands in one run, from one input tree: obj, claim, derive and lc. GRANTS
# are the build's `--allow-…` flags, comma-separated: the module records them, so they are part of what it is.
#
# **Inside the machine, and signed.** The compiler is told where its package cache is with `--wac-home /in/in/home`
# (wac since fade22039), not through $WAC_HOME, so it needs no environment and runs sealed like any other derivation,
# and each runner signs what it got. The entry is relative (`in/in/in/…`, which wac resolves from `/` since 0450d).
# Each build reproduces on both engines and is, byte for byte, the module the same compiler makes natively from the same
# relative entry, although the cache sits at a different absolute path there.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:-$(mktemp -d)}
shift $(( $# > 0 ? 1 : 0 ))
entries=${*:-packages/ipfs/cmd/obj.wac:read,write packages/reckon/cmd/claim.wac:read,write,net packages/reckon/cmd/derive.wac:read,write,run,env packages/lightclient/cmd/lc.wac:read}
WT=${WASMTIME_WAC:?set WASMTIME_WAC to the wac of the native host}
mkdir -p "$work"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok    $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }
node=$(command -v node)

cd "$root"
wac build --quiet --allow-read --allow-write --allow-run --allow-env packages/reckon/cmd/derive.wac -o "$work/derive"
wac build --quiet --allow-read --allow-write packages/ipfs/cmd/obj.wac -o "$work/obj"
wac build --quiet --allow-read --allow-write --allow-run --allow-env --allow-net packages/reckon/cmd/deps.wac -o "$work/deps"

# The compiler: the `wac` command at the commit wac.lock pins, built natively (selfbuild.sh shows it can build itself).
commit=$(sed -n 's/.*"wac": {.*"commit": "\([0-9a-f]\{40\}\)".*/\1/p' wac.lock | head -1)
quote() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
cache="$HOME/.wac/cache/git"
(cd "$cache/$(quote https://git.voltrevo.com/wac.git)/$commit" &&
  wac build --quiet --allow-read --allow-write --allow-run --allow-net --allow-env packages/wac/src/wac.wac -o "$work/wac")

# The input tree is wac-eth at HEAD, and the dependencies are what the working wac.lock pins, so a tree with changes not
# committed would build something other than what is on disk (a moved pin found the old wac missing from the copied
# cache). Refuse it, saying what to do.
if [ -n "$(git -C "$root" status --porcelain)" ]; then
  echo "builddeps: the tree has changes not committed, and the build takes HEAD: commit first" >&2
  git -C "$root" status --short >&2
  exit 2
fi
# The input tree: wac-eth at HEAD under in/, and under home/cache/git/ every locked dependency as the cache holds it.
cd "$work"
rm -rf tree && mkdir -p tree/in tree/home/cache/git
git -C "$root" archive HEAD | tar -x -C tree/in
sed -n 's/.*"git": "\([^"]*\)".*"commit": "\([0-9a-f]\{40\}\)".*/\1 \2/p' "$root/wac.lock" | while read -r git c; do
  d="$(quote "$git")/$c"
  [ -d "$cache/$d" ] || { echo "not in the package cache: $git at $c (sh tools/deps.sh)" >&2; exit 1; }
  mkdir -p "tree/home/cache/git/$d" && cp -r "$cache/$d/." "tree/home/cache/git/$d/"
done
# The dependencies in the input are what wac.lock pins by CID (docs/lock.md): each copied checkout is hashed again,
# less the cache's marker, and must be its entry's `cid`. An unpinned lock, or a cache that drifted, builds nothing.
WAC_HOME="$work/tree/home" wac deps.wasm check --lock "$root/wac.lock" > deps.check 2>&1 \
  && ok "the dependencies in the input are the CIDs wac.lock pins: $(grep -c '^ok' deps.check)" \
  || { bad "the dependencies are not what wac.lock pins: $(grep -v '^ok' deps.check | head -3)"; echo "$pass passed, $fail failed"; exit 1; }
st="--store $work/store"
# The runners' keys: the test keys everyone has, or with RUNNER_KEYS=DIR, the v8.key and wt.key in DIR, for a build
# whose claims are published (extension/release.sh).
if [ -n "${RUNNER_KEYS:-}" ]; then cp "$RUNNER_KEYS/v8.key" "$RUNNER_KEYS/wt.key" .; else
printf '%s\n' 4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318 > v8.key
printf '%s\n' 646f1ce2fdad0e6deeeb5c7e8e5543bdde65e86029e2fd9fc169899c440a7913 > wt.key
fi
for spec in $entries; do
  entry=${spec%%:*}
  grants=$([ "$spec" = "$entry" ] && echo "" || echo "${spec#*:}" | tr ',' ' ')
  flags=""; for g in $grants; do flags="$flags --allow-$g"; done
  stem=$(basename "$entry" .wac)
  # `--in tree` puts the tree at /in/in/; the cache is at /in/in/home, named to the compiler by --wac-home.
  { printf 'build\n--wac-home\n/in/in/home\nin/in/in/%s\n-o\n/out/%s\n' "$entry" "$stem"; for f in $flags; do echo "$f"; done; } > "$stem.args"
  recipe=$(wac derive.wasm recipe --program wac.wasm --args "$stem.args" --in tree $st 2>/dev/null)
  o1=$(wac derive.wasm run "$recipe" $st --key v8.key --runner "reckon-derive/2 v8" --timeout 1800000 2>/dev/null | sed -n 1p)
  o2=$($WT derive.wasm run "$recipe" $st --key wt.key --runner "reckon-derive/2 wasmtime" --timeout 1800000 2>/dev/null | sed -n 1p)
  [ "$(wac obj.wasm cat "$o1" status $st)" = "exit 0" ] && ok "$stem: the compiler builds $entry, dependencies and all, inside the machine" \
    || { bad "$stem: the build: $(wac obj.wasm cat "$o1" log $st | tail -3)"; continue; }
  [ "$o1" = "$o2" ] && ok "$stem: V8 and wasmtime derive the same output ($o1), each signing it" || bad "$stem: the engines differ: $o1, $o2"
  wac obj.wasm cat "$o1" "out/$stem.wasm" $st > "$stem.derived.wasm"

  # The same compiler, natively, on the same relative entry path, with the cache at another absolute path.
  [ -d native ] || { mkdir -p native/in/in && cp -r tree/in tree/home native/in/in/; }
  (cd native && "$node" "$(command -v wac)" ../wac.wasm build --wac-home "$work/native/in/in/home" \
    "in/in/in/$entry" -o "$stem" $flags >/dev/null 2>&1)
  cmp -s "$stem.derived.wasm" "native/$stem.wasm" \
    && ok "$stem: byte for byte the module the same compiler makes natively ($(wc -c < "$stem.derived.wasm") bytes)" \
    || bad "$stem: differs from the native build: $(python3 "$here/tools/wasmdiff.py" "$stem.derived.wasm" "native/$stem.wasm" | head -3)"
  # And it runs: with no arguments each of these refuses politely, saying how it is used, rather than trapping.
  wac "$stem.derived.wasm" > "$stem.said" 2>&1 || true
  if [ -s "$stem.said" ] && ! grep -qi "trap\|unreachable\|RuntimeError" "$stem.said"; then
    ok "$stem: the derived program runs (\"$(head -1 "$stem.said" | cut -c1-60)…\")"
  else
    bad "$stem: the derived program did not run: $(head -2 "$stem.said")"
  fi
done
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
