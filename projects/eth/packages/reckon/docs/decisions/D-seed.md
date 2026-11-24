# D: does the capstone already satisfy D?

**No, not yet.** The capstone derives the compiler that builds the app, on two runners and from reviewed source, and
shows it is a fixed point: the derived compiler builds the same compiler and the same app CID as the seed. That is
strong evidence the seed is honest, but it does not remove the trust. The policy's `roots` still names the seed, a
wac binary built natively at the pinned commit by a toolchain nothing here witnesses. A seed that recognised wac's
own source and reproduced itself would pass every check the capstone makes. What is left is to make the root
something small and readable rather than a compiler binary. wac's bootstrap ladder (`wac/bootstrap`) already does this
outside reckon: a wac-L0 assembler written twice (TypeScript and Rust, required to agree), then hand-written rungs
`boot/l1.l0` to `l5.l4` (about 8,200 lines in all) up to a compiler that reaches wacc's own fixed point byte for byte.
To bring that into reckon:

1. Run each rung as a derivation recipe under `wasm-gc/wac-host/2`, so every step from L1 up is signed by two runners.
2. Decide what the L0 assembler is inside the machine. It runs outside the ladder today, as TypeScript or Rust.
   Either compile it to wasm and name that wasm plus its two-source differential as the root, or name the reviewed
   `.l0` sources and the L0 assembler's source as roots, with the assembler's wasm derived as well.
3. Change the policy so the roots are the reviewed rung sources and the assembler, not the seed binary. The compiler
   the capstone uses then has a derivation chain that ends at text a person can read.

The rest of the capstone stays as it is.
