# wac-kps

[KPS — Key-Pinned Streams](https://github.com/ethereum/kps) in [wac](https://github.com/voltrevo/wac): an
authenticated, encrypted, multiplexed connection to a server named by the hash of its self-signed certificate —
an address is `ip:port:certhash`, with no domain and no certificate authority.

The goal is the whole of SPEC v0.2.1:

- **a listener** that accepts WebRTC and QUIC clients on one UDP port, under one identity;
- **a WebRTC dialer**, native and from a browser page;
- **a QUIC dialer**.

The transports are wac's own packages — `webrtc`, `quic`, `tls` — and the work they need lands there. This
repository is the KPS layer: addresses and pinning, the WebRTC stream framing and credit-based flow control
(SPEC §6.2, §6.5, §8), the QUIC mapping, and the listener's demultiplexer.

## Where it is

| | state |
| --- | --- |
| addresses, certhashes, the SDP fingerprint, the ICE password | **done**, agreeing with `@kpstreams/core` byte for byte (`test/address_test.wac`) |
| the identity: an anonymous P-256 certificate and its key, kept on disk | **done**; openssl reads the file and computes the certhash's digest (`test/identity_test.wac`) |
| the WebRTC mapping (framing, HELLO, credit) | **done**, one engine under every WebRTC end (`src/webrtc/conn.wac`, `test/engine_test.wac`) |
| the listener, WebRTC | **done**: Chromium running `@kpstreams/webrtc-client` passes as many scenarios against it as against `@kpstreams/server`, and Go's pion client echoes, crosses the window, and closes with a code (`test/listener_test.wac`) |
| the dialer from a page | **done**: a page built with `--grant webrtc` drives the browser's own RTCPeerConnection through wac-web's `wac.webrtc` and runs the same scenarios, 8 of 8, against `@kpstreams/server` and the wac listener (`src/webrtc/page.wac`, `test/page_test.wac`) |
| the native WebRTC dialer | **done**: wac's own ICE (controlling), DTLS client and SCTP initiator, upstream in wac's `webrtc` package; the same scenarios pass against `@kpstreams/server` (libdatachannel), the wac listener, and Go's `kps-server` (pion) as far as its example server serves them, and a certhash naming another key is not dialled (`src/webrtc/dial.wac`, `test/dial_test.wac`) |
| QUIC: the dialer, and the listener's QUIC path | **done**, on wac's new QUIC endpoint (`packages/quic/src/endpoint.wac`): the listener takes QUIC on the WebRTC port under the same certhash, and Go's quic-go client echoes, crosses the window, sends a datagram and closes with a code against it; the QUIC dialer passes every scenario against the wac listener, every one quic-go's and quiche's example servers serve, and follows quiche's Retry (`src/quic/`, `test/dial_test.wac`, `test/listener_test.wac`) |
| hostile traffic | a listener takes 6000 datagrams that are not KPS — random bytes, forged QUIC Initials and short headers, STUN-shaped junk, binding requests that do not know the certhash, DTLS-shaped noise — and still serves both transports, leaking nothing (`test/hostile_test.wac`); nothing is held for a WebRTC client that does not prove the certhash or a QUIC Initial that does not authenticate |

### How fast

Go's client echoing 1.6 MB through a listener on this machine (loopback, five runs each):

| | wac listener | `@kpstreams/server` |
| --- | --- | --- |
| WebRTC | 1.6 s | 0.39 s |
| QUIC | 0.36 s | fails (its QUIC echo stalls at this size) |

The WebRTC gap is mostly wac's software AES-GCM, which is constant-time GHASH and byte-wise AES; the handshake
costs the same (0.3 s, mostly ICE).

## Running it

`wac` built from the commit `wac.lock` pins, then:

    wac task deps     # the reference implementations under interop/js, once
    wac task test

During development the transport work is in a local wac checkout, and the page capability in a local wac-web one:
`sh tools/dev-link.sh ~/src/wac ~/src/wac-web` makes the locked commits resolve to them.

A page that dials: `wac run --allow-read --allow-write --allow-run <wac-web>/tools/build.wac cmd/dialpage.wac <dir>
--grant webrtc`, then open `<dir>/index.html#<address>` — or `node interop/js/page-dial.mjs <dir> <address>` to run it
in Chromium and print what it reports. Natively: `wac run --allow-net cmd/dial.wac [quic] <address>`.
