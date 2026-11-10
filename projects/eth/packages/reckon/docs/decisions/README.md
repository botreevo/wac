# Decisions pending

Each memo gives the options, their trade-offs, a recommendation, and what changes in code. Nothing here is decided
until Andrew decides it.

| Memo | Question | Recommendation |
| --- | --- | --- |
| [K1](K1-which-chain.md) | Which chain holds revocations, rejections and names | L1 now. An L2 only if write volume demands it, and then a ZK rollup. EAS not for revocations, since their absence can't be proved |
| [K2](K2-names.md) | Reckon registry names, ENS, or both | Both, as explicit schemes (`ens:NAME`, `name:NAME@0xPUB`) with no precedence, and policy deciding which it follows. ENS text record → registry name later |
| [K3](K3-browser.md) | Loading web apps in a browser | A browser extension, with `claim run` as the native helper meanwhile. A service-worker loader as a fallback. No verifying gateway |
| [J](J-v1-code.md) | The v1 code | Quarantine under `v1/` now. Delete once `claim run` and a CID lock exist |
| [D](D-seed.md) | Does the capstone satisfy D? | No: the seed is still a root. Run wac's bootstrap ladder as derivations and root the policy at its sources |
