// Admission, as the page sees it: a subject and settings in, `{ code, cid, lines }` out, `code` as `claim admit`'s
// exit code (0 admitted). It runs cmd/web.wac, built with wac's `--target browser --layout files` into `admit/`
// (extension/build.sh), in a hidden frame of this extension's own origin: its program runs in a worker that may
// block, its files are this extension's storage (OPFS), and its HTTP is the browser's fetch. So what it keeps is
// where the page reads it: the blocks in `store/`, the light client's state in `lc.state` (resumed next time), and an
// admitted tree below `trees/<cid>/`, written from blocks each checked against its CID.

const TIMEOUT_MS = 180000;

/** The arguments `web` is run with, from the settings. */
export function argsFor(settings, subject, role) {
  const a = [subject, role, '--policy-text', settings.policy || '{}', '--store', 'store', '--out-root', 'trees'];
  // The light client's state is kept once a checkpoint is set, and resumed from after that. Without a checkpoint (a
  // devnet, which has no beacon chain) there is no light client, and reads are of the node's latest block.
  if (settings.checkpoint && String(settings.checkpoint).trim() !== '') a.push('--state', 'lc.state');
  const opt = (flag, v) => { if (v && String(v).trim() !== '') a.push(flag, String(v).trim()); };
  opt('--checkpoint', settings.checkpoint);
  opt('--beacon-url', settings.beaconUrl);
  opt('--rpc', settings.rpc);
  opt('--registry', settings.registry);
  opt('--code-hash', settings.codeHash);
  opt('--now', settings.now);
  for (const m of String(settings.mirrors || '').split(/\s+/)) opt('--mirror', m);
  // Manifests (docs/discovery.md): `web` follows them and adds the mirrors they lead to; what they serve is checked.
  for (const m of String(settings.mirrorsFrom || '').split(/\s+/)) opt('--mirrors-from', m);
  return a;
}

/**
 * What the decision is as of, from admission's "as of …" line: the execution block and its time, the beacon slot and
 * its time; null for what it did not say.
 */
export function asOfIn(lines) {
  const l = lines.find((x) => x.startsWith('as of '));
  if (!l) return null;
  const num = (re) => { const m = re.exec(l); return m ? Number(m[1]) : null; };
  return { block: num(/execution block (\d+)/), blockTime: num(/execution block \d+ \(time (\d+)\)/),
           slot: num(/beacon slot (\d+)/), slotTime: num(/beacon slot \d+ \(time (\d+)\)/) };
}

/** The account `web` printed, read back: its lines, its exit code, and the CID it admitted. */
export function readAccount(text) {
  const lines = text.split('\n').map((l) => l.replace(/\s+$/, '')).filter((l) => l !== '');
  const exit = /^\[exit (-?\d+)\]$/m.exec(text);
  const admitted = /^web: admitted (\S+)$/m.exec(text);
  return {
    code: exit ? Number(exit[1]) : 3,
    cid: exit && Number(exit[1]) === 0 && admitted ? admitted[1] : null,
    lines: lines.filter((l) => !/^\[exit -?\d+\]$/.test(l)),
    asOf: asOfIn(lines),
  };
}

export async function admit(settings, subject, role) {
  const q = argsFor(settings, subject, role).map((x) => 'a=' + encodeURIComponent(x)).join('&');
  const frame = document.createElement('iframe');
  frame.hidden = true;
  frame.src = `admit/index.html?${q}`;
  document.body.appendChild(frame);
  try {
    const t0 = Date.now();
    while (Date.now() - t0 < TIMEOUT_MS) {
      await new Promise((ok) => setTimeout(ok, 200));
      const out = frame.contentDocument && frame.contentDocument.getElementById('out');
      const text = out ? out.textContent : '';
      if (/^\[exit -?\d+\]$/m.test(text)) return readAccount(text);
    }
    return { code: 3, cid: null, lines: [`admission did not finish in ${TIMEOUT_MS / 1000} s`, 'REFUSED'] };
  } finally {
    frame.remove();
  }
}
