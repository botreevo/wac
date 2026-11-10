#!/usr/bin/env python3
"""reckon's pages site, from site/ and the recorded transcripts in site/demos (see tools/site.sh).

    python3 tools/site.py OUT [COMMIT]

Writes OUT/index.html (the landing page with the demos' counts, the commit it is built from, and the docs list filled
in), OUT/style.css, OUT/demos/NAME.html for each site/demos/NAME.txt, and OUT/docs/*.md.txt (the README and
docs/*.md as plain text, since the site has no markdown renderer).
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
    "capstone": ("The capstone", "QUICK=1 sh packages/reckon/tools/capstone.sh WORKDIR",
                 "Source to a compiler to an app to its run, each a derivation signed by a runner on V8 and one on "
                 "wasmtime; claims published to a mirror; an ENS name on a devnet pointing at the app; and a fresh "
                 "client that resolves the name by proof, takes the claims from the mirror, fetches and checks the "
                 "bytes, admits and runs it. Then the mainnet half from a checkpoint, and the refusals. QUICK uses the "
                 "seed compiler for the app's build instead of one the seed built (the selfbuild demo shows those agree)."),
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
<nav class="top"><a class="mark" href="{up}">reckon</a><a href="{up}#how">how it works</a><a href="{up}#demos">demos</a><a href="{up}#trusted">still trusted</a><a href="{up}#source">source</a></nav>
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
    page += f'<pre class="term">{shade(text)}</pre>\n</main>\n</body>\n</html>\n'
    write(os.path.join(out, "demos", name + ".html"), page)

docs = [("README.md", os.path.join(here, "README.md"))]
docs += [(f, os.path.join(here, "docs", f)) for f in sorted(os.listdir(os.path.join(here, "docs"))) if f.endswith(".md")]
cards = []
for f, p in docs:
    text = read(p)
    m = re.search(r"^# (.+)$", text, re.M)
    title = m.group(1) if m else f
    os.makedirs(os.path.join(out, "docs"), exist_ok=True)
    shutil.copyfile(p, os.path.join(out, "docs", f + ".txt"))
    where = "packages/reckon/" + ("" if f == "README.md" else "docs/") + f
    cards.append(f'  <a class="card" href="docs/{f}.txt"><h3>{html.escape(title)}</h3><p><code>{where}</code></p></a>')
index = index.replace("@DOCS@", "\n".join(cards))
left = re.findall(r"@[A-Z:a-z-]+@", index)
if left:
    sys.exit(f"site: unfilled in index.html: {left}")
write(os.path.join(out, "index.html"), index)
shutil.copyfile(os.path.join(site, "style.css"), os.path.join(out, "style.css"))
write(os.path.join(out, ".nojekyll"), "")
print(f"site: {out}")
