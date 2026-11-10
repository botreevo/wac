# Issues

Bugs and tasks for wacuum, kept as files the way wac keeps its own (`issues/system/` in the wac repository),
so that they travel with the code and anyone working here can read them without leaving the checkout.
Something wrong with *wac* goes to wac's tracker, or to `docs/wac-asks.md` while it is a workaround here.

## When to file rather than just fix it

- **Something in what you are working on:** fix it. An issue opened and closed in one session is noise.
- **Something you found while working on something else** — another repository that uses wacuum, say — or
  something that needs a decision first: file it, so it is not lost.
- **Work that is blocked:** file it, with what it waits for.

An issue is for something actionable that is not already written down. A limit the README already states
is not an issue unless there is something to do about it.

## Filing one

Add `open/NNNNx-short-slug.md` from `TEMPLATE.md`, taking the next free number, followed by the letter of the
agent filing it (`d` and so on — as in wac, the letter keeps two agents filing at once from colliding). Add a
row at the top of `INDEX.md` and change its count in the same commit. Commit it on `master`; an issue is not a
code change.

## Closing one

In the commit that fixes it: move the file to `closed/`, set its status line to `- **Status:** closed`,
say at the end of the file what was done and what the reproduction does now, and delete its row from
`INDEX.md` and change the counts. Closed issues stay, so "was this ever a problem?" has an answer.

## What makes a report worth having

A reproduction: the command, the input, what was expected and what happened. If you narrowed it, say how.
