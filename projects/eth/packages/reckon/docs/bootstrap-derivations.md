# Bootstrap derivations: rooting trust at reviewed sources (decision D)

**Status, 2026-11-10: milestone 1 done (`tools/ladder.sh`, task `reckon:ladder`). Milestones 2–5 are a plan, waiting on
the choice below.**

Today every compiler in reckon's chains is derived from one *seed*: wac's compiler at the pinned commit, built natively
and named in the policy's `roots`. selfbuild.sh and the capstone show the seed is consistent with its source. A
compiler derived from the seed rebuilds itself byte for byte, on two engines. But consistency is not independence. A
seed that recognised wac's own source and reproduced itself would pass every one of those checks
(docs/decisions/D-seed.md).

D replaces that binary root with things a person can read. wac already has them: `wac/bootstrap`, a ladder of five
hand-written rungs from a wasm assembly text up to wacc. This plan runs that ladder as derivations, so that the
compiler the capstone uses has a chain of signed claims ending at reviewed text.

## The ladder, as it is

Read from wac `4f77740a9` (bootstrap/README.md, bootstrap.sh, bootstrap/js/ladder.js, bootstrap/rust-ladder):

| step | what runs | on what |
| --- | --- | --- |
| assemble | the wac-L0 assembler turns L0 text into a wasm module | outside wasm: TypeScript/JS (`js/assemble.js`, 1,065 lines) or Rust (`rust/src/lib.rs`, 1,217), required to agree |
| L1 | `boot/l1.l0`, an interpreter written by hand in L0, runs `boot/l2.l1` to make the L2 compiler | a raw wasm module, driven through a *seam*: the host writes source at an address the module names and reads text back |
| L2–L5 | each rung's compiler (`l3.l2`, `l4.l3`, `l5.l4`) compiles the next; every rung emits L0 text, which the assembler turns into wasm | raw modules, seam ABI |
| flatten | wac-L5 ignores `import`, so the host concatenates wacc's module graph, renaming colliding private names | outside wasm: `js/flatten.js` (336) or `rust-ladder/src/flatten.rs` (527) |
| wacc | the L5 compiler compiles flattened `packages/wacc/src` into wacc; the host then drives that wacc (`js/wacc.js`, `rust-ladder/src/wacc.rs`) to compile `packages/wac/src/wac.wac` | a raw module plus host glue that answers its file reads |
| fixed point | that `wac` command rebuilds itself until two rounds agree (2 rounds, 2,599,771 bytes at 4f77740a9) | the wac host |

Two hosts run the whole ladder: Deno or Node through `bootstrap/hosts/*.js`, and `rust-ladder` (V8 embedded in Rust).
`hosts_agree.test.ts` checks that they produce the same L0 text. **Both hosts use V8.** There is no wasmtime ladder.

What a person must read to trust it, as wac measured it: the L0 assembler (one of the two), `boot/l1.l0`, and the
flattener, about 3,600 lines. Everything above L1 is checked by running it. The host glue (ladder and wacc drivers,
about 400 lines per host) is not in that count, and in reckon it would be trusted too, so it is counted here.

## The obstacle: the rungs are not wac programs

The machine `wasm-gc/wac-host/2` runs a **wac program**: a module that speaks the wac host ABI (`Sys`, the world,
the process interface). A rung is a raw module: it exports `seam_src`/`seam_out`, and expects its host to write
bytes into its memory and call it. Nothing in the machine can instantiate an arbitrary module and reach into its
memory. A wac program can `spawn` another wac program, but not this.

So there are two ways to carry the ladder, and the choice is the main question this plan puts to Wac and Andrew.

- **(A) More machines, each a written rule with two independent runners.** A machine is any externally defined rule
  (docs/runner.md). The ladder has three:
  - `wac-l0/1`: "assemble L0 text as bootstrap/spec/l0.md says". Its runners are the TS and Rust assemblers, which
    are already required to agree.
  - `wasm-seam/1`: "instantiate this module, write the source at `seam_src`, call it, read the text at
    `seam_out`", sealed, with canonical NaNs.
  - `wac-flatten/1`, for the flattener. Its runners are the JS and Rust flatteners.

  Recipes chain: assemble(l1.l0) → l1.wasm; seam(l1.wasm, l2.l1) → L0 text; assemble(that) → the L2 compiler, and
  so on up the ladder.
  - **Pro:** no wac change, and the L0 trust stays exactly where wac's README puts it: two readings of one written
    format agreeing.
  - **Con:** `wasm-seam/1` needs a second engine for diversity. Both ladder hosts are V8, so it needs a wasmtime
    seam runner (small: Rust, wasmtime, about 150 lines), plus reckon-side runner wrappers that sign.
  - **Con:** the wacc driving step needs the same treatment as its own machine, or (B).
- **(B) One machine, with a std capability.** If wac's std let a sealed program instantiate a raw module and read and
  write its memory (say `sys.wasm().instantiate(bytes)` → exports and memory views, no imports beyond what the caller
  passes), the seam driver, the wacc driver and even the assembler could be wac programs running inside
  `wasm-gc/wac-host/2`, on V8 and wasmtime like everything else.
  - **Pro:** one machine and engine diversity for free.
  - **Con:** a wac change.
  - **Con:** it moves the L0 root into a wac program, which itself needs compiling. The assembler would have to stay
    outside, as in (A), or be written in L0 and assembled by itself (a new fixed point).

