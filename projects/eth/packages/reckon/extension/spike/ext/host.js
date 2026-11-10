// The extension page: shows the app in a sandboxed frame and collects what the frame reports.
const log = (s) => { document.getElementById('log').textContent += s + '\n'; };
window.results = [];
window.addEventListener('message', async (e) => {
  if (e.data && e.data.ask) {   // the frame's fetch: answered from the tree only
    const path = new URL(e.data.ask, 'https://tree.invalid/app/root/').pathname;
    const r = path.startsWith('/app/root/') ? await fetch(path) : null;
    e.source.postMessage({ id: e.data.id, status: r ? r.status : 404, body: r ? await r.text() : '' }, '*');
    return;
  }
  if (e.data && e.data.ready) return;
  window.results.push(e.data); log(JSON.stringify(e.data));
});
const f = document.createElement('iframe');
const sb = new URLSearchParams(location.search).get('sandbox') ?? 'allow-scripts';
if (sb !== 'none') f.setAttribute('sandbox', sb);
const q = new URLSearchParams(location.search);
if (q.get('loader') === '1') {
  f.src = '/loader.html';
  window.addEventListener('message', async (e) => {
    if (e.data && e.data.ready) e.source.postMessage({ document: await (await fetch('/app/root/' + (q.get('page') ?? 'inline.html'))).text() }, '*');
  });
} else {
  f.src = '/app/root/' + (q.get('page') ?? 'index.html') + (q.get('csp') === '1' ? '?csp=1' : '');
}
document.body.appendChild(f);
