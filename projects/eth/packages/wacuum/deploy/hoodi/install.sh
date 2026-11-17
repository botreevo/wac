#!/bin/sh
# Hoodi on one machine: wacuum on its store, snap-syncing in and then following the chain as a consensus client
# drives it, beside a reference node (geth) it takes the state from and is checked against. Ubuntu 24.04, as root,
# once; again to upgrade (it pulls and rebuilds, and keeps /etc/eth/hoodi.env and the data).
#
#     sh install.sh LIGHTHOUSE_VERSION [WAC_ETH_URL]       # e.g. v8.0.0 — the current release on the day
#
# What runs (each a systemd unit, every RPC on 127.0.0.1):
#
#     geth-hoodi           geth --hoodi, snap-synced          p2p 30303   auth 8551   http 8545
#     lighthouse-geth      Lighthouse driving geth            p2p 9000    http 5052
#     wacuum-hoodi         wacuum --store --snap              p2p 30304   auth+rpc 8552
#     lighthouse-wacuum    Lighthouse driving wacuum          p2p 9002    http 5053
#
# Two consensus clients because each execution client needs its own. Layout: /opt/wac (the compiler at
# wac-eth's pin), /opt/wac-eth (this repository), /data/{geth,lighthouse-geth,lighthouse-wacuum,wacuum}, and
# /etc/eth: the JWT secrets, Hoodi's genesis (as geth has it built in), its bootnodes, and hoodi.env — the
# settings wacuum runs with (heap, cache, history, checkpoint URL), kept across reinstalls.
set -eu
lighthouse=${1:?usage: sh install.sh LIGHTHOUSE_VERSION [WAC_ETH_URL]}
repo=${2:-https://git.voltrevo.com/wac-eth.git}
[ "$(id -u)" -eq 0 ] || { echo "install.sh: run as root" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)

apt-get update
apt-get install -y git build-essential pkg-config curl ca-certificates python3 software-properties-common
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
[ -d /opt/wac-eth/.git ] || git clone "$repo" /opt/wac-eth
git -C /opt/wac-eth pull --ff-only
pin=$(tr '\n' ' ' < /opt/wac-eth/wac.lock | sed -n 's/.*"wac" *: *{[^}]*"commit" *: *"\([0-9a-f]\{40\}\)".*/\1/p')
[ -n "$pin" ] || { echo "install.sh: no wac commit in wac.lock" >&2; exit 1; }
[ -d /opt/wac/.git ] || git clone https://github.com/voltrevo/wac.git /opt/wac
git -C /opt/wac fetch origin
git -C /opt/wac checkout --detach "$pin"
(cd /opt/wac && ./bootstrap.sh -o /usr/local/bin/wac)
chown -R wacuum:wacuum /opt/wac-eth
su -s /bin/sh wacuum -c 'cd /opt/wac-eth && sh tools/deps.sh'
su -s /bin/sh wacuum -c 'cd /opt/wac-eth/packages/wacuum && wac test --allow-read test'
su -s /bin/sh wacuum -c 'cd /opt/wac-eth/packages/wacuum && mkdir -p dist && wac app --allow-read --allow-write --allow-net cmd/wacuum.wac -o dist/wacuum'

for unit in geth-hoodi lighthouse-geth wacuum-hoodi lighthouse-wacuum; do
  install -m 644 "$here/$unit.service" /etc/systemd/system/
done
systemctl daemon-reload
echo "install.sh: done. Next (docs/hoodi.md): systemctl enable --now geth-hoodi lighthouse-geth; once geth has synced,"
echo "  systemctl enable --now wacuum-hoodi lighthouse-wacuum"
