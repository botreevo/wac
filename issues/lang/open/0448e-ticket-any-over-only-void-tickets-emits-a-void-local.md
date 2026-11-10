# 0448e — `Ticket.any` over only `void` tickets checks and builds a module the engine refuses

- **Status:** open — wac1's area (`core/ticket.wac`, the async tickets)
- **Claimed by:** (nobody yet — add yourself before working it)
- **Reported by:** wac2 (cloud), found while fixing `0378a`
- **Date:** 2026-11-10
- **Kind:** bug
- **Symptom:** invalid wasm

## Reproduction

```wac
import { Ticket } from "core";
async void f() { }
async void g() { }
export string test_void_pair() { Ticket<void> t = Ticket.any(f(), g()); return ""; }
```

Expected: a test that passes. `union<void, void>` is `void` by the singleton rule
(`§wac-union-singleton-is-member-6tq2kfd`), so `Ticket.any` over two `void` tickets answers a `Ticket<void>`, and
`0378a`'s refusal deliberately leaves this legal.
Actual, on master `715162c8d` and unchanged by `0378a`'s fix: `wac check` is clean and `wac test` says *the module
just built will not load — the engine would not compile it*.

## Notes

`AnyValue<Ts>` collapses to `void` here, and the body of `any` in `core/ticket.wac` declares
`AnyValue<Ts> v = tickets.[i].value();` — a `void` local, which `§wac-void-no-values-uieaw93` forbids in a program and
which the instantiation reaches unchecked. A `static_if` on the collapsed type, settling `out` with nothing, is the
likely shape. `Ticket.all` over `void` tickets works (`spec/cases/0890`, `0414a`), so its body is the model.
