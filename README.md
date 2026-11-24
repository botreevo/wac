# wac

A C-family language for WebAssembly GC, and the projects written in it — each in `projects/`, each with its own
gate and its own versions.

| project | what it is |
| --- | --- |
| [`wac`](projects/wac/) | the language: compiler, `core` and `std`, the specification, the bootstrap, and the libraries the stack is built from — TLS, SSH, Tor, QUIC, git, compression and more. **[Start here](projects/wac/README.md).** |
| [`web`](projects/web/) | the page a wac program is handed — `main(Page page)` — and the builder that makes one `index.html` of it |
| [`ide`](projects/ide/) | an IDE that runs in a browser tab, with wac's compiler checking as you type |
| [`desktop`](projects/desktop/) | a desktop in a browser tab: windows, a taskbar, apps, and the Archive Explorer |
| [`eth`](projects/eth/) | Ethereum: the packages that verify what the chain says, the wacuum execution client and its devnet, and Reckon |
| [`kps`](projects/kps/) | Key-Pinned Streams over WebRTC, in wac |
| [`sqlite`](projects/sqlite/) | SQLite: reads and writes real SQLite database files |
| [`tensor`](projects/tensor/) | tensors, gradients, layers and optimizers |
| [`git`](projects/git/) | a git server, for an unmodified `git` |
| [`repo`](projects/repo/) | this repository's own tooling: the pin check and the package-cache filler |

Get the `wac` command:

```sh
curl -fsSL https://raw.githubusercontent.com/voltrevo/wac/master/projects/wac/bootstrap.sh | sh -s -- --host deno
```

**One repository, separate projects.** A project reaches another only through a pin — a `wac.lock` entry naming
this repository, a commit in its history and the project's `subdir` — exactly as it would a repository elsewhere,
so each moves at its own pace and a change to one does not wait on another's tests. What this repository adds is
one place for all of them; [`CLAUDE.md`](CLAUDE.md) has the rules that make that hold.
