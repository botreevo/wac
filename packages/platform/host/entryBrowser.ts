// The two halves of a built program, in a page.
//
// Same bridge, same opcodes, same capability structs. What differs from Deno and Node is
// smaller than it looks: the worker is a web `Worker` from a blob URL, and the page checks
// `crossOriginIsolated` before doing anything, because without it `SharedArrayBuffer` is
// not constructible and the failure would otherwise be a bare TypeError from `newBridge`.
//
// The worker half is unchanged in shape from Deno's: a message brings the buffer, the
// application runs to completion on a thread that is allowed to block, and the result goes
// back. `Atomics.wait` throws on a page's main thread, which is exactly why the split
// exists and why the page must not be the one running wac.

import { bridgeOf, newBridge } from "./layout.ts";
import { serveHostCalls } from "./respond.ts";
import { browserWorld, type BrowserWorldOptions } from "./browser.ts";
import { callMain, mainArgs, WacExit } from "./provider.ts";
import { HOST_HTTP, type HostCapability } from "./hosthttp.ts";
import type { AppModule } from "./entry.ts";
import { runAsync } from "./asynchost.ts";
import type { DirHandle } from "./browser.ts";

/** `provides`: the capabilities the page answers by name (`hosthttp.ts`), which the worker's host offers. */
type Start = { sab: SharedArrayBuffer; child?: boolean; provides?: HostCapability[] };
/**
 * **Or no shared memory at all**, for a page that is not cross-origin isolated (`asynchost.ts`): the worker serves the
 * program itself, with `browserWorld` handed what the page would have handed it, and sends back what it writes.
 * `has` says which of the page's callbacks exist, so the world behaves as it would with the page's own options.
 */
type StartAsync = {
  async: true;
  args: (string | Uint8Array)[];
  root?: DirHandle;
  writable?: boolean;
  http?: boolean;
  cwd?: string;
  has: { write: boolean; writeErr: boolean; warn: boolean; closeOutput: boolean };
  /** Where the worker's file really is, when it was started from its source instead (an opaque frame). */
  base?: string;
};
/** What an async worker sends the page besides its result. */
type Said = { said: "write" | "writeErr"; bytes: Uint8Array } | { said: "warn"; line: string } | { said: "close"; toErr: boolean };
type Result = { ok: true; code: number } | { ok: false; error: string };

/**
 * The worker half. Call this at module scope, before awaiting anything.
 *
 * The handler has to be installed synchronously: a generated program suspends at its own
 * top-level `await WebAssembly.instantiate`, and a `postMessage` that arrives during that
 * suspension is dropped. `packages/stream`'s README records the same trap, and the Deno
 * launcher was bitten by it once — it worked one run in three.
 */
export function runAsWorkerBrowser(load: () => Promise<AppModule>): void {
  // `self` is a worker scope here, which Deno's default library does not know while
  // type-checking this file — the same cast `entry.ts` makes, for the same reason.
  const scope = self as unknown as {
    onmessage: ((e: MessageEvent) => void) | null;
    postMessage(m: Result): void;
  };
  // "This bundle parsed and evaluated", before the bridge has arrived and before the application
  // runs. It is the one fact a parent cannot otherwise learn, and `children.ts` waits for it or for
  // the load error before answering `spawn` — so a page that spawns a source which is not
  // JavaScript gets a failed child rather than a dead parent. wac-mono issue 0021.
  (scope as unknown as { postMessage(m: unknown): void }).postMessage({ ready: true });
  scope.onmessage = (ev: MessageEvent) => {
    if ((ev.data as StartAsync).async === true) return runAsyncWorker(ev.data as StartAsync, load, (m) => (scope as unknown as { postMessage(m: unknown): void }).postMessage(m));
    const start = ev.data as Start;
    void (async () => {
      const b = bridgeOf(start.sab);
      try {
        const app = await load();
        const asApp = app as unknown as Record<string, unknown>;
        const code = callMain(b, asApp, mainArgs(b, asApp, start.provides ?? []));
        scope.postMessage({ ok: true, code });
      } catch (e) {
        if (e instanceof WacExit) { scope.postMessage({ ok: true, code: e.code }); return; }
        scope.postMessage({
          ok: false,
          error: e instanceof Error ? `${e.message}\n${e.stack ?? ""}` : String(e),
        });
      }
    })();
  };
}

