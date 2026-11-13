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
| execution speed | **measured** 120–175 Mgas/s on recent mainnet blocks (below) | ~5 Mgas/s to keep up with a 60 M gas limit; much more to catch up |

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

Fetching that block's state took 56 rounds against a hosted endpoint's free tier, learning a few slots a
round (a read that comes back empty makes a transaction take another path); seeding from access lists cuts
that, and a node of one's own with `prestateTracer` needs one round.

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

Executing all of it at the in-memory speed measured above (~120 Mgas/s) would take **31 days** of
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
- `deploy/mainnet/`: `install.sh` (wac at the pin, wac-eth, the unit tests, the service user and layout),
  `reference.sh` (reth and Lighthouse from their releases, checkpoint-synced, as services) and the three
  systemd units.

## Runbook

1. `sh deploy/mainnet/install.sh` as root — about 15 minutes, most of it building wac from source.
2. `sh deploy/mainnet/reference.sh RETH_VERSION LIGHTHOUSE_VERSION` with the current releases. Lighthouse
   checkpoint-syncs in minutes; reth's full sync takes one to three days on this disk. Progress:
   `journalctl -fu reth`, and `curl -s localhost:8545 -H 'content-type: application/json' -d
   '{"jsonrpc":"2.0","id":1,"method":"eth_syncing","params":[]}'` answers `false` when it is done.
3. `systemctl enable --now wacuum-shadow`. Its log is `/data/wacuum/follow.log`: `N ok MS ms MGAS Mgas/s` a
   block, or `N DIFFERS …` with the reason. A block that differed keeps every answer under
   `/opt/wac-eth/packages/wacuum/scratch/follow/N`; `sh tools/mainnet/replay.sh N 1 scratch/follow/N`
   replays it again by hand, without the network.
4. After a crash or a reboot every service restarts itself; the shadow resumes from the last block in its
   log, or from the head if it has fallen more than 64 behind.
5. Progress for whoever asks: `tail /data/wacuum/follow.log`, `grep -c DIFFERS /data/wacuum/follow.log`.

## What is needed from Andrew when the machine is ready

- [ ] Its address, and SSH access as root (a key for this agent's sessions).
- [ ] OS: Ubuntu 24.04 LTS, x86_64.
- [ ] Disk: one 4 TB NVMe filesystem mounted at `/data` (or say where, and the scripts move).
- [ ] RAM 32 GB, 4 cores / 8 threads or better.
- [ ] Inbound ports open: 30303 tcp+udp (execution p2p), 9000 tcp+udp (consensus p2p). Nothing else
      inbound; every RPC listens on 127.0.0.1.
- [ ] Outbound HTTPS to github.com, sh.rustup.rs, static.rust-lang.org, crates.io, and the checkpoint
      sync URL (mainnet.checkpoint.sigp.io, or another of the public ones).
- [ ] Choice of reference clients: reth + Lighthouse is assumed (reth serves the `debug_` tracers the
      shadow uses); geth + Lighthouse works as well.
- [ ] Whether the machine may also run wacuum's own p2p (port 30304) once B begins.
