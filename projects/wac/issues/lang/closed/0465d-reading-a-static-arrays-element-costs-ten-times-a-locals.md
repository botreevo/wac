# 0465d — reading an element of a `static` array costs about ten times a local array's

- **Status:** closed 2026-11-17 (cloud) — not reproduced at master (aaef775ca + the perf lane); no change
- **Reported by:** turbostack (via the agent-coordination session)
- **Date:** 2026-11-11
- **Kind:** performance
- **Symptom:** slow code

## Reproduction

A loop of a million element reads, once from a `static` array and once from a local copy of it:

```wac
static i32[] TABLE = [1, 2, 3, 4, 5, 6, 7, 8];
export i32 viaStatic() { i32 s = 0; for (i32 i = 0; i < 1000000; i++) { s = s + TABLE[i & 7]; } return s; }
export i32 viaLocal() { i32[] t = TABLE; i32 s = 0; for (i32 i = 0; i < 1000000; i++) { s = s + t[i & 7]; } return s; }
```

Reported: about 10 ns a read through the static against about 1 ns through the local.

## Notes

Not yet looked at. Likely suspects, to be checked against the emitted wasm rather than assumed: the static is read
through a global (or an initialiser guard) on every access rather than once; the array's reference is re-derived each
time where a local's is in a register; or a bounds or null check the local form lets the engine hoist. `wac build` of
the two functions and a look at the loop bodies would say which.

## Fix

**Not reproduced.** The reproduction at ten million reads, three rounds each, on 2026-11-17, master:

| host | static | local | static, imported from another file |
| --- | --- | --- | --- |
| V8 (native) | 5.5 ms (0.55 ns a read) | 5.5 ms | 5.5–5.7 ms |
| wasmtime | 15.1–15.8 ms | 15.1–15.4 ms | — |
| Node | 7.3–10.1 ms | 5.9–6.6 ms | — |

The first round on V8 was 15.5 ms against 19.5 ms, both cold (baseline code before the optimiser takes the loop), and
the static was the *faster* of the two. Nothing here costs ten times a local. What the report measured is not known;
reopen with the program, the host and the wac commit if it is seen again.
