# Hoodi runbook

wacuum on Hoodi, on its store, snap-syncing in and then following the chain as Lighthouse drives it, beside
geth as the reference it takes the state from and is checked against. Everything is in `deploy/hoodi/`; this is
the order to run it in. The machine: Ubuntu 24.04 x86_64, 4 cores, 16 GB, 1 TB NVMe at `/data`, root SSH, inbound
30303–30304 and 9000–9003 (tcp and udp) (`docs/mainnet.md`'s machine request).

Checked here, without the machine: wacuum computes Hoodi's genesis hash from `geth --hoodi dumpgenesis`
(0xbbe31286…557c971b), geth accepts its handshake (so its fork ID, with Osaka and the BPO forks, is Hoodi's),
`run-wacuum.sh` finds the local geth and starts wacuum with its settings, and `tools/hoodi/compare.wac` compares
the two. Snap sync from geth, its healing as the pivot moves, and following a chain driven over the Engine API
are tested against geth on devnets (`tools/e2e/snap.wac`, `devnet.wac`). Under real consensus clients too, on private
chains with every fork through Fulu/Osaka at genesis (2026-11-14): `tools/e2e/clfollow.wac` is this deploy's shape —
geth builds, wacuum follows under a beacon node of its own, a kill catches up from the local geth, and a wacuum started
empty under a checkpoint-synced beacon node snap-syncs from geth and follows — under Prysm 7.3.1; `cllh.wac` runs
wacuum under Lighthouse 8.3.3 (the version this deploy was last checked with) and `tools/e2e/clsoak.wac` follows under
Lighthouse for hours with kills. What this run adds is Hoodi's own state and peers.

**Use a wacuum at or after `ac19578`.** Before it, a payload status named a block hash starting with a zero nibble
without that nibble, which consensus clients cannot read: about one block in 16 failed, and a following node stopped
there for good.

## Day one

1. **Install** — about 20 minutes, most of it building wac:

       sh /path/to/wac-eth/packages/wacuum/deploy/hoodi/install.sh LIGHTHOUSE_VERSION

   with Lighthouse's current release (https://github.com/sigp/lighthouse/releases); v8.3.3 is the one wacuum was
   tested under. It installs geth (the
   Ethereum PPA), Lighthouse, wac at wac-eth's pin, runs wacuum's unit tests, builds `dist/wacuum`, writes Hoodi's
   genesis, bootnodes and the JWT secrets into `/etc/eth`, and the four units. Check `CHECKPOINT_URL` in
   `/etc/eth/hoodi.env` against https://eth-clients.github.io/checkpoint-sync-endpoints/.

2. **The reference first:**

       systemctl enable --now geth-hoodi lighthouse-geth

   Lighthouse checkpoint-syncs in minutes; geth snap-syncs Hoodi in hours. Done when
   `curl -s -X POST -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"eth_syncing","params":[]}' 127.0.0.1:8545`
   answers `false`.

3. **Then wacuum:**

       systemctl enable --now wacuum-hoodi lighthouse-wacuum

   `journalctl -fu wacuum-hoodi` shows it: peers (`serving blocks`), then, once Lighthouse names a head,
   `snap sync from N peer(s)` … `snap sync done: … healed, … requests`, then blocks syncing in and the head
   following. Its log says what it is doing at each step; nothing is silent for long.

4. **Compare, from then on:**

       cd /opt/wac-eth/packages/wacuum && su -s /bin/sh wacuum -c \
         'wac run --allow-net --allow-read --allow-write tools/hoodi/compare.wac -- /data/wacuum/compare.log' &

   One line a minute: `N same 0x…` is the goal, `N behind M` is catching up, and any `DIFFERS` line names the
   block and both state roots — the place to start. `grep -c DIFFERS /data/wacuum/compare.log` for a count.

## What to watch, and what to do

- **Memory**: wacuum runs under `WAC_MAX_HEAP` (8g). If it runs out, its log says *ran out of memory* and the
  unit restarts it from its store; lower `CACHE_MB` or raise the heap in `/etc/eth/hoodi.env`, then
  `systemctl restart wacuum-hoodi`. `curl -s -X POST -H 'content-type: application/json' -d
  '{"jsonrpc":"2.0","id":1,"method":"wacuum_sizes","params":[]}' 127.0.0.1:8552` lists what it holds between
  blocks (the store's leaves, cache and queue; the blocks, history and payloads it keeps).
- **A restart** goes on from the store: the state of the block it last committed, then the log of what came
  after — up to 64 blocks replayed — and blocks it missed while down fetched from the local geth (its `--peer`).
  A crash at any point leaves the store whole, and a reorg after one can still take the store back, by the blocks'
  undo records (`docs/state-on-disk.md`, "Crash windows").
- **Lighthouse's view**: `journalctl -u lighthouse-wacuum | grep -E 'ERRO|CRIT'` — an execution engine error there
  (an answer it could not read, a payload it rejected) is wacuum's to look at, with the block's number. A
  `Synced` line with `exec_hash: … (verified)` is the healthy one.
- **Snap sync that fails** (`snap sync from … failed: …`) is retried at the next head; if it fails the same way
  twice, stop the unit and keep the log — it is the bug report. Starting over is `systemctl stop wacuum-hoodi`,
  `rm -rf /data/wacuum/*`, start.
- **Disk**: `du -sh /data/*`. wacuum's store is 16 KB pages, copy-on-write, so it holds some free pages after
  big commits; it is expected to be about the size of geth's state.

## Upgrading

`sh deploy/hoodi/install.sh LIGHTHOUSE_VERSION` again pulls wac-eth, moves wac to its pin if it moved, reruns the
tests, rebuilds `dist/wacuum` and keeps `/etc/eth/hoodi.env` and the data; then `systemctl restart wacuum-hoodi`.
A store written by an older format is refused with a message saying so; remove it and sync again.
