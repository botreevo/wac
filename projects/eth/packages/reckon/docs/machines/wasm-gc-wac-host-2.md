# Machine `wasm-gc/wac-host/2`

This document is the definition of the machine named `wasm-gc/wac-host/2`. A recipe that names the machine means
what this document says, whatever runner carries it out. A change to what it says is a new machine, `/3`, and not an
edit of this one. Its CID is listed in `docs/machines/README.md`, so a policy, a claim or a reader can name exactly
this text.

The rest of this repository implements the machine (`src/machine.wac`, `src/world.wac`, `src/canon.wac`,
`cmd/derive.wac`) and explains how it got here (`docs/runner.md`). Where they and this document differ, this document
is the machine and they have a bug.

## 1. A recipe

    { machine: "wasm-gc/wac-host/2", format: "unixfs-v1-2025+hidden", input: CID }

The input is a directory tree, encoded as `unixfs-v1-2025+hidden` describes: IPFS's `unixfs-v1-2025` profile, with
hidden files included, symbolic links refused, and no modes or times.

The tree has these entries at its top level:

| entry | | meaning |
| --- | --- | --- |
| `program` | required | a WebAssembly module (with garbage collection) that imports only wac's host protocol (§4), as `wac build` writes |
| `args` | optional | the program's arguments, one per line; a final newline is optional, and an empty or absent file is no arguments |
| anything else | optional | more input, which the program reads like everything else |

## 2. What the program sees

- **Files.** A file system holding exactly two things:
  - `/in`: the whole input tree, `program` and `args` included, read-only;
  - `/out`: empty, and writable.

  The program starts at `/`, and a relative path starts there. A path that would climb above `/` is refused. There are
  no modes, owners, links or times: asking for a time answers 0, and asking to set or make one of the others is
  refused.
- **Its arguments**, from `args`.
- **Nothing else.** It has no network, no environment variables, no clock (wall or monotonic) and no random bytes.
  Asking for any of them answers `Unsupported`. It cannot reach its runner's processes or files. It may start child
  programs from modules it holds. A child gets only what the program hands it, and is refused the same things.

## 3. Arithmetic

WebAssembly is deterministic except for the bit patterns of NaNs. In this machine, every NaN an operation produces is
**the canonical NaN** (`0x7FC00000` for f32, `0x7FF8000000000000` for f64), on every engine and CPU. This is
WebAssembly 3.0's deterministic profile.

`neg`, `abs`, `copysign`, the reinterpret instructions, loads, stores and moves are not NaN-producing operations, and
they carry bits exactly. A runner may impose the profile however it likes. The reference runner rewrites the module
(`src/canon.wac`).

## 4. The host protocol

The program speaks wac's host protocol: the imports wac's `std` makes and the answers it expects, as defined by `std`
at wac commit `fade220396e94c13324f05c1044fccb5a15690aa`. A module built by `wac build` at that commit, or at a later
commit whose protocol answers the same calls the same way, is a valid `program`. A change to the protocol that changes
any answer a program can observe is a new machine.

## 5. The output

When the program ends, the output is a directory tree of exactly three entries, encoded as the recipe's format says:

| entry | content |
| --- | --- |
| `status` | one line ending in a newline: `exit N` if the program ended with status N, or `trap NAME` if WebAssembly stopped it for a reason the module itself determines |
| `log` | every byte the program wrote to its standard output, in order |
| `out/` | everything under `/out` when it ended: files and directories, empty directories kept |

What the program writes to its diagnostic output is not part of the output.

The names a trap may have:

| `NAME` | what stopped it |
| --- | --- |
| `array-out-of-bounds` | an array access out of bounds |
| `memory-out-of-bounds` | a linear memory access out of bounds |
| `table-out-of-bounds` | a table access out of bounds, or an undefined element |
| `divide-by-zero` | integer division or remainder by zero |
| `integer-overflow` | an integer division whose result cannot be represented |
| `float-to-integer` | a float-to-integer conversion that traps |
| `null` | a null reference, or a null function |
| `cast` | a failed reference cast |
| `unreachable` | `unreachable` |

## 6. No output

A run whose answer would depend on the runner gives **no output**, and a runner makes **no claim** about it:

- running out of time (a recipe states no time limit, and a runner's own limit is its business);
- running out of stack or memory beyond the floor (§7);
- stopping in any way §5 does not name.

No output is not a failure of the machine. It means the machine gives no answer for this run on this runner.

## 7. The floor

Every runner of this machine gives an answer for any run that needs no more than:

| resource | at least | as measured by |
| --- | --- | --- |
| stack | enough for 10,000 nested calls of a two-argument `i64` function | `corpus/depth.wac` with argument `10000` |
| heap | 1 GiB live at once | `corpus/heap.wac` with argument `1024` (1 MiB arrays) |

A runner may provide more. A program that needs more may get an answer from some runners and no output from others,
but never a different answer.

## 8. Conformance

A runner shows that it implements this machine by witnessing its conformance suite (`docs/conformance.md`): recipes
from `corpus/`, each with the output this document gives it or `none` where §6 gives none. The suite is evidence, not
the definition. Where the suite and this document differ, this document holds, and the suite is replaced.
