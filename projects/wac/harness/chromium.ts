// Where a live test's Chromium is, and how to launch it — one place, for every `*_live.test.ts`.
// `issues/system/0452e`.
//
// Each live test carried its own copy of a check that looked in `$HOME/.cache/ms-playwright` and nowhere else,
// then launched whatever browser `npm:playwright@1` — which floats to the newest 1.x — expected. A machine whose
// Chromium is elsewhere (a cloud container keeps it at `$PLAYWRIGHT_BROWSERS_PATH`, `/opt/pw-browsers`) skipped
// every live test, and the gate read that as a pass; pointing the lookup there then failed on the version, since
// the newest Playwright wants a revision that is not installed.
//
// So the browser is found, not assumed, and launched **by its executable**, which makes the Playwright version
// irrelevant:
//
//   - `WAC_CHROMIUM`, an executable, when it is set;
//   - otherwise the newest `chromium-*` revision under `$PLAYWRIGHT_BROWSERS_PATH`, or under
//     `$HOME/.cache/ms-playwright` where that is not set.

/** The executable, or why there is none. Exactly one of the two is not `""`. */
export type Chromium = { executablePath: string; cannot: string };

function isFile(path: string): boolean {
  try {
    return Deno.statSync(path).isFile;
  } catch {
    return false;
  }
}

/** The browser this run can drive, or why it cannot — printed by the caller, never swallowed. */
export function findChromium(): Chromium {
  // `playwright-core` reads where Chrome keeps its profile at import time, which wants `sys`; `wac task test`
  // does not grant it, so a live test runs under `deno test -A` and is skipped, saying so, otherwise.
  if (Deno.permissions.querySync({ name: "sys", kind: "homedir" }).state !== "granted") {
    return { executablePath: "", cannot: "no `sys` permission: run this file with `deno test -A`" };
  }
  return chromiumExecutable();
}

/** `findChromium` without the `sys` question, for a test that runs the executable itself rather than Playwright. */
export function chromiumExecutable(): Chromium {
  const named = Deno.env.get("WAC_CHROMIUM") ?? "";
  if (named !== "") {
    return isFile(named)
      ? { executablePath: named, cannot: "" }
      : { executablePath: "", cannot: `WAC_CHROMIUM names ${named}, which is not a file` };
  }
  const home = Deno.env.get("HOME") ?? "";
  const dir = Deno.env.get("PLAYWRIGHT_BROWSERS_PATH") || `${home}/.cache/ms-playwright`;
  let revisions: string[];
  try {
    revisions = [...Deno.readDirSync(dir)]
      .filter((e) => e.isDirectory && /^chromium-\d+$/.test(e.name))
      .map((e) => e.name)
      .sort((a, b) => Number(b.slice(9)) - Number(a.slice(9)));
  } catch {
    return { executablePath: "", cannot: `no ${dir} — run: ./node_modules/.bin/playwright install chromium` };
  }
  for (const r of revisions) {
    for (const sub of ["chrome-linux64/chrome", "chrome-linux/chrome", "chrome-mac/Chromium.app/Contents/MacOS/Chromium"]) {
      if (isFile(`${dir}/${r}/${sub}`)) return { executablePath: `${dir}/${r}/${sub}`, cannot: "" };
    }
  }
  return { executablePath: "", cannot: `no chromium executable under ${dir}` };
}

/** `chromium.launch`'s options for a found browser: its executable, and no proxy between it and our server. */
export function launchOptions(c: Chromium, args: string[] = ["--no-proxy-server"]): { executablePath: string; args: string[] } {
  return { executablePath: c.executablePath, args };
}
