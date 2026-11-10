# 0453e — the TypeScript stripper erases `satisfies` where it is an identifier, and emits broken JavaScript

- **Status:** open
- **Claimed by:** (nobody yet — add yourself before working it)
- **Reported by:** wac2 (cloud), found by the W1 gate at `./bootstrap.sh --host nodejs`
- **Date:** 2026-11-10
- **Kind:** bug
- **Symptom:** a bundle that does not parse, from TypeScript that does

## Reproduction

```ts
export function satisfies(a: number, b: string): boolean {
  return a > 0 && b !== "";
}
if (!satisfies(1, "x")) throw new Error("no");
```

    $ wac run --allow-read --allow-write packages/ts/src/main.wac t.ts -o t.js
    $ node --input-type=module --check < t.js
    export function                                          {
                                                             ^
    SyntaxError: Unexpected token '{'

and the call becomes `if (!                 ) throw new Error("no");`. `deno check` and TypeScript accept the input: `satisfies`
is an operator only in `expr satisfies Type`, and a plain identifier everywhere else.

## Notes

`packages/ts/src/strip.wac` treats the word as the operator wherever it appears, erasing it and what follows as a
type. That is `design/system/0009` D4's failure exactly — *"a construct this cannot read is an error naming it and
its position. Never a guess, never a silent pass-through"* — except worse than a pass-through: a silent rewrite into
code that does not parse, found here only because `./bootstrap.sh --host nodejs` assembled the node host from it.
W1 renamed its function (`hosthttp.ts`'s `versionMatches`); the stripper is unchanged. The operator form follows an
expression, so a `satisfies` after `function`, after `(` or `,`, or before `(` is an identifier.
