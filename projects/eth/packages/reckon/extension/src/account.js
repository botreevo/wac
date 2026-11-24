// Admission's account, read for a person: one line that says what was decided and why, then the decision itself as a
// tree to open, then the rest (the light client, the name, the chain, "as of") as it was said. Pure functions over the
// lines `web` printed (admission.js), so test/account.cjs can check them without a browser.

/** A line of the decision tree: `<indent><cid>… admitted|refused as <role>`. */
const NODE = /^(\s*)(\S+)… (admitted|refused) as (\S+)/;
const indent = (l) => /^\s*/.exec(l)[0].length;

/** Where the decision tree is: from its first node to the verdict, or null when admission stopped before it. */
export function treeSpan(lines) {
  const from = lines.findIndex((l) => NODE.test(l) && indent(l) === 0);
  if (from < 0) return null;
  let to = from;
  while (to + 1 < lines.length && !/^(ADMITTED|REFUSED)$/.test(lines[to + 1]) && (indent(lines[to + 1]) > 0 || NODE.test(lines[to + 1]))) to++;
  return { from, to };
}

/**
 * What was decided, and why, in a line: `{ verdict: 'admitted' | 'refused' | 'unknown', text }`. A refusal's reason is
 * the deepest refused node's first reason (the rule it did not meet, under the role it was refused as), or, when
 * admission stopped before deciding anything, the line that stopped it.
 */
export function summarize(lines) {
  const admitted = lines.includes('ADMITTED');
  const refused = lines.includes('REFUSED');
  const span = treeSpan(lines);
  const said = lines.map((l) => /^web: admitted (\S+)/.exec(l)).find(Boolean);
  if (admitted) {
    const top = span ? NODE.exec(lines[span.from]) : null;
    const tree = span ? lines.slice(span.from, span.to + 1) : [];
    const n = (re) => tree.filter((l) => re.test(l)).length;
    const parts = [];
    if (n(/witnessed by/)) parts.push(`${n(/witnessed by/)} derivation(s)`);
    if (n(/endorsed by/)) parts.push(`${n(/endorsed by/)} endorsement(s)`);
    if (n(/a trust root/)) parts.push(`${n(/a trust root/)} trust root(s)`);
    const cid = said ? said[1] : top ? top[2] + '…' : '';
    return { verdict: 'admitted', text: `Admitted${top ? ` as ${top[4]}` : ''}${cid ? ': ' + cid : ''}${parts.length ? ` — ${parts.join(', ')} checked` : ''}` };
  }
  if (span) {
    // Where it failed at the bottom: refused nodes with nothing refused below them, which is why everything above them
    // failed. The deepest is named; the others are counted.
    const bottoms = [];
    for (let i = span.from; i <= span.to; i++) {
      const m = NODE.exec(lines[i]);
      if (!m || m[3] !== 'refused') continue;
      let j = i + 1, below = false;
      while (j <= span.to && indent(lines[j]) > indent(lines[i])) { if (/… refused as /.test(lines[j])) below = true; j++; }
      if (!below) bottoms.push(i);
    }
    if (bottoms.length) {
      const deepest = bottoms.reduce((a, b) => (indent(lines[b]) > indent(lines[a]) ? b : a));
      const m = NODE.exec(lines[deepest]);
      const why = deepest + 1 <= span.to && indent(lines[deepest + 1]) > indent(lines[deepest]) ? lines[deepest + 1].trim() : '';
      const more = bottoms.length > 1 ? ` (and ${bottoms.length - 1} more refused)` : '';
      return { verdict: 'refused', text: `Refused: ${m[2]}… as ${m[4]}${why ? `: ${why}` : ''}${more}` };
    }
  }
  // Admission stopped before a decision: the last thing it said, without the program's name.
  const last = [...lines].reverse().find((l) => l.trim() && !/^(ADMITTED|REFUSED)$/.test(l) && !/^as of /.test(l));
  return { verdict: refused ? 'refused' : 'unknown', text: `${refused ? 'Refused' : 'Not admitted'}${last ? ': ' + last.replace(/^(web|claim): /, '').trim() : ''}` };
}

/**
 * The decision tree as nodes: `{ line, children }`, by indentation. A node with children is shown folded unless it, or
 * something below it, was refused: what was refused is open, so the reason is in view.
 */
export function treeOf(lines) {
  const roots = [];
  const stack = [];
  for (const line of lines) {
    const node = { line: line.trim(), depth: indent(line), children: [], refused: /… refused as /.test(line) };
    while (stack.length && stack[stack.length - 1].depth >= node.depth) stack.pop();
    (stack.length ? stack[stack.length - 1].children : roots).push(node);
    stack.push(node);
  }
  const mark = (n) => { for (const c of n.children) if (mark(c)) n.refused = true; return n.refused; };
  roots.forEach(mark);
  return roots;
}

/**
 * Render the account into `el` (a DOM element): the summary line once something was decided, the lines before the tree,
 * the tree, the rest. Every line ends in a newline in the text, so `el.textContent` still reads as the lines did (and
 * copies as them), the tree's indentation aside.
 */
export function renderAccount(el, lines) {
  const doc = el.ownerDocument;
  el.replaceChildren();
  if (!lines.length) return;
  const nl = () => doc.createTextNode('\n');
  if (lines.includes('ADMITTED') || lines.includes('REFUSED')) {
    const s = summarize(lines);
    const head = doc.createElement('p');
    head.className = `verdict ${s.verdict}`;
    head.textContent = s.text;
    el.append(head, nl());
  }
  const span = treeSpan(lines);
  const plain = (ls) => { if (!ls.length) return; const pre = doc.createElement('pre'); pre.textContent = ls.join('\n') + '\n'; el.append(pre); };
  if (!span) { plain(lines); return; }
  plain(lines.slice(0, span.from));
  const tree = doc.createElement('div');
  tree.className = 'tree';
  const draw = (into, nodes, depth) => {
    for (const n of nodes) {
      if (!n.children.length) { const p = doc.createElement('div'); p.className = 'leaf'; p.textContent = n.line; into.append(p, nl()); continue; }
      const d = doc.createElement('details');
      if (n.refused || depth === 0) d.open = true;
      if (n.refused) d.className = 'refused';
      const sum = doc.createElement('summary');
      sum.textContent = n.line;
      d.append(sum, nl());
      draw(d, n.children, depth + 1);
      into.append(d);
    }
  };
  draw(tree, treeOf(lines.slice(span.from, span.to + 1)), 0);
  el.append(tree);
  plain(lines.slice(span.to + 1));
}
