# 0458e — a package file is keyed by where the cache is, so its generics are named after the machine

- **Status:** closed 2026-11-11 (wac2) — `packages/wacc/src/emit.wac` `packageKeyOf`; `packages/wac/test/wac/packagekey_test.wac`
- **Reported by:** wac2
- **Date:** 2026-11-10
- **Kind:** bug
- **Symptom:** wrong answer — one source, two modules, on two machines whose `$WAC_HOME` differs

`0270a` made a project's own keys relative to its root. A file reached through a package mapping is not in the
project: its key is the absolute path of the cache checkout.

    $ wac run --allow-read --allow-env tools/wac/sources.wac packages/platform/example/notes.wac
    F  /root/.wac/cache/git/https%3A%2F%2Fgithub.com%2Fvoltrevo%2Fwac-web.git/6ff6b30…/src/page.wac

A symbol is spelled from the declaring file's key (`fileTagOf`), so a generic a package declares, instantiated
over a type, carries `$WAC_HOME` in its name, and so does the module. Not measured as a byte difference yet: it
needs such an instantiation to survive into the name section. reckon's in-machine builds will meet it if their
cache path differs from the native one.

**Probably:** key a package file by what identifies it rather than where it is: the mapping's URL, commit and
path, or the `wac.lock` name and path, under a prefix no file on disk has. That is a key the reader has to
translate back to a path, so it touches the read, the `@/` root of a package and `subdir` confinement
(`0169a`). That's why it was left out of `0270a`.

## Fixed — wac2, 2026-11-11

**Measured first.** A module exporting a type a package declares, where the name is file-qualified (two `Thing`s, or
`web`'s `Element`), carried the cache path in its exports:
`$bind$s_Thing___tmp_…_h1_cache_git_https_3A_2F_2Fexample_invalid_2Fpkg_git_aaaa…_lib_new`. Built under a second
`$WAC_HOME` it was a different module. Nothing else in a module named the path: there is no name section, and a
program's own boundary (`Host`, `Page`) is not tagged.

**Fixed where the name is spelled, not where the key is chosen.** The fix proposed above — keying a package file by
what identifies it — reaches the read, a package's `@/` root and `subdir` confinement. The bytes come from one
function, `fileTagOf`, and `packageKeyOf` starts a package file's tag at `<repository>/<commit>/`, the part that is the
same on every machine. Keys, diagnostics and reads are unchanged.

`packagekey_test.wac` builds one project, against one package held in two caches under two homes, and compares the
bytes, with a control that the package's name is file-qualified at all. It failed before the change.
