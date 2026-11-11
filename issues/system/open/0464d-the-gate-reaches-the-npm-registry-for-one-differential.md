# 0464d — the gate reaches the npm registry for one differential

- **Status:** open
- **Claimed by:** (nobody yet — add yourself before working it)
- **Reported by:** wac1, from the 2026-11-11 Deno-policy audit
- **Date:** 2026-11-11
- **Kind:** missing feature
- **Symptom:** a gate that cannot run without the network, and a TS test driving the comparison

## What happens

`tools/push.sh` runs `npm ci` in `site/` whenever `site/node_modules` is missing or older than `package-lock.json`, and
refuses to run the suite if it fails. The only test that needs it is `packages/ts/test/stripDifferential.test.ts`,
which loads `site/node_modules/typescript` with `createRequire` to compare `packages/ts`'s stripper against
`ts.transpileModule`.

So a fresh clone, a new worktree, or a lock bump makes the gate reach the npm registry, and a session whose network
policy does not allow it cannot push — for one differential.

## Why it is also a policy question

The 2026-11-11 rule is that Deno is a host, or an oracle a wac program invokes. This differential is the TypeScript
compiler as an oracle, driven from a TS test (`*.test.ts` in the Deno pass) — the shape the rule moves under wac.

## What would close it

- The comparison moves to a wac test asking an inline oracle (`wactest/src/inline.wac`) that loads `typescript` — the
  same shape as every other oracle — and
- that test runs only where `site/node_modules` is present, saying so when it skips, so the gate itself needs no
  registry. `push.sh`'s `npm ci` then goes, or becomes the site build's own step.

Vendoring a fixed `typescript.js` would also remove the network, at the cost of a large file in the tree.
