# 37 — Core

`core` is the package that ships with the toolchain and needs nothing from the host. It holds the types and symbols
the language itself refers to, and the ordinary data structures a program should not have to find a package for.
Anything that reaches the world is in `std` ([44](44-std.md)) instead.

It is reached like any package — by its name, through its entry module — and a project cannot replace it
([02](../1-programs/02-modules-and-imports.md)).

## What `core` exports

| Name | What it is | Chapter |
|---|---|---|
| `operators` | namespace of the operator symbols, and their `FromLeft` reverses | [22](../3-expressions/22-operators.md) |
| `toString` | the conversion symbol interpolation uses | [23](../3-expressions/23-interpolation-and-markup.md) |
| `markup` | namespace of the symbols a markup tree builds itself with | [23](../3-expressions/23-interpolation-and-markup.md) |
| `math` | namespace of the logarithms, the exponentials and the power | [43](43-math.md) |
| `fromNumber`, `NumberLiteral` | literal conversion for a type of the program's own | [09](../2-types/09-numeric-literals.md) |
| `Vec<T>` | a growable array | [38](38-vec.md) |
| `Map<K, V>`, the hash and equality functions | a hash map | [39](39-map-and-hash.md) |
| `Result<T, E>` | success or failure | [40](40-result.md) |
| `Read` | the answer of a read that can end or fail | [41](41-read.md) |
| `Buf` | a growable byte buffer | [42](42-buf.md) |
| `Ticket<T>`, `TicketBase`, `Continuation`, `Queue<T>` | tickets and the scheduling they need | [35](../6-concurrency/35-tickets-and-await.md) |
| `Step`, `Coroutine`, `Generator`, `AsyncGenerator` | the machine under `async` and `gen` | [36](../6-concurrency/36-coroutines-and-generators.md) |
| `hypothetical<T>()` | an expression of type `T` for `typeof`, which traps if run | [30](../4-static/30-computed-types.md) |
| `Values<Ts>` | the tuple of what each of a tuple of tickets answers | [30](../4-static/30-computed-types.md), [35](../6-concurrency/35-tickets-and-await.md) |
| `AnyValue<Ts>` | the union of what each of a tuple of tickets answers | [30](../4-static/30-computed-types.md), [35](../6-concurrency/35-tickets-and-await.md) |

```wac
// expect: fromCoreRoot() = 2
import { Vec, Result, operators, toString } from "core";
import { operators.add } from "core";

export i32 fromCoreRoot() {
  Vec<i32> v;
  v.push(1);
  v.push(2);
  Result<i32, bool> r = Result.Ok(v.len());
  return r.orElse(0);
}
```

`[§wac-core-exports-markup-c3v8pwq]` Every name in the table above is exported by `core`'s entry module, at its root or — for
`operators`, `markup` and `math` — as a namespace.

Families of related names are namespaces — the operator symbols, the markup symbols, the mathematical functions — and
everything else is at the root.

```wac
// fragment — from core
export T hypothetical<T>() { trap; }
```

`[§wac-hypothetical-irymyyf]` `hypothetical<T>()` has type `T` and traps when called. It exists to be written inside
`typeof` ([30](../4-static/30-computed-types.md)), where it is checked and never run.

## Text: `strings`

`strings` is `core`'s namespace of text functions beyond a `string`'s own `len`, `slice`, `indexOf` and `+`:

```wac
// expect: words() = "b|c|a"
// expect: tidy() = "hello, world"
import { strings } from "core";
export string words() { return strings.join(strings.split("a,b,c", ",").len() == 3 ? ["b", "c", "a"] : [""], "|"); }
export string tidy() { return strings.toLower(strings.replace(strings.trim("  HELLO; WORLD \n"), ";", ",")); }
```

`[§wac-strings-bytes-k3w8q2n]` Every position `strings` answers or takes is a byte offset into the UTF-8 text, as
`slice`'s and `indexOf`'s are; `split`, `replace` and the searches never cut a character, because valid UTF-8 cannot
match inside one. `toLower` and `toUpper` change ASCII letters and leave every other byte as it was.

`[§wac-strings-split-join-m5r2v8t]` `split(s, sep)` cuts `s` at every `sep` and keeps empty pieces, so a string with no
`sep` is one piece and `join(split(s, sep), sep)` is `s`. An empty `sep` traps.

## Why these are in `core`

A name belongs in `core` when the language needs one agreed declaration of it. A symbol is the strongest case: the
compiler calls `toString` for interpolation and the `markup` methods for markup, and a fresh symbol spelled the same is
a different one. A type the compiler does not build is not a case at all — markup's trees are libraries, because
markup lowers to calls of the tree's own methods and names no type ([23](../3-expressions/23-interpolation-and-markup.md)).

The data structures are here for a weaker but still real reason: a program that wants a map should not have to find a
package first, and two hand-written maps are two places for the same bugs.

Nothing in `core` holds a capability, so nothing in it can reach the world. A program that imports only `core` can
compute and answer, and do nothing else ([07](../1-programs/07-programs.md)).

## Open

- **Where `core`'s data structures sit.** This chapter puts them at the root, and families in namespaces. Whether they
  should instead live in namespaces of their own (`collections.Vec`) is not decided.
