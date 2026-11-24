// The reference KPS listener, `@kpstreams/server`, as an echo server: the same behaviour as wac-kps's cmd/echo.wac,
// so a client can be run against both and the results compared.
//
//   node js-echo-server.mjs <dir> [port]       prints `kps <address>`
import { listen } from "@kpstreams/server";
import { join } from "node:path";
const dir = process.argv[2];
const ln = await listen({ port: Number(process.argv[3] ?? 41999), address: "127.0.0.1",
                          certPath: join(dir, "kps-cert.pem"), keyPath: join(dir, "kps-key.pem") });
console.log(`kps ${ln.address("127.0.0.1")}`);
for (;;) {
  const conn = await ln.accept();
  (async () => {
    for (;;) {
      let s;
      try { s = await conn.acceptStream(); } catch { return; }
      s.readable.pipeTo(s.writable).catch(() => {});
    }
  })();
  (async () => {
    for (;;) {
      try { await conn.sendDatagram(await conn.receiveDatagram()); } catch { return; }
    }
  })();
}
