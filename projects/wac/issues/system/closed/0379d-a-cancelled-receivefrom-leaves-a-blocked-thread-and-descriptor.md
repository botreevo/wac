# 0379d — a cancelled `receiveFrom` leaves a blocked thread and a descriptor on the V8 host

- **Status:** closed 2026-11-08 (cloud) — `native/v8/src/main.rs`, `Cap::ReceiveFrom`: one reader per socket (`rx_waiting`)
- **Reported by:** wac-kps
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** resource leak

## Reproduction

An async loop doing `await sys.clock().within(sock.receive(), 10)` on a bound UDP socket with no traffic, on the V8
host: `ls /proc/<pid>/fd | wc -l` grows by about 100 a second — wac-kps measured 440 a second on an idle listener,
against a limit of 20,000, so a listener died after about a minute idle. The threads holding them also competed for
each packet that did arrive.

## Why

Each `receiveFrom` spawned a thread blocked in `recv_from` on a clone of the socket. Cancelling the ticket — which
`within` does on every timeout — cannot unblock a thread in `recv_from`, so the thread and its descriptor stayed
until some later datagram arrived.

## Fix

One reader per socket. A `receiveFrom` joins the socket's queue of waiting tickets (`rx_waiting`) and starts a reader
only when none is serving it; the reader hands each datagram to the oldest ticket still waiting (one cancelled since
it queued hands the answer back and the next is tried), parks it for the next caller when none is, and ends when
nobody waits. The end is decided under the lock a caller joins the queue under, so no ticket is stranded. An idle
socket now holds at most one blocked reader: 200 timed-out receives leave 6 descriptors where they left 205, and a
datagram sent after them is received.
