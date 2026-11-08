# Where wac got in the way

Each entry is something wac refused or got wrong while this library was written, with the smallest program that
shows it and what this library does instead. Written against wac `701028301`.

## A negative float literal passed to a union parameter does not emit

```wac
struct T { i32 f(this, union<T, f64> x) { return 0; } }
export string test_n() { T t = T(); t.f(-0.5); return ""; }
```

`wac check` accepts it; `wac test` says *cannot emit — a value that enters no alternative of union<T, f64>*. `0.5`
emits, and so does `0.0 - 0.5`. The message names no position, so in a 900-line file it took a bisection to find.

**Here:** `dy.mul(y.pow(3.0)).mul(0.5).neg()` rather than `.mul(-0.5)` in the backward rule for `rsqrt`. Any caller of
`Tensor.mul`, `add` and the rest meets the same thing with a negative literal; `x.mul(0.0 - 0.5)` is the way round it.

## A lambda whose type comes through a `type` alias of a function type does not emit, when it returns an array literal

```wac
struct T { i32 v; }
type B = fn<T?[](T)>;
void take(B b) { }
export string test_a() { take((T t) => [t]); return ""; }
```

*cannot emit — a lambda (this module has 1, 1 in a position the walk does not type yet)*. The same with the parameter
written `fn<T?[](T)>` emits, as does the alias with a lambda that returns `t.v` through `fn<i32(T)>`.

**Here:** the backward rule's type is written out in full, `fn<Tensor?[](Tensor)>`, where `tensor.wac` would rather
have named it once.
