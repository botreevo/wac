#!/bin/sh
# Set up the mainnet shadow on a fresh Ubuntu 24.04 machine: the `wac` command at wac-eth's pin, wac-eth
# itself, and the systemd units under /etc/systemd/system. Run as root, once; again to upgrade (it pulls
# and rebuilds). The reference node — reth and Lighthouse — is installed from their own releases by
# reference.sh, since wacuum cannot sync mainnet yet and the shadow needs a node that has (docs/mainnet.md).
#
#     sh install.sh [WAC_ETH_URL]
#
# Layout: /opt/wac (the compiler's source), /opt/wac-eth (this repository), /data/{reth,lighthouse,wacuum}
# (each its own directory on the NVMe disk), and a `wacuum` user that owns /data/wacuum and runs the shadow.
set -eu
repo=${1:-https://git.voltrevo.com/wac-eth.git}
[ "$(id -u)" -eq 0 ] || { echo "install.sh: run as root" >&2; exit 1; }

apt-get update
apt-get install -y git build-essential pkg-config curl ca-certificates python3

# Rust, for the native wac host (V8). rustup into /opt/rust so the service user can use it too.
if ! command -v cargo >/dev/null 2>&1; then
  export RUSTUP_HOME=/opt/rust CARGO_HOME=/opt/rust
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal
  ln -sf /opt/rust/bin/cargo /usr/local/bin/cargo
  ln -sf /opt/rust/bin/rustc /usr/local/bin/rustc
fi

id wacuum >/dev/null 2>&1 || useradd --system --create-home --home-dir /home/wacuum --shell /usr/sbin/nologin wacuum
mkdir -p /data/reth /data/lighthouse /data/wacuum /opt
chown wacuum:wacuum /data/wacuum

# wac-eth, then wac at exactly the commit wac-eth's wac.lock pins.
[ -d /opt/wac-eth/.git ] || git clone "$repo" /opt/wac-eth
git -C /opt/wac-eth pull --ff-only
pin=$(sed -n 's/.*"wac".*"commit": *"\([0-9a-f]\{40\}\)".*/\1/p' /opt/wac-eth/wac.lock)
[ -n "$pin" ] || { echo "install.sh: no wac commit in wac.lock" >&2; exit 1; }
[ -d /opt/wac/.git ] || git clone https://github.com/voltrevo/wac.git /opt/wac
git -C /opt/wac fetch origin
git -C /opt/wac checkout --detach "$pin"
# The binary goes to /usr/local/bin; its package cache is per user, so each user fills its own.
(cd /opt/wac && ./bootstrap.sh -o /usr/local/bin/wac)
chown -R wacuum:wacuum /opt/wac-eth
su -s /bin/sh wacuum -c 'cd /opt/wac-eth && sh tools/deps.sh'
su -s /bin/sh wacuum -c 'cd /opt/wac-eth/packages/wacuum && wac test test'

install -m 644 /opt/wac-eth/packages/wacuum/deploy/mainnet/wacuum-shadow.service /etc/systemd/system/
systemctl daemon-reload
echo "install.sh: done. Next: sh reference.sh, wait for reth to sync, then systemctl enable --now wacuum-shadow"
