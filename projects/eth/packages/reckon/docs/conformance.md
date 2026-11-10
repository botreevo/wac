# Runner conformance, as derivations

A witness's claim is worth what its runner is worth. Before this, a policy could ask for two runners on two engines,
and nothing else about them: a runner that leaked its engine's NaNs, or ran without the machine's floor, counted the
same as one that did not. Conformance closes that gap with the system's own means. A runner shows that it implements
the machine by witnessing a suite of the machine's own cases, signed like any other derivation, and a policy counts its
word about anything else only once it has.

`tools/conformance.sh` (task `reckon:conformance`) checks it: 7 of 7.

## The suite

A conformance suite is an object: a tree whose `cases` file has one case per line:

    # comments
    RECIPE OUTPUT       the recipe must give this output tree
    RECIPE none         the recipe must give no output: the machine aborts it (past its floor, out of time)

The suite for `wasm-gc/wac-host/3` is built from `corpus/`, the programs `tools/machine.sh` checks. It has 19 cases:

- every ending the corpus reaches: exit 0, exit 7, and seven kinds of trap (memory-bounds, divide-by-zero,
  integer-overflow, null-reference, unreachable-code, bad-conversion, and explicit, whose message is part of the
  output). The suite for `/2` had 17, with `/2`'s names;
- the float programs, whose NaNs must come out canonical (floats, nanpaths, nbody);
- the probe, which must be refused the host's files, environment, clock and random bytes;
- the resource floor: depth.wac at 10,000 frames and heap.wac at 1 GiB must complete;
- four runs that must give nothing: unbounded recursion, an unbounded heap, a loop, and depth.wac at 1,000,000
  frames.

Each case's output is the one V8 and wasmtime agree on, and only after it gives the ending machine.sh expects. The
suite's author vouches for it as the machine's answer, and a policy names it by CID, so whoever writes the policy
chooses whose suite to trust, as with any root.

## The rule

    conformance: { "wasm-gc/wac-host/3": "bafy…suite" },

With that in a policy, a witness to a derivation under that machine counts only if its signer, **under the same
runner name**, meets all of these:

- it has witnessed every case that has an output, with that output, and has not revoked any of them;
- it has witnessed no case with another output;
- it has witnessed nothing at all for a case that gives none.

Otherwise the witness is left out, and admission says why:

    witnessed by v8 on 1 runner(s) (need 2 on 2); not counted: fresh on "reckon-derive/1 v8, another host": it has witnessed 0 of the suite's 13 cases with an output
    …; not counted: nan on "reckon-derive/1 nan-leaking": it gave bafybeifpj72… for bafyreicupvoy…, where the suite says bafybeih6bgg…
    …; not counted: over on "reckon-derive/1 unbounded": it claimed an output for bafyreidd3sqb…, where the machine gives none

Conformance is per runner name, not per key. A signer that moves to a new engine or a new runner version shows it
again under the new name, which is the point: what was tested is that implementation.

`claim derivation RECIPE OUTPUT --runner NAME --key F` signs a derivation established some other way than by `derive`,
such as another runner of the machine, a hardware attestation, or a machine this repository has no runner for. The
test uses it for the two runners that break the machine.

## What was run (2026-11-10, wac fade22039)

- **The suite** is 17 cases with 4 that give nothing, as one object.
- **Conforming runners.** V8's runner and wasmtime's runner witness the suite, then an app. The app is admitted on
  both witnesses.
- **Runners that do not count:**
  - a runner that never witnessed the suite, though its claim about the app is true;
  - a runner whose floats case carries its engine's own NaN;
  - a runner that signs an output for unbounded recursion.

  Each is refused for the reason shown above.
- **Revocation.** When wasmtime's runner revokes one of its suite derivations, it witnesses 12 of 13 and no longer
  counts.

## Limits

- **The suite is a sample, not a proof.** It catches a runner that gets these programs wrong, not every way to be
  wrong. canonfuzz (docs/canonfuzz.md) is a larger sample of the floats, and either can grow. A bigger suite is a new
  object, and policies move to it by naming it.
- **A runner can witness the suite honestly and lie elsewhere.** Conformance says the implementation is right, not
  that its operator is honest. That is still what two runners on two engines are for.
- **The cost is the suite, once per runner name.** About two minutes per engine, most of it heap.wac's gigabyte.
