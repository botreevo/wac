# 0432d — a named field's value is never checked, so a lambda there may call anything

- **Status:** closed 2026-11-08 (cloud) — `check.wac`'s `Construct` arm checks each named value; `spec/cases/0868`
- **Reported by:** wac-kps
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** accepted program (then an emit failure)

## Reproduction

```wac
import { Sys } from "std";
struct Report { fn<void(string)> emit; }
export i32 main(Sys sys) {
  Report r = Report { emit: (string text) => { sys.print(text); } };
  r.emit("x");
  return 0;
}
```

`wac check` is clean; `wac run` answers *a call to `Sys.print`, which this expression is emitted as and which is
not in the program*. `Sys` has no `print`. The same lambda as a positional argument, `Report((string t) => …)`, is
refused by the checker, and an undefined name inside the named one passed too.

## Why

`checkConstruct` asked whether each named value's *type* fits its field, which needs only `typeOfExpr`, and the
`Construct` arm of `checkExpr` walked the positional arguments and never the named ones. Nothing inside a named
value — a lambda's body above all — was checked at all.

## Fix

The `Construct` arm checks each named value with its field's type as the slot, as it checks a positional argument
with its parameter's. The repository's own entries — `lib.wac`, the `wac` command, the site — check clean with it.
