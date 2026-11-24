// A host that cannot wait: an `async` program served without `SharedArrayBuffer` — design/system/0015 decision 4.
//
// The blocking host (`provider.ts`) parks its worker in `Atomics.wait` until the page answers, which needs shared
// memory, which needs a cross-origin isolated page. A frame that cannot be isolated — an opaque-origin sandbox, as
// wac-eth's reckon loads its apps in — has none, and `allow="cross-origin-isolated"` and `credentialless` do not
// give it any. wac-web's pages run there because they never wait: their `waitAny` answers `HOST_CANNOT_WAIT`, an
// `async` program hands control back, and the host runs it on with `__wacAdvance` once an answer has arrived. This
// is the same for a `main(Sys)`: the compiler already exports `__wacStart`/`__wacAdvance` for an `async main`
// (`packages/wacc/src/program.wac` `asyncAdapter`), so all that was missing is a host that drives them.
//
// **The handlers are the blocking host's own** (`browserWorld`), run in the same worker as the program and called
// directly, so a request means here exactly what it means there. The payload a handler reads and the answer it
// writes go through `payloadOf` and `answerOf`, which the blocking host uses on each side of its bridge.
//
// **An answer the handler has at once is delivered inside the request** — the clock, an argument, a write — as on
// every host. That is what lets a synchronous `.wait()` on one of those still work: `Args` reads its arguments that
// way. Anything else arrives between turns, and the program is run on. A synchronous `.wait()` on anything else
// cannot be answered here: the wait answers `HOST_CANNOT_WAIT`, and std says so.

import { type Handlers } from "./respond.ts";
import { faultOf } from "./faults.ts";
import { OP } from "./ops.ts";
import { answerOf, closerOf, failureText, flat, type Flat, payloadOf, WacExit } from "./provider.ts";
import { capRequest, type HostCapability, notProvided, versionMatches } from "./hosthttp.ts";
import { FAULT_UNSUPPORTED } from "./faults.ts";

/** What `waitAny` answers when it cannot wait: std's `HOST_CANNOT_WAIT()`. */
export const HOST_CANNOT_WAIT = -2;

const failed = (e: unknown): Flat => flat({ fault: faultOf(e), text: e instanceof Error ? e.message : String(e) });

/**
 * The host value an `async` program's `__wacStart` is handed, serving `world`'s handlers without blocking.
 *
 * `wake` is called when an answer has been delivered between turns: the caller runs the program on.
 */
export function asyncHostFor(
  app: Record<string, unknown>,
  world: Handlers,
  wake: () => void,
  provides: HostCapability[] = [],
): unknown {
  const make = app.__wacHost;
  const answered = app.__wacAnswered;
  if (typeof make !== "function" || typeof answered !== "function") return undefined;
  let h: unknown = undefined;
  /** Requests whose answer has not arrived, by the program's id for them, with what each asked. */
  const flights = new Map<number, number>();
  const deliver = (id: number, f: Flat) => {
    if (id === 0) return;
    (answered as CallableFunction)(h, id, f.fault, f.text, f.bytes, f.n, f.m, f.flags);
  };

  const request = (op: number, id: number, a64: bigint, b64: bigint, text: string, bytes: Uint8Array) => {
    if (op === 0) {
      // Dropped: its answer is not wanted, and what it opens is closed when it lands (below).
      flights.delete(id);
      return;
    }
    if (op === OP.CAPABILITY) {
      const cap = provides.find((c) => c.name === text);
      const versions = new TextDecoder().decode(bytes);
      if (cap === undefined) return deliver(id, flat(notProvided(text)));
      if (!versionMatches(cap, versions)) {
        return deliver(id, flat({ fault: FAULT_UNSUPPORTED, text: `${text} ${cap.version} does not satisfy ${versions}` }));
      }
      return deliver(id, flat({ n: BigInt(cap.base), m: BigInt(cap.count), text: cap.version }));
    }
    if (op === OP.SPAWN || op === OP.SPAWN_SELF) {
      // A child is a worker joined to its parent by shared memory, which is what this host is for not having.
      return deliver(id, flat({ fault: FAULT_UNSUPPORTED, text: "a page that is not cross-origin isolated cannot start a process" }));
    }
    const provided = provides.some((c) => op >= c.base && op < c.base + c.count);
    const payload = provided ? capRequest(a64, b64, text, bytes) : payloadOf(op, Number(a64), Number(b64), text, bytes);
    const handler = world[op];
    if (payload === null || handler === undefined) {
      return deliver(id, flat({ fault: FAULT_UNSUPPORTED, text: `this host serves no request ${op}` }));
    }
    let out: Uint8Array | Promise<Uint8Array>;
    try {
      out = handler(payload);
    } catch (e) {
      return deliver(id, failed(e));
    }
    if (out instanceof Uint8Array) return deliver(id, answerOf(op, out));
    flights.set(id, op);
    out.then(
      (got) => {
        if (!flights.delete(id)) {
          // Dropped before it landed: close what it opened, which nobody else will.
          const close = closerOf(op);
          const f = answerOf(op, got);
          if (close !== null && f.fault === 0) {
            const shut = world[close];
            try { void shut?.(new Uint8Array(new Int32Array([Number(f.n)]).buffer)); } catch { /* closed itself */ }
          }
          return;
        }
        deliver(id, answerOf(op, got));
        wake();
      },
      (e) => {
        if (!flights.delete(id)) return;
        deliver(id, failed(e));
        wake();
      },
    );
  };

  /** Which of `ids` has been answered, by its index — or `HOST_CANNOT_WAIT`: an answer comes between turns. */
  const waitAny = (ids: ArrayLike<number>, _millis: number): number => {
    const want = Array.from(ids);
    const gone = want.findIndex((id) => !flights.has(id));
    return gone >= 0 ? gone : HOST_CANNOT_WAIT;
  };
  const exitWith = (code: number) => { throw new WacExit(code); };
  const interrupted = (): boolean => false;
  h = (make as CallableFunction)(request, waitAny, exitWith, interrupted);
  return h;
}

