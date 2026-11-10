# A runner for the deterministic WebAssembly machine

`cmd/derive.wac` runs recipes for the machine `wasm-gc/wac-host/0`, defined in `src/machine.wac`. `tools/machine.sh`
runs a corpus of programs (`corpus/`) through it on V8 (the Node host's `wac`) and on wasmtime (the native host's),
and checks what the machine promises. This page records what that showed. The machine is version 0 because two of
those promises do not hold yet, and both are below.

## The machine

- **Input**: a tree with a file `program` (a module `wac build` wrote) and, optionally, `args` (one argument per
  line). The program sees the whole input tree at `/in`, read-only, and an empty `/out`. Nothing else exists.
- **Output**: a tree of `status` (`exit N` or `trap NAME`), `log` (its standard output) and `out/`.
- **No output** when the run hits a runner's limit (time, memory, stack) or stops in a way the machine does not name.
  The runner then makes no claim.

## What the runner does

- It reads the recipe and its input tree from the object store, every block re-hashed.
- It spawns the program from the checked bytes, never from a file, holding exactly one capability. That capability is
  a file system that `src/world.wac` builds in memory from the input tree, with a writable `/out`. No path in it reaches
  the runner's disk: it is not a view onto a directory, so there is nothing to escape into.
- When the program ends, it classifies the ending, builds the output tree from `status`, the captured output and
  what was written, and imports it under `unixfs-v1-2025`. The CID that import gives is the output.
- With `--key`, it signs a `Derivation(recipe, output, runner)` statement and stores it.

## What the corpus showed (51 checks)

| program | ending | V8 = wasmtime | twice on one engine |
| --- | --- | --- | --- |
| `files` (reads `/in`, writes `/out`, tries to escape) | `exit 0` | same CID | same |
| `fail` | `exit 7` | same | same |
| `oob`, `div`, `ovf`, `nul`, `unwrap` | `trap array-out-of-bounds`, `divide-by-zero`, `integer-overflow`, `null`, `unreachable` | same | same |
| `deep` (stack), `big` (memory), `loop` (time) | abort: no output | — | — |
| `floats` | `exit 0` | **differs** (below) | same |
| `probe` | `exit 0` | **differs** (below) | differs |

The world held: writing to `/in` is refused as read-only, `/in/../../etc/hostname` is refused, no environment
variable is readable, the working directory is `/`, and a streamed write lands whole when it is closed.

## Findings

1. **A child spawned with no authority can still read a clock and random bytes.** `Sys.clock()` and `Sys.random()`
   need no grant in wac, and `Authority` has no field for them, so no parent can withhold them. The probe's log
   differs on every run. Until this is fixed, the machine's determinism depends on programs choosing not to read the
   clock or random bytes. That is a convention, not a guarantee. **The fix belongs in wac**: give `Authority` (or
   `Launch`) a sealed mode in which the host answers clock and randomness requests with `Unsupported`. On the Node
   host that is a grant check beside the file grants. On the native host it is the same check in
   `native/src/main.rs`. I did not make the change, because it alters a deliberate wac design choice ("needs no
   grant").

2. **NaN bits differ between engines, as the WebAssembly spec allows.** Of 24 float results, V8 and wasmtime agreed on
   23. They disagreed on `max(1, NaN with a payload)`: V8 returned the canonical NaN `fff8000000000000`, and wasmtime
   propagated the payload `7ff8000000000001`. Both behaviours are permitted. On x86 both engines produce a *negative*
   canonical NaN for `0/0` (`fff8…`); on ARM it would be positive (`7ff8…`). So NaN bits depend on the engine and on
   the CPU, and any program can observe them through `f64.toBits`. Ordinary arithmetic agreed bit for bit, including
   subnormals, signed zeros, a 2,000-step series and rounding.
   **The machine has to choose.** The best option is to adopt WebAssembly 3.0's *deterministic profile*, in which every
   NaN an operation produces is the positive canonical NaN. wasmtime implements it with one setting
   (`cranelift_nan_canonicalization`). V8 has no such setting, so a V8 runner would need a module rewrite that
   canonicalizes after each float operation that can produce a NaN. A cheaper but weaker option is to define the
   output as undefined when a program's output depends on NaN bits. That cannot be checked, so I would not choose it.

3. **The hosts report traps differently, and neither does it reliably.** The Node host answers a trapped child with
   no status ("the child did not run to an end") and the trap in V8's words on its diagnostic output. The wasmtime host
   answers status **1**, the same as a program that returned 1, with `trapped: wasm trap: …` on the diagnostic output.
   So the runner reads the last line of the diagnostic output to tell a trap from an exit and to name it. That works
   on both engines. But a program could print those words itself and exit 1 to be read as a trap on wasmtime and
   not on V8. The two runners would then disagree, so no quorum would form. That is safe, but it is a gap. **The fix
   belongs in wac**: `Child.exit()` should answer how the child ended (an exit, a trap with its kind, or a host
   limit) as a value rather than as words.

4. **Memory and stack limits are the engines' own and are not configurable here.** Hitting either aborts the run,
   correctly, but a runner cannot yet promise a minimum. A program that needs 3 GiB may produce an output on one
   runner and abort on another. That is not a wrong claim, only a missing one. The machine should state a minimum
   that every conforming runner provides (for example, 1 GiB of heap and a fixed number of frames), and runners
   should be configured to it.

5. **The program speaks wac's host protocol, not a WebAssembly standard interface.** That is why the machine is named
   `wac-host`. A machine for other languages would define its imports (WASI preview 1, restricted to a read-only
   `/in` and a writable `/out`, is the obvious candidate), and the same world, output tree and endings would carry
   over unchanged.

## Running it

```sh
WASMTIME_WAC=/path/to/native/wac sh packages/reckon/tools/machine.sh [WORKDIR]
```

Without `WASMTIME_WAC`, only the V8 half runs.
