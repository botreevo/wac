# wacuum-devnet

An Ethereum devnet, its block explorer and its faucet, as one [wac](https://git.voltrevo.com/wac.git) program.
Every block is built and executed by [wacuum](https://git.voltrevo.com/wacuum.git), the execution client written
in wac; the same process serves JSON-RPC and the site. Meant for **wacuum.voltrevo.com**, behind Caddy.

    ./dist/devnet --datadir data

| path | what |
| --- | --- |
| `POST /rpc` (and `POST /`) | JSON-RPC: the `eth_`, `net_` and `web3_` methods wacuum answers, CORS open, no token. The Engine API is refused, and `eth_call` runs with at most `--rpc-gas-cap` gas |
| `/` | the chain at a glance, the latest blocks and transactions, the faucet, and the details a wallet needs to add the network |
| `/block/<number or hash>`, `/tx/<hash>`, `/address/<address>` | the explorer |
| `/search?q=…` | a number, a hash or an address, sent to its page |
| `POST /faucet` | `address=0x…`: 10 ETH, at most once a day for each visitor and each recipient. A visitor is an IPv4 address, or an IPv6 /64 |
| `/genesis.json` | the chain's genesis, for anybody who wants a node of their own |
| `/healthz` | `ok` |

## How it fits together

    cmd/devnet.wac     flags, the faucet's key and the genesis, the block producer; starts everything
    src/node.wac       an engine from a genesis; the chain log and snapshots, as wacuum's own node keeps them
    src/server.wac     the HTTP port and its routes
    src/http.wac       requests and responses; the client's address behind a proxy
    src/explorer.wac   the pages: `web` components, rendered on the server with `documentOf`
    src/index.wac      which transactions touched which address, built from the blocks as they are made
    src/faucet.wac     the drip, and its per-visitor and per-address limits
    src/chain.wac      the genesis, addresses, and signing the faucet's transfers
    src/format.wac     ether, gwei, ages, short hashes
    src/style.wac      the stylesheet and the icon, as block strings
    tools/e2e.wac      a visitor and a wallet against a running devnet, over HTTP
    deploy/            a Caddyfile and a systemd unit

**Everything is wac**, the tooling included: there is no shell script, no JavaScript and no Python here. The
only other languages are the CSS inside `src/style.wac` and the configuration in `deploy/`.

**The node is wacuum's `--dev` mode.** A block from the mempool every `--block-time` seconds (2), each final as
soon as it is made; with `--datadir` every block goes to `chain.log` before anything that depends on it is
answered, and a restart replays it. Nothing here touches the EVM: the explorer and the faucet use the engine
through its own `eth_` methods, in process.

**The pages are drawn on the server.** `web`'s components are the same ones a browser page mounts, but a `web`
page runs in a worker with no network, so it could not ask the node anything. Here each request renders a tree
of components once with `documentOf`, every string escaped on the way out. The browser runs no script at
all, and the pages' Content Security Policy says so. So there is no *Add to wallet* button: a wac page cannot
reach a browser wallet, so the home page lists the details to add by hand.

**The faucet is not wacuum's well-known dev account.** That key (0x11…11) is public, so anyone could empty it.
The first start makes a key, keeps it in `<datadir>/faucet.key`, and writes a genesis funding its address with
a billion ether to `<datadir>/genesis.json`. Every later start reads both back. Delete the data directory to
start a new chain; `--chain-id` matters only then. The limits are kept in memory, so a restart forgets them.

**Behind Caddy, the visitor is the last address in `X-Forwarded-For`.** Caddy replaces that header with the
client's address, so the last entry is the one Caddy wrote. That header is trusted only on connections from
loopback. Without a proxy, `--direct` stops trusting it at all. An IPv6 visitor is their /64, since a host
on one can take as many addresses in it as it likes.

**The node answers 48 connections at a time, and closes one that has not been answered in ten seconds.** On
wac's JavaScript hosts a program can have 128 host calls in flight, and one more waits for ever: 130 idle
connections stopped the whole node, blocks and all, until the cap and the deadline went in (wac
`issues/system/0373d`). Caddy reads each
request whole before passing it on (`deploy/Caddyfile`), so slow clients wait at Caddy and never reach it.

**It keeps a day of blocks.** Every block the node serves is held in memory, a few kilobytes each, so blocks
older than `--history` (a day's worth by default) are dropped, and the explorer says so when asked for one.

**One request may run at most 10M gas** (`--rpc-gas-cap`). The engine does one thing at a time, so an
`eth_call` costs everyone the time it runs; with a block's gas of the slowest precompile that was 4.6 s, and is
1.3 s behind the cap. `eth_estimateGas` is tried once at the cap and refused if it fails there; a call that
succeeds with any gas it is given still costs about 5 s, because wacuum's search starts at a whole transaction's
limit whatever the caller asks (its `issues/0008d`).

**After a restart, older transactions have no receipt.** The node starts from its last snapshot and replays
the log after it, and wacuum keeps receipts only for the blocks it ran. The explorer still finds a transaction
from before the snapshot, from its block, and says that its status, fee and logs were not kept.

## Building

The devnet is part of [wac-eth](../README.md), with one wac pin for the whole repository: build the `wac` command
and fill the package cache as the root README says. Then, from `wacuum-devnet/`:

    wac test test      # the unit tests, in a second: pages, RPC, the faucet and its limits, against a real engine
    mkdir -p dist && wac app --allow-read --allow-write --allow-net cmd/devnet.wac -o dist/devnet

(`wac task devnet:test` and `wac task devnet:build` from the root do the same.)

and to see it working end to end, the way a visitor and a wallet use it:

    ./dist/devnet --datadir /tmp/devnet --block-time 1 &
    wac task e2e       # faucet, contract deployed and called, a transfer, and the explorer showing them

## Deploying

    sudo cp deploy/wacuum-devnet.service /etc/systemd/system/ && sudo systemctl enable --now wacuum-devnet

and `deploy/Caddyfile` in Caddy's configuration. The unit expects this repository at `/opt/wacuum-devnet` with
`wac task build` run, a `wacuum` user with `wac` in `~/.wac/bin`, and keeps the chain in
`/var/lib/wacuum-devnet`. Back that directory up: `faucet.key` and `genesis.json` are the chain's identity.

**Leave `--p2p-port` off on the public node.** wacuum's devp2p takes every inbound connection, and two hundred
silent ones stop the node for good, as above. Nor would a peer get far: another wacuum (from `/genesis.json`,
with `--peer`) connects and can fetch every block, but it syncs only to a head a consensus client names with
`engine_forkchoiceUpdated`, and this chain has none. Driving that by hand works, and the peer's state roots
match; a follower that does it by itself is still to be written. Both are wacuum's `issues/0001d` and `0003d`.

## Flags

    --datadir DIR          where the chain, the faucet's key and the genesis are kept (required)
    --addr ADDR --port N   where the site and JSON-RPC listen (127.0.0.1, 8545)
    --site-url URL         the site as the public reaches it, for the wallet details (https://wacuum.voltrevo.com)
    --name TEXT            what the site and wallets call the network (wacuum devnet)
    --chain-id N           read only when the genesis is first made (20261117)
    --block-time SECONDS   how often a block is made (2)
    --faucet-ether N       what one drip sends, in whole ether (10)
    --faucet-hours N       how long each visitor and each address waits between drips (24)
    --direct               trust no X-Forwarded-For: for running without a proxy in front
    --p2p-port N           accept devp2p peers, and run discovery, on this port (off; not on a public node)
    --ip ADDR              the address advertised to peers (127.0.0.1)
    --bootnode ENODE       a discovery node to start from; as many as wanted
    --snapshot-every N     finalized blocks between state snapshots (1024)
    --history N            blocks kept for the explorer and the eth_ methods (a day's: 86400 / --block-time)
    --rpc-gas-cap N        the most gas one eth_call or eth_estimateGas may use (10,000,000)

## Dependencies

wacuum is beside this in wac-eth, imported by path (`@/wacuum/src/lib.wac`), so the devnet always runs the
wacuum in the same commit. wac and **web** (components and `documentOf`) are pinned once, in wac-eth's root
`wac.lock`; one pin means the JSON the engine answers with and the JSON this code reads are one type.
