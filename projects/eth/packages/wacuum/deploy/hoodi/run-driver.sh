#!/bin/sh
# The light-client driver on Hoodi, as wacuum-driver-hoodi.service runs it: wacuum (port 8552) driven by the light
# client over BEACON_URL instead of by lighthouse-wacuum. The trusted root at the first start is CHECKPOINT, or else
# the finalized root CHECKPOINT_URL names (Lighthouse's own checkpoint trust); after that, the root the driver kept.
set -eu
. /etc/eth/hoodi.env
root=${CHECKPOINT:-}
if [ -z "$root" ] && [ ! -f /data/wacuum/driver.json ]; then
  root=$(curl -fsS -m 30 "$CHECKPOINT_URL/eth/v1/beacon/headers/finalized" | sed -n 's/.*"root":"\(0x[0-9a-f]\{64\}\)".*/\1/p')
  [ -n "$root" ] || { echo "run-driver.sh: no CHECKPOINT, and $CHECKPOINT_URL named no finalized root" >&2; exit 1; }
  echo "run-driver.sh: first start from $CHECKPOINT_URL's finalized root $root" >&2
fi
cd /opt/wac-eth/packages/wacuum
exec dist/driver --network hoodi --beacon "$BEACON_URL" --engine http://127.0.0.1:8552 --jwt-secret /etc/eth/jwt-wacuum.hex \
  --checkpoint "${root:-none}" --state /data/wacuum/driver.json --status /data/wacuum/driver-status.json
