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
| the native WebRTC dialer | next |
| QUIC: the dialer, and the listener's QUIC path | not started |

## Running it

`wac` built from the commit `wac.lock` pins, then:

    wac task deps     # the reference implementations under interop/js, once
    wac task test

During development the transport work is in a local wac checkout, and the page capability in a local wac-web one:
`sh tools/dev-link.sh ~/src/wac ~/src/wac-web` makes the locked commits resolve to them.

A page that dials: `wac run --allow-read --allow-write --allow-run <wac-web>/tools/build.wac cmd/dialpage.wac <dir>
--grant webrtc`, then open `<dir>/index.html#<address>` — or `node interop/js/page-dial.mjs <dir> <address>` to run it
in Chromium and print what it reports.
