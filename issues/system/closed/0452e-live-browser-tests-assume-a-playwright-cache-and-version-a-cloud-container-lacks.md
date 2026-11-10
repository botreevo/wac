# 0452e — the live browser tests assume `~/.cache/ms-playwright` and a matching `npm:playwright`, so a cloud container skips or fails them

- **Status:** closed 2026-11-10 (wac2) — `harness/chromium.ts`
- **Claimed by:** (nobody yet — add yourself before working it)
- **Reported by:** wac2 (cloud), running W1's `hostget_live.test.ts`
- **Date:** 2026-11-10
- **Kind:** bug — in the test harness
- **Symptom:** a browser test lane that passes having driven no browser

## Reproduction

In a Claude cloud container, where Chromium is preinstalled at `/opt/pw-browsers` (`chromium-1243`) and not under
`~/.cache/ms-playwright`:

    $ deno test -A --unstable-net packages/platform/test/hostget_live.test.ts
    hostget_live: skipped — no /root/.cache/ms-playwright: no browser installed
    ... ignored

`browser_live.test.ts`, `drop_live.test.ts`, `keys_live.test.ts` and the other live tests skip the same way, and the
gate goes green without having asked a browser anything.

Pointing the lookup at the installed browser (a symlink `~/.cache/ms-playwright -> /opt/pw-browsers`, or
`PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers`) gets further and then fails: `import("npm:playwright@1")` resolves the
newest 1.x, whose expected Chromium revision is not 1243, and `chromium.launch()` stops with Playwright's
"please run `npx playwright install`" box. The same test launched with
`executablePath: "/opt/pw-browsers/chromium"` passes (4 s).

## Notes

Two independent assumptions, so two fixes:

- **Where the browser is**: `canDriveBrowser()` (copied into each live test) reads only `$HOME/.cache/ms-playwright`.
  It could honour `PLAYWRIGHT_BROWSERS_PATH`, or an explicit `WAC_CHROMIUM` executable that the tests pass to
  `chromium.launch({ executablePath })` — the second also sidesteps the version question.
- **Which Playwright**: `npm:playwright@1` floats. Pinning it to the version whose browser revision is installed, or
  launching by `executablePath`, makes the result not depend on what npm published last.

`canDriveBrowser()` is duplicated in at least `browser_live.test.ts` and `hostget_live.test.ts`; a shared helper in
`harness/` would be the one place to fix. Not urgent: nothing is wrong with the code these tests exercise, but a skip
that reads as a pass is how a regression would get through.

## Fixed — wac2, 2026-11-10

`harness/chromium.ts` finds the browser for every live test: `WAC_CHROMIUM` when set, otherwise the newest
`chromium-*` revision under `$PLAYWRIGHT_BROWSERS_PATH` or `~/.cache/ms-playwright`. It launches **by executable**
(`launchOptions`), so the floating `npm:playwright@1` no longer matters. The nine copies of the check use it, and so
does `bootstrap/ts/browser.test.ts`, which had a revision (`chromium-1234`) written into its path.

**Running them found what the skips had hidden:**

- Three tests (`packages/raster/test/live.test.ts`, `packages/box/test/rasterterm_live.test.ts`, and
  `browser_live.test.ts`'s pixels) read a canvas with `getContext` after wac-web had started handing canvases to the
  program's worker. `harness/buildPage.ts`'s `canvasesOnThePage` keeps them on the page's thread, wac-web's own
  fallback, and wac-web's `sense_live` tests the handover.
- A page could not wait for a child at all: `0460e`.

`csp_live`, `hostget_live`, `keys_live`, `drop_live`, `site_live`, raster `live`, `rasterterm_live` (4) and
`bootstrap/ts/browser.test.ts` pass in a cloud container. `browser_live` waits on `0460e`.
