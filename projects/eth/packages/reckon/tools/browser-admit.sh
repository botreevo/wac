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
# The browser half needs wac at 78c748c1 or later: its browser build resolves wac.lock packages (W2a), and a page's
# HTTP goes through the browser's fetch (W1), so the servers it reads send CORS headers.
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
epid=""; bpid=""
replay() { [ -n "$epid" ] && kill $epid 2>/dev/null; sleep 0.2; node "$here/tools/replay.mjs" $eport "$1" & epid=$!; pids="$pids $epid"
  until curl -s -m1 -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "http://127.0.0.1:$eport/" >/dev/null; do sleep 0.2; done; }
beacon() { [ -n "$bpid" ] && kill $bpid 2>/dev/null; sleep 0.2; node "$here/tools/beacon-replay.mjs" $bport "$1" & bpid=$!; pids="$pids $bpid"; up $bport; }
replay honest; beacon honest
node "$here/tools/browser/serve.mjs" $mport mirror & pids="$pids $!"
up $mport

step "the entry point on the command line: web, over src/admission.wac"
out=$(wac web.wasm ens:vitalik.eth app --policy-text "$policy" --store cli --mirror "http://127.0.0.1:$mport" \
  --checkpoint $checkpoint --beacon-url "http://127.0.0.1:$bport" --now 15630000 --rpc 127.0.0.1:$eport 2>&1) && code=0 || code=$?
printf '%s\n' "$out" | sed 's/^/   | /'
[ $code -eq 0 ] && printf '%s' "$out" | grep -q "^ADMITTED" && ok "admitted, as claim admit admits it" || bad "exit $code"
printf '%s' "$out" | grep -qF "name: vitalik.eth → ipfs://$content" && ok "the name proved to the recorded CID" || bad "the name"

step "the same in headless Chromium: wac's --target browser, the program in a worker, its HTTP the browser's fetch"
src=${WAC_SRC:-}
if ! command -v deno >/dev/null || [ -z "$src" ] || [ ! -f "$src/packages/platform/build.ts" ]; then
  bad "the browser half needs deno on PATH and WAC_SRC, a wac checkout at the pinned commit: see the header"
else
  mkdir -p page
  (cd "$root" && deno run -A "$src/packages/platform/build.ts" "$here/cmd/web.wac" --target browser \
     --allow-read --allow-write --allow-net --allow-env -o "$work/page/web.html" > "$work/build.log" 2>&1) || true
  [ -s page/web.html ] && ok "built: page/web.html, $(wc -c < page/web.html) bytes" || bad "the browser build: $(tail -3 build.log)"
  node "$here/tools/browser/serve.mjs" $port page & pids="$pids $!"; up $port
  # in_page EXPECT WHAT BECAUSE [CHECKPOINT]: run the page with the usual settings, and check how it ends.
  in_page() {
    want=$1; what=$2; because=$3; cp=${4:-$checkpoint}
    q=$(python3 -c 'import sys, urllib.parse; print("&".join("a=" + urllib.parse.quote(x, safe="") for x in sys.argv[1:]))' \
      ens:vitalik.eth app --policy-text "$policy" --mirror "http://127.0.0.1:$mport" --checkpoint "$cp" \
      --beacon-url "http://127.0.0.1:$bport" --now 15630000 --rpc 127.0.0.1:$eport)
    got=$(node "$here/tools/browser/open.cjs" "http://127.0.0.1:$port/web.html?$q" 180000 2>&1)
    printf '%s\n' "$got" | grep -v '^$\|^web.wac$\|^Arguments come' | sed 's/^/   | /'
    if printf '%s' "$got" | grep -q '^\[exit 0\]'; then g=admitted; else g=refused; fi
    if [ "$g" != "$want" ]; then bad "$what: wanted $want, got $g"
    elif ! printf '%s' "$got" | grep -qF -- "$because"; then bad "$what: $g, but not because \"$because\""
    else ok "$what: $g, because \"$because\""; fi
  }
  in_page admitted "ens:vitalik.eth, in the browser: checkpoint → light client → anchored name → mirror's claims → policy" \
    "name: vitalik.eth → ipfs://$content"
  in_page refused "in the browser, a checkpoint the bootstrap is not for" "HTTP 404" 0x$(printf 'cd%.0s' $(seq 32))
  beacon bootstrap; in_page refused "in the browser, a beacon node that changes a byte of the bootstrap" "not the checkpoint's"
  beacon update;    in_page refused "in the browser, …of an update" "an update did not verify"
  beacon finality;  in_page refused "in the browser, …of the finality update" "the finality update did not verify"
  beacon honest
  replay header;    in_page refused "in the browser, an execution node that answers the anchor with another header" "re-encodes to a different hash"
  replay proof;     in_page refused "in the browser, an execution node that changes a storage proof" "the name:"
  replay honest
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
