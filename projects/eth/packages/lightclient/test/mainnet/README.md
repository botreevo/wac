Ethereum mainnet light-client data, fetched from lodestar-mainnet.chainsafe.io on 2026-11-10 by `tools/mainnet.sh`
(Fulu; the beacon API's `application/octet-stream` bodies, as served):

- `bootstrap.ssz`: for the finalized checkpoint 0xa8356934e2fba13cb82917ea04203c75ca84bb735cefe3cf2f35976628e1e937, slot 15621760
- `updates.ssz`: period 1906's update, in the API's chunked list form
- `finality.ssz`, `optimistic.ssz`: the latest of each at the time. The optimistic update is signed by 511 of the 512 members.

`test/wac/mainnet_test.wac` verifies them offline, as a regression test on real data: signatures by mainnet's own sync
committee, partial participation included, and the execution block they prove.
- `block.json`, `proof.json`: an execution node's `eth_getBlockByNumber` for the finalized execution block (26382137) and
  `eth_getProof` of the ENS registry's owner and resolver slots for vitalik.eth at that block, as answered (JSON-RPC
  bodies; fetched the same day).
