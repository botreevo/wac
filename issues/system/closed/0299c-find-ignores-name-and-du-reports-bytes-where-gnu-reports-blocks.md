# 0299 — `find` accepts `-name` and ignores it

- **Status:** closed 2026-11-10 (cloud) — `find` reads its expression; `applets_test.wac`
- **Claimed by:** wac2
- **Reported by:** agent-c
- **Date:** 2026-08-31
- **Kind:** bug
- **Symptom:** wrong answer — a filter that filters nothing

## Reproduction

In a directory holding `fields.txt`, `m1.txt` (17 bytes), `m2.txt` and `prose.txt`:

| | GNU | box |
|---|---|---|
| `find . -name m1.txt` | `./m1.txt` | **the entire walk** |

Two more looked wrong on the same run and are not — see the correction below.

## Corrected 2026-08-31 — one of the three is a defect

**`find . -name m1.txt` prints every entry.** The filter is accepted and ignored, so matching nothing
and matching everything are the same command. This is the failure `lib/flags.wac` exists to prevent —
it refuses a flag an applet has not implemented rather than letting it look supported — and `find`
escapes it because `-name` takes a *value*, which the shared parser reads as an operand rather than
as a flag. `flagsChecked(name)` does not list `find`.

That one stands. **The other two were mine to get wrong**, and `box.test.ts`'s own sweep says so.

**`du` is byte-based on purpose.** It is not "bytes where GNU reports blocks" — it is GNU's `du -sb`,
which is what the sweep compares it against, and measured they agree exactly:

    GNU du       4   m1.txt      (1K blocks)
    GNU du -sb  17   m1.txt      (bytes)
    box du      17   m1.txt

I compared against plain `du`, saw a different number, and filed it. The deliberate choice was one
line away in the test I was migrating.

**`find`'s order is normalised by the comparison, not by the applet.** The sweep sorts *both* sides
before comparing, precisely because `readDir`'s order is the filesystem's while `ls` sorts. So a
sorted answer is expected here rather than a divergence nobody noticed.

Both are worth stating somewhere a reader will find them — `packages/sh/README.md` records this
package's divergences and neither is in it — but neither is a bug, and this issue claiming they were
is the kind of wrong that reads as knowledge.

## How it was found, and what to do with it

Lifting `box.test.ts`'s applet-agreement sweep into `appletCases()` — `issues/system/0193`. The 29
other invocations added at the same time agreed with GNU on the first run. `-name` had never been
compared before: the Deno sweep asked `find` only through a whole-tree walk, where a filter that
ignores its argument and one that has no argument look the same.

**The regression test is one line**, and it belongs in `packages/box/test/wac/cases.wac`'s
`appletCases()` on the day they pass:

    "find . -name m1.txt",

It is not there now because a red vector case is a red suite for everybody. The comment in that file
points here.

`find .` and `du m1.txt` cannot be plain vector cases either, but for a different and duller reason:
the vectors compare against the tool named in the script, and these two need `find . | sort` and
`du -sb` to be the thing asked. That is a case-list question, not a defect.

## Why

`find` read no expression at all: `-name` takes a value, so the shared parser left it among the operands, `refuseFlags` does not cover `find`, and `find . -name m1.txt` printed the whole walk — a filter matching nothing and one matching everything were one command.

## Fix

`packages/box/src/applets/find.wac` reads the expression after its roots: `-name PATTERN`, a shell glob (`*`, `?`, `[…]`, `[!…]`) against the last component, and `-type f` or `-type d`, every one of them required, the root included. Any other predicate is refused as GNU refuses it — *"find: unknown predicate `-newer'"* — and `-name` with nothing after it is *"find: missing argument to `-name'"*. `test_find_reads_its_expression` holds a plain name, a set, a star through a subdirectory, `-type d`, both together, a root other than `.`, the bare walk unchanged, and both refusals. The other two findings in this issue were corrected as not defects when it was filed.
