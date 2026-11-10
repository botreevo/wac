// The account as the page shows it (src/account.js): one line saying what was decided and why, and the decision as a
// tree to open. The summaries are checked against accounts from the site's recorded runs (site/demos/*.txt), and the
// rendering in the extension's page: refused branches open, admitted ones folded, the text still the lines it was.
//
//     node packages/reckon/extension/test/account.cjs
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

let pass = 0, fail = 0;
const ok = (c, what) => { if (c) { pass++; console.log(`ok    ${what}`); } else { fail++; console.log(`FAIL  ${what}`); } };

// Every account in a recorded transcript: a run of "   | " lines that ends in ADMITTED or REFUSED.
function accounts() {
  const dir = path.resolve(__dirname, '../../site/demos');
  const out = [];
  for (const f of fs.readdirSync(dir).filter((f) => f.endsWith('.txt'))) {
    let cur = [];
    for (const l of fs.readFileSync(path.join(dir, f), 'utf8').replace(/\x1b\[[0-9;]*m/g, '').split('\n')) {
      if (!l.startsWith('   | ')) { cur = []; continue; }
      cur.push(l.slice(5));
      if (/^(ADMITTED|REFUSED)$/.test(l.slice(5))) { out.push({ file: f, lines: cur }); cur = []; }
    }
  }
  return out;
}

(async () => {
  const { summarize } = await import(path.resolve(__dirname, '../src/account.js'));
  const all = accounts();
  const find = (re) => all.map((a) => ({ ...a, s: summarize(a.lines) })).find((a) => re.test(a.s.text));
  ok(all.length >= 20, `${all.length} accounts from the recorded runs`);
  const verdicts = all.map((a) => [a.lines.includes('ADMITTED') ? 'admitted' : 'refused', summarize(a.lines).verdict]);
  ok(verdicts.every(([want, got]) => want === got), 'every summary says what the account decided');
  const deep = find(/as build: recipe \S+: witnessed by v8 on 1 runner\(s\) \(need 2 on 2\)/);
  ok(deep, `a refusal deep in the tree is summarized by the rule that failed at the bottom: "${deep && deep.s.text}"`);
  const nobody = find(/^Refused: \S+ as app: endorsed by nobody \(need 1\)$/);
  const many = find(/ \(and \d+ more refused\)$/);
  ok(many, `several refusals at the bottom: one named, the rest counted: "${many && many.s.text}"`);
  ok(nobody, `an unendorsed app: "${nobody && nobody.s.text}"`);
  const early = find(/^Refused: name: vitalik\.eth: not followed/);
  ok(early, `a refusal before any tree, by the line that stopped it: "${early && early.s.text.slice(0, 90)}…"`);
  const lc = find(/^Refused: the light client: /);
  ok(lc, `a light client that did not verify: "${lc && lc.s.text.slice(0, 90)}"`);
  const full = find(/^Admitted as app: \S+ — \d+ derivation\(s\), \d+ endorsement\(s\), \d+ trust root\(s\) checked$/);
  ok(full, `an admission, counted: "${full && full.s.text}"`);

  // The rendering, in the extension's own page.
  // The largest refused account with admitted branches beside the refused one: the folding has something to fold.
  const refused = all.filter((a) => a.lines.includes('REFUSED') && a.lines.some((l) => /… admitted as /.test(l)) && a.lines.some((l) => /… refused as /.test(l)))
    .sort((x, y) => y.lines.length - x.lines.length)[0];
  const ext = path.resolve(__dirname, '../src');
  const ctx = await chromium.launchPersistentContext('', { channel: 'chromium', headless: true,
    args: [`--disable-extensions-except=${ext}`, `--load-extension=${ext}`] });
  let [sw] = ctx.serviceWorkers();
  if (!sw) sw = await ctx.waitForEvent('serviceworker');
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.goto(`chrome-extension://${sw.url().split('/')[2]}/page.html`);
  const seen = await page.evaluate(async (lines) => {
    const { renderAccount } = await import('./account.js');
    const el = document.getElementById('account');
    renderAccount(el, lines);
    const ds = [...el.querySelectorAll('.tree details')];
    return {
      verdict: el.querySelector('.verdict') && el.querySelector('.verdict').textContent,
      cls: el.querySelector('.verdict') && el.querySelector('.verdict').className,
      details: ds.length,
      openRefused: ds.filter((d) => d.classList.contains('refused')).every((d) => d.open),
      folded: ds.filter((d) => !d.open).length,
      foldedAdmitted: ds.filter((d) => !d.classList.contains('refused') && d.parentElement.closest('details')).every((d) => !d.open),
      text: el.textContent,
      visible: el.getBoundingClientRect().height > 0,
    };
  }, refused.lines);
  ok(seen.cls === 'verdict refused' && seen.verdict.startsWith('Refused: '), `the page leads with the reason: "${seen.verdict}"`);
  ok(seen.details >= 2 && seen.openRefused && seen.foldedAdmitted && seen.folded > 0, `the tree: ${seen.details} branches, the refused ones open, the ${seen.folded} admitted below the top folded`);
  ok(/^REFUSED$/m.test(seen.text) && refused.lines.every((l) => seen.text.includes(l.trim())), "the account's text is still every line it was");
  await page.screenshot({ path: path.join(process.env.SHOTS || '/tmp', 'account-refused.png') }).catch(() => {});
  const progress = await page.evaluate(async () => {
    const { renderAccount } = await import('./account.js');
    const el = document.getElementById('account');
    renderAccount(el, ['admitting ens:x.eth as app…']);
    return { verdict: !!el.querySelector('.verdict'), text: el.textContent };
  });
  ok(!progress.verdict && /admitting/.test(progress.text), 'while admitting, no verdict: only what is happening');
  ok(errors.length === 0, `no errors on the page${errors.length ? ': ' + errors.join('; ') : ''}`);
  await ctx.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
})();
