# 0447e — `spec/7-library/44-std.md` shows `within` matched with nested patterns the language does not have

- **Status:** closed 2026-11-17 (wac2) — `spec/7-library/44-std.md`
- **Reported by:** wac2 (cloud), found while triaging `0300b`
- **Date:** 2026-11-10
- **Kind:** diagnostic — a spec example, not the compiler
- **Symptom:** compile error, for a program copied from the spec

## Reproduction

The only example of `clock.within` in the spec, just above `[§wac-std-within-8mdio9r]`:

```wac
// fragment
match (await sys.clock().within(sock.recv(), 30000)) {
  Ok(Data(bytes)): { … }
  Ok(End): { … }
  Err(TimedOut t): { sock.close(); }        // silent for thirty seconds
  Err(e): { … }
}
```

Made whole with a program-made ticket and checked on master `715162c8d`:

```wac
import { Sys, TimedOut } from "std";
import { Ticket, Result } from "core";
export async i32 main(Sys sys) {
  Ticket<Result<i32, string>> never;
  match (await sys.clock().within(never, 200)) {
    Ok(v): { return 1; }
    Err(TimedOut t): { return 7; }
    Err(e): { return 2; }
  }
}
```

    error: unexpected token
      --> q.wac:7:18
     7 |     Err(TimedOut t): { return 7; }
       |                  ^ expected ')', found 't'

and 13 errors after it as the parser loses its place.

## Notes

Both `Ok(Data(bytes))` and `Err(TimedOut t)` are **nested** patterns — a variant pattern and a type pattern inside a
payload position — which is `issues/lang/0027`, open and deliberately deferred. A type pattern exists only at the top
of `matches` (`Circle c matches s`, `spec/cases/0341`). The fragment is marked `// fragment`, so nothing compiles it
and nothing noticed.

What works today, and answers the same question:

```wac
match (await sys.clock().within(never, 200)) {
  Ok(v): { return 1; }
  Err(e): { return e is TimedOut ? 7 : 2; }
}
```

That returns 7 after the deadline. Two reasonable fixes, which is why this is an issue rather than an edit: rewrite
the fragment in today's syntax (and make it a compiled example, so it cannot drift again), or keep it as the motivating
example for `0027` and say so beside it. Which one depends on whether `0027` is still deferred.

## Fixed — wac2, 2026-11-17

The fragment is written in patterns the language has: the `Ok` arm matches the `Read` it holds (`Data`, `End` — and
`Failed`, which the old one never showed and a whole program cannot leave out), and the `Err` arm asks `e is TimedOut`.
Made whole — a `Socket` and a `Sys` around it — it checks clean on the current compiler. Still marked `// fragment`,
since its `…` bodies are prose.
