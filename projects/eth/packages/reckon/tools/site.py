#!/usr/bin/env python3
"""reckon's pages site, from site/ and the recorded transcripts in site/demos (see tools/site.sh).

    python3 tools/site.py OUT [COMMIT]

Writes OUT/index.html (the landing page with the demos' counts, the commit it is built from, and the docs list filled
in), OUT/style.css, OUT/demos/NAME.html for each site/demos/NAME.txt, OUT/docs/*.html (the README and docs/*.md,
rendered), and OUT/downloads/ from site/downloads/.
"""
import html
import os
import re
import shutil
import sys

here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
site = os.path.join(here, "site")
out = sys.argv[1]

DEMOS = {
    "hostile": ("A hostile app, every way out", "node packages/reckon/extension/test/hostile.cjs [PORT]",
                "An admitted app whose pages try every way out of the sandbox loader we know of: fetch, XHR, "
                "WebSocket, EventSource, beacons, workers, imports, every kind of subresource, frames, objects, forms, "
                "popups, every kind of navigation, storage, cookies, the parent's DOM, the extension's API, other "
                "trees, and WebRTC. Each way out is aimed at its own path on a TCP and UDP listener, and each line "
                "says what the app saw, the CSP directive the browser reported, and what stopped it. Two got through "
                "before: a frame navigating itself, now closed by a per-tab request fence, and WebRTC, now closed by "
                "the loader's shim."),
    "turbostack": ("A third-party app, sealed end to end", "WASMTIME_WAC=… WAC_SRC=… sh packages/reckon/tools/turbostack.sh WORKDIR",
                   "wac-turbostack's duel page — a Tetris network that taught itself by self-play against turbostack's "
                   "original model — built only inside the sealed machine, with nothing of turbostack's run outside "
                   "it: wac-web's own page builder writes the page's module, the compiler builds it, the builder wraps "
                   "it into the page, and a gatherer puts the page beside the two models' weights, each step a "
                   "derivation agreed by V8 and wasmtime. A reviewer's endorsements, a policy that admits the site "
                   "through all four steps back to the compiler, the name turbostack on a devnet's registry, the "
                   "mirror found from a manifest (--mirrors-from); then admitted by name in the browser extension, "
                   "where both players load their weights and play in the sandbox loader."),
    "chess": ("A chess engine, sealed end to end", "WASMTIME_WAC=… WAC_SRC=… sh packages/reckon/tools/chess.sh WORKDIR",
              "wac-chess, a chess engine written from scratch in wac with a page to play it on, and the first app in "
              "wac-web's worker mode (the search runs off the page's thread): built only inside the sealed machine "
              "by wac-web's own page builder and the compiler, each step a derivation agreed by V8 and wasmtime, "
              "reviewed, named chess on a devnet's registry, admitted by name through every step back to the "
              "compiler, then opened in the browser extension, where the board is set and the engine answers a move "
              "from its opening book, with no network and no extension API."),
    "demo-app": ("A real app, admitted and run", "WASMTIME_WAC=… WAC_SRC=… sh packages/reckon/tools/demo-app.sh WORKDIR",
                 "A Mandelbrot set as a wac-web page (demo/mandelbrot.wac), end to end, every build step sealed: "
                 "wac-web's own page builder (its two halves that start no process) and the compiler, each a "
                 "derivation on V8 and on wasmtime, making the page the builder makes natively in one step, byte for "
                 "byte, a reviewer's endorsements, the page named "
                 "mandelbrot on a devnet's registry, admitted by name on the command line, then in the browser "
                 "extension: the name read by proof, the page fetched and checked, and run in the sandbox loader, "
                 "where it draws and zooms with no network and no extension API."),
    "capstone": ("The capstone", "LADDER=… sh packages/reckon/tools/capstone.sh WORKDIR",
                 "Source to a compiler to an app to its run, each a derivation signed by a runner on V8 and one on "
                 "wasmtime, under a policy with no roots: the compiler is built by the wac command wac's bootstrap "
                 "makes from its hand-written rungs, every step derived by two runners (rungs.sh), and the app is "
                 "admitted through 55 objects back to 16 a reviewer endorsed; withdraw one runner's run of one rung "
                 "and it is refused. Then claims published to a mirror, an ENS name on a devnet pointing at the app, "
                 "and a fresh client that resolves the name by proof, takes the claims from the mirror, fetches and "
                 "checks the bytes, admits and runs it; the mainnet half from a checkpoint; and the refusals."),
    "admit-by-name": ("vitalik.eth, from a checkpoint", "sh packages/reckon/tools/admit-by-name.sh WORKDIR",
                      "Offline on recorded mainnet data: one claim admit from a beacon checkpoint to a decision, with "
                      "the beacon data from a directory and then over the light-client REST API from a replaying "
                      "node, and each way it must refuse: no endorsement, another checkpoint, a node lying about the "
                      "header or a proof, an unknown name, and lying beacon answers."),
    "selfbuild": ("The compiler builds itself", "SELF=1 sh packages/reckon/tools/selfbuild.sh WORKDIR",
                  "wac's compiler run by the sealed machine: it builds an app that runs as the next derivation, then "
                  "compiles its own source on V8 and on wasmtime, and the compiler it produced compiles it again, "
                  "byte for byte. Admission follows the chain."),
    "ladder": ("The ladder meets the seed", "sh packages/reckon/tools/ladder.sh WORKDIR",
               "Decision D, milestone 1. wac's bootstrap ladder, five hand-written rungs from wasm assembly text up "
               "to wacc, builds the wac command from source with no compiler binary at all. Inside the sealed machine, "
               "on V8 and on wasmtime, that command compiles wac, and so does the seed: the same output tree, one CID. "
               "The ladder step itself is not yet a signed derivation (docs/bootstrap-derivations.md)."),
    "l0": ("Assembling the bootstrap's root", "sh packages/reckon/tools/l0.sh WORKDIR",
           "Decision D, milestone 2: wac-L0, the hand-written wasm text the bootstrap ladder starts from, as a machine "
           "(wac-l0/1) whose rule is wac's written spec and whose two runners are wac's Rust and JavaScript "
           "assemblers. They agree on every L0 text wac's tests hold and on the ladder's first rung, the L1 "
           "interpreter, which is admitted only through both runners and a reviewed source."),
    "flatten": ("Flattening wacc", "LADDER=… sh packages/reckon/tools/flatten.sh WORKDIR",
                "The step outside every rung: wac-L5 ignores imports, so the bootstrap flattens a module graph into "
                "one program. As a machine (wac-flatten/1), wac's JavaScript and Rust flatteners are its two runners; "
                "they agree on wacc's 38 modules, the same 3.7 MB the ladder makes, and flattened wacc is admitted "
                "only through both."),
    "conformance": ("Runners that earn their word", "WASMTIME_WAC=… sh packages/reckon/tools/conformance.sh WORKDIR",
                    "A conformance suite is 17 of the machine's own cases, with the output each must give, as one object. "
                    "Each runner witnesses it as it witnesses anything; a policy that names the suite counts a runner's "
                    "word only once that runner has. A runner that never ran it, one that leaks its engine's NaNs, and "
                    "one with no floor are each left out, and admission says why."),
    "rungs": ("The whole bootstrap, as derivations", "LADDER=… sh packages/reckon/tools/rungs.sh WORKDIR",
              "Every step from wac's five hand-written rungs to the wac command, each a derivation two runners sign: "
              "assembled (wac-l0/1), run through the rung's seam (wasm-seam/1, on V8 and wasmtime), flattened "
              "(wac-flatten/1), and wacc driven to compile wac (wacc-drive/1). wacc's 7.9 MB of assembly and the wac "
              "command are byte for byte what wac's own ladder makes, and the command is admitted back to reviewed "
              "text, with no binary among its roots. When one runner withdraws one rung's run, the chain is refused."),
    "bootconf": ("Conformance for the bootstrap", "LADDER=… sh packages/reckon/tools/bootconf.sh WORKDIR",
                 "The bootstrap's own machines get suites too: 14 cases for the assembler (wac's L0 tests, the first "
                 "rung, the empty text, three texts that must be refused) and 6 for the flattener (wac's L5 tests, a "
                 "renaming clash, wacc's sources, a missing import). An assembler that pads its modules, or a "
                 "flattener that renames a clash its own way, is not counted, even where it agrees."),
    "discovery": ("Finding mirrors", "sh packages/reckon/tools/discovery.sh WORKDIR",
                  "From one URL to every mirror: manifests are static JSON files, served with CORS, naming mirrors and "
                  "further manifests. Two sites each carry one mirror and a manifest; following them finds both, and "
                  "the decision needs both. A manifest leading to a lying mirror costs nothing but its forged "
                  "statement, left out and named."),
    "demo": ("Two runners, one policy", "sh packages/reckon/tools/demo.sh WORKDIR",
             "The smallest whole loop, with no chain: one recipe on two engines, a reviewer's endorsements, a policy "
             "that needs both, and each kind of revocation."),
    "claims-mirror": ("Claims through mirrors", "sh packages/reckon/tools/claims-mirror.sh WORKDIR",
                      "Two signers publish into one mirror served by a plain web server; a client with an empty store "
                      "admits from it over HTTP; a tampered statement is left out and reported; a revocation that one "
                      "mirror lacks counts once a second mirror carries it."),
}

