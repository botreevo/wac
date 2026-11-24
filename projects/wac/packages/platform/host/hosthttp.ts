/**
 * `wac.http ^1` — HTTP as a capability a host provides by name (`capability(host, "wac.http", "^1")`), answered in a
 * page by the browser's `fetch`.
 *
 * **Why a capability and not sockets.** A page has no TCP, and `browser.ts` refuses `CONNECT` rather than fake one
 * over `fetch` (its header says why: a byte stream is not what `fetch` is). A request and its response *are*: so this
 * is HTTP at HTTP's level, and `packages/http`'s client and `packages/fetch` ask for it first and fall back to
 * sockets where a host does not provide it — every host but the browser's. Offered only when the build granted
 * `--allow-net`: it is network access like any other.
 *
 * Three requests from `base` (which callers take from `capability`'s answer, never this file's number):
 *
 * - **+0 open** — `text` is `"METHOD URL"`; `bytes` is the request's header lines, `Name: value\r\n` each, then an
 *   empty line, then the body, whole; `b` is a deadline in milliseconds for the whole request, body reads included,
 *   or negative for none. Answers `n` a handle, `m` the status, `text` the URL the response came from, and `bytes`
 *   the response's header lines in the same form. Running out is `FAULT_TIMED_OUT`, `timed out after <ms>ms`.
 * - **+1 read** — `a` the handle. Answers the body's next piece in `bytes`, at most `CHUNK`, and `flags` 1 once it
 *   has ended (with no bytes).
 * - **+2 close** — `a` the handle: the body is abandoned and the request aborted.
 *
 * What the program sees is what the *browser* exposes, which is not always what the server sent:
 * - **Redirects are followed** (`fetch`'s default), so the status is the last response's and `text` names its URL.
 * - **Response headers are the ones a page may read**: never `Set-Cookie`, and cross-origin only the
 *   CORS-safelisted ones plus what `Access-Control-Expose-Headers` lists.
 * - **Request headers a page may not set are dropped**, silently: `Host`, `Content-Length`, `Connection`,
 *   `Transfer-Encoding` and the rest of the forbidden list. A client that writes them for a socket (`packages/http`
 *   does) loses nothing — the browser writes its own.
 * - **A request the browser refuses to complete** — no route, DNS, TLS, or a cross-origin response without CORS
 *   headers, which a page is not told apart — is `FAULT_UNREACHABLE`, worded exactly
 *   `network error or CORS refusal`.
 */
import { CHUNK } from "./layout.ts";
import { i32le, i64le, readI32le, readI64le } from "./call.ts";
import { Faulted } from "./faults.ts";

/** What a host provides by name: answered by `capability`, its requests numbered `base` up to `base + count`. */
export type HostCapability = { name: string; version: string; base: number; count: number };

/**
 * Below the range a parent hands out (`PROVIDED_FROM`, 1048576, in std), and far above the host's own opcodes. A
 * caller never writes it: `capability` answers it.
 */
export const HOST_HTTP: HostCapability = { name: "wac.http", version: "1.0.0", base: 4096, count: 3 };
export const HTTP_OPEN = HOST_HTTP.base;
export const HTTP_READ = HOST_HTTP.base + 1;
export const HTTP_CLOSE = HOST_HTTP.base + 2;

const FAULT_OTHER = 5;
const FAULT_UNSUPPORTED = 9;
const FAULT_UNREACHABLE = 16;
const FAULT_TIMED_OUT = 17;

/** Whether a host providing `cap` satisfies `versions` — `^1`, `^1.2`, `1`, `1.0.0`, `*`: by major version. */
export function versionMatches(cap: HostCapability, versions: string): boolean {
  const v = versions.trim().replace(/^[\^~=v]+/, "");
  if (v === "" || v === "*") return true;
  const want = v.split(".")[0];
  return want === cap.version.split(".")[0];
}

// ── The wire between the worker and the page: one request, one answer ─────────────────────────────

const enc = new TextEncoder();
const dec = new TextDecoder();

/** A request to a provided capability: `a`, `b`, `text` and `bytes` as the program asked them. */
export function capRequest(a: bigint, b: bigint, text: string, bytes: Uint8Array): Uint8Array {
  const t = enc.encode(text);
  const out = new Uint8Array(20 + t.length + bytes.length);
  out.set(i64le(a), 0);
  out.set(i64le(b), 8);
  out.set(i32le(t.length), 16);
  out.set(t, 20);
  out.set(bytes, 20 + t.length);
  return out;
}

