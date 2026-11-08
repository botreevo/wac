// `@kpstreams/core`'s answers to the questions wac-kps's own code answers, one line in, one line out.
//
//   parse <address>          →  `parse ok <ip> <port> <certhash>`  or  `parse err`
//   format <ip> <port> <ch>  →  `format <address>`
//   decode <certhash>        →  `decode <digest-hex>`  or  `decode err`
//   encode <digest-hex>      →  `encode <certhash>`
//   fp <digest-hex>          →  `fp <sdp fingerprint>`
//   pwd <digest-hex> <ufrag> →  `pwd <ice-pwd>`
//
// Batched: every line read, every answer written, then `DONE <n>` — so a run that stopped halfway cannot pass for
// one that agreed with everything.

import { parseAddress, formatAddress, decodeCerthash, encodeCerthash } from "@kpstreams/core";
import { digestToSdpFingerprint, deriveICEPwd } from "@kpstreams/core/webrtc";

const hex = (u8) => Buffer.from(u8).toString("hex");
const bytes = (h) => new Uint8Array(Buffer.from(h, "hex"));

const input = await new Promise((resolve) => {
  const chunks = [];
  process.stdin.on("data", (c) => chunks.push(c));
  process.stdin.on("end", () => resolve(Buffer.concat(chunks).toString()));
});
const lines = input.split("\n").filter((l) => l.length > 0);
const out = [];
for (const line of lines) {
  const [op, ...rest] = line.split(" ");
  try {
    if (op === "parse") {
      const a = parseAddress(rest.join(" "));
      out.push(`parse ok ${a.ip} ${a.port} ${a.certhash}`);
    } else if (op === "format") {
      out.push(`format ${formatAddress({ ip: rest[0], port: Number(rest[1]), certhash: rest[2] })}`);
    } else if (op === "decode") {
      out.push(`decode ${hex(decodeCerthash(rest[0]))}`);
    } else if (op === "encode") {
      out.push(`encode ${encodeCerthash(bytes(rest[0]))}`);
    } else if (op === "fp") {
      out.push(`fp ${digestToSdpFingerprint(bytes(rest[0]))}`);
    } else if (op === "pwd") {
      out.push(`pwd ${await deriveICEPwd(bytes(rest[0]), rest[1])}`);
    } else {
      out.push(`${op} unknown`);
    }
  } catch {
    out.push(`${op} err`);
  }
}
out.push(`DONE ${lines.length}`);
process.stdout.write(out.join("\n") + "\n");