**Recommendation: (A) first, (B) only if Wac wants the capability anyway.** (A) adds no compiler, and its roots are
the ones wac already argues for. Every step is a function of bytes to bytes, so each is easy to state as a machine.

## Milestones

1. **The ladder's compiler meets the seed's (no new machines yet).**
   - Build the `wac` command with the ladder from the rung sources (the rust-ladder host and the JS host, each at the
     pinned wac commit).
   - Run that command as the compiler in selfbuild's self-build chain, inside `wasm-gc/wac-host/2` on V8 and wasmtime.
   - Check that it reaches the **same fixed point** the seed reaches: the self-built compiler's bytes equal selfbuild's
     C, comparing with tools/wasmdiff.py, which ignores the manifest's entry path. That path is a likely cause of the
     5-byte difference between bootstrap.sh's 2,599,771 and selfbuild's 2,599,776.
   - In the policy, this is still one unsigned step: "the ladder's output", named as a root next to the rung sources
     it came from.

   What it shows: the seed and the ladder are two unrelated origins of one compiler. That is diverse double-compiling,
   with the seed as one leg and the reviewed ladder as the other. It is useful whatever happens to (A) or (B).

   **Done, 2026-11-10, at wac `4f77740a9`.**
   - The rust-ladder built the `wac` command from the five rung sources in about 4.5 minutes: 2,602,438 bytes. That is
     not the seed's 2,599,771, as expected, since a different wacc compiled it.
   - Inside the machine, that command compiled wac's source. On V8 and on wasmtime it derived **the same output tree,
     one CID** (`bafybeidhz3tbgnq…`), with the same compiler at `out/wac.wasm`, 2,599,776 bytes.
   - The seed's compile of the same source gives that same CID, so the claim index lists two recipes (four signed
     derivations) as its origins.
   - The 5-byte gap to bootstrap.sh's fixed point is the manifest's entry path (`in/in/packages/…` inside the
     machine), as suspected. No wac change is needed.

   So the ladder already reaches the same compiler as the seed. What milestones 2–5 add is that each step is signed and
   checked, and that the seed can leave `roots`.
2. **L0 as a machine.** `wac-l0/1`, its definition (pointing at bootstrap/spec/l0.md at a pinned commit), and two
   runners that sign: the TS and Rust assemblers wrapped by a reckon command. A recipe is `{program: none, in: x.l0}`
   (the machine is the assembler, so there is no program slot). Checked: both runners give one CID for every rung's L0
   in the ladder.
3. **The rungs as derivations.** `wasm-seam/1` and its runners: the rust-ladder's seam step on V8, and a new wasmtime
   one. Each rung up to L5 becomes a signed derivation. Checked: the L0 text at each rung agrees with what
   `hosts_agree` records.
4. **Flatten and wacc.**
   - `wac-flatten/1`, with the JS and Rust flatteners as runners.
   - The wacc driving step: it compiles `packages/wac/src/wac.wac` with the ladder's wacc. It becomes a machine
     (`wacc-drive/1`) or, under (B), a wac program in the main machine.
   - Then the fixed-point rounds in `wasm-gc/wac-host/2` as today.
5. **The policy and the capstone, rooted at sources.**
   - `roots` lose the seed binary. They gain the rung sources (`boot/*`), the L0 spec and both assemblers' sources,
     both flatteners, and the host glue, each as an endorsed object (endorsed by a reviewer key, as the app's source
     is), or as roots directly.
   - The machines list gains the new machine names.
   - The capstone runs full (not QUICK) with that policy: the app is admitted only through a chain that ends at
     reviewed text, and refused when any rung's derivation lacks its second runner.
   - The "still trusted" list loses the seed. It keeps the engines, the two assemblers' agreement, and the host glue.

## What needs wac changes

- **None for milestones 1–4 under (A).** Requests to the wac agent, possibly:
  - a `--source-dir`/`-o` path that makes the ladder hosts' outputs independent of the working directory, if
    milestone 1 finds path-dependent bytes;
  - and if the 5-byte difference is not the manifest path, an explanation of it.
- **(B) needs one:** a std capability to instantiate a raw module and access its memory and exports, sealed and
  deterministic.
- **`--wac-home`** (in progress) removes `--env-from-runner` from the build steps. That flag is independent of D, but
  milestone 5's capstone should not depend on an unsigned step.

## Cost and risk

- **Time.** At 4f77740a9, the nodejs bootstrap (ladder plus two fixed-point rounds) took a few minutes, and an
  in-machine self-build takes about 4 minutes per engine. Milestone 1 is about half an hour of machine time. Milestones
  2–4 add per-rung runs, each small except L5 compiling wacc.
- **The host glue is real trusted code.** About 400 lines per host, outside both the rungs and the assembler. Under (A)
  each piece becomes a machine definition with two implementations, which is the best this design can do short of (B).
- **Rung determinism on wasmtime is untested.** The ladder has only ever run on V8. NaNs are unlikely to matter in
  compilers, but the seam runner should use the same canonicalising rewrite as the main machine, to be sure.
