#!/bin/sh
# Claims through mirrors, with the command line and a real web server (docs/claims-mirror.md): two signers publish
# into one mirror directory, a client with an empty store admits from it over HTTP, a tampered statement on the server
# is left out and reported, and a revocation the first mirror lacks counts once a second mirror carries it.
#
#     sh packages/reckon/tools/claims-mirror.sh WORKDIR     (PORT defaults to 8780; the second mirror is PORT+1, the server above both PORT+2)
#
# Needs: wac on PATH, python3 and curl.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=$1; rm -rf "$work"; mkdir -p "$work"; work=$(cd "$work" && pwd)
port=${PORT:-8780}; port2=$((port + 1)); port3=$((port + 2))
for p in $port $port2; do
  if curl -s -m1 -o /dev/null "http://127.0.0.1:$p/" 2>/dev/null; then echo "claims-mirror: port $p is taken; set PORT" >&2; exit 2; fi
done
pass=0; fail=0
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
expect() {  # expect ok|refused DESCRIPTION [BECAUSE] -- command…
  want=$1; what=$2; because=""; shift 2
  if [ "$1" != "--" ]; then because=$1; shift; fi
  shift
  if out=$("$@" 2>&1); then got=ok; else got=refused; fi
  printf '%s\n' "$out" | sed 's/^/   | /'
  if [ "$got" != "$want" ]; then fail=$((fail+1)); echo "   FAIL ($what: wanted $want, got $got)"
  elif [ -n "$because" ] && ! printf '%s' "$out" | grep -qF -- "$because"; then fail=$((fail+1)); echo "   FAIL ($what: $got, but not because \"$because\")"
  else pass=$((pass+1)); echo "   PASS ($what: $got${because:+, because \"$because\"})"; fi
}

cd "$root"
wac build --quiet --allow-read --allow-write --allow-net "$here/cmd/claim.wac" -o "$work/claim"
CL="wac $work/claim.wasm"
cd "$work"
printf '%s\n' a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1 > alice.key
printf '%s\n' b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2 > bob.key
subject=bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku
cat > policy.json5 <<POLICY
{ signers: { alice: "$($CL address --key alice.key)", bob: "$($CL address --key bob.key)" },
  roles: { app: [{ endorsed: { by: ["alice", "bob"], at_least: 2 } }] } }
POLICY
admit() { $CL admit "$subject" app --policy policy.json5 "$@"; }

step "two signers, each in their own store, publish into one mirror"
aid=$($CL endorse "$subject" reviewed --key alice.key --store alice 2>/dev/null)
bid=$($CL endorse "$subject" reviewed --key bob.key --store bob 2>/dev/null)
expect ok "alice publishes" "1 statement(s)" -- $CL publish mirror --store alice
expect ok "bob publishes beside her" "2 statement(s)" -- $CL publish mirror --store bob
expect ok "alice again: nothing changes" "2 statement(s)" -- $CL publish mirror --store alice

step "a client with an empty store, and the mirror over HTTP"
( cd mirror && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 ) & srv=$!
trap 'kill $srv ${srv2:-} ${srv3:-} 2>/dev/null || true' EXIT INT TERM
until curl -s -m1 -o /dev/null "http://127.0.0.1:$port/"; do sleep 0.2; done
expect refused "nothing local, no mirror: refused" "endorsed by nobody" -- admit --store client
expect ok "with the mirror: both endorsements, admitted" "ADMITTED" -- admit --store client --mirror "http://127.0.0.1:$port"
expect ok "the same from the directory" "ADMITTED" -- admit --store client --mirror mirror

step "a tampered statement on the server is left out, and reported"
first=$(sed -n 's/^signed //p' mirror/claims/index | sed -n 1p)
second=$(sed -n 's/^signed //p' mirror/claims/index | sed -n 2p)
cp "mirror/ipfs/$first" first.block
cp "mirror/ipfs/$second" "mirror/ipfs/$first"                 # the first statement's name, the second's bytes
expect refused "one endorsement of two left: refused" "endorsed by" -- admit --store client2 --mirror "http://127.0.0.1:$port"
expect refused "…and the client is told which" "left out: mirror 0" -- admit --store client2 --mirror "http://127.0.0.1:$port"
cp first.block "mirror/ipfs/$first"

step "a revocation one mirror lacks counts when another carries it"
cp -r mirror mirror2
$CL revoke "$bid" --key bob.key --store bob >/dev/null 2>&1
expect ok "bob publishes his revocation to the second mirror" "3 statement(s)" -- $CL publish mirror2 --store bob
( cd mirror2 && exec python3 -m http.server "$port2" --bind 127.0.0.1 >/dev/null 2>&1 ) & srv2=$!
until curl -s -m1 -o /dev/null "http://127.0.0.1:$port2/"; do sleep 0.2; done
expect ok "from the first mirror alone, which lacks it: admitted" "ADMITTED" -- admit --store client3 --mirror "http://127.0.0.1:$port"
expect refused "with the second as well: refused" "endorsed by alice (need 2)" -- admit --store client3 --mirror "http://127.0.0.1:$port" --mirror "http://127.0.0.1:$port2"

step "a mirror below a path, as a static site publishes one"
( exec python3 -m http.server "$port3" --bind 127.0.0.1 >/dev/null 2>&1 ) & srv3=$!
until curl -s -m1 -o /dev/null "http://127.0.0.1:$port3/"; do sleep 0.2; done
expect ok "the first mirror, read at /mirror on a server whose root is above it: admitted" "ADMITTED" -- admit --store client4 --mirror "http://127.0.0.1:$port3/mirror"
expect refused "a path with no mirror there: nothing found, refused" "endorsed by nobody" -- admit --store client5 --mirror "http://127.0.0.1:$port3/nowhere"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