export type CapRequest = { a: bigint; b: bigint; text: string; bytes: Uint8Array };

export function readCapRequest(p: Uint8Array): CapRequest {
  const tl = readI32le(p, 16);
  return { a: readI64le(p, 0), b: readI64le(p, 8), text: dec.decode(p.subarray(20, 20 + tl)), bytes: p.slice(20 + tl) };
}

export type CapAnswer = { n?: bigint; m?: bigint; flags?: number; text?: string; bytes?: Uint8Array };

export function capAnswer(x: CapAnswer): Uint8Array {
  const t = enc.encode(x.text ?? "");
  const bytes = x.bytes ?? new Uint8Array(0);
  const out = new Uint8Array(24 + t.length + bytes.length);
  out.set(i64le(x.n ?? 0n), 0);
  out.set(i64le(x.m ?? 0n), 8);
  out.set(i32le(x.flags ?? 0), 16);
  out.set(i32le(t.length), 20);
  out.set(t, 24);
  out.set(bytes, 24 + t.length);
  return out;
}

export function readCapAnswer(p: Uint8Array): Required<CapAnswer> {
  const tl = readI32le(p, 20);
  return {
    n: readI64le(p, 0),
    m: readI64le(p, 8),
    flags: readI32le(p, 16),
    text: dec.decode(p.subarray(24, 24 + tl)),
    bytes: p.slice(24 + tl),
  };
}

// ── The page's side: `fetch` ──────────────────────────────────────────────────────────────────────

/**
 * Request headers a page cannot set (the Fetch standard's forbidden request-header names), dropped here so every
 * browser — and a test's stand-in `fetch` — sees the same request. The browser would drop most of them anyway.
 */
const FORBIDDEN = new Set([
  "accept-charset", "accept-encoding", "access-control-request-headers", "access-control-request-method",
  "connection", "content-length", "cookie", "cookie2", "date", "dnt", "expect", "host", "keep-alive", "origin",
  "referer", "set-cookie", "te", "trailer", "transfer-encoding", "upgrade", "via",
]);
const forbidden = (name: string) => {
  const n = name.toLowerCase();
  return FORBIDDEN.has(n) || n.startsWith("proxy-") || n.startsWith("sec-");
};

/** The header lines and the body after them: `Name: value\r\n`… `\r\n` body. */
function splitHead(bytes: Uint8Array): { headers: [string, string][]; body: Uint8Array } {
  let end = -1;
  for (let i = 0; i + 1 < bytes.length; i++) {
    if (bytes[i] === 13 && bytes[i + 1] === 10 && (i === 0 || (i >= 2 && bytes[i - 2] === 13 && bytes[i - 1] === 10))) {
      end = i;
      break;
    }
  }
  if (end < 0) throw new Faulted(FAULT_OTHER, "wac.http: a request's header block has no blank line after it");
  const headers: [string, string][] = [];
  for (const line of dec.decode(bytes.subarray(0, end)).split("\r\n")) {
    if (line === "") continue;
    const colon = line.indexOf(":");
    if (colon <= 0) throw new Faulted(FAULT_OTHER, `wac.http: a header line without a name: ${JSON.stringify(line)}`);
    headers.push([line.slice(0, colon).trim(), line.slice(colon + 1).trim()]);
  }
  return { headers, body: bytes.slice(end + 2) };
}

/**
 * The page's handlers for `wac.http`, keyed by request number, over `fetchFn` — the page's own `fetch` unless a test
 * hands one in. Each open response is held until it is read to its end or closed.
 */
