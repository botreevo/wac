# Where wac got in the way

Written down with a reproduction, worked around here.

## An async function awaiting inside a `match` arm does not emit

`SqliteFile` was first written `async`, awaiting `Files.stat`, `readFile`, `writeFile` and `rename`. It
checked clean and then trapped at run time on the first `await` inside a `for … in` loop, and a smaller
program awaiting a stdout write inside a `match` arm stopped at emission:

    wacc: cannot emit dbg2.wac — a call to __wacCo___wacMain, declined: an assignment between related
    reference types: never[][] into never[]

```wac
import { Sys } from "std";
import { flatten } from "core";
export async i32 main(Sys sys) {
  match (flatten(await sys.files().stat("x"))) {
    Ok(st): { await sys.stdout().line("ok"); }
    Err(e): { await sys.stdout().line("err"); }
  }
  return 0;
}
```

**Worked around** by making `SqliteFile` synchronous: each file operation is `Ticket.wait()`ed. That
also keeps its interface the same shape as `Connection`'s.

## `wac update` cannot fetch from git.voltrevo.com

It answers wac's fetcher 401, so a project depending on this one fills the cache with `git` (wacuum's
`tools/deps.wac`). See the README.

## No random-access file writes in std

std reads and writes whole files, so every commit rewrites the whole database. A `pwrite`-shaped
operation (and `fsync`) would let commits write only the pages they changed, which is SQLite's own way
and what would make large databases practical.
