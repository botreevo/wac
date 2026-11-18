# 0009d — The crash test with `--flush-every 64` failed once in 19 runs: the restarted node ended four blocks short, its state not the never-killed node's

- **Status:** open
- **Reported by:** agent-d
- **Date:** 2026-11-18
- **Kind:** bug
- **Symptom:** once, after kills and restarts, the store node's head was block 196 (not 200) and 58 slots and balances
  differed from the node that was never killed

## Reproduction

    wac run --allow-read --allow-write --allow-net --allow-run tools/e2e/crash.wac -- 200 40 64

Expected: `ok   the same head and state root as the node never killed: 200 0x6c92f897…` and 0 slots differing.
Actual, once (the merge gate of `amsterdam-r` at c690dd9, 2026-11-18 ~07:00 UTC):
`FAIL the same head and state root as the node never killed: 196 0x39d23f35…` and `FAIL slots and balances across the
chain the same: 58 differ`.

It has not happened again: the same commit passed twice right after, master f80e7fc passed 8 runs in a row, and
d625bb1 (before Amsterdam) 6. The `--flush-every 1` run of the same gate passed. The gate log keeps only the summary
lines, so the failing run's restarts and kills are not known.

## Notes

The failing state differs and the head is short, so it is not the comparison running early: some restart came back
on a store whose head or state was behind what it had acknowledged, and the payloads given again from the head it
reported did not bring it level. With a flush every 64 blocks most kills fall between flushes, so the suspects are the
replay of the block log since the last flush (`adoptStored`, the lost-tail recovery) and a reorg's undo across a
flush. To catch it: run the test in a loop with its directory and every restart's log kept (crash.wac removes them
when it ends), and stop at the first failure.
