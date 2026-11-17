#!/bin/sh
# Whether this machine is the one docs/mainnet.md asks for, before installing anything: the OS, cores, memory, the
# data disk (size, free, solid state), the clock, the p2p ports free, and the outbound HTTPS the install and the
# reference node need. One line a check — PASS, WARN or FAIL — and exit 1 if any failed. Changes nothing.
#
#     sh preflight.sh [DATA_DIR]        # /data by default
set -u
data=${1:-/data}
failed=0
pass() { echo "PASS  $*"; }
warn() { echo "WARN  $*"; }
fail() { echo "FAIL  $*"; failed=1; }

. /etc/os-release 2>/dev/null || true
arch=$(uname -m)
if [ "${ID:-}" = ubuntu ] && [ "${VERSION_ID:-}" = 24.04 ] && [ "$arch" = x86_64 ]; then pass "Ubuntu 24.04, x86_64"
else warn "${PRETTY_NAME:-unknown OS} on $arch: the scripts were written for Ubuntu 24.04 x86_64 (the reference binaries are x86_64)"; fi

cores=$(nproc)
if [ "$cores" -ge 8 ]; then pass "$cores threads"
elif [ "$cores" -ge 4 ]; then warn "$cores threads: 8 is EIP-7870's figure; reth's sync will be slower"
else fail "$cores threads: at least 4"; fi

# The kernel keeps some for itself: a 32 GB machine shows 31, a 16 GB one 15.
mem=$(awk '/^MemTotal:/ { print int($2 / 1048576) }' /proc/meminfo)
if [ "$mem" -ge 30 ]; then pass "$mem GB of memory"
elif [ "$mem" -ge 15 ]; then warn "$mem GB of memory: 32 is asked for; reth and Lighthouse want ~12–24 between them"
else fail "$mem GB of memory: at least 16"; fi

if [ -d "$data" ]; then
  size=$(df -BG --output=size "$data" | tail -1 | tr -dc 0-9)
  free=$(df -BG --output=avail "$data" | tail -1 | tr -dc 0-9)
  if [ "$size" -ge 3500 ]; then pass "$data: $size GB, $free GB free"
  elif [ "$size" -ge 2000 ]; then warn "$data: $size GB: a mainnet reth is ~1.5 TB and grows; 4 TB is asked for"
  else fail "$data: $size GB: a mainnet reth alone is ~1.5 TB"; fi
  dev=$(df --output=source "$data" | tail -1)
  rota=$(lsblk -ndo ROTA "$dev" 2>/dev/null | head -1 | tr -d ' ')
  case "$rota" in
    0) pass "$data is on solid state ($dev)" ;;
    # A virtual disk (virtio, vd*) often says it spins whatever is under it: then it is the provider's word that counts.
    1) case "$dev" in
         /dev/vd*|/dev/xvd*) warn "$data is on a virtual disk ($dev) that calls itself rotational: check with the provider that it is NVMe" ;;
         *) fail "$data is on a spinning disk ($dev): reth cannot keep up with mainnet on one" ;;
       esac ;;
    *) warn "$data's disk ($dev): could not tell whether it is solid state" ;;
  esac
else
  fail "$data does not exist: mount the data disk there, or pass where it is"
fi

if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; then pass "the clock is synchronized (NTP)"
else warn "the clock is not known to be synchronized: a consensus client needs it within a second or so"; fi

for port in 30303 9000; do
  if ss -Hltun "sport = :$port" 2>/dev/null | grep -q .; then fail "port $port is already in use"
  else pass "port $port is free"; fi
done

# What install.sh and reference.sh fetch, and the checkpoint Lighthouse starts from. git.voltrevo.com is where
# wac-eth comes from: an answer of 401 there means the box needs credentials for it (or pass install.sh a URL).
for url in https://github.com/voltrevo/wac.git/info/refs?service=git-upload-pack https://sh.rustup.rs https://static.rust-lang.org https://index.crates.io/config.json \
           https://mainnet.checkpoint.sigp.io/eth/v1/node/version https://git.voltrevo.com/wac-eth.git/info/refs?service=git-upload-pack; do
  code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$url")
  case "$code" in
    2*|3*) pass "outbound: $url ($code)" ;;
    401|403) warn "outbound: $url answers $code: reachable, but not without credentials" ;;
    *) fail "outbound: $url (${code:-no answer})" ;;
  esac
