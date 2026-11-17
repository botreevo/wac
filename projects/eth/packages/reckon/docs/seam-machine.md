# The seam machine, `wasm-seam/1`

Decision D, milestone 3 (docs/bootstrap-derivations.md, option A). wac's bootstrap ladder runs five rungs. Each is a
wasm module that the rung below made: L1 is an interpreter assembled from hand-written L0, and L3, L4 and L5 are
compilers. A host hands each rung text through a *seam*, an address in its memory, and reads its answer back. Running
a rung is now a derivation. With `wac-l0/1` (the assembler) and `wac-flatten/1` (the flattener), every step from the
hand-written rungs to wacc is a claim that two runners sign.

`tools/rungs.sh` (task `reckon:rungs`) checks it, then milestone 4's steps (docs/drive-machine.md).

## The rule

**`wasm-seam/1` is the protocol wac's `bootstrap/js/ladder.js` runs a rung by, at wac `aaef775ca`:
`bafkreiftyqf7afochsqjz3jjgu3r4w4znxeuruwuaunmxqrhqbie2jud64` (`l1Text` and `through`).** The Rust ladder
(`bootstrap/rust-ladder/src/main.rs`) runs the same protocol.

    input tree    module            the rung, a wasm module
                  source            the text it is given
                  subject           optional, for the interpreter: an L2 program for `source` (the L2 compiler) to compile
                  suffix            optional, for a compiler: appended to `source` after a newline, as the Rust ladder
                                    appends a driver to wacc's flattened source (`format!("{waccc}\n{driver}")`)
    output tree   status            "ok"
                  out/answer.l0     the rung's answer

The module is instantiated with **no imports at all**: there is nothing for it to reach. A rung has one of two shapes,
told apart by its exports:

| shape | exports | run |
| --- | --- | --- |
| the interpreter (L1) | `memory`, `seam_at`, `run_at` | the text, NUL-terminated, at `seam_at()`; `run_at(at)` answers where the answer starts, NUL-terminated. With `subject`, the text is `source`, then `\n(compile (quote (`, the subject, `)))\n`, as `l2ToL0` makes it |
| a compiler (L3–L5) | `memory`, `seam_src`, `seam_out`, `compile` | the text, NUL-terminated, at `seam_src()`; `compile(src, out)` answers the length of what it wrote at `seam_out()` |

Memory is grown when the text does not fit. A module of neither shape, or a trap, is no answer and no claim. A rung
that cannot compile something writes `!!` lines into its answer and carries on. That is still its answer, and the
assembler refuses it at the next step.

## The runners

| runner | how |
| --- | --- |
| `seam (node, V8) at wac aaef775ca` | `tools/seam/node.mjs`, about 60 lines |
| `seam (wasmtime) at wac aaef775ca` | `tools/seam/wasmtime`, a Rust crate of about 100 lines on wasmtime 47 with GC, the version and proposals wac's native host uses, built `--offline` from the cargo cache that host leaves |

`cmd/boot.wac` runs them as it runs the other host-run machines: `boot recipe --module F --source F [--subject F]`,
then `boot run RECIPE --tool CMD`. The tool is called `CMD IN OUT`, where IN is a directory holding the input's files.

## What was run (2026-11-17, wac aaef775ca)

| step | machine | output, both runners agreeing |
| --- | --- | --- |
| `boot/l1.l0` → L1 | wac-l0/1 | the interpreter |
| L1 runs `boot/l2.l1` on `boot/l3.l2` | wasm-seam/1 | the L3 compiler as L0, 32,907 bytes |
| → L3 | wac-l0/1 | the L3 compiler |
| L3 on `boot/l4.l3` | wasm-seam/1 | the L4 compiler as L0, 71,614 bytes |
| → L4 | wac-l0/1 | |
| L4 on `boot/l5.l4` | wasm-seam/1 | the L5 compiler as L0, 242,220 bytes |
| → L5 | wac-l0/1 | |
| `packages/wacc/src` (39 modules) | wac-flatten/1 | one program, 3.7 MB |
| L5 on it | wasm-seam/1 | wacc as L0, 7,941,639 bytes, **byte for byte what wac's own ladder makes** |
| → wacc | wac-l0/1 | wacc |

- **Admission.** A policy admits wacc only through every step. Its roots are no binaries at all: the five
  hand-written rungs and wacc's source, endorsed by a reviewer. The decision walks 35 admitted objects:
  - 9 assembled modules;
  - 8 rung answers;
  - 4 rungs;
  - 5 reviewed L0 texts or answers;
  - 2 flattenings;
  - 2 reviewed sources.
- **Refusals.** It refuses while the rungs are unreviewed. When wasmtime's runner withdraws its run of the L4 rung,
  one runner is not enough and wacc is refused.

## What it does not do yet

- **wacc is not `wac`.** wacc compiling the `wac` command needs a host to hand it the files: that is
  `wacc-drive/1`, milestone 4 (docs/drive-machine.md), which `tools/rungs.sh` runs after these steps.
- **The seed is still in the capstone's roots.** Milestone 5 roots the capstone's policy here instead.
- **No NaN canonicalization.** A rung computes text and runs no floating point the answer depends on. It compiles
  float code; it does not execute it.
- **The runners are host programs**, as for `wac-l0/1` and `wac-flatten/1`. Two of them, on two engines, must agree.
