# fetch

One HTTP request to a URL — `http://` or `https://` — and the whole response back.

```wac
import { fetch.fetch, fetch.Caps } from "wac";

Caps caps = Caps(sys.clock(), sys.random(), sys.env(), sys.net(), sys.files());
match (fetch(caps, "POST", "https://app.example/devices", ["Content-Type: application/json"], body)) {
  Ok(r): { /* r.status, r.headers.first("content-type"), r.body */ }
  Err(why): { /* could not connect, TLS refused, or the response did not parse */ }
}
```

It joins pieces that were already here: `http`'s response parser and CONNECT tunnel, and `tls`'s client and
trust store. `packages/git/src/transport.wac` had joined them once for git's two endpoints; this is the
same loop for any method, header set and URL.

- **Trust**: `SSL_CERT_FILE` when set, otherwise `/etc/ssl/certs/ca-certificates.crt`. An empty store
  refuses `https://` rather than skipping verification.
- **Proxy**: `HTTPS_PROXY` / `HTTP_PROXY` (either case), unless `NO_PROXY` names the host or a domain it
  is under. TLS goes through a CONNECT tunnel; plain HTTP is sent to the proxy in absolute form.
- **Framing**: `Connection: close`, the body read to the socket's end and parsed once with `eof` set, so
  a connection that failed half way is an error rather than a short body. No keep-alive, no redirects.

`Host`, `Content-Length`, `Connection` and `Transfer-Encoding` are the client's to write; a caller passing
one is refused.

    wac test --allow-read packages/fetch/test/wac/fetch_test.wac