/** How a run ended: its status, or what it failed with. */
export type Outcome = { ok: true; code: number } | { ok: false; error: string };

/**
 * Run an `async` program's `main(Sys)` on `world` and settle with how it ended — the non-blocking `callMain`.
 *
 * Refused, saying why, for a module that exports no `__wacStart`: a `main` that is not `async` waits by blocking,
 * and a host that cannot block can only stop it at its first wait.
 */
export function runAsync(app: Record<string, unknown>, world: Handlers, provides: HostCapability[] = []): Promise<Outcome> {
  return new Promise<Outcome>((settle) => {
    const start = app.__wacStart, advance = app.__wacAdvance, done = app.__wacDone, status = app.__wacStatus;
    if (typeof start !== "function" || typeof advance !== "function" || typeof done !== "function" ||
      typeof status !== "function") {
      settle({
        ok: false,
        error: "this page is not cross-origin isolated, so it cannot wait, and only an `async` main runs without " +
          "waiting — make main `async`, or serve the page with Cross-Origin-Opener-Policy: same-origin and " +
          "Cross-Origin-Embedder-Policy: require-corp",
      });
      return;
    }
    let run: unknown = null;
    let host: unknown = undefined;
    let over = false;
    let queued = false;
    const end = (o: Outcome) => {
      if (over) return;
      over = true;
      settle(o);
    };
    /** After a turn: settled, or waiting for an answer that will `wake` it. */
    const check = () => {
      if (over || !(done as CallableFunction)(run)) return;
      const code = Number((status as CallableFunction)(run));
      // **Not `__wacOutstanding`**, which `callMain` asks after a blocking `main`: driven through `__wacStart`, the
      // adapter's own continuation for `main`'s ticket is still counted when it reports done, so every program would
      // be told it left work. wac-web's driver, which runs the same exports, does not ask either.
      end({ ok: true, code });
    };
    const caught = (e: unknown) => {
      if (e instanceof WacExit) return end({ ok: true, code: e.code });
      end({ ok: false, error: failureText(app, e) });
    };
    const turn = () => {
      queued = false;
      if (over) return;
      try {
        run = (advance as CallableFunction)(run);
        check();
      } catch (e) {
        caught(e);
      }
    };
    // Between turns, never inside one: an answer that lands while the program is running waits for it to yield.
    const wake = () => {
      if (queued || over) return;
      queued = true;
      setTimeout(turn, 0);
    };
    try {
      host = asyncHostFor(app, world, wake, provides);
      run = (start as CallableFunction)(host);
      check();
    } catch (e) {
      caught(e);
    }
  });
}