ansi = re.compile(r"\x1b\[[0-9;]*m")


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def write(p, s):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)


built = sys.argv[2] if len(sys.argv) > 2 else "?"          # the commit the site is built from


def counts(text):
    """The script's own closing tally: "N passed, M failed" (each script counts its checks its own way)."""
    tally = re.findall(r"^\s*(\d+) passed, (\d+) failed", ansi.sub("", text), re.M)
    if not tally:
        sys.exit("site: a recording has no closing tally; record it again")
    return int(tally[-1][0]), int(tally[-1][1])


def shade(text):
    lines = []
    for l in ansi.sub("", text).splitlines():
        e = html.escape(l)
        s = l.lstrip()
        if s.startswith("ok ") or s.startswith("PASS"):
            e = f'<span class="ok">{e}</span>'
        elif s.startswith("FAIL"):
            e = f'<span class="bad">{e}</span>'
        elif l.startswith("#") or l.startswith("=="):
            e = f'<span class="h">{e}</span>'
        lines.append(e)
    return "\n".join(lines)


head = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{title} · reckon</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Serif:wght@600&display=swap">
<link rel="stylesheet" href="{up}style.css">
</head>
<body>
<main class="page">
<nav class="top"><a class="mark" href="{up}">reckon</a><a href="{up}#how">how it works</a><a href="{up}#demos">demos</a><a href="{up}#trusted">still trusted</a><a href="{up}docs/guide.html">guide</a><a href="{up}#source">source</a></nav>
"""

index = read(os.path.join(site, "index.html")).replace("@COMMIT@", built)
for name, (title, cmd, intro) in DEMOS.items():
    text = read(os.path.join(site, "demos", name + ".txt"))
    date, commit = read(os.path.join(site, "demos", name + ".recorded")).split()[:2]
    ok, bad = counts(text)
    if bad:
        sys.exit(f"site: the {name} recording has {bad} failing checks; record it again")
    index = index.replace(f"@N:{name}@", f"{ok} checks passed")
    page = head.format(title=html.escape(title), up="../")
    page += f'<p class="eyebrow">Demo · recorded {date} at {commit}</p>\n<h1>{html.escape(title)}</h1>\n'
    page += f'<p class="lede">{html.escape(intro)}</p>\n<pre><code>{html.escape(cmd)}</code></pre>\n'
    page += f'<p class="meta"><span>{ok} ok</span><span>{bad} failed</span><span>unedited output</span></p>\n'
    shots = sorted(f for f in os.listdir(os.path.join(site, "demos")) if f.startswith(name + "-") and f.endswith(".png"))
    os.makedirs(os.path.join(out, "demos"), exist_ok=True)
    for f in shots:
        shutil.copyfile(os.path.join(site, "demos", f), os.path.join(out, "demos", f))
        page += f'<p><img src="{f}" alt="{html.escape(title)}: {html.escape(f[len(name) + 1:-4])}" style="width:100%;height:auto;border:1px solid var(--line);border-radius:8px"></p>\n'
    page += f'<pre class="term">{shade(text)}</pre>\n</main>\n</body>\n</html>\n'
    write(os.path.join(out, "demos", name + ".html"), page)

# The docs, rendered: the README and docs/*.md (and docs/machines/*.md) as pages under docs/, with the Markdown these
# files use (headings, paragraphs, lists, indented code, tables, inline code, emphasis, links). A link to another
# rendered doc points at its page; a link to anything else is kept as text.
docs = [("README.md", os.path.join(here, "README.md"))]
docs += [(f, os.path.join(here, "docs", f)) for f in sorted(os.listdir(os.path.join(here, "docs"))) if f.endswith(".md")]
mdir = os.path.join(here, "docs", "machines")
docs += [("machines/" + f, os.path.join(mdir, f)) for f in sorted(os.listdir(mdir)) if f.endswith(".md")]
pages = {f: f[:-3] + ".html" for f, _ in docs}


def link(target, at):
    """A doc's link target, as the page it now is (relative to the doc at `at`), or None for anything not rendered."""
    path, _, frag = target.partition("#")
    if path.startswith(("http://", "https://")):
        return target
    if path == "":
        return "#" + frag
    base = os.path.dirname(at)
    norm = os.path.normpath(os.path.join(base, path)).replace("\\", "/")
    if norm.startswith("docs/"):
        norm = norm[5:]
    if at == "README.md" and path.startswith("docs/"):
        norm = path[5:]
    if norm in pages:
        rel = os.path.relpath(pages[norm], os.path.dirname(pages[at]) or ".")
        return rel + ("#" + frag if frag else "")
    return None


