// The extension's page: settings, a subject to open, admission's account, and the admitted app in the sandbox loader.
// The order is fixed: admit, then read the admitted tree from OPFS, then show it. An app is never shown otherwise.
import { admit } from './admission.js';
import { openTree } from './tree.js';
import { buildDocument, typeOf } from './build-doc.js';

const $ = (id) => document.getElementById(id);
const FIELDS = ['checkpoint', 'beaconUrl', 'rpc', 'registry', 'codeHash', 'mirrors', 'policy'];
const DEFAULTS = { mirrors: 'https://trustless-gateway.link', policy: '{ signers: {}, roles: {} }' };

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

async function open(subject, role) {
  const settings = await loadSettings();
  account([`admitting ${subject} as ${role}…`]);
  const d = await admit(settings, subject, role);
  account(d.lines);
  if (d.code !== 0 || !d.cid) return;
  const tree = await openTree(d.cid);
  if (!tree) { account([...d.lines, `admitted, but its tree is not in storage: ${d.cid}`]); return; }
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
