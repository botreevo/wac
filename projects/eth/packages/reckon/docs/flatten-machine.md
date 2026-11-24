# The flattener machine, `wac-flatten/1`

Decision D, milestone 2b (docs/bootstrap-derivations.md). wac-L5, the last rung, ignores `import`: no wac-L4 program
can read a file. So wac's bootstrap turns a module graph into one program before the L5 compiler sees it. It
concatenates the modules in dependency order and renames the private names two modules share. That step is code
outside every rung, and a bug there gives a wrong program quietly. `wac-flatten/1` makes it a derivation with two
runners.

It is needed whichever way the rungs end up running ((A) or (B) in the plan). The flattener is host code in
JavaScript and Rust, not a wasm rung, and moving it inside a machine would mean writing it again in wac.

`tools/flatten.sh` (task `reckon:flatten`) checks it: 9 of 9.

## The rule

There is no prose spec for flattening, as there is for L0. The rule is the one wac's two flatteners share, and wac
requires them to agree byte for byte:

| | at wac fade22039 | size |
| --- | --- | --- |
| `bootstrap/js/flatten.js`, `flatten()` | `bafkreifcoey5u3sfwx4e6kzta5sru3wcu33zsqyumuxhzmynkbpfqfb4em` | 336 lines |
| `bootstrap/rust-ladder/src/flatten.rs`, `flatten()` | `bafkreibgzsis2ncnyf2nw55fwktvc7jmhcg5lv23afcrdyxkn6bedcj7pu` | 527 lines |

The rule, in short:

- **Gather.** Starting at the entry, gather depth-first and post-order, each file once, by its canonical path.
- **Resolve.** `./` and `../` specifiers resolve against the importing file's directory. `core` and `std` name no
  file and are skipped. Any other specifier is looked for up the directory chain, at most 12 levels.
- **Rename.** `import { x as y }` is undone in the importing module. A private top-level name that two modules
  declare is suffixed with its module's name, in the module that must give way.
- **Refuse.** The one refusal is an import of a file that is not there.

A change to either file is a new machine, `wac-flatten/2`.

    input tree    tree/…            the sources
                  entry             the entry's path within tree/, one line; no leading /, no `..`
    output tree   status            "ok" or "refused"
                  out/flat.wac      the program, when ok

As with `wac-l0/1`:

- there is no program in the input, because the machine is the flattener;
- a refusal's wording is diagnostics, not output;
- a runner whose tool crashes gives no output and no claim.

## The runners

`cmd/boot.wac` runs both host-run machines. It writes the tree out under a fresh work directory and runs the tool as
`TOOL ENTRY OUT`.

| runner | how |
| --- | --- |
| `flatten.js (node) at wac fade22039` | `tools/boot/flatten.mjs`: `flatten()` with the filesystem as `bootstrap/hosts/node.js` gives it (`read`, `realpath`) |
| `flatten.rs (ladder --dump-flat) at wac fade22039` | `tools/boot/flatten-rust.sh`: the ladder's own `--dump-flat`. The ladder panics on every error, so a missing file (the refusal) is told apart by its message |

The ladder binary used here was built from wac 4f77740a9. Its `rust-ladder/` and `js/` sources are byte-identical
at fade22039.

## What was run (2026-11-10, wac fade22039)

- **wacc.** `packages/wacc/src` is 38 modules with entry `api.wac`, the program the L5 compiler builds. Both runners
  give one output (`bafybeiawr2l2lpe…`), the same 3,694,270 bytes the ladder flattens from wac's own checkout. So
  writing the tree under a work directory does not change the program.
- **The imports fixture.** `bootstrap/tests/l5/imports.l5` reaches `lib/point.l5` and `lib/scale.l5` by bare
  specifiers, found up the directory chain. Both runners give one output, and it carries the library's declarations.
- **Refusals.** An import of a missing file is refused by both, as one output. An entry that climbs out of `tree/`
  is not a recipe for this machine.
- **Admission.** Flattened wacc is refused while nobody has endorsed its source. It is admitted once a reviewer has,
  witnessed by both runners. After the JavaScript runner revokes, the Rust one alone is refused.

## Limits

- **The directory walk can leave the tree.** A bare specifier is looked for up to 12 directories up, and the runner
  cannot stop a tool from looking above its work directory. Both runners write the tree under a fresh directory, so
  a stray file found there would show as two runners disagreeing, or as a CID nobody else derives, rather than
  silently. wacc's imports are all `./`, so for the ladder's own use the walk never starts.
- **`fileSet` is not this machine.** The ladder also hands wacc its sources as a set of files keyed by how they name
  each other (`fileSet` / `file_set`). That belongs to the wacc driving step, milestone 4.
