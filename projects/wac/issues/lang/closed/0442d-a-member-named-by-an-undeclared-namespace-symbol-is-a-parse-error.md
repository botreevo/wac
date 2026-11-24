# 0442d — a member named by a symbol its namespace does not declare is a parse error

- **Status:** closed 2026-11-09 (cloud) — `namespaces.wac`'s `rewriteUses`; `spec/cases/0877`
- **Reported by:** cloud session
- **Date:** 2026-11-09
- **Kind:** diagnostic
- **Symptom:** a cascade of "unexpected token"

## Reproduction

```wac
import { operators } from "core";
struct V { i32 x; bool [operators.less](const this, const V rhs) { return this.x < rhs.x; } }
```

Thirty-odd *unexpected token … found '['*, for a misspelling of `operators.lessThan`.

## Why

The namespace lowering rewrites `operators.lessThan` to the verbatim name `@"operators.lessThan"` before parsing. A
member the namespace does not have was left as written, and inside `[…]` the parser takes one name — so it met a dot.

## Fix

A chain naming nothing there, written as a member's name, is rewritten to its qualified name all the same, so the
checker answers *undefined name — no symbol 'operators.less' in scope* at the name, as an import of one already did.
