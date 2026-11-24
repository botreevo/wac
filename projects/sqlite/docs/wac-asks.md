# Where wac got in the way

Written down with a reproduction, worked around here.

## An async function awaiting inside a `match` arm does not emit

`SqliteFile` was first written `async`, awaiting `Files.stat`, `readFile`, `writeFile` and `rename`. It
checked clean and then trapped at run time inside `open`, with no message; the cause was not isolated.
A smaller program awaiting a stdout write inside a `match` arm stopped at emission:

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

## No random-access file writes in std — done, on a branch

std read and wrote whole files, so every commit rewrote the whole database and opening one read it
all into memory. **Added** to std as `Files.openRandom(path, write)` → `RandomFile` (`readAt`,
`writeAt`, `size`, `truncate`, `sync`, `close`), requests 69–73, on wac's master since `4085b2e9c`, with the Node, Deno and wasmtime hosts answering it (the V8 binary's arm is written but was not
built). This library now reads pages as it needs them and commits only the pages it changed, behind a
rollback journal synced before the file is touched.
