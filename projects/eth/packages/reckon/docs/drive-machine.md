# The drive machine, `wacc-drive/1`

Decision D, milestone 4 (docs/bootstrap-derivations.md, option A). With `wasm-seam/1` (docs/seam-machine.md), the
bootstrap ladder's every step up to wacc is a derivation. One step is left before the `wac` command: wacc compiling
`packages/wac/src/wac.wac`. wacc does not read files. A host hands it the program's files a byte at a time, through the
driver that wac's ladder appends to wacc's source (`bootstrap/drivers/spec_cases.wac`), and reads the module back the
same way. Doing that is now a machine.

`tools/rungs.sh` (task `reckon:rungs`) checks it, with milestone 3's steps before it: 20 of 20, in about 15 minutes.

## The rule

**`wacc-drive/1` is the tail of wac's `ladder --with-wacc` at wac `aaef775ca`:**

| file | CID | what it gives |
| --- | --- | --- |
| `bootstrap/rust-ladder/src/main.rs` | `bafkreiczywyurplbmcwugoswpcykzgtsviqyklzmxkcrjhpxkmufpm5buq` | the steps: the file set, `emitFiles`, decline when 8 bytes or fewer, `seal` |
| `bootstrap/rust-ladder/src/wacc.rs` | `bafkreicykxci25bckfxaa5qclka7q6paucmumzl2tw2spdyej422hihecq` | driving wacc's `drv_*` exports, byte by byte |
| `bootstrap/js/wacc.js` | `bafkreidumh73aq5hyhguz5cxvmqcpmhqdil7yqn6gxk3lxzo4h2psixple` | the same, in JavaScript, and `grantsOf` |
| `bootstrap/rust-ladder/src/flatten.rs` | `bafkreibgzsis2ncnyf2nw55fwktvc7jmhcg5lv23afcrdyxkn6bedcj7pu` | the file set (`file_set`, `key_of`) |
| `bootstrap/js/flatten.js` | `bafkreifcoey5u3sfwx4e6kzta5sru3wcu33zsqyumuxhzmynkbpfqfb4em` | the same (`fileSet`) |
| `bootstrap/drivers/spec_cases.wac` | `bafkreie53rcszez6xskwneznjzf4rdrrpvo2mv5pbi6t4y3t6yaoqpqbgq` | the driver a drivable wacc carries (an input, not the machine) |

    input tree    wacc              a wacc that carries the driver: wac-L5's answer for wacc's flattened source with
                                    spec_cases.wac appended (wasm-seam/1's suffix), assembled (wac-l0/1)
                  tree/             the sources: a copy of wac's checkout, or as much of it as the program reaches
                  entry             the program's path within tree/, e.g. packages/wac/src/wac.wac
                  name              the module name the manifest records, e.g. wac.wasm (the ladder takes it from -o)
                  grants            what the module may ask its host for: read, write, net, env, run, separated by spaces
    output tree   status            "ok"
                  out/module.wasm   the module, sealed with its wac.manifest section

The file set is computed from inside `tree/`, so its keys are repository-relative, as the ladder computes them from
inside wac's checkout. wacc is instantiated with **no imports**. It is driven:

1. `drv_files` and the `drv_alloc`/`drv_setByte`/`drv_allocName`/`drv_setNameByte`/`drv_pushFile` calls hand it each
   file;
2. `drv_buildFiles` with the entry's key compiles them;
3. `drv_byteAt` reads the module back;
4. `drv_seal(grants)` with the entry and name gives the sealed module. The grant bits are read 1, write 2, net 4,
   env 8, run 16.

A module of 8 bytes or fewer is a decline: no claim is made, and the runner exits 1 with wacc's reason
(`drv_declineFiles`, `drv_declineByte`). A trap is no answer and no claim either.

## The runners

| runner | how |
| --- | --- |
| `wacc-drive (node, V8) at wac aaef775ca` | `tools/drive/node.mjs`, about 30 lines: wac's own `js/flatten.js` and `js/wacc.js`, imported from the pinned checkout |
| `wacc-drive (Rust, wasmtime) at wac aaef775ca` | `tools/drive/wasmtime`, a Rust crate of about 100 lines on wasmtime 47 with GC, as for the seam. It includes wac's `flatten.rs` as is (copied in at build time) and drives `drv_*` as `wacc.rs` does |

The two differ in engine (V8 against wasmtime) and in the file set's implementation (JavaScript against Rust).

`cmd/boot.wac` runs them as it runs the other host-run machines:
`boot recipe --wacc F --tree DIR --entry PATH --name N --grants "read …"`, then `boot run RECIPE --tool CMD`.

## What was run (2026-11-17, wac aaef775ca)

| step | machine | output, both runners agreeing |
| --- | --- | --- |
| L5 on wacc's flattened source, with `spec_cases.wac` appended | wasm-seam/1 | the drivable wacc as L0, 7,951,738 bytes, with no `!!` lines |
| → the drivable wacc | wac-l0/1 | |
| the drivable wacc on `packages/wac/src/wac.wac`, grants read write env net run | wacc-drive/1 | **the `wac` command, 2,713,106 bytes, byte for byte what `ladder --with-wacc packages/wac/src/wac.wac -o wac.wasm` makes** |

Each drive takes a few minutes: about 2½ on V8 and 5 on wasmtime. wacc is driven a byte at a time.

- **Admission.** The policy role `command` asks for both runners, and for a `wacc` slot that is a rung (assembled, back
  through every step of milestone 3). Every other slot (the tree, the entry, the name, the grants) must be reviewed.
  The `wac` command is refused while those are unreviewed. Once they are endorsed, it is admitted through 43 objects back to 12
  reviewed ones: the five hand-written rungs, wacc's source, the driver, wac's source and the drive's settings. There
  is no binary among its roots.

## What it does not do yet

- **The capstone uses it** (milestone 5). With LADDER, the capstone's compiler is built by this drive's output, and
  its policy has no roots (docs/capstone.md, "Rooted at sources").
- **The tree is endorsed whole.** A reviewer endorses the copy of wac's checkout the drive reads, not each file the
  program reaches.
- **The runners are host programs**, as for the other host-run machines. Two of them, on two engines, must agree.
