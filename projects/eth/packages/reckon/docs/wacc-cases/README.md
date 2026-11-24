# wacc cases

Three versions of real files from this repository on which wacc (wac `993f147`, Node host) went wrong. None is
reduced yet: small programs written to isolate them compiled correctly.

| file | put it at | what happens |
| --- | --- | --- |
| `trust-silent.wac` | `src/trust.wac` | compiles; `statements()` never matches a built statement to its subject, so source reviews are dropped and `wactrust run` refuses every app |
| `trust-invalid-module.wac` | `src/trust.wac` | the same loop written with an index; `wac build` succeeds and V8 refuses the module: *Compiling function "$lambda$10/57:1065" failed: not enough arguments on the stack for call (need 1, got 0)* |
| `wactrust-forin-path.wac` | `cmd/wactrust.wac` | `wac check` passes; `wac build` fails: *text from a string[], which has no `[toString]`*, for `\{path}` where `path` is the variable of `for (string path in …)` |

All three involve a loop over values with a `match` or an `await` in it, inside an `async` function. The
repository's current code moves the first into an ordinary function (`about()`), and uses an index for the third.

## An enum variant named `Map`

Found 2026-11-10 in `packages/ipfs`. An enum with a variant named `Map` (`Value.Map` in `src/dagcbor.wac`, before it
became `Dict`) compiles alone, and so does a file importing it. A file that imports it *together with* the `json`
namespace from `"wac"` gets three diagnostics, `undefined type` with a three-character caret, attributed to the importing
file at line numbers that are not its own (47, 52, 212). The likely cause: variant names are file-scope type names, and
`Map` is also `core`'s map type, which the json package uses. Renaming the variant made all three disappear.

## Aggregated test modules and constants

Also 2026-11-10. `wac test` over several packages' suites at once compiles them into one aggregated module, and for
some combinations wacc refuses to emit it: *a constant whose value is not a constant expression*. Seen with
`packages/ipfs/test` in the full set, and with `packages/reckon/test/admit_test.wac` together with
`packages/wacuum-devnet/test`. Each suite passes alone and alongside most others. For admit_test with the devnet's
tests, the failure needs at least one test to reach the admission code: with only its helpers (which nothing reaches)
it emits. Not caused by names admit_test declares: renaming its constants (one, `ALICE`, was also the devnet's) and
turning them into functions changed nothing. Not reduced further. wac-eth's `test` task runs one package per
invocation meanwhile.
