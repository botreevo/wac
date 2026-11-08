// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Names, revocations and deny lists for wac-trust (design/system/0016 H6-H8).
///
/// Everything a client checks is a storage slot, so that its absence can be proved with an
/// eth_getProof against a state root: the client reads slots, never calls functions and never
/// reads events. The layout below is therefore part of the interface, and `src/registry.wac`
/// derives the same slots. Every record is keyed by the address that wrote it: nobody can revoke,
/// deny or name anything on anyone else's behalf, and there is no owner, admin or upgrade.
contract TrustRegistry {
    /// slot 0: revoked[signer][statementId] = timestamp of the revocation, 0 if none.
    mapping(address => mapping(bytes32 => uint256)) public revoked;
    /// slot 1: denied[list][hash] = timestamp the hash was put on that list, 0 if not on it.
    mapping(address => mapping(bytes32 => uint256)) public denied;

    struct Name {
        bytes32 current;      // +0
        bytes32 pending;      // +1  0 when nothing is proposed
        uint256 effectiveAt;  // +2  when pending replaces current
        uint256 delay;        // +3  fixed at claim; how long a proposal waits
    }
    /// slot 2: names[publisher][keccak256(name)]
    mapping(address => mapping(bytes32 => Name)) public names;

    event Revoked(address indexed signer, bytes32 indexed statement);
    event Denied(address indexed list, bytes32 indexed hash, bool on);
    event Proposed(address indexed publisher, bytes32 indexed name, bytes32 hash, uint256 effectiveAt);

    /// A signer withdraws one of their own statements. Permanent: a revocation cannot be undone,
    /// so a stolen key can add revocations but never remove one.
    function revoke(bytes32 statement) external {
        require(revoked[msg.sender][statement] == 0, "already revoked");
        revoked[msg.sender][statement] = block.timestamp;
        emit Revoked(msg.sender, statement);
    }

    /// A deny list is the address that keeps it. Unlike a revocation an entry can come off,
    /// because a list is an opinion that can be corrected.
    function deny(bytes32 hash, bool on) external {
        denied[msg.sender][hash] = on ? block.timestamp : 0;
        emit Denied(msg.sender, hash, on);
    }

    /// The first pointer for a name takes effect at once, and fixes the delay every later change waits.
    function claim(bytes32 name, bytes32 hash, uint256 delay) external {
        Name storage n = names[msg.sender][name];
        require(n.current == bytes32(0), "claimed");
        require(hash != bytes32(0), "zero hash");
        n.current = hash;
        n.delay = delay;
        emit Proposed(msg.sender, name, hash, block.timestamp);
    }

    /// A change is visible at once and effective only after the name's delay, which is the window
    /// for anyone watching to object (revoke, deny) before a follower moves.
    function propose(bytes32 name, bytes32 hash) external {
        Name storage n = names[msg.sender][name];
        require(n.current != bytes32(0), "unclaimed");
        require(hash != bytes32(0), "zero hash");
        if (n.pending != bytes32(0) && block.timestamp >= n.effectiveAt) n.current = n.pending;
        n.pending = hash;
        n.effectiveAt = block.timestamp + n.delay;
        emit Proposed(msg.sender, name, hash, n.effectiveAt);
    }

    /// Withdraw a proposal that has not yet taken effect.
    function cancel(bytes32 name) external {
        Name storage n = names[msg.sender][name];
        require(n.pending != bytes32(0) && block.timestamp < n.effectiveAt, "nothing to cancel");
        n.pending = bytes32(0);
        n.effectiveAt = 0;
        emit Proposed(msg.sender, name, n.current, block.timestamp);
    }
}
