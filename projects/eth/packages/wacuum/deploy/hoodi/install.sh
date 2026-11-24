#!/bin/sh
# Hoodi on one machine: wacuum on its store, snap-syncing in and then following the chain as a consensus client
# drives it, beside a reference node (geth) it takes the state from and is checked against. Ubuntu 24.04, as root,
# once; again to upgrade (it pulls and rebuilds, and keeps /etc/eth/hoodi.env and the data).
#
#     sh install.sh LIGHTHOUSE_VERSION [WAC_REPO_URL]       # e.g. v8.0.0 — the current release on the day
#
# What runs (each a systemd unit, every RPC on 127.0.0.1):
#
#     geth-hoodi           geth --hoodi, snap-synced          p2p 30303   auth 8551   http 8545
#     lighthouse-geth      Lighthouse driving geth            p2p 9000    http 5052
#     wacuum-hoodi         wacuum --store --snap              p2p 30304   auth+rpc 8552
#     lighthouse-wacuum    Lighthouse driving wacuum          p2p 9002    http 5053
#
# Two consensus clients because each execution client needs its own. Layout: /opt/wac (the compiler at
# wac-eth's pin), /opt/wac-eth (wac-eth: projects/eth of /opt/wac-repo,
# wac's repository), /data/{geth,lighthouse-geth,lighthouse-wacuum,wacuum}, and
# /etc/eth: the JWT secrets, Hoodi's genesis (as geth has it built in), its bootnodes, and hoodi.env — the
# settings wacuum runs with (heap, cache, history, checkpoint URL), kept across reinstalls.
set -eu
lighthouse=${1:?usage: sh install.sh LIGHTHOUSE_VERSION [WAC_REPO_URL]}
repo=${2:-https://github.com/voltrevo/wac.git}
[ "$(id -u)" -eq 0 ] || { echo "install.sh: run as root" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)

apt-get update
apt-get install -y git build-essential pkg-config curl ca-certificates python3 software-properties-common prometheus-node-exporter
# geth from the Ethereum team's PPA: the reference, and the source of Hoodi's genesis.
add-apt-repository -y ppa:ethereum/ethereum
apt-get update
apt-get install -y ethereum

# Rust, for wac's native host (V8), into /opt/rust so every user has it.
if ! command -v cargo >/dev/null 2>&1; then
  export RUSTUP_HOME=/opt/rust CARGO_HOME=/opt/rust
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal
  ln -sf /opt/rust/bin/cargo /usr/local/bin/cargo
  ln -sf /opt/rust/bin/rustc /usr/local/bin/rustc
fi

# Lighthouse from its release.
cd /tmp
curl -fsSLO "https://github.com/sigp/lighthouse/releases/download/$lighthouse/lighthouse-$lighthouse-x86_64-unknown-linux-gnu.tar.gz"
tar xzf "lighthouse-$lighthouse-x86_64-unknown-linux-gnu.tar.gz" -C /usr/local/bin lighthouse

id eth >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin eth
id wacuum >/dev/null 2>&1 || useradd --system --create-home --home-dir /home/wacuum --shell /usr/sbin/nologin wacuum
# Read access to git.voltrevo.com, which is not public, for root and the service user alike: a line
# https://USER:TOKEN@git.voltrevo.com in /etc/eth/git-credentials, if it is there (docs/mainnet.md, "Access to the
# pinned commits"). Without it, every pinned commit must be on GitHub.
if [ -f /etc/eth/git-credentials ]; then
  chown root:wacuum /etc/eth/git-credentials
  chmod 640 /etc/eth/git-credentials
  git config --system credential.https://git.voltrevo.com.helper "store --file /etc/eth/git-credentials"
fi
mkdir -p /data/geth /data/lighthouse-geth /data/lighthouse-wacuum /data/wacuum /etc/eth /opt
chown -R eth:eth /data/geth /data/lighthouse-geth /data/lighthouse-wacuum
chown wacuum:wacuum /data/wacuum

# A secret for each execution/consensus pair, readable by both sides of it.
for pair in geth wacuum; do
  [ -f /etc/eth/jwt-$pair.hex ] || (od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > /etc/eth/jwt-$pair.hex)
done
chown eth:eth /etc/eth/jwt-geth.hex
chown wacuum:eth /etc/eth/jwt-wacuum.hex
chmod 640 /etc/eth/jwt-geth.hex /etc/eth/jwt-wacuum.hex

# Hoodi's genesis as geth has it built in (wacuum computes its hash, 0xbbe31286…557c971b, and checks it), and
# the execution bootnodes eth-clients publishes.
geth --hoodi dumpgenesis > /etc/eth/hoodi-genesis.json
# (enodes.yaml, a YAML list; enodes.txt, which this fetched before, is gone — checked 2026-11-17), one per line.
curl -fsSL https://raw.githubusercontent.com/eth-clients/hoodi/main/metadata/enodes.yaml |
  grep -oE 'enode://[0-9a-f]{128}@[^ #]+' > /etc/eth/hoodi-bootnodes.txt ||
  echo "install.sh: no bootnode list fetched; wacuum will use only the local geth" >&2
chmod 644 /etc/eth/hoodi-genesis.json /etc/eth/hoodi-bootnodes.txt 2>/dev/null || true
[ -f /etc/eth/hoodi.env ] || install -m 644 "$here/hoodi.env" /etc/eth/hoodi.env

# wac-eth, then wac at exactly the commit wac-eth's wac.lock pins, then wacuum built once into an executable.
# wac-eth is projects/eth of wac's repository (since 2026-11-24). The repository goes to /opt/wac-repo, whole: its pins
# into itself are filled out of its own history (tools/deps.sh). /opt/wac-eth is a link to projects/eth in it, so the
# units and scripts that name /opt/wac-eth are unchanged. A machine installed before has /opt/wac-eth as a clone of
# wac-eth; that is kept, as /opt/wac-eth.before-monorepo, not deleted.
if [ -d /opt/wac-eth ] && [ ! -L /opt/wac-eth ]; then mv /opt/wac-eth /opt/wac-eth.before-monorepo; fi
[ -d /opt/wac-repo/.git ] || git clone "$repo" /opt/wac-repo
# Owned by the service user after the first install; root's git refuses such a checkout unless told it is safe.
git -c safe.directory=/opt/wac-repo -C /opt/wac-repo pull --ff-only
ln -sfn /opt/wac-repo/projects/eth /opt/wac-eth
pin=$(tr '\n' ' ' < /opt/wac-eth/wac.lock | sed -n 's/.*"wac" *: *{[^}]*"commit" *: *"\([0-9a-f]\{40\}\)".*/\1/p')
[ -n "$pin" ] || { echo "install.sh: no wac commit in wac.lock" >&2; exit 1; }
[ -d /opt/wac/.git ] || git clone "${WAC_URL:-https://github.com/voltrevo/wac.git}" /opt/wac
git -C /opt/wac fetch origin
# GitHub can lag behind git.voltrevo.com, where pins are made: the commit from there when origin lacks it.
if ! git -C /opt/wac cat-file -e "$pin^{commit}" 2>/dev/null; then
  echo "install.sh: $pin is not at $(git -C /opt/wac remote get-url origin); fetching it from git.voltrevo.com" >&2
  git -C /opt/wac fetch https://git.voltrevo.com/wac.git "$pin"
fi
git -C /opt/wac checkout --detach "$pin"
# Built beside the old one and renamed over it: the running units hold /usr/local/bin/wac open, and a copy onto a
# running executable fails (Text file busy), which stopped an upgrade here with the units up.
# A pin from before wac moved into projects/wac has it at the root; one from after, at projects/wac.
src=/opt/wac
if [ -f /opt/wac/projects/wac/bootstrap.sh ]; then src=/opt/wac/projects/wac; fi
(cd "$src" && ./bootstrap.sh -o /usr/local/bin/wac.new)
mv -f /usr/local/bin/wac.new /usr/local/bin/wac
chown -R wacuum:wacuum /opt/wac-repo
su -s /bin/sh wacuum -c 'cd /opt/wac-eth && sh tools/deps.sh'
su -s /bin/sh wacuum -c 'cd /opt/wac-eth/packages/wacuum && wac test --allow-read test'
su -s /bin/sh wacuum -c 'cd /opt/wac-eth/packages/wacuum && mkdir -p dist && wac app --allow-read --allow-write --allow-net cmd/wacuum.wac -o dist/wacuum.new && mv -f dist/wacuum.new dist/wacuum'
# The light-client driver (the driver mode) and the status tool.
su -s /bin/sh wacuum -c 'cd /opt/wac-eth/packages/wacuum && wac app --allow-net --allow-read --allow-write --allow-env cmd/driver.wac -o dist/driver.new && mv -f dist/driver.new dist/driver'
su -s /bin/sh wacuum -c 'cd /opt/wac-eth/packages/wacuum && wac app --allow-net --allow-read --allow-write tools/mainnet/allwac.wac -o dist/allwac.new && mv -f dist/allwac.new dist/allwac'

# Metrics: node_exporter on loopback only (its default is every address), reading the textfile the status timer writes.
textfiles=/var/lib/prometheus/node-exporter
mkdir -p "$textfiles"
chgrp wacuum "$textfiles" && chmod 775 "$textfiles"
grep -q 'listen-address' /etc/default/prometheus-node-exporter 2>/dev/null ||
  echo 'ARGS="--web.listen-address=127.0.0.1:9100 --collector.textfile.directory=/var/lib/prometheus/node-exporter"' >> /etc/default/prometheus-node-exporter

for unit in geth-hoodi lighthouse-geth wacuum-hoodi lighthouse-wacuum wacuum-driver-hoodi wacuum-hoodi-status; do
  install -m 644 "$here/$unit.service" /etc/systemd/system/
done
install -m 644 "$here/wacuum-hoodi-status.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl restart prometheus-node-exporter
echo "install.sh: done. Next (docs/hoodi.md): systemctl enable --now geth-hoodi lighthouse-geth; once geth has synced,"
echo "  systemctl enable --now wacuum-hoodi wacuum-hoodi-status.timer, and one of lighthouse-wacuum (the Lighthouse mode)"
echo "  or wacuum-driver-hoodi (the all-wac driver mode) — docs/hoodi.md"
