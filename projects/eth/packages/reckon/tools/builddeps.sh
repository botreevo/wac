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
# **This steps outside the machine, and says so.** The compiler finds its package cache through $WAC_HOME, and the
# machine gives a program no environment. Until wac lets a runner serve a fixed environment, the runner hands the
# program its own (`derive --env-from-runner`), started under `env -i` with WAC_HOME alone; such a run is never signed.
# What it shows is that nothing else stands in the way: each build reproduces on both engines and is the same module the
# same compiler makes natively (all but the manifest's record of the entry path, which is absolute in the machine),
# although the cache sits at different absolute paths in the two.
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
clean() { env -i PATH="$PATH" WAC_HOME=/in/in/home "$@"; }
for spec in $entries; do
  entry=${spec%%:*}
  grants=$([ "$spec" = "$entry" ] && echo "" || echo "${spec#*:}" | tr ',' ' ')
  flags=""; for g in $grants; do flags="$flags --allow-$g"; done
  stem=$(basename "$entry" .wac)
  # `--in tree` puts the tree at /in/in/. The entry is given absolute: given relative, inside the machine, wac's
  # compiler refuses an `@/` import as leaving its project (a wac issue, reported; natively the same build works).
  { printf 'build\n/in/in/in/%s\n-o\n/out/%s\n' "$entry" "$stem"; for f in $flags; do echo "$f"; done; } > "$stem.args"
  recipe=$(wac derive.wasm recipe --program wac.wasm --args "$stem.args" --in tree $st 2>/dev/null)
  o1=$(clean "$node" "$(command -v wac)" derive.wasm run "$recipe" $st --env-from-runner --timeout 1800000 2>/dev/null)
  o2=$(clean "$WT" derive.wasm run "$recipe" $st --env-from-runner --timeout 1800000 2>/dev/null)
  [ "$(wac obj.wasm cat "$o1" status $st)" = "exit 0" ] && ok "$stem: the compiler builds $entry, dependencies and all, inside the machine" \
    || { bad "$stem: the build: $(wac obj.wasm cat "$o1" log $st | tail -3)"; continue; }
  [ "$o1" = "$o2" ] && ok "$stem: V8 and wasmtime derive the same output ($o1)" || bad "$stem: the engines differ: $o1, $o2"
  wac obj.wasm cat "$o1" "out/$stem.wasm" $st > "$stem.derived.wasm"

  # The same compiler, natively, on the same relative entry path, with the cache at another absolute path.
  [ -d native ] || { mkdir -p native/in/in && cp -r tree/in tree/home native/in/in/; }
  (cd native && env -i PATH="$PATH" WAC_HOME="$work/native/in/in/home" "$node" "$(command -v wac)" ../wac.wasm build \
    "in/in/in/$entry" -o "$stem" $flags >/dev/null 2>&1)
  # The manifest records the entry path as given, /in/… here and relative on the host; everything else must match.
  [ "$(python3 "$here/tools/wasmdiff.py" "$stem.derived.wasm" "native/$stem.wasm")" = same ] \
    && ok "$stem: the same module as the same compiler run natively, but for the manifest's entry path ($(wc -c < "$stem.derived.wasm") bytes)" \
    || bad "$stem: differs from the native build"
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
