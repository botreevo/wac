# 0009d — The crash test with `--flush-every 64` failed once in 19 runs: the restarted node ended four blocks short, its state not the never-killed node's

- **Status:** closed
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

## Fixed (2026-11-18)

Caught on the 28th of 35 runs with everything kept (the crash test now keeps a failing run's directory): the
identical wrong state root, 0x39d23f35…, as in the gate. The block log ended `196' 197' 196 197 198 199 200` — a
side chain of two empty blocks, then the main chain — and the store's last flush had landed on the side block 196'.
The restart adopted every logged block at or below the store's height as already in its state, by number: the main
block 196 too, though the store had never held it and no undo record existed for it. Replaying 197' moved the store
onto the side chain; the main 197 needed the main 196's state, which nothing could reach, so it and its children were
passed over as a dead fork; and the last fork choice the log could follow named the main 196. The node came back
with that block as its head and the store's state (197') answering under its name.

Now only the store's own block and its ancestors among the log's blocks are adopted (`Engine.storeChain`); any other
block of the log at or below the store's height is run, the store moved back to its parent by the undo records.
On a copy of the failing run's store and log the old code comes back at head 196 with the wrong root, and the fixed
one at head 200 with the never-killed node's root. `test/resume_test.wac`'s
`test_a_store_flushed_on_a_side_block_with_the_main_block_only_in_the_log` builds the same shape in a few blocks
(a flush every third step, landing on a side block 3'): SYNCING before the fix, VALID after.
