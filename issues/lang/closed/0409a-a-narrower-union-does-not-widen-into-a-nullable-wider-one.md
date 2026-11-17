# 0409a — a narrower union does not widen into a nullable wider one

- **Status:** closed
- **Claimed by:** (nobody yet — add yourself before working it)
- **Reported by:** agent-a
- **Date:** 2026-10-27
- **Kind:** bug
- **Symptom:** compile error

## Reproduction

```wac
struct A { string m; }
struct B { string m; }
struct C { string m; }
type Wide = union<A, B, C>;
type Narrow = union<A, B>;
Narrow pick(bool x) { return x ? A("a") : B("b"); }
export i32 main() {
  Wide w = pick(true);        // accepted
  Wide? n = null;
  n = pick(false);            // refused
  Wide? m = pick(true);       // refused
  return (n is null ? 0 : 1) + (m is null ? 0 : 1);
}
```

Expected: compiles and answers 2 — a `Narrow` is a `Wide`, and a `Wide` is a `Wide?`.
Actual: *initialiser does not match the declared type* at both `Wide?` lines; the plain `Wide w = pick(true)` and a
`Wide` parameter are accepted.

## Notes

Found holding "the first fault so far" in a `FilesFault?` while copying a file (`packages/box/src/lib/safe.wac`): an
`OutputFault` from `Output.write` would not assign into it. Worked around there by returning at each fault instead.

## Fixed — 2026-11-17

`assignable` refused any union source into a slot that was not itself a union, one line before the general unwrap of
a nullable slot would have asked about its base. A union into a `T?` is now a union into `T`
(`packages/wacc/src/check.wac`). The emitter already wrote it: `packages/wacc/test/wac/nullableunion_test.wac` checks
the reproduction at all three positions, emits it, runs it, and holds that a wider union still does not narrow into a
nullable narrower one.
