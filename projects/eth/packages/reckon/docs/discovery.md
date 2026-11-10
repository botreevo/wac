# Finding mirrors

A mirror (docs/claims-mirror.md) is a store directory, `claims/index` and `ipfs/CID`, served by any web server. A client
reads a mirror only if it knows where it is. Discovery lets one URL lead to many mirrors: a **manifest** is a static
JSON file naming mirrors and further manifests, and a client follows them.

`tools/discovery.sh` (task `reckon:discovery`) checks it: 11 of 11.

## Rules

- **Static.** A manifest, an index and a block are each a plain `GET` of a file. Nothing needs server logic, so any
  static host serves them: a pages site, a bucket, a CDN, IPFS.
- **CORS on everything.** Every answer carries `Access-Control-Allow-Origin: *`, so a page or an extension can read
  it. `tools/serve.py` is a static server that does this, for tests and for trying it locally.
- **Availability only.** Nothing discovered is trusted. A mirror found through a manifest is one more place to look,
  exactly like one given with `--mirror`. Every block is re-hashed and every statement's signature checked. A lying
  manifest can lead to mirrors that withhold or serve garbage. That costs time, never a wrong decision: what fails is
  left out and named.
- **Old mirrors keep working.** A mirror is the same store directory as before. `--mirror` now also takes a path, so
  a mirror can live below a site's root.

## The manifest: `reckon-mirrors/1`

    {
      "format": "reckon-mirrors/1",
      "mirrors": ["downloads/claims", "https://mirror.example/reckon"],
      "manifests": ["https://friend.example/reckon-mirrors.json"]
    }

| field | meaning |
| --- | --- |
| `format` | required, exactly `"reckon-mirrors/1"`; anything else is not this format and is refused |
| `mirrors` | URLs of mirrors, each as `--mirror` takes it: `http://` or `https://`, a host and optionally a path, where `PATH/claims/index` and `PATH/ipfs/CID` are |
| `manifests` | URLs of further manifests to follow |

- **Relative entries.** An entry that is not absolute resolves against the manifest's own URL, as a link in a page
  does: `downloads/claims` beside it, `../x` up one, `/x` from the origin. A site can name the mirror it carries
  without knowing where it is hosted.
- **Unknown fields** are ignored, so later versions can add to the format without breaking this one.
- **The conventional name** is `reckon-mirrors.json`, at the root of whatever carries it. This site publishes one at
  `https://pages.voltrevo.com/wac-eth/reckon-mirrors.json`, naming the extension release's claims mirror.

## Following manifests

From one manifest URL, breadth-first:

- each manifest is fetched once (cycles are fine), at most **16 manifests**;
- mirrors are collected in the order found, without repeats, at most **32**;
- a manifest that cannot be fetched (not there, not 200, not JSON, another format) is reported and skipped.

Nothing fails the walk. The answer is the list of mirrors and the list of problems.

## Commands

    claim mirrors URL                          the mirrors URL leads to, one per line (to pass as --mirror); problems to stderr
    claim manifest OUT [--lists URL]… [--follow URL]…     write a manifest
    claim admit|run|origins|… --mirrors-from URL…         the walk inside the command: what it finds joins --mirror
    web SUBJECT ROLE … --mirrors-from URL…                the same in a browser; the extension's setting "mirror manifests"

`src/discovery.wac` holds `readManifest`, `writeManifest`, `resolveUrl` and `discover(caps, url, maxManifests,
maxMirrors)`, and `mirrorsAsked(caps, args)`: the `--mirror`s as given, then what each `--mirrors-from` walk finds (16
manifests and 32 mirrors a walk), each mirror once, with the walks' problems to report. A walk that finds no mirror is
one of them. `claim` and `web` both take their mirrors from it; the extension passes each line of its setting as
`--mirrors-from`. `tools/discovery.sh` checks it in `claim admit` (15 of 15, with the four checks below).

## What was run (2026-11-10)

`tools/discovery.sh` sets up two static sites with CORS. Each carries one mirror below its root and a manifest, and
the two endorsements a decision needs are split between the two mirrors.

- Every answer a page reads (the manifest, the index, a block) carries the header, and a preflight is answered.
- From the first manifest's URL, `claim mirrors` finds both mirrors: one named relatively, the other through the
  second manifest. The cycle back is followed once. A missing manifest (404) and one that is not JSON are reported.
- With the mirrors found, the subject is admitted. With either mirror alone, it is refused.
- A third manifest leads to a lying mirror first. Its forged statement is left out and named, and the honest
  mirrors still decide.
- A chain of 20 manifests stops at 16 and says so.
- Mirrors given by hand work as before. claims-mirror.sh also checks a mirror below a path (13 of 13).
