# 0461e — a request cannot be raced: `request` and `fetch` wait at every step

- **Status:** closed 2026-11-11 (wac2) — `requestAsync`, `requestWithinAsync`, `fetchAsync`, `fetchWithinAsync`;
  `packages/http/test/wac/deadline_test.wac`
- **Reported by:** wac-eth's reckon2, through the coordinator
- **Date:** 2026-11-10
- **Kind:** missing feature
- **Symptom:** two requests cannot be in flight at once, and none runs on a host that cannot wait

## What was asked

reckon2 wants to race mirrors: send the same request to several, take the first answer with `Ticket.any`, cancel the
rest. `client.wac`'s `request`/`requestWithin` and `packages/fetch`'s `fetch`/`fetchWithin` each `.wait()` at every
step — connect, send, every read, and `wac.http`'s open and reads — so a caller holds one request at a time. The same
waits are what a page that is not cross-origin isolated cannot do (`packages/platform/host/asynchost.ts`), so neither
ran there.

## Fixed — wac2, 2026-11-11

**One implementation, awaited.** `exchange`, `fetchWithinAsync` with its `plain` and `overTls`, `hostRequestAsync`
and `connectThroughAsync` are `async`, and `waitForAsync` bounds each step by the deadline. Each blocking form —
`request`, `requestWithin`, `fetch`, `fetchWithin`, `hostRequest`, `connectThrough` — is its `async` twin waited for
(`deadline.wac` `settled`), so nothing that calls them changes, and there is no second copy of the protocol to drift.
The twins are exported from each package's `lib.wac`.

`deadline_test.wac` `test_two_requests_race_and_the_loser_is_cancelled`: two requests to a server that never answers,
one with a 200ms deadline; `Ticket.any` settles at about 200ms with the timeout while the other is still in flight,
and the other is cancelled.
