// `wac.http ^1` as the page answers it (`host/hosthttp.ts`), over a stand-in `fetch` — the handlers, the wire, and
// the worker's lookup, without a browser. `browser_live.test.ts` drives the same thing through Chromium.
import { CHUNK } from "../host/layout.ts";
import {
  capAnswer, capRequest, HOST_HTTP, HTTP_CLOSE, HTTP_OPEN, HTTP_READ, httpHandlers, readCapAnswer, readCapRequest,
  versionMatches,
} from "../host/hosthttp.ts";
import { Faulted } from "../host/faults.ts";

function assert(ok: boolean, msg: string): void {
  if (!ok) throw new Error(msg);
}

const enc = new TextEncoder();
const dec = new TextDecoder();

/** A `fetch` that answers from a function and records what it was asked. */
function standIn(answer: (req: Request) => Response | Promise<Response>) {
  const asked: Request[] = [];
  const f = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init);
    asked.push(req);
    return await answer(req);
  }) as typeof fetch;
  return { f, asked };
}

const open = (method: string, url: string, headers: string[], body = "") =>
  capRequest(0n, 0n, `${method} ${url}`, enc.encode(headers.map((h) => h + "\r\n").join("") + "\r\n" + body));

async function readAll(h: Record<number, (p: Uint8Array) => Promise<Uint8Array>>, handle: bigint) {
  const pieces: Uint8Array[] = [];
  for (;;) {
    const a = readCapAnswer(await h[HTTP_READ](capRequest(handle, 0n, "", new Uint8Array(0))));
    if (a.flags & 1) break;
    assert(a.bytes.length <= CHUNK, `a piece of ${a.bytes.length} bytes is more than a chunk`);
    pieces.push(a.bytes);
  }
  return { pieces, body: dec.decode(new Uint8Array(pieces.flatMap((p) => [...p]))) };
}

Deno.test("the wire carries every field both ways", () => {
  const q = readCapRequest(capRequest(7n, -3n, "GET http://x/", enc.encode("a: b\r\n\r\n")));
  assert(q.a === 7n && q.b === -3n && q.text === "GET http://x/" && dec.decode(q.bytes) === "a: b\r\n\r\n", "request");
  const a = readCapAnswer(capAnswer({ n: 9n, m: 200n, flags: 1, text: "u", bytes: enc.encode("z") }));
  assert(a.n === 9n && a.m === 200n && a.flags === 1 && a.text === "u" && dec.decode(a.bytes) === "z", "answer");
});

Deno.test("a lookup is by major version", () => {
  for (const v of ["^1", "1", "^1.2", "1.0.0", "*", ""]) assert(versionMatches(HOST_HTTP, v), `${v} should match`);
  for (const v of ["^2", "2.0.0", "0"]) assert(!versionMatches(HOST_HTTP, v), `${v} should not match`);
});

Deno.test("open sends the method, URL, headers and body, and answers status, URL and headers", async () => {
  const { f, asked } = standIn(() =>
    new Response("hello", { status: 201, headers: { "x-answer": "42", "content-type": "text/plain" } })
  );
  const h = httpHandlers(f);
  const a = readCapAnswer(await h[HTTP_OPEN](open("POST", "http://example.test/p?q=1", ["X-One: 1", "Accept: */*"], "body!")));
  assert(a.m === 201n, `status ${a.m}`);
  assert(a.text === "http://example.test/p?q=1", `url ${a.text}`);
  const lines = dec.decode(a.bytes);
  assert(lines.includes("x-answer: 42\r\n") && lines.includes("content-type: text/plain\r\n"), `headers ${lines}`);
  const req = asked[0];
  assert(req.method === "POST" && req.url === "http://example.test/p?q=1", `${req.method} ${req.url}`);
  assert(req.headers.get("x-one") === "1" && req.headers.get("accept") === "*/*", "request headers");
  assert(await req.text() === "body!", "request body");
  const { body } = await readAll(h, a.n);
  assert(body === "hello", `body ${body}`);
});

Deno.test("headers a page may not set are dropped, the rest kept", async () => {
  const { f, asked } = standIn(() => new Response(""));
  const h = httpHandlers(f);
  await h[HTTP_OPEN](open("GET", "http://example.test/", [
    "Host: elsewhere", "Content-Length: 3", "Connection: close", "Transfer-Encoding: chunked", "Proxy-Thing: x",
    "Sec-Fetch-Mode: no", "X-Kept: yes",
  ]));
  const got = [...asked[0].headers.keys()];
  assert(got.length === 1 && got[0] === "x-kept", `sent ${got.join(", ")}`);
});

Deno.test("a body larger than a chunk comes back in chunks, and whole", async () => {
  const big = "abcdefghij".repeat(CHUNK / 4);   // 2.5 chunks
  const { f } = standIn(() => new Response(big));
  const h = httpHandlers(f);
  const a = readCapAnswer(await h[HTTP_OPEN](open("GET", "http://example.test/big", [])));
  const { pieces, body } = await readAll(h, a.n);
  assert(body === big, `the body came back ${body.length} bytes, not ${big.length}`);
  assert(pieces.length >= 3, `${pieces.length} pieces for ${big.length} bytes`);
});

Deno.test("a refusal the page is told about — CORS among them — is UNREACHABLE, worded exactly", async () => {
  const { f } = standIn(() => { throw new TypeError("Failed to fetch"); });
  const h = httpHandlers(f);
  let caught: unknown = null;
  try {
    await h[HTTP_OPEN](open("GET", "http://elsewhere.test/", []));
  } catch (e) {
    caught = e;
  }
  assert(caught instanceof Faulted, `threw ${caught}`);
  assert((caught as Faulted).fault === 16, `fault ${(caught as Faulted).fault}`);
  assert((caught as Faulted).message === "network error or CORS refusal", (caught as Faulted).message);
});

Deno.test("close abandons the body, and the handle is gone after", async () => {
  let aborted = false;
  const { f } = standIn((req) => {
    req.signal.addEventListener("abort", () => { aborted = true; });
    return new Response(new ReadableStream({ pull: () => new Promise(() => {}) }));
  });
  const h = httpHandlers(f);
  const a = readCapAnswer(await h[HTTP_OPEN](open("GET", "http://example.test/slow", [])));
  await h[HTTP_CLOSE](capRequest(a.n, 0n, "", new Uint8Array(0)));
  assert(aborted, "the request was not aborted");
  let caught = false;
  try {
    await h[HTTP_READ](capRequest(a.n, 0n, "", new Uint8Array(0)));
  } catch {
    caught = true;
  }
  assert(caught, "a closed handle was still read");
});
