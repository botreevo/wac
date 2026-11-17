# The machines, and the texts that define them

A recipe names its machine by a string. The string means what a text says, and the text is named here by its CID: an
edit to it gives another CID and so another machine, never a changed one. `tools/specs.sh` (task `reckon:specs`) checks
every CID below against the file.

| machine | defined by | CID | |
| --- | --- | --- | --- |
| `wasm-gc/wac-host/3` | `docs/machines/wasm-gc-wac-host-3.md` | `bafkreibrqnblfr3fhacaxdvwhxcrqtsk3jpayphceqht42mi2ecaognsey` | as /2, with how a run ended recorded as the host's kind of trap, and an explicit trap's message; the default since wac d48da8771 |
| `wasm-gc/wac-host/2` | `docs/machines/wasm-gc-wac-host-2.md` | `bafkreifs2iwnlhwigrexb6yhbwqf6u4auttshbzc7rw4ukffkuhf5unpky` | WebAssembly with garbage collection, sealed, canonical NaNs, a floor, trap names from the engine's words; runners: `cmd/derive.wac` on V8 and wasmtime, for both |
| `wac-l0/1` | `wac:bootstrap/spec/l0.md` | `bafkreico54x6lyhwewwurc5mh7cmss4sivn5c6jk5dmjev7ebsagjddjpu` | wac's L0 text, assembled; runners: wac's Rust and JavaScript assemblers (docs/l0-machine.md) |
| `wasm-seam/1` | `wac:bootstrap/js/ladder.js` | `bafkreiftyqf7afochsqjz3jjgu3r4w4znxeuruwuaunmxqrhqbie2jud64` | one rung of wac's bootstrap ladder run through its seam (`l1Text`, `through`); runners: node (V8) and wasmtime (docs/seam-machine.md) |
| `wac-flatten/1` | `wac:bootstrap/js/flatten.js` | `bafkreifcoey5u3sfwx4e6kzta5sru3wcu33zsqyumuxhzmynkbpfqfb4em` | a module graph as one program; with the next line, the two implementations that define it together (docs/flatten-machine.md) |
| `wac-flatten/1` | `wac:bootstrap/rust-ladder/src/flatten.rs` | `bafkreibgzsis2ncnyf2nw55fwktvc7jmhcg5lv23afcrdyxkn6bedcj7pu` | |

`wac:` paths are in wac's source at the commit `wac.lock` pins. A CID of a file this small is the raw CID
of its SHA-256, which is what `obj add` gives a file of up to 1 MiB under `unixfs-v1-2025`.

A machine's conformance suite (docs/conformance.md) is evidence that a runner implements it, not its definition.
