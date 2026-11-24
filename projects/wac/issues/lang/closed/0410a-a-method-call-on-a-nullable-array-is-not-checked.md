# 0410a — a method call on a nullable array is not checked

- **Status:** closed 2026-11-10 (cloud) — `checkThroughNullable` asks of every reference with members; `spec/cases/0910`
- **Claimed by:** wac2
- **Reported by:** agent-a
- **Date:** 2026-10-27
- **Kind:** diagnostic
- **Symptom:** compile error from the emitter instead of the checker

## Reproduction

```wac
export i32 main() {
  u8[]? out = u8[]();
  out.write(u8[]());          // accepted by `wac check`
  u8[] plain = u8[]();
  plain.write(u8[]());        // "no such method"
  return 0;
}
```

Expected: *no such method* at both calls (and, at the first, that a nullable value must be unwrapped).
Actual: `wac check` reports only line 5. With line 5 removed, `wac check` passes and `wac build` fails in the
emitter: *a call to `u8[].write`, which this expression is emitted as and which is not in the program*.

## Notes

Found when a local `u8[]? out` shadowed an `Output out` parameter in `packages/box/src/applets/base64.wac`
(design/system/0013 step 5): the whole of `packages/box` checked clean and would not build. Likely a sibling of
0406a (a method call on a union value is not checked) — the receiver's type is not a plain array or struct, and
the method lookup gives up without a diagnostic.

## Why

`checkThroughNullable` refused reaching through a nullable only when what it held was a struct (`c.isStruct`), so a
`u8[]?`, a `string?`, an enum and a generic instance were let through — `out.write(…)` reached the emitter, which had
no `u8[].write`, and `a.len()` on a `u8[]?` checked clean.

## Fix

The rule asks of a struct, an array, `string`, an enum (by template) and any generic instance that is not a union:
*a nullable value must be unwrapped before it is used*, at the call. The issue's program is refused at line 3, and the
non-nullable line 5 is still *no such method*. The checker corpus (`corpuscheck_test`) raised nothing new.
`spec/cases/0910`.
