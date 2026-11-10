# A runner for the deterministic WebAssembly machine

`cmd/derive.wac` runs recipes for the machine `wasm-gc/wac-host/2`, defined in `src/machine.wac`. `tools/machine.sh`
runs a corpus of programs (`corpus/`) through it on V8 (the Node host's `wac`) and on wasmtime (the native host's),
and checks what the machine promises. This page records what that showed. Version 0 broke two of those promises.
Version 1 kept one of them (finding 2, NaNs) by rewriting the module. Version 2 keeps the other (finding 1, clock and
randomness): the program runs sealed, which wac now provides.

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

## What the corpus showed (51 checks, version 0)

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

## Version 1: canonical NaNs (2026-11-10)

Finding 2 is settled the way it recommends. Before running a program, the runner rewrites it (`src/canon.wac`):
after every float operation that can produce a NaN (arithmetic, `min`/`max`, `sqrt`, the four roundings,
`promote`, `demote`), it inserts a call to one of two appended functions, which replace a NaN with the canonical
positive one. This is WebAssembly 3.0's deterministic profile: `neg`, `abs`, `copysign` and the reinterprets still
move bits exactly, so a payload written with `fromBits` survives until an operation produces a new NaN.

- `floats.wac` now gives one CID on V8 and wasmtime. `0/0` is `7ff8…` on both (x86 had given `fff8…`), and so is
  `max(1, payload)`. `-(0/0)` is `fff8…`, because `neg` is a bit operation.
- The decoder reads every instruction a wac-built module uses and refuses anything else (SIMD and threads included),
  so a module it cannot read is never run without the profile. `tools/wasmscan`, built on wasmparser (the decoder
  wasmtime uses), is its oracle: across 4,418 functions in six modules, both find the same operators at the same
  offsets, and every rewritten module validates. `tools/machine.sh` repeats that check when cargo is available.
- The cost was a call after each float operation, which on float-heavy code was most of the running time (below).

### Inline, and only where a NaN could be seen (2026-11-10)

The rewrite no longer calls anything. After an operation whose NaN could be seen, it inserts
`local.tee $t; const NaN; local.get $t; local.get $t; eq; select`, through one f64 and one f32 scratch local appended to
the function. It also leaves the check out wherever the payload cannot be seen. That is a result consumed by another
NaN-producing operation (itself checked), by a comparison, by a conversion to an integer or by `drop`, or one kept in a
local that is only ever read that way. A small stack simulation over straight-line code decides this, and it counts
anything it does not model as seeing the value.

`corpus/nbody.wac`, the five-body simulation and a 120×120 matrix product, 10,000,000 steps, median of five runs on
this container (4 cores; Node 22.23 for V8, the native wasmtime host):

| nbody, 10M steps | unrewritten | version 1: a call after each op | inline, where seen |
| --- | --- | --- | --- |
| V8 | 1026 ms | 1775 ms (+73%) | 1192 ms (+16%) |
| wasmtime | 2682 ms | 9216 ms (+244%) | 3095 ms (+15%) |
| module size | 31,493 B | 31,810 B | 32,070 B |

wasmtime does not inline the call, which is why version 1 cost so much more there. Inlining the check after
*every* operation, without leaving any out, gave 1857 ms on V8 (+81%), no better than the call, because V8 had already
inlined it: what costs is the check, so the gain is in not making it. All three give the same output bits.

`corpus/nanpaths.wac` sends a produced NaN out every way it can leave: through a local, a chain, a local only read by
arithmetic, an array, a struct, a return, a select, a loop-carried local, `neg`, `copysign`, an f32, and a comparison.
The program checks each one itself. Unrewritten on V8 (x86) it fails 11 of 12, since `0/0` there is `fff8…`. Rewritten
it passes on both engines, and so does `floats.wac`, whose output is the same bit for bit as under version 1.
`tools/machine.sh`: 75 of 75 with wasmtime, and wasmscan finds the same operators at the same offsets in all seven
modules, every one valid after the rewrite. `test/canon_test.wac` covers the cases one at a time.

## Version 2: sealed, no clock and no random bytes (2026-11-10)

Finding 1 is settled the way it recommends, in wac (`4f77740a9`, `Launch.sealed()`): a child started sealed gets no
clock and no random bytes, and neither does anything it spawns, on every host. Each request answers `Unsupported`.
`cmd/derive.wac` spawns every program sealed, which is the whole of what changes between `/1` and `/2`. The rest of
the machine (the world, canonical NaNs, the floor below) is as it was.

`corpus/probe.wac`, which asked for everything the machine does not give, used to be the one program whose output
the machine could not promise. Now its log is the same on both engines:

    clock: refused this program was started sealed: it has no clock and no random bytes
    monotonic: refused this program was started sealed: it has no clock and no random bytes
    random: refused this program was started sealed: it has no clock and no random bytes
    read /etc/hostname: refused /etc/hostname: No such file or directory
    env HOME: refused Not granted to this application
    cwd: /