/** The worker half without shared memory: the program and its host in this worker (`asynchost.ts`). */
function runAsyncWorker(start: StartAsync, load: () => Promise<AppModule>, post: (m: unknown) => void): void {
  const say = (m: Said) => post(m);
  if (start.base !== undefined) (globalThis as unknown as { __wacBase?: string }).__wacBase = start.base;
  void (async () => {
    try {
      const app = await load() as unknown as Record<string, unknown>;
      const world = browserWorld({
        args: start.args,
        root: start.root,
        writable: start.writable,
        http: start.http,
        cwd: start.cwd,
        write: start.has.write ? (bytes) => say({ said: "write", bytes }) : undefined,
        writeErr: start.has.writeErr ? (bytes) => say({ said: "writeErr", bytes }) : undefined,
        warn: start.has.warn ? (line) => say({ said: "warn", line }) : undefined,
        closeOutput: start.has.closeOutput ? (toErr) => say({ said: "close", toErr }) : undefined,
      });
      post(await runAsync(app, world, start.http ? [HOST_HTTP] : []));
    } catch (e) {
      post({ ok: false, error: e instanceof Error ? `${e.message}\n${e.stack ?? ""}` : String(e) });
    }
  })();
}

/** What a page needs to say about the environment it is offering. */
export type PageOptions = BrowserWorldOptions & {
  /** The worker's source. The build inlines the whole program here. */
  workerSource?: string;
  /**
   * **Or where the worker is**, a file beside the page — `--layout files`, for a page under a CSP that refuses a
   * `blob:` worker, as a Manifest V3 extension's does. One of the two; the source wins when both are given. A page
   * started this way has no source to hand `spawnSelf`, which is refused in it.
   */
  workerUrl?: string | URL;
};

/**
 * The launcher half: serve capabilities on the page's thread, run the worker, resolve with
 * the application's exit code.
 *
 * Never blocks. `serveHostCalls` waits with `Atomics.waitAsync`, so the event loop keeps
 * turning and the asynchronous work a capability needs — an OPFS read, say — can actually
 * happen while the worker is parked waiting for it.
 */
export async function runInPage(opts: PageOptions): Promise<number> {
  // Another one Deno's library does not declare, because it is a page property.
  const isolated = (globalThis as unknown as { crossOriginIsolated?: boolean }).crossOriginIsolated;
  // **Not isolated is not the end**: an `async` main runs without waiting (`asynchost.ts`), and one that is not is
  // refused there, saying both ways out.
  if (isolated !== true) return await runInPageAsync(opts);

  const bridge = newBridge();
  // `selfSource` so `spawnSelf` has something to run: a page has no filesystem of programs, and
  // this is the program. `opts` already carries the bundle — it is what the launcher starts.
  const responder = serveHostCalls(bridge, browserWorld({ ...opts, selfSource: opts.workerSource }));

  if (opts.workerSource === undefined && opts.workerUrl === undefined) {
    throw new Error("runInPage: neither a worker's source nor where it is");
  }
  const url = opts.workerSource !== undefined
    ? URL.createObjectURL(new Blob([opts.workerSource], { type: "text/javascript" }))
    : String(opts.workerUrl);
  const worker = new Worker(url, { type: "module" });
  try {
    const code = await new Promise<number>((resolve, reject) => {
      worker.addEventListener("message", (ev: MessageEvent) => {
        const r = ev.data as Result | { ready: true };
        if ("ready" in r) return;   // the load notice, which the launcher has no use for
        if (r.ok) resolve(r.code);
        else reject(new Error(r.error));
      });
      worker.addEventListener("error", (e: ErrorEvent) => {
        // Contained, or the page reports it twice: once as the program's failure and once as an
        // uncaught error of its own.
        e.preventDefault();
        reject(new Error(e.message));
      });
      worker.postMessage({ sab: bridge.sab, provides: opts.http ? [HOST_HTTP] : [] } as Start);
    });
    return code;
  } finally {
    responder.stop();
    worker.terminate();
    if (opts.workerSource !== undefined) URL.revokeObjectURL(url);
  }
}