export function httpHandlers(fetchFn: typeof fetch = globalThis.fetch.bind(globalThis)): Record<number, (p: Uint8Array) => Promise<Uint8Array>> {
  type Open = {
    reader: ReadableStreamDefaultReader<Uint8Array> | null;
    held: Uint8Array;
    abort: AbortController;
    timer: ReturnType<typeof setTimeout> | undefined;
    ms: number;
  };
  /** A deadline's abort, told apart from a `close`: the reason is this. */
  const DEADLINE = "wac.http deadline";
  const ranOut = (abort: AbortController) => abort.signal.aborted && abort.signal.reason === DEADLINE;
  const finish = (id: number) => {
    const o = open.get(id);
    if (o !== undefined && o.timer !== undefined) clearTimeout(o.timer);
    open.delete(id);
  };
  const open = new Map<number, Open>();
  let next = 1;

  return {
    [HTTP_OPEN]: async (p) => {
      const q = readCapRequest(p);
      const space = q.text.indexOf(" ");
      if (space <= 0) throw new Faulted(FAULT_OTHER, `wac.http: open wants "METHOD URL", not ${JSON.stringify(q.text)}`);
      const method = q.text.slice(0, space);
      const url = q.text.slice(space + 1);
      const { headers, body } = splitHead(q.bytes);
      const h = new Headers();
      for (const [name, value] of headers) if (!forbidden(name)) h.append(name, value);
      const abort = new AbortController();
      const ms = Number(q.b);
      // **One deadline for the request, body included**: the timer stays until the body ends or is closed.
      const timer = ms >= 0 ? setTimeout(() => abort.abort(DEADLINE), ms) : undefined;
      let res: Response;
      try {
        res = await fetchFn(url, {
          method,
          headers: h,
          // A fresh `ArrayBuffer`, which is what `BodyInit` takes: the request's bytes may be a view of a shared one.
          body: method === "GET" || method === "HEAD" ? undefined : new Uint8Array(body).buffer,
          redirect: "follow",
          signal: abort.signal,
        });
      } catch (e) {
        if (timer !== undefined) clearTimeout(timer);
        if (ranOut(abort)) throw new Faulted(FAULT_TIMED_OUT, `timed out after ${ms}ms`);
        // A `TypeError` is every refusal a page is told about, CORS included and indistinguishably.
        if (e instanceof TypeError) throw new Faulted(FAULT_UNREACHABLE, "network error or CORS refusal");
        throw new Faulted(FAULT_OTHER, `wac.http: ${e instanceof Error ? e.message : String(e)}`);
      }
      const id = next++;
      open.set(id, { reader: res.body === null ? null : res.body.getReader(), held: new Uint8Array(0), abort, timer, ms });
      let lines = "";
      res.headers.forEach((value, name) => { lines += `${name}: ${value}\r\n`; });
      return capAnswer({ n: BigInt(id), m: BigInt(res.status), text: res.url || url, bytes: enc.encode(lines) });
    },

    [HTTP_READ]: async (p) => {
      const q = readCapRequest(p);
      const o = open.get(Number(q.a));
      if (o === undefined) throw new Faulted(FAULT_OTHER, `wac.http: no open response ${q.a}`);
      if (o.held.length === 0 && o.reader !== null) {
        let r: ReadableStreamReadResult<Uint8Array>;
        try {
          r = await o.reader.read();
        } catch (e) {
          finish(Number(q.a));
          if (ranOut(o.abort)) throw new Faulted(FAULT_TIMED_OUT, `timed out after ${o.ms}ms`);
          throw new Faulted(FAULT_UNREACHABLE, `wac.http: the body stopped arriving — ${e instanceof Error ? e.message : String(e)}`);
        }
        if (r.done) {
          finish(Number(q.a));
          return capAnswer({ flags: 1 });
        }
        o.held = r.value;
      }
      if (o.held.length === 0) {
        finish(Number(q.a));
        return capAnswer({ flags: 1 });
      }
      // **At most a chunk per answer**: a response piece can be larger than the buffers the bridge pools.
      const piece = o.held.slice(0, CHUNK);
      o.held = o.held.subarray(piece.length);
      return capAnswer({ bytes: piece });
    },

    [HTTP_CLOSE]: (p) => {
      const q = readCapRequest(p);
      const o = open.get(Number(q.a));
      finish(Number(q.a));
      if (o !== undefined) {
        o.abort.abort();
        o.reader?.cancel().catch(() => {});
      }
      return Promise.resolve(capAnswer({}));
    },
  };
}

/** The answer for a capability this host does not provide, worded as every host words it. */
export function notProvided(name: string): { fault: number; text: string } {
  return { fault: FAULT_UNSUPPORTED, text: `no capability ${name} on this host` };
}
