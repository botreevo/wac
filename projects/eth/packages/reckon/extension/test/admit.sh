#!/bin/sh
# Milestone 3 of docs/browser-extension.md: the extension admits, then shows what it admitted. Its admission is
# cmd/web.wac built into the extension (build.sh), run in the extension's own page: the light client from a checkpoint
# against recorded mainnet data, claims from a mirror, the policy, and the admitted tree written into the extension's
# storage from checked blocks, then shown through the sandbox loader. See admit.cjs for what is checked.
#
#     WAC_SRC=/path/to/wac sh packages/reckon/extension/test/admit.sh WORKDIR     (PORT defaults to 8890, and 3 more)
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
reckon=$(cd "$here/.." && pwd)
root=$(cd "$reckon/../.." && pwd)
work=$1; rm -rf "$work"; mkdir -p "$work"; work=$(cd "$work" && pwd)
port=${PORT:-8890}; eport=$((port + 1)); bport=$((port + 2)); mport=$((port + 3))
pids=""
cleanup() { [ -n "$pids" ] && kill $pids 2>/dev/null || true; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM HUP

sh "$here/build.sh" > "$work/build.log" 2>&1 || { tail -5 "$work/build.log"; exit 1; }
cd "$root"
wac build --quiet --allow-read --allow-write --allow-net --allow-env "$reckon/cmd/claim.wac" -o "$work/claim"
wac build --quiet --allow-read --allow-write --allow-net packages/ipfs/cmd/obj.wac -o "$work/obj"
cd "$work"
CL="wac $work/claim.wasm"; O="wac $work/obj.wasm"
printf '%s\n' c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3 > reviewer.key

# An app, and another tree nobody reviewed; vitalik.eth's CID endorsed too, though its content is on no mirror here.
mkdir -p app/css app/data other
cat > app/index.html <<'HTML'
<!doctype html><meta charset=utf-8><title>an admitted app</title><link rel=stylesheet href="css/app.css">
<h1 id=h>admitted</h1>
<script src="main.js"></script>
HTML
printf 'h1 { color: rgb(7, 8, 9); }\n' > app/css/app.css
printf '{"says":"from its own tree"}\n' > app/data/x.json
cat > app/main.js <<'JS'
const r = (k, v) => parent.postMessage({ report: k, value: v }, '*');
r('origin', String(self.origin));
r('color', getComputedStyle(document.getElementById('h')).color);
fetch('data/x.json').then(x => x.json()).then(j => r('fetch', j.says), e => r('fetch', 'error ' + e));
JS
printf 'nobody reviewed this\n' > other/README
appCid=$($O add app --store pub); otherCid=$($O add other --store pub)
vitalik=bafybeia5eyombgegdwmvfzwisveadaaok2vdjkv5rklfdmcljysjrjc4km
$CL endorse "$appCid" reviewed --key reviewer.key --store pub >/dev/null 2>&1
$CL endorse "$vitalik" reviewed --key reviewer.key --store pub >/dev/null 2>&1
$CL publish pub --store pub >/dev/null 2>&1
policy="{ signers: { reviewer: \"$($CL address --key reviewer.key)\" }, roles: { app: [{ endorsed: { by: [\"reviewer\"], at_least: 1 } }] } }"

node "$reckon/tools/replay.mjs" $eport honest & pids="$pids $!"
node "$reckon/tools/beacon-replay.mjs" $bport honest & pids="$pids $!"
node "$reckon/tools/browser/serve.mjs" $mport pub & pids="$pids $!"
until curl -s -m1 -o /dev/null "http://127.0.0.1:$mport/" && curl -s -m1 -o /dev/null "http://127.0.0.1:$bport/"; do sleep 0.2; done

cat > settings.json <<JSON
{ "checkpoint": "0xa8356934e2fba13cb82917ea04203c75ca84bb735cefe3cf2f35976628e1e937",
  "beaconUrl": "http://127.0.0.1:$bport", "rpc": "127.0.0.1:$eport", "now": "15630000",
  "mirrors": "http://127.0.0.1:$mport", "policy": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$policy") }
JSON
node "$here/test/admit.cjs" "$work/settings.json" "$appCid" "$otherCid" "$vitalik"
