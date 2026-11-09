# 0441d — an operator on a generic struct is refused

- **Status:** closed 2026-11-09 (cloud) — `check.wac`'s `checkOperatorArg` reads the parameter in the receiver's world; `spec/cases/0876`
- **Reported by:** cloud session, testing the cross-file operator report from wacuum
- **Date:** 2026-11-09
- **Kind:** bug
- **Symptom:** a correct program refused

## Reproduction

```wac
import { operators } from "core";
struct Box<T> {
  T v;
  Box<T> [operators.add](const this, const Box<T> rhs) { return this; }
}
export i32 f() { Box<i32> b = Box<i32>(1) + Box<i32>(2); return b.v; }
```

*argument does not match the parameter's type — expected const Box<T>, found Box<i32>*. In one file or across two.

## Why

`checkOperatorArg` compared the operand with the method's parameter type as the template wrote it. The operator's
*result* was read through `substituteType` with the receiver's type, and its operand was not.

## Fix

The parameter is read in the receiver's world too — the left operand's type for a binary operator, the right's for a
reversed one, the target's for a compound assignment (whose expected type for the right-hand side was the template's
as well).
