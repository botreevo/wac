# 0366a — `wac run` lists an export as `f()` and refuses `f()`

- **Status:** closed 2026-11-10 (cloud) — `call_named` in `native/v8/src/main.rs`; `runNamed_test.wac`
- **Claimed by:** wac2
- **Reported by:** agent-a
- **Date:** 2026-10-22
- **Kind:** diagnostic
- **Symptom:** the suggested spelling is refused

## Reproduction

```wac
export i32 f() { return 1; }
```

    $ wac run g.wac
    wac: g.wac exports no main, so name the function to run:
      f()
    $ wac run g.wac 'f()'
    wac: g.wac exports no `f()`. It exports:
      f()
    $ wac run g.wac f
    1

Expected: the list shows what to type (`f`), or `f()` is accepted.
Actual: the list shows a spelling that the next run refuses, and the refusal repeats it.

## Why

The listing of what a module exports showed each as a signature, `f()` or `gcd(i32, i32)`, which is not what the command takes — and typing it was refused as *no such export* by a message that listed it again.

## Fix

Both of the issue's expectations: the listing shows what to type — the name, then each parameter as an argument, `gcd <i32> <i32>` — and a name written as a call is that name, so `wac run g.wac 'f()'` runs `f` and `'gcd(i32, i32)' 48 18` answers 6. An unknown name is still refused with the listing. `packages/wac/test/wac/runNamed_test.wac` holds the new listing and the call spelling.