/**
 * `runInPage` for a page that is not cross-origin isolated: the worker serves its program itself, and the page only
 * shows what it writes. Spawning is refused there, and so is a `main` that is not `async`.
 */
async function runInPageAsync(opts: PageOptions): Promise<number> {
  if (opts.workerSource === undefined && opts.workerUrl === undefined) {
    throw new Error("runInPage: neither a worker's source nor where it is");
  }
  // **An opaque origin refuses a module worker from a `blob:` URL, and one by URL from any server**, which is another
  // origin to it — and takes one from a `data:` URL. Measured in Chromium in a `sandbox="allow-scripts"` frame, which
  // is the frame this path exists for. So there a worker beside the page (`--layout files`) is fetched — a CORS read
  // the server allows or refuses — and started from its source, told where it really is so it finds `app.wasm`.
  const opaque = (globalThis as unknown as { origin?: string }).origin === "null";
  let source = opts.workerSource;
  let base: string | undefined = undefined;
  if (source === undefined && opaque) {
    base = String(new URL(String(opts.workerUrl), location.href));
    const res = await fetch(base);
    if (!res.ok) throw new Error(`${base}: ${res.status}`);
    source = await res.text();
  }
  const url = source === undefined
    ? String(opts.workerUrl)
    : opaque
    ? "data:text/javascript;base64," + base64(new TextEncoder().encode(source))
    : URL.createObjectURL(new Blob([source], { type: "text/javascript" }));
  const worker = new Worker(url, { type: "module" });
  try {
    return await new Promise<number>((resolve, reject) => {
      worker.addEventListener("message", (ev: MessageEvent) => {
        const m = ev.data as Result | Said | { ready: true };
        if ("ready" in m) return;
        if ("said" in m) {
          if (m.said === "warn") void opts.warn?.(m.line);
          else if (m.said === "close") opts.closeOutput?.(m.toErr);
          else if (m.said === "write") void opts.write?.(m.bytes);
          else void opts.writeErr?.(m.bytes);
          return;
        }
        if (m.ok) resolve(m.code);
        else reject(new Error(m.error));
      });
      worker.addEventListener("error", (e: ErrorEvent) => {
        e.preventDefault();
        reject(new Error(e.message));
      });
      const start: StartAsync = {
        async: true,
        args: opts.args ?? [],
        root: opts.root,
        writable: opts.writable,
        http: opts.http === true,
        cwd: opts.cwd,
        has: { write: !!opts.write, writeErr: !!opts.writeErr, warn: !!opts.warn, closeOutput: !!opts.closeOutput },
        base,
      };
      worker.postMessage(start);
    });
  } finally {
    worker.terminate();
    if (url.startsWith("blob:")) URL.revokeObjectURL(url);
  }
}

function base64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

/**
 * **Arguments from `args.json` beside the page**, an array of strings, when there is one — for a page whose URL is
 * not the place for them (an extension's own page) — and from the query string otherwise.
 */
export async function argsFromPage(search: string, base: string | URL): Promise<string[]> {
  try {
    const res = await fetch(new URL("args.json", base));
    if (res.ok) {
      const got = await res.json();
      if (Array.isArray(got) && got.every((a) => typeof a === "string")) return got;
      throw new Error("args.json must be an array of strings");
    }
  } catch (e) {
    if (e instanceof Error && e.message.startsWith("args.json")) throw e;
  }
  return argsFromLocation(search);
}

/** Arguments from the query string: `?a=one&a=two` becomes `["one", "two"]`. */
export function argsFromLocation(search: string): string[] {
  return new URLSearchParams(search).getAll("a");
}
