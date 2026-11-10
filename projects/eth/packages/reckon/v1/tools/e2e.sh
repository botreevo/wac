#!/bin/sh
# The whole of design/system/0016, end to end, on a wacuum devnet: build, rebuild, sign, publish, name, run —
# and then every attack the design says it stops, each checked to be stopped for the reason it claims.
#
#     sh packages/reckon/v1/tools/e2e.sh WORKDIR       (from anywhere; WACUUM defaults to packages/wacuum/dist/wacuum.wasm, TOOLCHAIN to
#                                          WORKDIR/toolchain: the kt1 of the wac tree the `wac` on PATH was built from)
#
# Needs: wac on PATH, node with tools/oracle's packages installed, git, curl, python3.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
work=$1; mkdir -p "$work"; work=$(cd "$work" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
wacuum=${WACUUM:-$root/packages/wacuum/dist/wacuum.wasm}
[ -f "$wacuum" ] || { echo "e2e: build wacuum first: (cd packages/wacuum && wac build --allow-read --allow-write --allow-net cmd/wacuum.wac -o dist/wacuum)" >&2; exit 2; }
W="wac $here/dist/reckon.wasm"
wallet="node $here/tools/wallet/wallet.mjs"
keys=$work/keys; stmts=$work/stmts; mirror=$work/mirror; evil=$work/mirror-evil
mkdir -p "$keys" "$stmts" "$mirror" "$evil"
pass=0; fail=0
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
matches() {  # matches OUTPUT 'PHRASE || PHRASE …': whether OUTPUT contains any one of the phrases
  rest=$2
  while :; do
    case "$rest" in *" || "*) p=${rest%%" || "*}; rest=${rest#*" || "} ;; *) p=$rest; rest="" ;; esac
    if printf '%s' "$1" | grep -qF -- "$p"; then return 0; fi
    if [ -z "$rest" ]; then return 1; fi
  done
}
expect() {  # expect ok|refused DESCRIPTION [BECAUSE] -- command…   (BECAUSE: a phrase the output must contain, or
            # several separated by " || ", any one of which will do)
  want=$1; what=$2; because=""; shift 2
  if [ "$1" != "--" ]; then because=$1; shift; fi
  shift
  if out=$("$@" 2>&1); then got=ok; else got=refused; fi
  printf '%s\n' "$out" | sed 's/^/   | /'
  if [ "$got" != "$want" ]; then fail=$((fail+1)); echo "   FAIL ($what: wanted $want, got $got)"
  elif [ -n "$because" ] && ! matches "$out" "$because"; then fail=$((fail+1)); echo "   FAIL ($what: $got, but not because \"$because\")"
  else pass=$((pass+1)); echo "   PASS ($what: $got${because:+, because \"$because\"})"; fi
}

step "a devnet: wacuum --dev, its state proved by its own eth_getProof"
mkdir -p "$work/devnet"
( cd "$work/devnet" && exec wac "$wacuum" --dev --datadir data --port 8545 > node.log 2>&1 ) &
node_pid=$!
trap 'kill $node_pid ${liar_pid:-} ${http_pid:-} 2>/dev/null || true' EXIT
until curl -s -m1 -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' http://127.0.0.1:8545/ >/dev/null; do sleep 0.5; done
# A wacuum built before it kept recent states (1fd0013) proves only its head, so a proof can lose the race with the
# next block. dist/ is not in git: refuse a stale one, with the fix, rather than flake on it.
_n() { curl -s -m2 -X POST -H 'content-type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}" "http://127.0.0.1:$1/"; }
until [ "$(_n 8545 eth_blockNumber '[]' | sed -n 's/.*"result":"0x\([0-9a-f]*\)".*/\1/p')" != 0 ]; do sleep 0.5; done
sleep 2.5
_b=$(_n 8545 eth_blockNumber '[]' | sed -n 's/.*"result":"\(0x[0-9a-f]*\)".*/\1/p')
if _n 8545 eth_getBalance "[\"0x0000000000000000000000000000000000000000\",\"$(printf '0x%x' $((_b - 1)))\"]" | grep -q "not available"; then
  echo "e2e: $wacuum keeps only its head's state; rebuild it (wac task wacuum:build)" >&2; exit 2
fi
printf '1111111111111111111111111111111111111111111111111111111111111111' > "$keys/dev"
for k in publisher rebuilder1 rebuilder2 reviewer denylist thief; do
  [ -f "$keys/$k" ] || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$keys/$k"
  eval "addr_$k=\$($wallet address $keys/$k)"
  $wallet fund "$keys/dev" "$($wallet address $keys/$k)" 10 >/dev/null
done
set -- $($wallet deploy "$keys/dev"); registry=$1; codehash=$2
echo "registry $registry, runtime code $codehash"

step "build from a clean commit, and two independent rebuilds from a fresh clone"
cd "$root"
toolchain=${TOOLCHAIN:-$(cat "$work/toolchain" 2>/dev/null || true)}
[ -n "$toolchain" ] || { echo "e2e: set TOOLCHAIN, or write it to $work/toolchain" >&2; exit 2; }
echo "$toolchain" > "$work/toolchain"
commit=$(git rev-parse HEAD)
$W build --dir packages/reckon/v1/examples/hello --path hello.wasm --toolchain "$toolchain" --key "$keys/publisher" --out "$stmts/hello.pub.json" -- wac build hello.wac -o hello
$W build --dir packages/reckon/v1/examples/notes --path dist/index.html --toolchain "$toolchain" --key "$keys/publisher" --out "$stmts/notes.pub.json" \
  -- wac run --allow-read --allow-write --allow-run build.wac src/app.wac dist --title notes
rm -rf "$work/clone"; git clone -q "$root" "$work/clone"
for app in hello notes; do for r in rebuilder1 rebuilder2; do
  WAC_HOME=${WAC_HOME:-$HOME/.wac} $W rebuild "$stmts/$app.pub.json" --git "$work/clone" "$commit" --toolchain "$toolchain" --key "$keys/$r" --out "$stmts/$app.$r.json"
done; done
source=$(sed -n 's/.*"source":"\(kt1:[0-9a-f]*\)".*/\1/p' "$stmts/hello.pub.json")
$W review "$source" "read all of it" --key "$keys/reviewer" --out "$stmts/source.review.json"
hello=$(sed -n 's/.*"output":"\(kb1:[0-9a-f]*\)".*/\1/p' "$stmts/hello.pub.json")
notes=$(sed -n 's/.*"output":"\(kb1:[0-9a-f]*\)".*/\1/p' "$stmts/notes.pub.json")
echo "hello $hello"; echo "notes $notes"

step "publish to a mirror; name both apps on chain, each change to wait 20 s"
$W publish "$mirror" --blob packages/reckon/v1/examples/hello/hello.wasm --blob packages/reckon/v1/examples/notes/dist/index.html $(for f in "$stmts"/*.json; do printf -- '--statement %s ' "$f"; done)
$wallet claim "$keys/publisher" "$registry" hello "$hello" 20
$wallet claim "$keys/publisher" "$registry" notes "$notes" 20
cat > "$work/trust.json5" <<POLICY
{
  // The rebuilders are who vouch for builds; the publisher's own statement does not count towards the quorum.
  signers: { publisher: '$addr_publisher', rebuilder1: '$addr_rebuilder1', rebuilder2: '$addr_rebuilder2', reviewer: '$addr_reviewer' },
  app: { built: { of: ['rebuilder1', 'rebuilder2'], at_least: 2 }, reviewed: { of: ['reviewer'], at_least: 1 } },
  dependency: { reviewed: { of: ['reviewer'], at_least: 1 } },
  toolchains: ['$toolchain'],
  deny: ['$addr_denylist'],
  freshness: { max_age: 120, on_stale: 'refuse' },
  follow: { min_delay: 10 },
  chain: { rpc: '127.0.0.1:8545', registry: '$registry', code_hash: '$codehash' },
}
POLICY
P="--policy $work/trust.json5"
pub=$addr_publisher

step "1. the command-line app: resolved, decided, fetched, hash-checked, run holding nothing"
expect ok "run hello" "hello from a verified module, world" -- $W run "hello@$pub" $P --mirror "$mirror" -- world
step "2. the web app: the same, and the checked bytes written out to open from file://"
expect ok "run notes" -- $W run "notes@$pub" $P --mirror "$mirror" --out "$work/notes-verified"
cmp "$work/notes-verified/index.html" packages/reckon/v1/examples/notes/dist/index.html && echo "   the page written is the page built"

step "3. a mirror serving other bytes is ignored when another has the right ones, and refused when it is the only one"
mkdir -p "$evil/blobs"; cp -r "$mirror/statements" "$evil/"
h=${hello#kb1:}; cp packages/reckon/v1/examples/notes/dist/index.html "$evil/blobs/$h"
expect ok "evil mirror first, honest second" "hello from a verified module" -- $W run "hello@$pub" $P --mirror "$evil" --mirror "$mirror"
expect refused "evil mirror only" "do not hash to" -- $W run "hello@$pub" $P --mirror "$evil"
step "   ...and the same mirror over HTTP"
( cd "$mirror" && exec python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1 ) & http_pid=$!
until curl -s -m1 -o /dev/null http://127.0.0.1:8765/; do sleep 0.2; done
expect ok "honest mirror over http" -- $W run "hello@$pub" $P --mirror http://127.0.0.1:8765

step "4. a forged statement: rebuilder2's signature over a different output"
python3 - "$stmts/hello.rebuilder2.json" "$work/forged.json" <<'PY'
import sys, json; s = json.load(open(sys.argv[1])); s["output"] = "kb1:" + "ee" * 32; open(sys.argv[2], "w").write(json.dumps(s, separators=(",", ":")))
PY
expect refused "verify a forged statement" "as it claims" -- $W verify "$work/forged.json"

step "5. a stranger's statements count for nothing"
$W build --dir packages/reckon/v1/examples/hello --path hello.wasm --toolchain "$toolchain" --key "$keys/thief" --out "$work/thief.json" -- wac build hello.wac -o hello >/dev/null 2>&1
$W publish "$work/mirror-thief" --blob packages/reckon/v1/examples/hello/hello.wasm --statement "$work/thief.json" --statement "$stmts/hello.rebuilder1.json" --statement "$stmts/source.review.json" >/dev/null
expect refused "one rebuilder and a stranger" "built by rebuilder1 (need 2)" -- $W run "$hello" $P --mirror "$work/mirror-thief"

step "6. a rebuilder revokes: the quorum is gone"
id=$($W verify "$stmts/hello.rebuilder2.json" | sed 's/.*id 0x//')
$wallet revoke "$keys/rebuilder2" "$registry" "$id"
expect refused "run hello after rebuilder2 revoked" "rebuilder2 revoked statement" -- $W run "hello@$pub" $P --mirror "$mirror"
expect ok "notes is not affected" -- $W run "notes@$pub" $P --mirror "$mirror" --out "$work/notes-verified"

step "7. a node that hides that revocation is caught by the proof"
node "$here/../tools/liar.mjs" 8546 8545 & liar_pid=$!
until curl -s -m1 -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' http://127.0.0.1:8546/ >/dev/null; do sleep 0.2; done
sed 's/127.0.0.1:8545/127.0.0.1:8546/' "$work/trust.json5" > "$work/trust-liar.json5"
# mpt words the refusal by where the substitute proof leaves the real trie: it ends early, or a node's hash is not
# the one its parent names. Which one depends on the trie's shape, so either will do.
expect refused "run hello by hash through the lying node" "the proof ends where || but its parent named" -- $W run "$hello" --policy "$work/trust-liar.json5" --mirror "$mirror"

step "8. a deny list you follow names the web app"
$wallet deny "$keys/denylist" "$registry" "$notes" on
expect refused "run notes on the deny list" "is on a deny list you follow" -- $W run "notes@$pub" $P --mirror "$mirror" --out "$work/notes-verified"
$wallet deny "$keys/denylist" "$registry" "$notes" off
expect ok "taken off the list again" -- $W run "notes@$pub" $P --mirror "$mirror" --out "$work/notes-verified"

step "9. the publisher's key is stolen and the name pointed at other code"
cp packages/reckon/v1/examples/hello/hello.wasm "$work/evil.wasm"; printf 'evil' >> "$work/evil.wasm"
evilid=$($W blob "$work/evil.wasm"); $W publish "$mirror" --blob "$work/evil.wasm" >/dev/null
$wallet propose "$keys/publisher" "$registry" notes "$evilid"
expect ok "during the delay the old page is still what notes means" "not followed yet" -- $W run "notes@$pub" $P --mirror "$mirror" --out "$work/notes-verified"
echo "   waiting out the 20 s delay"; sleep 22
expect refused "after the delay: the name moved, but no rebuilder vouches for it" "no statement from a signer you trust" -- $W run "notes@$pub" $P --mirror "$mirror" --out "$work/notes-verified"

step "10. a name its publisher can move without notice is not followed"
$wallet claim "$keys/publisher" "$registry" quick "$hello" 0
expect refused "resolve quick (delay 0 < min_delay 10)" "the policy wants at least 10s" -- $W resolve "quick@$pub" $P

step "11. no current answer from the chain: refused, because on_stale is refuse"
sed 's/127.0.0.1:8545/127.0.0.1:8599/' "$work/trust.json5" > "$work/trust-down.json5"
expect refused "run by hash with the chain unreachable" "ECONNREFUSED" -- $W run "$notes" --policy "$work/trust-down.json5" --mirror "$mirror" --out "$work/notes-verified"

step "12. the registry's address running other code is refused"
sed "s/$codehash/0x$(printf 'ab%.0s' $(seq 32))/" "$work/trust.json5" > "$work/trust-code.json5"
expect refused "a code hash that is not the registry's" "runs other code" -- $W check "$notes" --policy "$work/trust-code.json5" --mirror "$mirror"

step "13. a dependency: wac-web's tree, as notes' lock pins it, reviewed"
web=$(sed -n 's/.*"web": {[^}]*"tree": "\(kt1:[0-9a-f]*\)".*/\1/p' packages/reckon/v1/examples/notes/wac.lock)
expect refused "unreviewed dependency" "reviewed by nobody" -- $W check "$web" $P --purpose dependency --mirror "$mirror"
$W review "$web" "the page library" --key "$keys/reviewer" --out "$stmts/web.review.json" >/dev/null
$W publish "$mirror" --statement "$stmts/web.review.json" >/dev/null
expect ok "reviewed dependency" -- $W check "$web" $P --purpose dependency --mirror "$mirror"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
