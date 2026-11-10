// The extension's page: settings, a subject to open, admission's account, and the admitted app in the sandbox loader.
// The order is fixed: admit, then read the admitted tree from OPFS, then show it. An app is never shown otherwise.
import { admit } from './admission.js';
import { openTree } from './tree.js';
import { buildDocument, typeOf } from './build-doc.js';

const $ = (id) => document.getElementById(id);
const FIELDS = ['checkpoint', 'beaconUrl', 'rpc', 'registry', 'codeHash', 'mirrors', 'policy', 'now'];
// No mirror by default: a public gateway is a choice to make, and one that is down slows every admission until it is
// left out. The settings suggest one.
const DEFAULTS = { mirrors: '', policy: '{ signers: {}, roles: {} }' };

async function loadSettings() {
  const got = await chrome.storage.local.get('settings');
  return { ...DEFAULTS, ...(got.settings || {}) };
}

async function saveSettings() {
  const s = {};
  for (const f of FIELDS) s[f] = $(f).value;
  await chrome.storage.local.set({ settings: s });
}

let shown = null;   // { tree, page }: what the frame shows, and the only tree its requests are answered from

function account(lines) { $('account').textContent = lines.join('\n'); }

const STALE_S = 3600;   // a decision older than this is marked: the chain may have moved since (a revocation, a name)

/** The "as of" banner: which block and slot the decision was made at, when, and how long ago. */
function showAsOf(asOf, ok) {
  const el = $('asof');
  if (!asOf || (asOf.block === null && asOf.slot === null)) { el.textContent = ''; el.className = ''; return; }
  const t = asOf.blockTime ?? asOf.slotTime;
  const age = t === null ? null : Math.max(0, Math.round(Date.now() / 1000 - t));
  const ago = age === null ? '' : age < 120 ? `${age} s ago` : age < 7200 ? `${Math.round(age / 60)} min ago`
    : age < 172800 ? `${Math.round(age / 3600)} h ago` : `${Math.round(age / 86400)} days ago`;
  const parts = [];
  if (asOf.block !== null) parts.push(`execution block ${asOf.block}`);
  if (asOf.slot !== null) parts.push(`beacon slot ${asOf.slot}`);
  el.textContent = `${ok ? 'Admitted' : 'Decided'} as of ${parts.join(', ')}` + (t === null ? '' : ` · ${new Date(t * 1000).toISOString().replace('.000Z', 'Z')} · ${ago}`)
    + (age !== null && age > STALE_S ? ' · older than an hour: the chain may have changed since' : '');
  el.className = age !== null && age > STALE_S ? 'stale' : 'fresh';
}

/** Show `page` of `tree` in a fresh sandbox loader. Exported for the tests, which put a tree in OPFS themselves. */
export async function show(tree, page = 'index.html') {
  const { html, report } = buildDocument(tree, page);
  shown = { tree, page };
  const frame = $('app');
  const fresh = frame.cloneNode(false);   // a new browsing context: nothing of the last page survives
  fresh.classList.add('shown');
  frame.replaceWith(fresh);
  const ready = new Promise((ok) => {
    const on = (e) => { if (e.source === fresh.contentWindow && e.data && e.data.ready) { removeEventListener('message', on); ok(); } };
    addEventListener('message', on);
  });
  fresh.src = 'loader.html';
  await ready;
  fresh.contentWindow.postMessage({ document: html }, '*');
  const notes = [];
  if (report.missing.length) notes.push(`not in the tree: ${report.missing.join(', ')}`);
  if (report.outside.length) notes.push(`outside the tree, so not loaded: ${report.outside.join(', ')}`);
  if (report.modules.length) notes.push(`module scripts with relative imports, which may not run: ${report.modules.join(', ')}`);
  return { report, notes };
}

// The app's requests: answered from the shown tree only, for the frame showing it only.
addEventListener('message', async (e) => {
  const frame = $('app');
  if (!shown || e.source !== frame.contentWindow || !e.data) return;
  if (typeof e.data.ask === 'string') {
    const bytes = shown.tree.read(e.data.ask);
    const body = bytes === null ? null : bytes.slice().buffer;
    e.source.postMessage({ id: e.data.id, status: bytes === null ? 404 : 200, type: typeOf(e.data.ask), body }, '*', body ? [body] : []);
  } else if (typeof e.data.navigate === 'string') {
    if (shown.tree.read(e.data.navigate) !== null) await show(shown.tree, e.data.navigate);
  }
});

/** Take down whatever was shown: a new subject is not shown until it is admitted, and the last one must not linger
 *  beside its account as if it were the new one. */
function clear() {
  shown = null;
  const frame = $('app');
  const blank = frame.cloneNode(false);
  blank.classList.remove('shown');
  frame.replaceWith(blank);
}

async function open(subject, role) {
  clear();
  showAsOf(null, false);
  const settings = await loadSettings();
  account([`admitting ${subject} as ${role}…`]);
  const d = await admit(settings, subject, role);
  account(d.lines);
  showAsOf(d.asOf, d.code === 0);
  if (d.code !== 0 || !d.cid) return;
  const tree = await openTree(d.cid);
  if (!tree) { account([...d.lines, `admitted, but its tree is not in storage: ${d.cid}`]); return; }
  window.__reckon.last = { subject, cid: d.cid, paths: tree.paths };
  const { notes } = await show(tree);
  if (notes.length) account([...d.lines, ...notes]);
}

(async () => {
  const s = await loadSettings();
  for (const f of FIELDS) $(f).value = s[f] ?? '';
  $('save').addEventListener('click', saveSettings);
  $('open').addEventListener('submit', (e) => { e.preventDefault(); open($('subject').value.trim(), $('role').value.trim() || 'app'); });
  const q = new URLSearchParams(location.search).get('open');
  if (q) { $('subject').value = q; open(q, $('role').value); }
  window.__reckon = { show, openTree };   // for the tests
})();
