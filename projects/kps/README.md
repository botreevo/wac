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
| the WebRTC mapping (framing, HELLO, credit) | next |
| listener, dialers | not started |

## Running it

`wac` built from the commit `wac.lock` pins, then:

    wac task deps     # the reference implementations under interop/js, once
    wac task test

During development the transport work is in a local wac checkout: `sh tools/dev-link.sh ~/src/wac` makes the
locked commit resolve to it.
