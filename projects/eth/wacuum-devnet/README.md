# wacuum-devnet

An Ethereum devnet, its block explorer and its faucet, as one [wac](https://git.voltrevo.com/wac.git) program.
Every block is built and executed by [wacuum](https://git.voltrevo.com/wacuum.git), the execution client written
in wac; the same process serves JSON-RPC and the site. Meant for **wacuum.voltrevo.com**, behind Caddy.

    ./dist/devnet --datadir data

| path | what |
| --- | --- |
| `POST /rpc` (and `POST /`) | JSON-RPC: the `eth_`, `net_` and `web3_` methods wacuum answers, CORS open, no token. The Engine API is refused |
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
    tools/deps.wac     the locked dependencies into wac's cache, with git
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
connections stopped the whole node, blocks and all, until the cap and the deadline went in. Caddy reads each
request whole before passing it on (`deploy/Caddyfile`), so slow clients wait at Caddy and never reach it.

**After a restart, older transactions have no receipt.** The node starts from its last snapshot and replays
the log after it, and wacuum keeps receipts only for the blocks it ran. The explorer still finds a transaction
from before the snapshot, from its block, and says that its status, fee and logs were not kept.

## Building

You need the `wac` command. This was developed and tested with one built from wac `96e5a0cfe` (wac's `master`
on 2026-10-30), three commits after the library commit `wac.lock` pins:

    git clone https://git.voltrevo.com/wac.git ~/src/wac
    cd ~/src/wac && git checkout 96e5a0cfe && ./bootstrap.sh --host nodejs

Node is the fastest of wac's hosts for wacuum, by two to four times. Then clone this with `-b master`: the
server's default branch is `main` and empty, as for the other repositories there.

    git clone -b master https://git.voltrevo.com/wacuum-devnet.git && cd wacuum-devnet

    wac task deps      # the three locked dependencies into wac's cache, with git (`wac update` gets a 401 from git.voltrevo.com)
    wac task test      # the unit tests, in a second: pages, RPC, the faucet and its limits, against a real engine
    wac task build     # dist/devnet, one executable file (it runs on the `wac` it finds on PATH)

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
match; a follower that does it by itself is still to be written.

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

## Dependencies

`wac.json5` imports three packages by git, each pinned in `wac.lock`:

- **wacuum**, from its `lib` branch: `master` plus a `src/lib.wac` named as the package's `exports`. wac lets a
  project reach another project only through its `exports`, and wacuum's `master` has none. Once that commit is
  on wacuum's `master`, point the `ref` there.
- **wac**, at the commit wacuum pins, so that values crossing between the two (JSON from the engine, above all)
  are one type.
- **web**, for components and `documentOf`.
