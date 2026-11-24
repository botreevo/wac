#!/usr/bin/env python3
# aiortc, as the browser: data channels of every kind against `example/answer.wac`, judged from this side.
#
#   channels_oracle.py <host> <port> <command...>
#
# aiortc never saw this code. It offers; the wac program, started here with the offer on its input, answers and
# echoes every message on the channel it arrived on. What is asked of it, each one a line `PASS <what>` or
# `FAIL <what>: <why>`, then `DONE <n>`:
#
#   - a **negotiated** channel (id 0, ordered, reliable) carries a message both ways — nothing opened it on the wire;
#   - a negotiated **unordered, maxRetransmits 0** channel (id 1) carries datagrams — aiortc refuses to use one at
#     all unless the peer's INIT said it speaks FORWARD-TSN;
#   - three **DCEP** channels open (the wac side acknowledges), and each echoes its own messages;
#   - a 50 KB message, many SCTP chunks, comes back whole;
#   - **closing** a DCEP channel resets its stream, the wac side resets back, and aiortc sees the channel closed —
#     while the others keep working.
#
# Every wait has a deadline, so a wac side that never answers is a FAIL with a reason rather than a hung test.

import asyncio
import subprocess
import sys

from aiortc import RTCPeerConnection, RTCSessionDescription

results = []


def check(ok, what, why=""):
    results.append(f"PASS {what}" if ok else f"FAIL {what}: {why}")


async def wait_for(cond, seconds):
    for _ in range(int(seconds * 50)):
        if cond():
            return True
        await asyncio.sleep(0.02)
    return cond()


async def main():
    host, port, cmd = sys.argv[1], sys.argv[2], sys.argv[3:]
    pc = RTCPeerConnection()
    ctl = pc.createDataChannel("ctl", negotiated=True, id=0)
    dg = pc.createDataChannel("dg", negotiated=True, id=1, ordered=False, maxRetransmits=0)
    dcep = [pc.createDataChannel(f"s{i}") for i in range(3)]
    got = {}

    def collect(ch):
        got[ch.label] = []
        ch.on("message", lambda m, ch=ch: got[ch.label].append(m))

    for ch in [ctl, dg] + dcep:
        collect(ch)
    closed = set()
    for ch in dcep:
        ch.on("close", lambda ch=ch: closed.add(ch.label))

    await pc.setLocalDescription(await pc.createOffer())
    proc = subprocess.Popen(cmd + [host, port], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    proc.stdin.write(pc.localDescription.sdp.encode())
    proc.stdin.close()
    lines = []
    answer = ""
    loop = asyncio.get_running_loop()
    while "a=sctp-port" not in answer:
        line = await loop.run_in_executor(None, proc.stdout.readline)
        if not line:
            break
        answer += line.decode()
    async def pump():
        while True:
            line = await loop.run_in_executor(None, proc.stdout.readline)
            if not line:
                return
            lines.append(line.decode().strip())
    pumping = asyncio.ensure_future(pump())
    try:
        await pc.setRemoteDescription(RTCSessionDescription(sdp=answer, type="answer"))
        ok = await wait_for(lambda: all(ch.readyState == "open" for ch in [ctl, dg] + dcep), 10)
        check(ok, "every channel opens", "states " + ",".join(ch.readyState for ch in [ctl, dg] + dcep))
        if not ok:
            return
        # Not asserted: which parity aiortc's ids have. RFC 8832 §6 gives the DTLS client the even ids; aiortc ties
        # parity to the ICE role instead and its client uses odd ones (3, 5, 7 here). Chromium follows the RFC.

        ctl.send(b"hello-ctl")
        check(await wait_for(lambda: got["ctl"] == [b"hello-ctl"], 5), "the negotiated channel echoes",
              repr(got["ctl"]))

        for i in range(20):
            dg.send(f"dg-{i}".encode())
        await wait_for(lambda: len(got["dg"]) >= 20, 5)
        check(sorted(got["dg"]) == sorted(f"dg-{i}".encode() for i in range(20)),
              "the unordered, unretransmitted channel carries datagrams both ways", f"{len(got['dg'])} back")

        for i, ch in enumerate(dcep):
            for k in range(5):
                ch.send(f"{ch.label}-{k}")
        for ch in dcep:
            want = [f"{ch.label}-{k}" for k in range(5)]
            check(await wait_for(lambda ch=ch, want=want: got[ch.label] == want, 5),
                  f"DCEP channel {ch.label} echoes in order", repr(got[ch.label]))

        big = bytes((i * 7) & 0xFF for i in range(50000))
        dcep[0].send(big)
        check(await wait_for(lambda: big in got[dcep[0].label], 10), "a 50 KB message comes back whole",
              f"{[len(m) for m in got[dcep[0].label]]}")

        victim = dcep[1]
        victim_id = victim.id
        victim.close()
        check(await wait_for(lambda: victim.label in closed, 10), "closing a channel resets it both ways",
              f"aiortc's state {victim.readyState}")
        check(await wait_for(lambda: f"closed {victim_id}" in lines, 5), "and the wac side reports it closed",
              repr(lines[-5:]))
        dcep[2].send("after")
        check(await wait_for(lambda: got[dcep[2].label][-1:] == ["after"], 5),
              "the other channels still work after one closes", repr(got[dcep[2].label][-2:]))
    finally:
        await pc.close()
        proc.kill()
        pumping.cancel()


asyncio.run(main())
for r in results:
    print(r)
print(f"DONE {len(results)}")