done

# Every commit the install fetches, fetched now, with this machine's own credentials: wac-eth (WAC_ETH_URL), wac at
# the commit wac-eth's wac.lock pins, and each import wac's own lock pins (wac-web). A github.com/voltrevo pin is tried
# on GitHub and then on git.voltrevo.com, as install.sh and tools/deps.sh fetch it. git.voltrevo.com is not public:
# without read credentials there (docs/mainnet.md, "Access to the pinned commits"), a pin GitHub lacks cannot be had.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# A commit at a URL, or at its git.voltrevo.com mirror: which one served it, or nothing.
fetchable() {
  url=$1
  commit=$2
  d="$tmp/$(printf '%s' "$url$commit" | md5sum | cut -c1-12)"
  git init -q "$d"
  if GIT_TERMINAL_PROMPT=0 git -C "$d" fetch -q --depth 1 "$url" "$commit" 2>/dev/null; then echo "$url"; return; fi
  mirror=$(printf '%s' "$url" | sed -n 's|^https://github.com/voltrevo/|https://git.voltrevo.com/|p')
  if [ -n "$mirror" ] && GIT_TERMINAL_PROMPT=0 git -C "$d" fetch -q --depth 1 "$mirror" "$commit" 2>/dev/null; then echo "$mirror"; fi
}
# The commit field of an import named NAME in a wac.lock (the lock as one line; an entry holds no braces).
pinOf() { tr '\n' ' ' < "$2" | sed -n "s/.*\"$1\" *: *{[^}]*\"commit\" *: *\"\([0-9a-f]\{40\}\)\".*/\1/p"; }
urlOf() { tr '\n' ' ' < "$2" | sed -n "s/.*\"$1\" *: *{[^}]*\"git\" *: *\"\([^\"]*\)\".*/\1/p"; }

ethUrl=${WAC_ETH_URL:-https://git.voltrevo.com/wac-eth.git}
if GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 "$ethUrl" "$tmp/wac-eth" 2>/dev/null; then
  pass "pinned: wac-eth from $ethUrl"
  wacPin=$(pinOf wac "$tmp/wac-eth/wac.lock")
  wacUrl=${WAC_URL:-https://github.com/voltrevo/wac.git}
  from=$(fetchable "$wacUrl" "$wacPin")
  if [ -n "$from" ]; then
    pass "pinned: wac $wacPin from $from"
    # wac's own imports, from its lock at that commit.
    d="$tmp/$(printf '%s' "$wacUrl$wacPin" | md5sum | cut -c1-12)"
    git -C "$d" show "$wacPin:wac.lock" > "$tmp/wac.lock" 2>/dev/null
    for name in web webbuild; do
      u=$(urlOf "$name" "$tmp/wac.lock")
      c=$(pinOf "$name" "$tmp/wac.lock")
      [ -n "$c" ] || continue
      got=$(fetchable "$u" "$c")
      if [ -n "$got" ]; then pass "pinned: wac's $name $c from $got"
      else fail "pinned: wac's $name $c is at neither $u nor its git.voltrevo.com mirror (from here)"; fi
    done
  else
    fail "pinned: wac $wacPin is at neither $wacUrl nor git.voltrevo.com (from here) — see docs/mainnet.md, \"Access to the pinned commits\""
  fi
else
  fail "pinned: wac-eth cannot be cloned from $ethUrl (from here) — see docs/mainnet.md, \"Access to the pinned commits\""
fi

[ "$failed" -eq 0 ] && echo "preflight: ready" || echo "preflight: not ready — see the FAIL lines"
exit "$failed"
