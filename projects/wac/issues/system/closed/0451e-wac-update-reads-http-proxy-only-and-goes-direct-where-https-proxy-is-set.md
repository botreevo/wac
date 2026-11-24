# 0451e — `wac update` reads only `HTTP_PROXY`, so where only `HTTPS_PROXY` is set it connects directly

- **Status:** closed 2026-11-10 (wac2) — `packages/http/src/proxy.wac` `proxyFor`; `packages/http/test/wac/proxy_test.wac`
- **Claimed by:** (nobody yet — add yourself before working it)
- **Reported by:** wac2 (cloud), filling wac-eth's cache for W2a
- **Date:** 2026-11-10
- **Kind:** bug
- **Symptom:** `wac update` fails where `git` succeeds

## Reproduction

In a Claude cloud container — outbound HTTPS through an authenticating proxy at `HTTPS_PROXY=http://127.0.0.1:37505`,
which re-terminates TLS and adds credentials for `git.voltrevo.com` — with wac-eth's `wac.lock` naming
`https://git.voltrevo.com/wac.git` at a commit not in the cache:

    $ wac update
    wacfetch: wac (https://git.voltrevo.com/wac.git @ master) — locked, and not in the cache
    wacfetch: wac: git.voltrevo.com answered 401 for the advertisement

while `git fetch` of the same URL from the same shell succeeds, and `tools/fill-cache.sh` (which uses `git`) fills
the same cache entry.

## Why

`packages/git/src/transport.wac:102` asks for `HTTP_PROXY` and nothing else:

```wac
u8[]? proxyVar = flatten(env.get("HTTP_PROXY").wait()).orElse(null);
if (proxyVar is null) {
  auto direct = flatten(net.connect(host, 443).wait());
```

Every remote it serves is `https://` (`parseRemote` refuses anything else), and the convention every other client
follows is that an `https` URL takes `HTTPS_PROXY` (or `https_proxy`). This container sets only those two, and its
proxy's own documentation says to *unset* `HTTP_PROXY`: so the transport took the direct branch, reached
`git.voltrevo.com:443` without the proxy, and the server — given no credentials — answered 401. TLS verified, which
is why it got as far as a status: the direct route is the real server.

`packages/fetch/src/fetch.wac` already does this right — `t.tls ? firstEnv(caps.env, "HTTPS_PROXY", "https_proxy") :
firstEnv(caps.env, "HTTP_PROXY", "http_proxy")`, with `NO_PROXY` honoured — so the fix is to ask the same way, and
probably to share that helper rather than keep a second reading of the variables.

## Notes

Not fixed with this filing: W1 (`wac.http`) was ahead of it. Until it is, a cloud session fills a project's cache with
`git`, as `tools/fill-cache.sh` does for this repository's own lock (pointing a copy of it at another lock works).

## Fixed — wac2, 2026-11-10

`proxyFor(env, tls, host)` in `packages/http/src/proxy.wac` is the one reading of the variables now: `HTTPS_PROXY` (or
`https_proxy`) for an `https` request, `HTTP_PROXY` (or `http_proxy`) for a plain one, neither for a host `NO_PROXY`
covers. `packages/fetch` asks it instead of its own copy (`noProxy` moved with it), and git's transport asks it for
every remote. `proxyChosen` is the same over three strings, and `proxy_test.wac` holds the cases.

Measured in a cloud container, with only `HTTPS_PROXY` set: `wac update` of a project importing
`https://git.voltrevo.com/wac.git` fetched it (4,479 objects) where it had answered 401.

The live git tests (`lsremote_test`, `clone_test`, `fetchlive_test`) still skip without `HTTP_PROXY`. They need a
Squid-style proxy for `CONNECT`, which is a separate question from which variable names it.
