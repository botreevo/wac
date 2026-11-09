# Notes for whoever works on this next

README.md says what this is, how it fits together and how to deploy it; read it first. This file is what a
README does not say.

## Working agreements

- **wacuum is a dependency, not a place to work around.** If the explorer needs something the engine's `eth_`
  methods do not answer, add it to wacuum (and to its `src/lib.wac`), then move the pin here. Do not reach into
  the engine's fields from here beyond what `cmd/devnet.wac` already does (`mempool`, `head`, `produce`).
- **The `wac` pin follows wacuum's.** Moving it alone gives two copies of `json`, and an engine answer stops
  being the `JsonValue` this code imports.
- **Every page goes through `documentOf`/`htmlOf`.** Nothing writes HTML by string concatenation; that is what
  keeps every value from the chain (token names, input data, anything a stranger can put in a transaction)
  escaped. A new attribute that `web`'s tags do not list uses a quoted tag: `<"input" aria-label="…"/>`.
- **Everything is wac, the tooling too.** A tool is a wac program under `tools/` run by a task; a task's
  command line runs in `wac sh`. The browser runs no script: a feature that would need one (a wallet button)
  is left out, or done with a form the server answers.
- Comments explain *why*, in full sentences, as wac's and wacuum's do.

## Things that have bitten

- `wac update` gets a 401 from git.voltrevo.com; `wac task deps` (tools/deps.wac) fills the cache with
  `git`. It imports only `std`, since what it fetches is what any other import needs first.
- A project cannot import a file inside another project, even a git submodule: wac says to import its
  directory, which means its `exports`. That is why wacuum names `src/lib.wac` as its own.
- **wac's JavaScript hosts allow 128 host calls in flight; the 129th waits for ever and the program stops.**
  Every connection reading, every sleep, every peer holds one. `src/server.wac` caps connections and reaps slow
  ones for that reason; anything new that waits on the host (a timer per request, more peers) spends from the
  same 128. A test that holds a few hundred idle connections finds it in seconds.
- **Never `pkill -f` a pattern that is in your own command line**: it kills the shell running it. Find the PID.
- `i32` to `u64` has no single cast; go through `i64` and `as@`.
- `web`'s tag functions take a fixed list of attributes (no `aria-*`, no `data-*`): use a quoted tag for others.
- The CSP's `frame-ancestors` is ignored in a `<meta>`; it is sent as a header on HTML responses instead.
- The faucet's limits are per IP. Behind Caddy, every connection is from loopback, so a misconfigured proxy
  that does not set `X-Forwarded-For` would put every visitor under one limit: the symptom is the faucet
  refusing everybody after the first drip of the day.
