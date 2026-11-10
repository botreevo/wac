// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// ENS on a devnet, for tools/byname.sh: just enough of the registry and the public resolver that the code which
/// reads mainnet's by proof (packages/ens: verified.wac, contenthash.wac) reads these unchanged. A fixture, not ENS.
///
/// What is the same as mainnet is the **storage layout**, because that is all a proof-reading client depends on:
///
///     DevENSRegistry   slot 0   mapping(bytes32 node => Record { address owner; address resolver; uint64 ttl; })
///                               (owner at the base; resolver and ttl packed in the next slot)
///     DevResolver      slot 0   mapping(bytes32 node => uint64) recordVersions
///                      slot 1   (the ABI records' mapping on mainnet; unused here)
///                      slot 2   (the address records' mapping; unused here)
///                      slot 3   mapping(uint64 version => mapping(bytes32 node => bytes)) versionable_hashes
///
/// What is not: there is no hierarchy. A node is claimed by whoever claims it first, not by the owner of its parent,
/// and the resolver accepts a contenthash from the node's owner in the registry and nobody else.
contract DevENSRegistry {
    struct Record {
        address owner;
        address resolver;
        uint64 ttl;
    }
    mapping(bytes32 => Record) records;

    event Claimed(bytes32 indexed node, address owner, address resolver);

    function claim(bytes32 node, address resolver_) external {
        require(records[node].owner == address(0) || records[node].owner == msg.sender, "claimed by another");
        records[node] = Record(msg.sender, resolver_, 0);
        emit Claimed(node, msg.sender, resolver_);
    }

    function owner(bytes32 node) external view returns (address) { return records[node].owner; }
    function resolver(bytes32 node) external view returns (address) { return records[node].resolver; }
}

contract DevResolver {
    mapping(bytes32 => uint64) recordVersions;
    mapping(bytes32 => bytes) unusedAbi;
    mapping(bytes32 => address) unusedAddr;
    mapping(uint64 => mapping(bytes32 => bytes)) versionable_hashes;

    DevENSRegistry immutable registry;

    event ContenthashChanged(bytes32 indexed node, bytes hash);
    event VersionChanged(bytes32 indexed node, uint64 newVersion);

    constructor(DevENSRegistry r) { registry = r; }

    modifier owned(bytes32 node) {
        require(registry.owner(node) == msg.sender, "not the node's owner");
        _;
    }

    /// EIP-1577 bytes: 0xe3 0x01 then a CID, for IPFS.
    function setContenthash(bytes32 node, bytes calldata hash) external owned(node) {
        versionable_hashes[recordVersions[node]][node] = hash;
        emit ContenthashChanged(node, hash);
    }

    /// Clears every record at once, as mainnet's does: the old version's bytes stay in storage, unread.
    function clearRecords(bytes32 node) external owned(node) {
        recordVersions[node]++;
        emit VersionChanged(node, recordVersions[node]);
    }

    function contenthash(bytes32 node) external view returns (bytes memory) {
        return versionable_hashes[recordVersions[node]][node];
    }
}
