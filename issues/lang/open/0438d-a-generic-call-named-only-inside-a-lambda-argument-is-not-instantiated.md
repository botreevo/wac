# 0438d — a generic function called only inside a lambda handed to a constructor is not instantiated

- **Status:** open — worked round in `std/platform.wac` (`openedRandom` calls named helpers)
- **Reported by:** wac-kps (master at 4085b2e9c broke the aggregated test runs of six packages)
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** emit failure

## Reproduction

`std`'s `openedRandom` as 4085b2e9c wrote it — `RandomFile(` six lambdas `)`, each calling the generic
`hostAsk<U>(…, (Answer x) => decode(x, p))` in its body. Any aggregated `wac test` run reaching `Files`
(`packages/ssz/test/wac`, quic, tls, tor, webrtc, lightclient) answered *a call to `hostAsk`, which this expression
is emitted as and which is not in the program*. Moving each body into a named function fixed it.

## Notes

The instance `hostAsk<Result<u8[], HostFault>>` and its siblings are named nowhere but inside those lambdas, which
are themselves arguments of a construction. `findLambdasExpr`'s note says a generic named only inside a lambda was
already a blind spot once and was fixed for the walk that discovers instances; this shape — the lambda an argument
of a `Construct`, the generic call returning from its body with a lambda of its own as an argument — is evidently not
reached. A small reproduction is the next step.
