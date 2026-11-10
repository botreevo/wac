#!/bin/sh
# Milestone 1 of docs/browser-extension.md: admission in a real browser. cmd/web.wac (src/admission.wac behind a
# main(Sys)) admits ens:vitalik.eth on recorded mainnet data, first on the command line as a check of the entry
# point itself, then built with wac's `--target browser` and run in headless Chromium. Both read the same servers: the
# recorded execution and beacon nodes (tools/replay.mjs, tools/beacon-replay.mjs, both with CORS) and a claims mirror
# served over HTTP with CORS.
#
#     sh packages/reckon/tools/browser-admit.sh WORKDIR     (PORT defaults to 8860: the page, then 3 more)
#
# Needs: wac, node, Playwright's Chromium (preinstalled), deno (for wac's browser build: WAC_SRC is a checkout of
# wac at the pinned commit, at a path with no `%` in it, which deno's file URLs mangle).
#
# **The browser half is blocked on wac, twice, and says which**, counting nothing:
#   - W2: wac's browser build (packages/platform/build.ts) resolves relative, `@/`, core and std imports, and not
#     the packages a project's wac.lock pins, so a program importing "wac" (all of wac-eth) does not build for it;
#   - W1: in a page, wac's browser host refuses sockets (a page has no TCP), and there is no HTTP capability yet, so
#     admission would be refused "network access" at its first request.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=$1; rm -rf "$work"; mkdir -p "$work"; work=$(cd "$work" && pwd)
port=${PORT:-8860}; eport=$((port + 1)); bport=$((port + 2)); mport=$((port + 3))
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "   PASS ($*)"; }
bad() { fail=$((fail + 1)); echo "   FAIL ($*)"; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
pids=""
cleanup() { [ -n "$pids" ] && kill $pids 2>/dev/null || true; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM HUP
up() { until curl -s -m1 -o /dev/null "http://127.0.0.1:$1/"; do sleep 0.2; done; }

cd "$root"
wac build --quiet --allow-read --allow-write --allow-net --allow-env "$here/cmd/web.wac" -o "$work/web"
wac build --quiet --allow-read --allow-write --allow-net --allow-env "$here/cmd/claim.wac" -o "$work/claim"
cd "$work"
CL="wac $work/claim.wasm"
checkpoint=0xa8356934e2fba13cb82917ea04203c75ca84bb735cefe3cf2f35976628e1e937
content=bafybeia5eyombgegdwmvfzwisveadaaok2vdjkv5rklfdmcljysjrjc4km
printf '%s\n' c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3 > reviewer.key
policy="{ signers: { reviewer: \"$($CL address --key reviewer.key)\" }, roles: { app: [{ endorsed: { by: [\"reviewer\"], at_least: 1 } }] } }"
$CL endorse "$content" "reviewed the site" --key reviewer.key --store local >/dev/null 2>&1
$CL publish mirror --store local >/dev/null 2>&1
node "$here/tools/replay.mjs" $eport honest & pids="$pids $!"
node "$here/tools/beacon-replay.mjs" $bport honest & pids="$pids $!"
node "$here/tools/browser/serve.mjs" $mport mirror & pids="$pids $!"
up $bport; up $mport
until curl -s -m1 -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "http://127.0.0.1:$eport/" >/dev/null; do sleep 0.2; done

step "the entry point on the command line: web, over src/admission.wac"
out=$(wac web.wasm ens:vitalik.eth app --policy-text "$policy" --store cli --mirror "http://127.0.0.1:$mport" \
  --checkpoint $checkpoint --beacon-url "http://127.0.0.1:$bport" --now 15630000 --rpc 127.0.0.1:$eport 2>&1) && code=0 || code=$?
printf '%s\n' "$out" | sed 's/^/   | /'
[ $code -eq 0 ] && printf '%s' "$out" | grep -q "^ADMITTED" && ok "admitted, as claim admit admits it" || bad "exit $code"
printf '%s' "$out" | grep -qF "name: vitalik.eth → ipfs://$content" && ok "the name proved to the recorded CID" || bad "the name"

step "the same in headless Chromium: wac's --target browser, the program in a worker"
deno=$(command -v deno || true)
src=${WAC_SRC:-}
if [ -z "$deno" ] || [ -z "$src" ] || [ ! -f "$src/packages/platform/build.ts" ]; then
  echo "   SKIP (needs deno on PATH and WAC_SRC, a wac checkout at the pinned commit: see the header)"
else
  mkdir -p page
  (cd "$root" && deno run -A "$src/packages/platform/build.ts" "$here/cmd/web.wac" --target browser \
     --allow-read --allow-write --allow-net --allow-env -o "$work/page/web.html" > "$work/build.log" 2>&1) || true
fi
if [ -n "$deno" ] && [ -n "$src" ] && [ ! -s page/web.html ]; then
  if grep -q "no file was supplied at that path" build.log; then
    echo "   BLOCKED (W2: wac's browser build does not resolve wac.lock packages: $(grep -c 'no file was supplied' build.log) imports unresolved, e.g. $(grep -o '[^ /]*/src/[a-z0-9]*\.wac:[0-9]*' build.log | head -1))"
  else
    bad "the browser build failed: $(tail -3 build.log)"
  fi
elif [ -n "$deno" ] && [ -n "$src" ]; then
  ok "built: page/web.html, $(wc -c < page/web.html) bytes"
  node "$here/tools/browser/serve.mjs" $port page & pids="$pids $!"; up $port
  q=$(python3 -c 'import sys, urllib.parse; print("&".join("a=" + urllib.parse.quote(x, safe="") for x in sys.argv[1:]))' \
    ens:vitalik.eth app --policy-text "$policy" --mirror "http://127.0.0.1:$mport" --checkpoint $checkpoint \
    --beacon-url "http://127.0.0.1:$bport" --now 15630000 --rpc 127.0.0.1:$eport)
  page=$(node "$here/tools/browser/open.cjs" "http://127.0.0.1:$port/web.html?$q" 180000 2>&1)
  printf '%s\n' "$page" | sed 's/^/   | /'
  if printf '%s' "$page" | grep -q "^ADMITTED"; then
    ok "admitted in the browser"
    printf '%s' "$page" | grep -qF "name: vitalik.eth → ipfs://$content" && ok "the name proved to the recorded CID, in the browser" || bad "the name, in the browser"
  elif printf '%s' "$page" | grep -q "network access"; then
    echo "   BLOCKED (the page reached its first request and was refused \"network access\": wac's browser host has no HTTP yet, W1)"
  else
    bad "neither admitted nor refused for network access"
  fi
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
