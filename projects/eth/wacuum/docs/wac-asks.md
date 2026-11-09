# What wacuum wants from wac

Found while building this, at wac `a473e07`. Each one has a reproduction small enough to paste.

## The static evaluator: no `switch`, and one step budget for a whole file (wac `issues/lang/0422w`)

Two things met while moving bn254's and secp256k1's constants to compile time:

- A `switch` anywhere on a static's path is "something the compiler cannot evaluate statically yet".
  `U256.word` was a switch; it is ifs now, which compile no worse.
- `Ev.create()` sets an 8,000,000-step budget and the checker makes one `Ev` per file (`ensureStaticView`,
  `check.wac`), so every static in a file draws on the same budget: a static that evaluates alone fails when
  placed after two others. The comment by `step()` reads as if the budget were per evaluation ("no table
  anyone writes reaches it"). bn254 fits by computing its constants from one exponentiation rather than
  three.

## An operator method is not found from another file

`spec/3-expressions/22-operators.md` says `a + b` on a struct calls the left operand's `[operators.add]`
method. That works in the file declaring the struct and nowhere else:

```wac
// v.wac
import { operators } from "core";
export struct V {
  i32 x;
  V [operators.add](const this, const V rhs) { return V(this.x + rhs.x); }
}
export i32 here() { V a = V(1); return (a + a).x; }      // fine
```

```wac
// use.wac
import { operators } from "core";                         // with or without this line
import { V } from "./v.wac";
export i32 f() { V a = V(1); return (a + a).x; }         // error: V has no implementation of operators.add
```

`operatorMethodOf` in `packages/wacc/src/check.wac` looks the method up under
`c.coreMember("operators." + sym)`, which is the *using* file's spelling of the symbol. That table is filled
only while the checker processes a file that imports from core (`api.wac`, `noteCoreSym`), and the key the
method was registered under is the declaring file's. `convertsToText` solved the same problem for
`toString` by also looking under core's own name.

**What it costs here:** `U256` has named methods (`a.add(b)`), not operators.

## Not a bug: a `const` reference to a `const struct` stays `const`

This was listed here as a checker gap, and it is not one. The sentence in `spec/2-types/17-const.md` that
says no reference to a `const struct` "was ever writable — `const` or not" describes the situation; it is
not a rule that lets `const` be dropped, and `§wac-const-no-launder-t584c4n` (a const reference never
becomes a plain one) applies to every type. `return this;` from a `const this` method is accepted by the
accessor exception, `§wac-deep-const-accessor-w3kf8nq`, which makes the result const at the call site.

Written the way the language means it: `const W n = this;`, or `(const W) n` to rebind, and `const W` as
the return type. `U256` still takes a plain `this` everywhere, which is simpler and costs nothing.

## Done: a dense integer `switch` is one `br_table`

wacc emitted a `switch` as a comparison per case, in order, so the EVM interpreter's opcode switch made an
opcode's place in it what dispatching it cost: checking three hot opcodes ahead of it was 22% on the Node
host. Since `d267592b8` a switch whose cases are dense integer constants is one `br_table`, and its subject
is read once (it was read once per case compared, which was also a bug for a subject with effects).

## Done: `bls` and `bignum` are reachable from outside the repository

`lib.wac` exported neither, so KZG point evaluation and EIP-2537's seven precompiles could not be written.
Both are exported since wac `96f6bd34d`, and `src/precompiles/bls.wac` is built on `bls`: every point
evaluation and EIP-2537 state test passes. The one thing `bls` lacked for the EVM, the map from Fp to G1
(its SSWU and 11-isogeny), is written there.

## Done: the JavaScript hosts give a program the network it is granted

`wac run --allow-net` on the Node host used to start the program as a child with only its standard
streams, so `sys.net()` answered "not granted" and the node needed a native host. `01762d3f7` fixed it,
and since the repin to `09e49772a` the node runs on the Node host as on wasmtime: the RPC and devnet end-to-end tests
(TCP and UDP, against geth) both pass with the Node-hosted `wac`.

## Done: a running Keccak-256

RLPx's frame MACs are a Keccak-256 over everything sent so far, read after every frame without ending it.
wac's crypto package had that shape only for SHA3-256; `crypto.Keccak256` is there since `3d6824b52`, and
wacuum's own copy of the permutation is gone.

## Done: a program importing from the `wac` dependency builds again

`a5a17eeba` refused any `main(Sys)` program that imported a namespace member from `"wac"` ("the exported
function `__wacHost` is not in the module the emitter produced"); `8b92a23dd` fixed it, and the repin to it
also brought `01762d3f7`, which gives the Node host a network.
