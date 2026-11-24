#!/bin/sh
# The reference node the shadow replays against: reth (execution) and Lighthouse (consensus, checkpoint
# synced), from their release binaries, as systemd units. Versions are arguments so the runbook can name
# what was current on the day; check each project's release page for the latest.
#
#     sh reference.sh RETH_VERSION LIGHTHOUSE_VERSION     # e.g. v1.9.0 v8.0.0
#
# reth serves debug_traceBlockByNumber (prestateTracer) and debug_executionWitness on 127.0.0.1:8545, which
# the shadow uses; nothing listens publicly but the p2p ports (30303 tcp/udp for reth, 9000 tcp/udp for
# Lighthouse).
set -eu
[ "$(id -u)" -eq 0 ] || { echo "reference.sh: run as root" >&2; exit 1; }
reth=$1
lighthouse=$2
cd /tmp
curl -fsSLO "https://github.com/paradigmxyz/reth/releases/download/$reth/reth-$reth-x86_64-unknown-linux-gnu.tar.gz"
tar xzf "reth-$reth-x86_64-unknown-linux-gnu.tar.gz" -C /usr/local/bin reth
curl -fsSLO "https://github.com/sigp/lighthouse/releases/download/$lighthouse/lighthouse-$lighthouse-x86_64-unknown-linux-gnu.tar.gz"
tar xzf "lighthouse-$lighthouse-x86_64-unknown-linux-gnu.tar.gz" -C /usr/local/bin lighthouse
id eth >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin eth
mkdir -p /data/reth /data/lighthouse /etc/eth
[ -f /etc/eth/jwt.hex ] || (od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > /etc/eth/jwt.hex)
chown -R eth:eth /data/reth /data/lighthouse /etc/eth
chmod 640 /etc/eth/jwt.hex
dir=$(cd "$(dirname "$0")" && pwd)
install -m 644 "$dir/reth.service" "$dir/lighthouse.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now reth lighthouse
echo "reference.sh: started. Progress: journalctl -fu reth; curl -s localhost:5052/eth/v1/node/syncing"
