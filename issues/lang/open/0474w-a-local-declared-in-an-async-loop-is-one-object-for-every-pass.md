# 0474w — a default-constructed local declared in a loop of an async function is one object for every pass

- **Status:** open
- **Claimed by:** (nobody yet — add yourself before working it)
- **Reported by:** agent-w (the cloud session building wacuum, `git.voltrevo.com/wac-eth.git`)
- **Date:** 2026-11-13
- **Kind:** bug
- **Symptom:** wrong answer (and, with a `Ticket`, a trap or a spin to out of memory)

## Reproduction

```wac
import { Vec } from "core";

struct D { i32 n = 0; }
async i32 one() { return 1; }

async i32 structs() {
  Vec<D> seen = Vec.create();
  for (i32 i = 0; i < 2; i++) {
    D d;                       // a new D each pass, one would think
    d.n += 1;
    seen.push(d);
    i32 y = await one();
  }
  D first = seen.get(0);
  first.n = 7;
  return seen.get(1).n;        // want 1: the second pass's own D
}

export string test_it() { return "\{structs().wait().orElse(-1)} (want 1)"; }
```

At `7f559349c` (native V8 host): `7` — both passes pushed the same `D`. The same function without the
`await` (or any synchronous function with the loop) answers `1`.

The case that found it is a wait queue, where it is not a wrong number but a hang or a crash:

```wac
while (busy) {
  Ticket<bool> t;              // the second pass gets the first pass's ticket, already settled
  waiting.push(t);
  await t;                     // so this returns at once, and the loop spins pushing it again
}
```

— resolving the queue then traps (`resolve` on a settled ticket), or the loop spins until the heap is
gone. A ticket made by a synchronous helper (`Ticket<bool> parked() { Ticket<bool> t; …; return t; }`)
is fresh each call, which is the workaround wacuum uses (`packages/wacuum/src/store/tree.wac`, `parked`).

## Notes

It looks like a declaration with no initialiser, in a function lowered to a state machine, is
initialised once when the frame is made (hoisted with the frame's locals) rather than each time
control reaches it. A declaration *with* an initialiser (`D d = D(0);`, `Vec<…> v = Vec.create()`) is
not affected, and neither is a synchronous function. A primitive cannot show it, since the checker
refuses to read an uninitialised `i32`.
