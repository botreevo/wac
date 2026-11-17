# Can wacuum sync mainnet? (2026-11-13)

Written before a machine is provisioned for it, to say what that machine can be used for. **Short answer:
not yet, and not by any amount of hardware.** wacuum executes today's mainnet blocks correctly and fast —
measured below on real blocks — but it keeps the whole state in memory, runs only the forks from Cancun
on, and has no way to obtain a state other than executing from its genesis. Each of those alone rules out
a mainnet sync. What the machine *can* do on day one is shadow the chain: a reference client syncs it,
and wacuum re-executes every new block against that client's state and checks it. That is set up in
`deploy/mainnet/` and is the recommended first use.

Every number is marked **measured** (here, with the command that produced it) or **estimated** (with what
it rests on).

## The machine assumed

EIP-7870's full-node tier, which ethereum.org's run-a-node page points to: **4 TB NVMe, 32 GB RAM,
4 cores / 8 threads (~1000 single-thread, ~3000 multi-thread PassMark), 50 Mbps down / 15 Mbps up.**
Sources: [EIP-7870](https://eips.ethereum.org/EIPS/eip-7870),
[ethereum.org, run a node](https://ethereum.org/en/developers/docs/nodes-and-clients/run-a-node/),
[geth's hardware page](https://geth.ethereum.org/docs/getting-started/hardware-requirements).

Nothing above that is needed for the shadow (reth or geth plus Lighthouse fit in about 1.5 TB and 16 GB
today). Two asks beyond it, both cheap:

- **Ubuntu 24.04 LTS, x86_64**, root over SSH: the install script assumes apt and systemd, and the reference
  clients' release binaries are x86_64 Linux.
- **The 4 TB as one NVMe filesystem at `/data`**, not split: reth, Lighthouse and wacuum's own files each
  take a directory there.

## Where wacuum stands, area by area

| | today | what a mainnet sync needs |
| --- | --- | --- |
| sync modes | full sync from its own genesis, fetching headers back and bodies forward from peers when the consensus client names an unknown head | snap sync (or a state import) at a recent block — or full sync from 2015's genesis |
| forks | Cancun, Prague, Osaka, BPO1–5, by timestamp; every execution-spec-tests v5.4.0 fixture for them passes | the same, for following the head. A sync from genesis needs Frontier through Shanghai as well, plus proof-of-work header rules |
| genesis | a geth-format `genesis.json` whose chain is on Cancun or later at block 0 (`genesisFrom` refuses mainnet's) | mainnet's 2015 genesis, or a trusted checkpoint (a block hash and its state) to start from |
| state storage | entirely in memory, in wac GC objects: accounts, storage, both tries | on disk, with a bounded cache |
| persistence | a log of every imported block and fork choice, and every 1024 finalized blocks a snapshot of the *whole* state, rewritten | incremental writes of what each block changed |
| memory | **measured**: about 1.4 KB an account and 0.6 KB a storage slot, 0.9 KB once its trie exists; and the Node/V8 host stops at a ~1.4 GB heap | a cache of a few GB, the rest on disk |
| p2p | RLPx, discv4, eth/69 with EIP-2124 fork ids; dials and accepts peers, serves headers, bodies and receipts, gossips transactions; talks to geth (`tools/e2e/devnet.wac`) | snap/1 as a client, to fetch a state; discv5 is optional |
| following the head | the Engine API, V1–V5, with JWT: a consensus client (Lighthouse, Teku, …) drives it as it would geth | the same — this part is done |
| correctness | execution-spec-tests v5.4.0: every state, blockchain and engine test for Cancun, Prague and Osaka (and the transitions to BPO4); **and, measured here, real mainnet blocks match their headers** | the same, on every mainnet block — which the shadow checks |
| execution speed | **measured** 216 Mgas/s on five recent mainnet blocks, senders recovered (below) | ~5 Mgas/s to keep up with a 60 M gas limit; much more to catch up |

## Measurements

### Recent mainnet blocks, executed here and checked against their headers (measured)

`tools/mainnet/replay.sh FROM COUNT` takes blocks from a JSON-RPC node, fetches the accounts and slots
they read as they were before the first one (`eth_getProof`, `eth_getStorageAt`, `eth_getCode` at
`FROM - 1`, the reads learnt by running the blocks and seeded by `eth_createAccessList`), then imports the
blocks as `engine_newPayload` would: header rules, every transaction, withdrawals, system calls and
requests, and every commitment — gas used, transactions root, receipts root, logs bloom, withdrawals root,
requests hash — compared with the header. Only the state root cannot be, since the world holds just what the
blocks touched. The time is everything but fetching: decoding, sender recovery, execution and the (partial)
roots, on wac's native V8 host, one thread of this container's Xeon (2.1 GHz).

| blocks | transactions | gas | senders recovered | senders known | checks |
| --- | ---: | ---: | ---: | ---: | --- |
| 26,404,000 (2026-11-13, under BPO2) | 211 | 40.4 M | 327 ms — **123 Mgas/s** | 232 ms — **173 Mgas/s** | all match but the state root |
| 26,404,100–26,404,104 (20–21 blobs each, one block at the 60 M limit) | 1131 | 178.9 M | 825 ms — **216 Mgas/s** | 674 ms — **265 Mgas/s** | all match but the state root |
| 26,432,348–26,432,379 (2026-11-17, offline, from answers fetched over HTTPS) | 6914 | 976 M | 5753 ms — **169 Mgas/s** | 4031 ms — **242 Mgas/s** | 18 match but the state root; 14 differ in gas used only, with one slot still unfetched (below) |

Fetching the first block's state took 56 rounds against a hosted endpoint's free tier, learning a few slots
a round (a read that comes back empty makes a transaction take another path). For the five, the access
lists named 2669 accounts and 10 330 slots up front, and 111 more rounds found the last ~2% — about an
hour, most of it the rate limit. A node of one's own with `prestateTracer` names everything in one round.
The first figure is lower because one block is too short to time well: the five are the better number.

The 32 blocks of 2026-11-17 (replayed offline: `replay.sh` fetches into a directory, and `replay.wac --dir` runs
it with no network) were run the same way, then the 1- and 5-block sets of 11-13 again on the code of the day, both
as before. Learning their state took ~2 h of rounds on the free tier, and stalled in a chain of one contract's slots
(0xbeef007e…, which reads a slot whose key is the last one's value), learnt one a round for 250+ rounds; with the
last read as empty (`--anyway`), the 14 blocks that differ do so in gas used only — as a transaction taking another
path on a missing read does. That is likely, not shown, until the chain is fetched to its end; a node of one's own
with `prestateTracer` names all of it in one round, which is what the shadow box will have.

So the interpreter, the precompiles and the transaction rules agree with mainnet on the traffic it has
today, and execution is not what stands between wacuum and the head: a block arrives every 12 s and
carries at most 60 M gas, about 5 Mgas/s.

### The worst blocks an attacker can build (measured earlier, `docs/` and issue 0007d)

The slowest operations, by gas, are BLS12-381 MSMs of one point, BN254 additions, map-to-G1 and KZG point
evaluation, at 7–8 Mgas/s. A full 60 M gas block of them takes 7–9 s: inside a 12 s slot, without much room.
Issue 0007d lists five fixtures still over 2 s.

### Memory (measured with a scratch program, not committed)

A `World` with only funded accounts: 300 000 accounts → 579 MB resident, 100 000 → 260 MB: about 1.6 KB an
account including the process. One million accounts did not fit: V8 stopped at a 1.38 GB heap
("Ineffective mark-compacts near heap limit"). One million storage slots in one contract: 594 MB, and
944 MB once the storage trie was built for a root.

Mainnet's state is about 300 million accounts and well over a billion storage slots (**estimated**, from
public figures for geth's snapshot, ~250–350 GB flat). At these sizes that is over a terabyte of heap — a
thousand times the host's ceiling, and thirty times the machine's memory. No tuning closes that: the state
has to live on disk.

### The chain from genesis (measured by sampling, estimated in total)

`eth_getBlockByNumber` every 50 000 blocks, 0 to 26.4 M:

| era | blocks | gas | transactions | mean gas a block |
| --- | ---: | ---: | ---: | ---: |
| 2015 → Byzantium | 4.4 M | 3.0×10¹² | 0.06 B | 0.7 M |
| Byzantium → Istanbul | 4.7 M | 3.2×10¹³ | 0.56 B | 6.8 M |
| Istanbul → London | 3.9 M | 4.6×10¹³ | 0.64 B | 11.7 M |
| London → the merge | 2.6 M | 4.0×10¹³ | 0.48 B | 15.8 M |
| the merge → Cancun | 3.9 M | 5.4×10¹³ | 0.54 B | 13.9 M |
| Cancun → Prague | 3.0 M | 4.3×10¹³ | 0.44 B | 14.3 M |
| Prague → now | 4.1 M | 1.1×10¹⁴ | 1.11 B | 26.3 M |
| **total** | **26.4 M** | **3.2×10¹⁴** | **3.8 B** | |

Executing all of it at the in-memory speed measured above (~200 Mgas/s) would take **19 days** of
execution alone; at a disk-bound 30–50 Mgas/s, which is where clients with mature databases land on old
blocks, **75–125 days**. Recovering 3.8 billion senders at 150 µs each is 6.6 days of it, on one core.
Pre-merge bodies are also no longer served by most peers since history expiry (2025), so a sync from
genesis needs era1 archives, hundreds of GB, from a mirror.

## Ways to the head

**A. Full sync from 2015's genesis.** Needs every fork from Frontier to Shanghai (with their gas schedules,
refund rules, the DAO change, pre-Byzantium receipts carrying a state root after each transaction),
proof-of-work header checks (or a checkpoint that skips them), era1 import, the state on disk, and months of
execution. *Probability of reaching the head within six months: under 5%.* Not recommended.

**B. Snap sync to a recent block, then follow with a consensus client.** wacuum already runs the forks the
head is on and the Engine API a consensus client drives. Missing:

1. **State on disk** (the blocker under everything): a key-value store written in wac over the host's
   `RandomFile` (wac has no database and no bindings to one), flat account and storage tables, trie nodes
   by path so a root rehashes only what changed, and a bounded in-memory cache. *Estimated 3–5 weeks.*
2. **Reads that wait for the disk.** Every host read in wac is asynchronous; the EVM is synchronous. Either
   the interpreter suspends at a missing account or slot and resumes after the read — feasible, since its
   frames already live on a stack of its own rather than the host's — or each block is prefetched by a
   first speculative run, which is what `replay.wac` does across the network today. `World` now takes a
   `StateSource` for what it does not hold (this change), which either one plugs into. *1–2 weeks.*
3. **snap/1 as a client**: account and storage ranges with their proofs, bytecodes, and healing the trie
   while the pivot moves. *3–4 weeks.*
4. **Persistence that is incremental** rather than a whole-state snapshot every 1024 blocks. *1 week, with 1.*
5. **The V8 heap ceiling**: the cache wants more than 1.4 GB; a wac host option for the heap limit, asked of
   wac. *Days.*

*Probability of reaching the head and staying there, on the assumed machine, within three months of
focused work: about 35%. Within six: about 70%.* The disk store and snap's healing are where it can go
wrong; both are well specified by geth and reth, but nothing in wac has done either.

**C. Shadow the head (available now).** A reference client syncs; wacuum re-executes every new block
against that client's state and checks every commitment but the state root. It answers the question the
fixtures cannot — does wacuum agree with mainnet on every block, as it happens — and measures its speed on
live traffic, while B is built. `deploy/mainnet/` installs it. *Probability it runs on day one: ~90%*
(the reference node's own sync takes one to three days first).

## Blockers, ranked

1. **The state is in memory** — over a terabyte of heap against a ~1.4 GB host limit. Fix: B1, B2, B4.
2. **No way to get a state but executing from genesis** — and genesis is pre-Cancun. Fix: B3 (or a state
   import from a trusted source, the cheap way to test B1 before B3 exists).
3. **Forks before Cancun** — matters only for path A.
4. **Heap ceiling** — B5.
5. **Worst-case blocks at 7–9 s** of a 12 s slot — not a blocker, a margin to watch (0007d).
6. **A compiler fault at this wac pin**: a program holding both `fetch` and the block types fails to emit
   (`docs/wac-asks.md`). Worked around by splitting the replay tool in two.

## What was prepared here, without the machine

- `World` takes a `StateSource`: what it does not hold is asked of it once, then held. The replay tool uses
  it today; a disk store is the next thing to implement it.
- `tools/mainnet/replay.sh` (`fetch.wac` + `replay.wac`): mainnet blocks executed and checked, as above.
  `WACUUM_PRESTATE=1` names each block's reads with the node's `prestateTracer` in one call instead of
  learning them, for a node that serves `debug_` (a local reth or geth).
- `tools/mainnet/follow.sh`: the shadow — each new head block replayed and logged, one line a block.
- `deploy/mainnet/`: `preflight.sh` (the machine checked against this page before anything is installed),
  `install.sh` (wac at the pin, wac-eth, the unit tests, the service user and layout, metrics and log rotation),
  `reference.sh` (reth and Lighthouse from their releases, checkpoint-synced, as services), and the units:
  `reth`, `lighthouse`, `wacuum-shadow`, and `wacuum-status.timer`, which writes the shadow's status each minute
  as Prometheus metrics (`tools/mainnet/status.wac`).

## Runbook

(This is the mainnet shadow's. **Hoodi comes first** — wacuum on its own store, snap-synced, driven by
Lighthouse beside a geth reference: `docs/hoodi.md` and `deploy/hoodi/`.)

1. **Check the machine**: `sh deploy/mainnet/preflight.sh` (from a checkout, or fetched alone) — the OS, cores,
   memory, `/data` (size, free, solid state), the clock, the p2p ports, and the outbound HTTPS the install needs.
   It changes nothing; a FAIL line says what to fix. A virtual disk that calls itself rotational is a WARN: ask
   the provider.
2. **Install**: `sh deploy/mainnet/install.sh` as root — about 20 minutes, most of it building wac from source.
   `WAC_URL=https://git.voltrevo.com/wac.git` if the box reaches that and not GitHub. It installs wac at
   wac-eth's pin, runs wacuum's unit tests as the service user, node_exporter on 127.0.0.1:9100, the units, and
   logrotate's rule for the shadow's log.
3. **The reference**: `sh deploy/mainnet/reference.sh RETH_VERSION LIGHTHOUSE_VERSION` with the current
   releases. Lighthouse checkpoint-syncs in minutes; reth's full sync takes one to three days on this disk.
   Progress: `journalctl -fu reth`, and `curl -s localhost:8545 -H 'content-type: application/json' -d
   '{"jsonrpc":"2.0","id":1,"method":"eth_syncing","params":[]}'` answers `false` when it is done.
4. **The shadow**: `systemctl enable --now wacuum-shadow wacuum-status.timer`.

### Access to the pinned commits

The install fetches three things by commit: wac-eth itself, wac at the commit wac-eth's `wac.lock` pins, and what
wac's own lock pins (wac-web). Pins name GitHub, and the owner pushes to git.voltrevo.com first and syncs GitHub
after — so a fresh pin is often on git.voltrevo.com alone (on 2026-11-17 neither wac `aaef775ca` nor wac-web
`a859d17` was on GitHub). `install.sh` and `tools/deps.sh` fetch a pin GitHub lacks from git.voltrevo.com, and
wac-eth comes from there in any case — but **git.voltrevo.com is not public**: it needs credentials, which this
project's development containers get from a proxy and a fresh box does not have. One of two things is needed:

- **(a) Read credentials for git.voltrevo.com on the box.** An access token for an account that can read
  `wac`, `wac-web` and `wac-eth`, as one line in `/etc/eth/git-credentials`, before `install.sh` runs:

      mkdir -p /etc/eth && install -m 600 /dev/null /etc/eth/git-credentials
      echo 'https://USER:TOKEN@git.voltrevo.com' > /etc/eth/git-credentials

  `install.sh` makes it readable by the `wacuum` user and points git at it for every user
  (`git config --system credential.https://git.voltrevo.com.helper "store --file /etc/eth/git-credentials"`),
  so root's clones and the service user's `tools/deps.sh` both use it, at install and at every upgrade. (An SSH
  deploy key would need every URL rewritten to SSH; the token keeps the URLs as they are.)
- **(b) The pinned commits on GitHub.** Andrew pushes wac at the pin (and wac-web at wac's pin) to
  github.com/voltrevo, and wac-eth too, then runs `install.sh https://github.com/voltrevo/wac-eth.git`. Nothing
  else changes; the next pin move needs the same again.

`preflight.sh` says which: it fetches each of the four commits from here, as the install will, and FAILs naming any
it cannot get (`pinned: wac aaef775… is at neither … nor git.voltrevo.com`).

### What it writes, and where to look

- **The log**, `/data/wacuum/follow.log`: `N ok MS ms MGAS Mgas/s` a block, or `N DIFFERS … — why`. Rotated weekly,
  26 kept, compressed. `journalctl -u wacuum-shadow` has only what goes wrong around it (a build that failed, a
  node that did not answer).
- **A block that differed** keeps every answer under `/data/wacuum/differs/N`; `sh tools/mainnet/replay.sh N 1
  /data/wacuum/differs/N` replays it again by hand, without the network. That directory is the bug report.
- **Status, by hand**: `sh tools/mainnet/status.sh /data/wacuum/follow.log` (from `/opt/wac-eth/packages/wacuum`,
  as `wacuum`) — blocks checked and differed, the last, the lag behind reth's head, and a block's time and Mgas/s
  (median, p95, most) over the last 1000.
- **Metrics**, each minute: `curl -s 127.0.0.1:9100/metrics | grep wacuum_shadow` —
  `wacuum_shadow_blocks{result="ok"|"differs"}`, `wacuum_shadow_last_block`, `wacuum_shadow_last_differs`,
  `wacuum_shadow_lag_blocks` (-1 when reth did not answer), `wacuum_shadow_block_ms{quantile}` and
  `wacuum_shadow_mgas_per_second{quantile}`; with node_exporter's own (disk, memory, CPU). Nothing scrapes
  them yet: point a Prometheus at it over an SSH tunnel, or read them with curl.
- **What to alert on**, when something scrapes: `wacuum_shadow_blocks{result="differs"}` rising (a block
  wacuum computes differently from mainnet: the point of the exercise); `wacuum_shadow_lag_blocks > 10` for
  ten minutes (the shadow stuck or too slow — or reth behind, which `eth_syncing` tells apart);
  `wacuum_shadow_block_ms{quantile="0.95"} > 4000` (a block's replay near a third of the slot); the data disk
  past 85%.

### Restarts and upgrades

After a crash or a reboot every service restarts itself; the shadow resumes from the last block in its log, or
from the head if it has fallen more than 64 behind (and after a rotation, from the head). Upgrading is
`install.sh` again — it pulls wac-eth, moves wac to its pin if it moved, reruns the tests — then
`systemctl restart wacuum-shadow`.

Tested here (2026-11-17, an Ubuntu 24.04 container, not the box): `preflight.sh`; `install.sh` end to end, twice
(install, then upgrade), up to the systemd steps the container cannot run — wac built at the pin, wacuum's 26
unit-test files passing as the `wacuum` user; the units through `systemd-analyze verify`; logrotate's rule through
`logrotate -d`; `follow.sh` and `status.sh` against a hosted mainnet endpoint (block 26 432 160: ok, 145 ms,
133 Mgas/s), the metrics file written by `wacuum` and served by node_exporter. Installing found three things, now
fixed: the pinned wac commit was not on GitHub yet (fetched from git.voltrevo.com when so); nor was the wac-web
commit wac's own lock names (`tools/deps.sh` does the same); and a second run — an upgrade — stopped at `git
pull`, root's git refusing the checkout the service user owns.

## The all-wac mode: wacuum and the light-client driver (2026-11-17)

**What it is.** wacuum driven by `cmd/driver.wac` instead of a consensus client: the driver follows the beacon chain
with Ethereum's light-client protocol (`packages/lightclient`) and turns each head it proves into the Engine API calls
a consensus client would make — `engine_newPayloadV4` for every block from one wacuum has to the head, then
`engine_forkchoiceUpdatedV3` with the head and, as safe and finalized, the light client's finalized block. No beacon
state, no validators, no p2p on the consensus side: the driver reads a beacon node's REST API (the light-client
endpoints and `/eth/v2/beacon/blocks`), and any beacon node will do, a public one included.

**What it trusts — plainly.** This is an *optimistic, light-client-driven* execution client, the model of Helios and
of Nimbus's light-client mode:

- **Trusted:** one beacon block root, at the first start (the checkpoint), and the sync committees that follow from it
  by the protocol's rules. The head is a block the current sync committee (512 validators, rotated every ~27 hours)
  signed with more than half of the highest participation seen over the last two periods; the finalized block is one
  two thirds of the committee signed as finalized.
- **Not trusted:** the beacon node. Light-client updates are believed only as far as their BLS signatures and Merkle
  branches carry them; a block only as far as its execution block hash is the one the light client proved, or the
  parent hash of a block already believed. wacuum derives that hash from every field of the payload, the parent beacon
  root and the execution requests, and checks the blob versioned hashes against the transactions, so a beacon node
  that changed a byte gets the block refused, never a different block accepted.
- **Not checked, that a full consensus client checks:** the beacon state transition (attestations, slashings, the
  validator set's balances), fork choice by attestation weight, and the availability of blob data. A sync committee
  that signed a head the rest of the chain never accepted would be followed until a finalized update says
  otherwise. Execution is checked in full — wacuum runs every block, so state, receipts and state roots are its own.
- **Restarts** start from the last finalized root the driver verified (kept in `/data/wacuum/driver.json`), so the
  checkpoint is trusted once.

**Tested.**

- *Unit*: a mainnet Fulu block (slot 15 677 439: 297 transactions, 18 blobs, 3 deposit requests) as the beacon API
  serves it becomes a payload whose derived block hash is its own; a changed deposit or parent root is refused
  (`test/driver_test.wac`).
- *Devnet* (`tools/e2e/cldriver.wac`): geth builds under Lighthouse and its validators; the driver reads Lighthouse's
  light-client API and drives wacuum, which no consensus client talks to. wacuum follows to block ~130 with transfers
  and a blob block, survives its own kill and the driver's (before finality from the checkpoint, after it from the
  root it kept), and its finalized block is geth's. A reorg was not provoked — one validator client holds every key —
  and goes by the same walk: from the new head back by parent hash to a block wacuum has.
- *Mainnet dry run*: DRYRUN

**Running it** needs one more thing of wacuum: **it does not start on mainnet's genesis yet** ("the chain is not on
Cancun or later at genesis" — it runs Cancun on, and mainnet's genesis is Frontier's). A start that takes mainnet's
known genesis hash and its Cancun-onward schedule (`src/chain/mainnet.wac`) and snap-syncs to the head the driver
names, never running a block before Cancun, is the missing piece. With it, on the box: `install.sh` builds
`dist/driver`, makes `/etc/eth/jwt-wacuum.hex` and installs `/etc/eth/mainnet-wac.env` (set `CHECKPOINT`, and
`BEACON_URL` if not the default) and `wacuum-driver.service`; then `systemctl enable --now wacuum-driver` beside
wacuum on its store at 127.0.0.1:8551. `journalctl -fu wacuum-driver` shows one line a head: its slot, its execution
hash, wacuum's answer and the finalized slot.

**Memory, by mode** (the box's 32 GB):

| mode | processes | resident, together |
| --- | --- | ---: |
| the shadow (C): reth + Lighthouse + `wacuum-shadow` | reth *8–12 GB*, Lighthouse *4–6 GB*, the shadow **< 1 GB** | *~14–20 GB* |
| wacuum under Lighthouse (B), no reference | wacuum *3–5 GB*, Lighthouse *4–6 GB* | *~8–12 GB* |
| **all wac: wacuum + the driver** | wacuum *3–5 GB*, the driver **~155 MB** (measured, mainnet, the dry run) | ***~3.5–5.5 GB*** |

The all-wac mode is the smallest by the consensus client it leaves out; it leaves the most of the box to the page
cache, which wacuum's store reads through.

## Memory on the 32 GB box (2026-11-17)

Each figure is marked **measured** (here, on this container) or *estimated*. Two arrangements matter: the shadow (C),
which is what the box runs first, and later wacuum on its own store following mainnet beside the reference (B).

**wacuum's own parts**, on a store, at mainnet's rate:

| part | size | how known |
| --- | ---: | --- |
| the entry cache (`--cache-mb`) | as set: 256 MB default, 2 GB on Hoodi | the setting |
| leaves held | 64 MB | a fixed budget (`LEAF_BYTES`) |
| the store's interior (B+tree separators) | *~400 MB at mainnet's ~150 GB flat state* | estimated (`docs/state-on-disk.md`, `state-cache.md`) |
| the overlay, at `--flush-every 8` | **5 MB** at a 2.9 GB store (35 MB at 64); at most 64 MB, when it flushes | measured (`tools/measure/flush.wac`); the cap |
| history (`--history N`) | **~320 KB a mainnet block**: header, transactions, receipts — 8192 blocks ≈ 2.6 GB, 1024 ≈ 330 MB | measured roughly (`replay.wac --hold`, resident growth, errs high) |
| payloads built, mempool, peers | tens of MB | the soak's `wacuum_sizes` |
| the process beyond its heap (V8, code, buffers) | **~80–150 MB** | measured: the soak's 2400 blocks under a 256 MB heap peaked at 323–339 MB resident |

So on mainnet `CACHE_MB=1536` and `HISTORY=1024` come to ~2.5 GB of live data; V8 wants room above that to collect,
so `WAC_MAX_HEAP=6g`, and wacuum's resident memory is expected at *3–5 GB*. Hoodi's settings (`HISTORY=8192`) are
for Hoodi's small blocks: on mainnet they would hold ~2.6 GB of history alone.

**The box, 32 GB** (*estimated* from the clients' documentation and common reports; to be measured on the box):

| process | shadow (C) | wacuum following too (B) |
| --- | ---: | ---: |
| reth (mainnet, full) | *8–12 GB*, plus the page cache it reads through | the same |
| Lighthouse for reth | *4–6 GB* | the same |
| `wacuum-shadow` (one block's replay at a time) | **< 1 GB** (bounded at 8 GB by its unit) | — |
| wacuum on its store (`WAC_MAX_HEAP=6g`, `CACHE_MB=1536`, `HISTORY=1024`) | — | *3–5 GB* |
| a second Lighthouse, driving wacuum (each execution client needs its own) | — | *4–6 GB* |
| node_exporter, the OS | < 1 GB | < 1 GB |
| **total** | **~14–20 GB**, the rest page cache | **~21–30 GB**: tight |

The shadow fits with room for reth's page cache, which is what makes reth fast. Both stacks together leave little:
on 32 GB, wacuum's cache goes down (`CACHE_MB=1024`), or the shadow's reference is stopped once wacuum follows on
its own, or the box has 64 GB. The memory figures to take on the day: `systemctl status` of each unit (its memory),
`free -g`, and `wacuum_sizes` from wacuum's RPC.

## What is needed from Andrew when the machine is ready

- [ ] Its address, and SSH access as root (a key for this agent's sessions).
- [ ] OS: Ubuntu 24.04 LTS, x86_64.
- [ ] Disk: one 4 TB NVMe filesystem mounted at `/data` (or say where, and the scripts move).
- [ ] RAM 32 GB, 4 cores / 8 threads or better.
- [ ] Inbound ports open: 30303 tcp+udp (execution p2p), 9000 tcp+udp (consensus p2p). Nothing else
      inbound; every RPC listens on 127.0.0.1.
- [ ] Outbound HTTPS to github.com, sh.rustup.rs, static.rust-lang.org, crates.io, git.voltrevo.com, and the
      checkpoint sync URL (mainnet.checkpoint.sigp.io, or another of the public ones). `preflight.sh` checks each.
- [ ] Access to the pinned commits: a read token for git.voltrevo.com in `/etc/eth/git-credentials`, or the pins
      pushed to GitHub ("Access to the pinned commits", above). `preflight.sh` checks each pinned commit.
- [ ] Choice of reference clients: reth + Lighthouse is assumed (reth serves the `debug_` tracers the
      shadow uses); geth + Lighthouse works as well.
- [ ] Whether the machine may also run wacuum's own p2p (port 30304) once B begins.

## Machine request (2026-11-13, after path B's store and snap sync)

**Hoodi first, then mainnet, on one box.** All sizes below are estimates unless marked.

**Minimum for Hoodi alone:** 4 cores, 16 GB RAM, 1 TB NVMe, 25 Mbit/s, Ubuntu 24.04 x86_64, root SSH; inbound
30303 tcp/udp (execution p2p), 9000 tcp/udp (consensus p2p); outbound HTTPS (GitHub, rustup, crates.io, a
checkpoint-sync URL). Software installed by `deploy/mainnet/install.sh`/`reference.sh`: wac at the pin,
wac-eth, Lighthouse (Hoodi, checkpoint-synced), and one reference execution client that serves snap/1
(geth or reth) for wacuum to snap-sync from and be checked against. Hoodi's state is small (tens of GB in
geth; wacuum's store perhaps twice that with its 64 KB pages and path-scheme tries), so a Hoodi stack —
reference EL + CL + wacuum — is a few hundred GB.

**The EIP-7870 box (4 TB NVMe, 32 GB, 4c/8t, 50/15 Mbit/s) covers all three, in turn:**

| use | disk (estimated) | notes |
| --- | ---: | --- |
| Hoodi: reference EL + Lighthouse + wacuum `--store --snap` | ~0.3–0.5 TB | the first test of snap and healing on a public chain |
| shadow mode C on mainnet: reth/geth + Lighthouse | ~1.5 TB | as `deploy/mainnet/` sets it up |
| mainnet wacuum on the store, beside the reference | ~0.4–0.6 TB | flat state ~150 GB, tries and page overhead on top |
| **together** | **~2.5 TB of 4** | Hoodi can be removed before mainnet if room is short |

RAM: 32 GB is ample — wacuum's heap is capped at ~1.4 GB today (4 GB once wac's `--max-heap` lands), the
reference EL wants ~8–16 GB, Lighthouse ~4–8 GB. CPU: wacuum executes on one core. Nothing above EIP-7870 is
needed; 8 TB rather than 4 would only matter for keeping Hoodi, a mainnet reference and wacuum's mainnet
store side by side for long.
