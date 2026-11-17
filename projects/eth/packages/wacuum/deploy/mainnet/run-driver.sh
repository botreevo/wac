#!/bin/sh
# The light-client driver, as wacuum-driver.service runs it: the settings in /etc/eth/mainnet-wac.env (the beacon node
# to read, the checkpoint for the first start), the JWT secret wacuum reads, and the finalized root it keeps in
# /data/wacuum/driver.json — from which every start after the first bootstraps, so CHECKPOINT matters once.
set -eu
. /etc/eth/mainnet-wac.env
cd /opt/wac-eth/packages/wacuum
exec dist/driver --beacon "$BEACON_URL" --engine http://127.0.0.1:8551 --jwt-secret /etc/eth/jwt-wacuum.hex \
  --checkpoint "$CHECKPOINT" --state /data/wacuum/driver.json --network mainnet
