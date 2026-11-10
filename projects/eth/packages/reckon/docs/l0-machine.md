# The wac-L0 machine, `wac-l0/1`

Decision D, milestone 2 (docs/bootstrap-derivations.md). The root of wac's bootstrap ladder is an assembler, not a
compiler: the first rung, `boot/l1.l0`, is wasm written as text by hand, and every later rung emits that same text.
`wac-l0/1` makes assembling it a derivation: a recipe, an output tree, and runners that sign what they got.

`tools/l0.sh` (task `reckon:l0`) checks it: 20 of 20, or 21 with `LADDER`.

## The rule

**`wac-l0/1` is wac's `bootstrap/spec/l0.md`, at wac `fade220396e94c13324f05c1044fccb5a15690aa`:
`bafkreico54x6lyhwewwurc5mh7cmss4sivn5c6jk5dmjev7ebsagjddjpu`, 8,878 bytes, 207 lines.**

That document is the whole definition. It was written so that "two independent implementations should agree byte for
byte without either author being clever", and wac holds two that do. A later edit to it is a new machine, `wac-l0/2`,
not a change to this one.

    input tree    source            the L0 text, UTF-8; the only entry
    output tree   status            "ok" or "refused"
                  out/module.wasm   the module, when ok

- **No program.** The machine is the assembler. This is what makes it a root rather than one more step: nothing
  inside the recipe says how to assemble, so nothing inside it can be swapped.
- **A refusal is an answer, but its message is not part of it.** The two assemblers word their errors differently and
  agree only that the text is not L0. The output says `refused`, and the message goes to the runner's diagnostics.
- **A runner's own failure is not an answer.** That covers an assembler that did not start, crashed, or claimed
  success and wrote nothing. The runner gives no output and makes no claim, as `wasm-gc/wac-host/2` does past a
  runner's limits.
- **Determinism is the format's.** L0 states every index by name and fixes section order, so an assembler has no
  choices to make. The module is a pure function of the text.

## The runners

`cmd/l0.wac` is the runner. It runs an assembler as a host command, `CMD IN OUT`: exit 0 with OUT written is a module,
exit 1 a refusal, anything else a failure.

| runner | implementation, at fade22039 | size |
| --- | --- | --- |
| `wax (Rust) at wac fade22039` | `bootstrap/rust/src/lib.rs` (`bafkreicqule7…`) and `main.rs` (`bafkreifjfzpv…`), no dependencies, built with cargo | 1,217 + 31 lines |
| `wax.js (node) at wac fade22039` | `bootstrap/js/assemble.js` (`bafkreihgzalz…`), through `tools/l0/assemble.mjs`, which gives it the same `IN OUT` shape | 1,065 lines |

Wac requires the two to agree, and `bootstrap/ts/differential.test.ts` checks it in wac's own tests. Here each one signs
a derivation, so a policy can ask for both. It writes that with `runners: 2` and the two keys, and gets a module only
when two implementations written apart, in different languages and run by different toolchains, produced the same
bytes.

    l0 recipe --source boot/l1.l0 --store S
    l0 run RECIPE --assembler "PATH/TO/wax" --key rust.key --runner "wax (Rust) at wac fade22039" --store S
    l0 run RECIPE --assembler "node tools/l0/assemble.mjs PATH/TO/assemble.js" --key js.key --runner "wax.js (node) at wac fade22039" --store S

## A policy

The L1 interpreter, as the next milestone will need it: the module inside an assembled tree, where the tree was
derived by both runners from a source a reviewer endorsed.

    machines: ["wac-l0/1"],
    roles: {
      interpreter: [{ within: { role: "assembled", path: "out/module.wasm" } }],
      assembled: [{ derived: { by: ["rust", "js"], at_least: 2, runners: 2, other: "source" } }],
      source: [{ endorsed: { by: ["reviewer"], at_least: 1 } }],
    }

## What was run (2026-11-10, wac fade22039)

- **Agreement.** The two runners give one output tree for every L0 text wac's tests hold (`bootstrap/tests/l0`, 9
  files), for `boot/l1.l0` (1,814 lines), and for the largest L0 the ladder makes: wacc's, as the L5 compiler emits it
  (7,840,261 bytes, 434,354 lines, `bafybeihb35eru37…`).
- **Behaviour.** The modules compute what `bootstrap/tests/expect.json` says, 7 of 7. That includes the L1
  interpreter's 720.
- **Refusals and failures.** A text with an unknown instruction is refused by both, as one output with no module. An
  assembler that exits 2 gives no output and no claim.
- **Admission.** The L1 interpreter's module (`bafkreig6tirm…`) is refused while nobody has endorsed `boot/l1.l0`.
  It is admitted once a reviewer has. A runner that changes one byte of its output gets another CID, and its module
  is refused on one runner's word. When the JavaScript runner revokes its derivation, the Rust one alone is not
  enough.

## What it does not do yet

- **Nothing runs the module.** That is milestone 3 (`wasm-seam/1`, or (B)): the L1 interpreter running `boot/l2.l1`
  to make the L2 compiler, and so on up.
- **The runners are host commands.** They run outside any sandbox, unlike `wasm-gc/wac-host/2`'s programs. Each
  reads one file and writes one, and two of them must agree. A runner's operator is trusted to run the implementation
  named in its runner string, exactly as a `wasm-gc` runner is trusted to run the engine it names.
- **The node runner leans on V8's JavaScript.** It is the assembler's language runtime, not the wasm engine that
  later runs the module, so it is not the same dependency the seam runner will have.
