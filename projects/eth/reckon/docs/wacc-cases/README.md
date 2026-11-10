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