def inline(text, at):
    out = []
    for i, part in enumerate(re.split(r"(`[^`]*`)", text)):
        if i % 2 == 1:
            out.append("<code>" + html.escape(part[1:-1]) + "</code>")
            continue
        t = html.escape(part, quote=False)
        t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
        t = re.sub(r"(?<![\w*])\*([^*\s][^*]*?)\*(?![\w*])", r"<i>\1</i>", t)
        def a(m):
            href = link(html.unescape(m.group(2)), at)
            return m.group(1) if href is None else f'<a href="{html.escape(href)}">{m.group(1)}</a>'
        t = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", a, t)
        out.append(t)
    return "".join(out)


def render(md, at):
    lines = md.split("\n")
    out = []
    i = 0
    def blank(l): return l.strip() == ""
    while i < len(lines):
        l = lines[i]
        if blank(l):
            i += 1
            continue
        if l.startswith("```"):
            j = i + 1
            while j < len(lines) and not lines[j].startswith("```"):
                j += 1
            out.append("<pre><code>" + html.escape("\n".join(lines[i + 1:j])) + "</code></pre>")
            i = j + 1
            continue
        m = re.match(r"^(#{1,4}) (.*)$", l)
        if m:
            n = len(m.group(1))
            out.append(f"<h{n}>{inline(m.group(2), at)}</h{n}>")
            i += 1
            continue
        if l.startswith("    "):
            j = i
            block = []
            while j < len(lines) and (lines[j].startswith("    ") or (blank(lines[j]) and j + 1 < len(lines) and lines[j + 1].startswith("    "))):
                block.append(lines[j][4:])
                j += 1
            out.append('<pre><code>' + html.escape("\n".join(block)) + "</code></pre>")
            i = j
            continue
        if l.startswith("|"):
            j = i
            rows = []
            while j < len(lines) and lines[j].startswith("|"):
                row = lines[j].strip()[1:]
                row = row[:-1] if row.endswith("|") and not row.endswith("\\|") else row
                cells = [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", row)]
                if not all(re.fullmatch(r":?-{3,}:?", c) for c in cells):
                    rows.append(cells)
                j += 1
            t = ['<div class="table-wrap"><table>']
            for k, r in enumerate(rows):
                tag = "th" if k == 0 else "td"
                t.append("<tr>" + "".join(f"<{tag}>{inline(c, at)}</{tag}>" for c in r) + "</tr>")
            t.append("</table></div>")
            out.append("\n".join(t))
            i = j
            continue
        if re.match(r"^(\s*)(- |\d+\. )", l):
            j = i
            items = []   # (indent, ordered, text)
            while j < len(lines) and not blank(lines[j]):
                m = re.match(r"^(\s*)(- |\d+\. )(.*)$", lines[j])
                if m:
                    items.append([len(m.group(1)), m.group(2) != "- ", m.group(3)])
                elif items:
                    items[-1][2] += " " + lines[j].strip()
                j += 1
            stack = []
            html_ = []
            for ind, ordered, text in items:
                while stack and stack[-1][0] > ind:
                    html_.append("</li></" + ("ol" if stack.pop()[1] else "ul") + ">")
                if not stack or stack[-1][0] < ind:
                    html_.append("<" + ("ol" if ordered else "ul") + "><li>")
                    stack.append((ind, ordered))
                else:
                    html_.append("</li><li>")
                html_.append(inline(text, at))
            while stack:
                html_.append("</li></" + ("ol" if stack.pop()[1] else "ul") + ">")
            out.append("".join(html_))
            i = j
            continue
        j = i
        para = []
        while j < len(lines) and not blank(lines[j]) and not lines[j].startswith(("#", "|", "    ", "```")) \
                and not re.match(r"^(\s*)(- |\d+\. )", lines[j]):
            para.append(lines[j].strip())
            j += 1
        if not para:
            para = [l.strip()]
            j = i + 1
        out.append("<p>" + inline(" ".join(para), at) + "</p>")
        i = j
    return "\n".join(out)


cards = []
for f, p in docs:
    text = read(p)
    m = re.search(r"^# (.+)$", text, re.M)
    title = m.group(1) if m else f
    up = "../" * (pages[f].count("/") + 1)
    page = head.format(title=html.escape(re.sub(r"[`*]", "", title)), up=up)
    where = "packages/reckon/" + ("" if f == "README.md" else "docs/") + f
    page += f'<p class="eyebrow">{html.escape(where)}</p>\n<div class="doc">\n{render(text, f)}\n</div>\n</main>\n</body>\n</html>\n'
    write(os.path.join(out, "docs", pages[f]), page)
    cards.append(f'  <a class="card" href="docs/{pages[f]}"><h3>{inline(title, f)}</h3><p><code>{where}</code></p></a>')
index = index.replace("@DOCS@", "\n".join(cards))
left = re.findall(r"@[A-Z:a-z-]+@", index)
if left:
    sys.exit(f"site: unfilled in index.html: {left}")
write(os.path.join(out, "index.html"), index)
shutil.copyfile(os.path.join(site, "style.css"), os.path.join(out, "style.css"))
# Downloads (the extension, extension/release.sh): copied as they are, the zip, its manifest and its claims mirror.
# The site's manifest (docs/discovery.md): the mirrors it carries, named relative to itself.
if os.path.isfile(os.path.join(site, "reckon-mirrors.json")):
    shutil.copyfile(os.path.join(site, "reckon-mirrors.json"), os.path.join(out, "reckon-mirrors.json"))
if os.path.isdir(os.path.join(site, "downloads")):
    shutil.copytree(os.path.join(site, "downloads"), os.path.join(out, "downloads"))
write(os.path.join(out, ".nojekyll"), "")
print(f"site: {out}")