`tools/machine.sh`: 86 of 86 with wasmtime. Every program, probe included, gives one CID on V8 and wasmtime and
the same one twice; each refusal above is checked; the floor holds; wasmscan agrees on all seven modules.

## Minimum resources (machine /2, unchanged from /1)

A run that exceeds what its runner allows aborts and yields no claim, which is safe but means two runners can disagree
about whether there is an answer at all. So the machine names a floor, and every conforming runner provides at least
this much. Programs that stay within it get an answer from every runner. Frame size depends on the code, so the floor
is defined by two reference programs in `corpus/`, not in bytes:

| resource | every runner of `/2` must complete | measured on this machine (V8 / wasmtime) |
| --- | --- | --- |
| stack | `depth.wac 10000`: 10,000 nested calls of a two-argument `i64` function | ~50,000–60,000 / ~10,000–12,000 |
| heap | `heap.wac 1024`: 1 GiB live at once, in 1 MiB `u8[]` arrays | 1–2 GiB / at least 4 GiB |
| time | none: a recipe states none, and a runner's time limit is its own | |

The floor is the lower of the two engines in each row: wasmtime's default stack (about 10,000 of these frames) and
V8's heap (between 1 and 2 GiB). `tools/machine.sh` checks it on both engines, and checks that a million frames
aborts. A runner may provide more; a program that relies on more may get an answer from some runners and none from
others, never a wrong one. Raising the floor (wasmtime's `max_wasm_stack`, V8's `--max-old-space-size`) would be a
new machine version, because what a recipe can count on changes.

The wac compiler building itself (below) stays well inside the floor on both engines.

## Builds as derivations (2026-11-10)

The machine's first real program is wac's compiler: the `wac` command at the commit wac-eth pins, built to a plain
module. It needs nothing the machine withholds. It reads its sources from `/in`, writes the program to `/out`, and its
standard library is built in. `tools/selfbuild.sh` (`wac task reckon:selfbuild`) checks 10 things:

- **A build is a derivation.** The recipe is the compiler, the arguments `build in/in/hello.wac -o /out/hello`, and the
  source; the output tree holds `out/hello.wasm`. V8 and wasmtime derive the same CID, and the app is byte-identical
  to what the same compiler produces run natively. Run natively on another path, the bytes differ only in the
  manifest, which records the entry path as given and the output's name.
- **Its product runs as the next derivation.** The app, taken out of the build's output, is the program of a second
  recipe, and both engines agree on its run.
- **Admission follows the chain.** The run's result is admitted only because its program is the file at
  `out/hello.wasm` in a build output (the new `within` rule). That build is admitted because two runners on two
  engines witnessed it, its compiler is a trust root, and its source is endorsed. Before the reviewer endorses the
  source, it is refused.
- **The compiler reproduces itself.** With `SELF=1`, the compiler (A, built natively) compiles its own 4,050-file
  source inside the machine, in 1 m 46 s against 1 m 11 s natively. The result (B) is byte-identical to A run
  natively on the same entry path, and wasmtime derives the same CID. B then compiles the same source again inside
  the machine, and the result is B, byte for byte: a fixed point, witnessed on two engines.

Still open: the compiler is the trust root here. Making it derived (B, from endorsed source by A) is one more rule in
the policy, `compiler: [{ derived: { … program: "compiler" … } }]` with A as the root, and it is how a toolchain's
history would be told. Programs that import packages beyond std need those packages in the input tree, laid out where
the compiler's lock resolves them; that is the next step toward building wac-eth itself this way.

### With dependencies (2026-11-10)

`tools/builddeps.sh` builds four of wac-eth's own commands, `obj`, `claim`, `derive` and `lc`, which import wac's
library and wac-eth's packages, the same way, from one input tree (16 checks; the run is kept in
`docs/builds-run.txt`). The input tree is
wac-eth's source plus every dependency `wac.lock` pins, laid out as wac's package cache (`home/cache/git/<repo>/<commit>/`).
Before anything is built, every dependency in the input is hashed again, less the cache's marker, and must be the
CID its `wac.lock` entry pins (`deps check`, docs/lock.md). For each command, V8 and wasmtime derive the same output,
**each runner signs it**, and the program is byte for byte the module the same compiler makes natively, although the
cache sits at a different absolute path in the two. Each derived program runs.

**Since wac fade22039 the build is wholly inside the machine.** The compiler is told where its cache is by an
argument, `--wac-home /in/in/home`, not by `$WAC_HOME`, so it needs no environment, and its entry is relative
(`in/in/in/…`), which wac resolves from `/` since 0450d. Before that, the entry was given absolute, which left the
manifest's record of it different from a native build's, and the runner handed the program its own environment
(`derive --env-from-runner`, now removed), so no such run could be signed.

## Running it

```sh
WASMTIME_WAC=/path/to/native/wac sh packages/reckon/tools/machine.sh [WORKDIR]
```

Without `WASMTIME_WAC`, only the V8 half runs.
