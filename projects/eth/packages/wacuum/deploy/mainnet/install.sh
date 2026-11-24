#!/bin/sh
# Set up the mainnet shadow on a fresh Ubuntu 24.04 machine: the `wac` command at wac-eth's pin, wac-eth
# itself, and the systemd units under /etc/systemd/system. Run as root, once; again to upgrade (it pulls
# and rebuilds). The reference node — reth and Lighthouse — is installed from their own releases by
# reference.sh, since wacuum cannot sync mainnet yet and the shadow needs a node that has (docs/mainnet.md).
#
#     sh preflight.sh && sh install.sh [WAC_REPO_URL]
#
# WAC_URL (environment) is where wac comes from, GitHub by default: the pin names a commit the owner syncs to both
# GitHub and git.voltrevo.com, and the box may have credentials for only one of them.
#
# Layout: /opt/wac (the compiler's source), /opt/wac-eth (wac-eth: projects/eth
# of /opt/wac-repo, wac's repository), /data/{reth,lighthouse,wacuum}
# (each its own directory on the NVMe disk), and a `wacuum` user that owns /data/wacuum and runs the shadow.
# Also: the shadow's status each minute as Prometheus metrics (wacuum-status.timer → node_exporter's textfile
# collector, node_exporter on 127.0.0.1:9100 only), and its log rotated weekly.
set -eu
repo=${1:-https://github.com/voltrevo/wac.git}
[ "$(id -u)" -eq 0 ] || { echo "install.sh: run as root" >&2; exit 1; }

apt-get update
apt-get install -y git build-essential pkg-config curl ca-certificates python3 prometheus-node-exporter logrotate

# Rust, for the native wac host (V8). rustup into /opt/rust so the service user can use it too.
if ! command -v cargo >/dev/null 2>&1; then
  export RUSTUP_HOME=/opt/rust CARGO_HOME=/opt/rust
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal
  ln -sf /opt/rust/bin/cargo /usr/local/bin/cargo
  ln -sf /opt/rust/bin/rustc /usr/local/bin/rustc
fi

id wacuum >/dev/null 2>&1 || useradd --system --create-home --home-dir /home/wacuum --shell /usr/sbin/nologin wacuum
# Read access to git.voltrevo.com, which is not public, for root and the service user alike: a line
# https://USER:TOKEN@git.voltrevo.com in /etc/eth/git-credentials, if it is there (docs/mainnet.md, "Access to the
# pinned commits"). Without it, every pinned commit must be on GitHub.
if [ -f /etc/eth/git-credentials ]; then
  chown root:wacuum /etc/eth/git-credentials
  chmod 640 /etc/eth/git-credentials
  git config --system credential.https://git.voltrevo.com.helper "store --file /etc/eth/git-credentials"
fi
mkdir -p /data/reth /data/lighthouse /data/wacuum /data/wacuum/differs /opt
chown wacuum:wacuum /data/wacuum /data/wacuum/differs

# wac-eth, then wac at exactly the commit wac-eth's wac.lock pins.
# wac-eth is projects/eth of wac's repository (since 2026-11-24). The repository goes to /opt/wac-repo, whole: its pins
# into itself are filled out of its own history (tools/deps.sh). /opt/wac-eth is a link to projects/eth in it, so the
# units and scripts that name /opt/wac-eth are unchanged. A machine installed before has /opt/wac-eth as a clone of
# wac-eth; that is kept, as /opt/wac-eth.before-monorepo, not deleted.
if [ -d /opt/wac-eth ] && [ ! -L /opt/wac-eth ]; then mv /opt/wac-eth /opt/wac-eth.before-monorepo; fi
[ -d /opt/wac-repo/.git ] || git clone "$repo" /opt/wac-repo
# Owned by the service user after the first install; root's git refuses such a checkout unless told it is safe.
git -c safe.directory=/opt/wac-repo -C /opt/wac-repo pull --ff-only
ln -sfn /opt/wac-repo/projects/eth /opt/wac-eth
# The lock as one line, and the commit from the "wac" entry alone: wac.lock lists other imports beside it.
pin=$(tr '\n' ' ' < /opt/wac-eth/wac.lock | sed -n 's/.*"wac" *: *{[^}]*"commit" *: *"\([0-9a-f]\{40\}\)".*/\1/p')
[ -n "$pin" ] || { echo "install.sh: no wac commit in wac.lock" >&2; exit 1; }
[ -d /opt/wac/.git ] || git clone "${WAC_URL:-https://github.com/voltrevo/wac.git}" /opt/wac
git -C /opt/wac fetch origin
# GitHub can lag behind git.voltrevo.com, where pins are made (2026-11-17: aaef775ca was not on GitHub yet):
# the commit is fetched from there when origin does not have it.
if ! git -C /opt/wac cat-file -e "$pin^{commit}" 2>/dev/null; then
  echo "install.sh: $pin is not at $(git -C /opt/wac remote get-url origin); fetching it from git.voltrevo.com" >&2
  git -C /opt/wac fetch https://git.voltrevo.com/wac.git "$pin"
fi
git -C /opt/wac checkout --detach "$pin"
# The binary goes to /usr/local/bin; its package cache is per user, so each user fills its own.
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
# The light-client driver, built once into an executable (the all-wac mode, docs/mainnet.md), and the secret it and
# wacuum share; its settings kept across reinstalls.
su -s /bin/sh wacuum -c 'cd /opt/wac-eth/packages/wacuum && mkdir -p dist && wac app --allow-net --allow-read --allow-write --allow-env cmd/driver.wac -o dist/driver.new && mv -f dist/driver.new dist/driver'
su -s /bin/sh wacuum -c 'cd /opt/wac-eth/packages/wacuum && wac app --allow-net --allow-read --allow-write cmd/wacuum.wac -o dist/wacuum.new && mv -f dist/wacuum.new dist/wacuum'
su -s /bin/sh wacuum -c 'cd /opt/wac-eth/packages/wacuum && wac app --allow-net --allow-read --allow-write tools/mainnet/allwac.wac -o dist/allwac.new && mv -f dist/allwac.new dist/allwac'
mkdir -p /etc/eth
[ -f /etc/eth/jwt-wacuum.hex ] || (od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > /etc/eth/jwt-wacuum.hex)
chown wacuum /etc/eth/jwt-wacuum.hex && chmod 600 /etc/eth/jwt-wacuum.hex
[ -f /etc/eth/mainnet-wac.env ] || install -m 644 /opt/wac-eth/packages/wacuum/deploy/mainnet/mainnet-wac.env /etc/eth/mainnet-wac.env

# Metrics: node_exporter on loopback only (its default is every address), reading the textfile the timer writes.
here=/opt/wac-eth/packages/wacuum/deploy/mainnet
textfiles=/var/lib/prometheus/node-exporter
mkdir -p "$textfiles"
chgrp wacuum "$textfiles" && chmod 775 "$textfiles"
grep -q 'listen-address' /etc/default/prometheus-node-exporter 2>/dev/null ||
  echo 'ARGS="--web.listen-address=127.0.0.1:9100 --collector.textfile.directory=/var/lib/prometheus/node-exporter"' >> /etc/default/prometheus-node-exporter
install -m 644 "$here/wacuum-shadow.logrotate" /etc/logrotate.d/wacuum-shadow

install -m 644 "$here/wacuum-shadow.service" "$here/wacuum-status.service" "$here/wacuum-status.timer" "$here/wacuum-driver.service" "$here/wacuum-mainnet.service" "$here/wacuum-allwac-status.service" "$here/wacuum-allwac-status.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl restart prometheus-node-exporter
echo "install.sh: done. Next: sh reference.sh RETH_VERSION LIGHTHOUSE_VERSION, wait for reth to sync, then"
echo "  systemctl enable --now wacuum-shadow wacuum-status.timer   (docs/mainnet.md, Runbook)"
