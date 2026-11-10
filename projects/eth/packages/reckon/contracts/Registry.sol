// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// reckon's registry, v2: revocations, rejection lists and delayed names, for objects named by IPFS CIDs.
///
/// A prototype. All storage, no owner, no admin, no upgrade: every record is keyed by the address that wrote it, so
/// nobody can revoke, reject or name anything on anyone else's behalf. A client never calls this contract and never
/// reads its events: it reads storage slots with eth_getProof against a state root, so "not revoked" is a proof that
/// a slot is empty. The layout is therefore part of the interface, and `src/registry2.wac` derives the same slots.
///
/// **CIDs.** Every CID reckon uses is CIDv1 with a sha2-256 multihash and a one-byte codec (raw 0x55, dag-pb 0x70,
/// dag-cbor 0x71), so its binary form is 36 bytes: 0x01, codec, 0x12, 0x20, then the 32-byte digest. That is checked
/// on the way in. A CID as a mapping key is `keccak256(cid bytes)`; a CID as a value is two words, codec and digest.
///
/// **Layout** (`k(x)` is keccak256, `p(a)` the address left-padded to 32 bytes, `w(n)` n as a 32-byte word):
///
///     slot 0  revokedAt[signer][k(statement cid)]                  k(k(cid) ‖ k(p(signer) ‖ w(0)))
///               = the block time of the revocation; 0 if not revoked
///     slot 1  rejections[list][k(subject cid)]                     base = k(k(cid) ‖ k(p(list) ‖ w(1)))
///               base+0  since    the block time it was put on the list; 0 if not on it
///               base+1  reason   a hash of the reason: the keeper's choice for reject(), keccak256 of the
///                                statement's reason for rejectSigned(); 0 if none
///     slot 2  names[publisher][k(name as UTF-8)]                   base = k(k(name) ‖ k(p(publisher) ‖ w(2)))
///               base+0  codec          the current CID's codec; 0 if the name was never claimed
///               base+1  digest         the current CID's digest
///               base+2  pendingCodec   a proposed CID's codec; 0 if nothing is proposed
///               base+3  pendingDigest
///               base+4  effectiveAt    when the proposed CID replaces the current one
///               base+5  delay          how long a proposal waits
///               base+6  pendingDelay   a proposed delay
///               base+7  delayAt        when pendingDelay replaces delay; 0 if no delay is proposed
///
/// **A name at time t**, from storage alone: the pending CID if one is proposed and t ≥ effectiveAt, else the current
/// one; its delay is pendingDelay if delayAt ≠ 0 and t ≥ delayAt, else delay. A matured proposal is folded into the
/// current slots by the next write, but a reader never needs that to have happened.
contract Registry {
    mapping(address => mapping(bytes32 => uint256)) public revokedAt;

    struct Rejection {
        uint256 since;   // +0
        bytes32 reason;  // +1
    }
    mapping(address => mapping(bytes32 => Rejection)) public rejections;

    struct Name {
        uint256 codec;          // +0
        bytes32 digest;         // +1
        uint256 pendingCodec;   // +2
        bytes32 pendingDigest;  // +3
        uint256 effectiveAt;    // +4
        uint256 delay;          // +5
        uint256 pendingDelay;   // +6
        uint256 delayAt;        // +7
    }
    mapping(address => mapping(bytes32 => Name)) public names;

    event Revoked(address indexed signer, bytes32 indexed statement);
    event Rejected(address indexed list, bytes32 indexed subject, bool on, bytes32 reason);
    event Proposed(address indexed publisher, bytes32 indexed name, bytes cid, uint256 effectiveAt);
    event DelayProposed(address indexed publisher, bytes32 indexed name, uint256 delay, uint256 effectiveAt);

    /// A CID's codec and digest, refusing anything that is not one of the three reckon uses.
    function split(bytes calldata cid) internal pure returns (uint256 codec, bytes32 digest) {
        require(cid.length == 36 && cid[0] == 0x01 && cid[2] == 0x12 && cid[3] == 0x20, "not a CIDv1 sha2-256");
        codec = uint8(cid[1]);
        require(codec == 0x55 || codec == 0x70 || codec == 0x71, "not a raw, dag-pb or dag-cbor CID");
        digest = bytes32(cid[4:36]);
    }

    // ------------------------------------------------------------------ revocations

    /// A signer withdraws one of their own statements, named by its CID. Permanent: a stolen key can add revocations
    /// but never remove one.
    function revoke(bytes calldata statement) external {
        split(statement);
        record(msg.sender, keccak256(statement));
    }

    /// The address that signed a claims.wac statement whose EIP-712 struct hash is `hash`.
    function signerOf(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address signer) {
        bytes32 domain = keccak256(abi.encode(keccak256("EIP712Domain(string name,string version)"), keccak256("reckon"), keccak256("2")));
        signer = ecrecover(keccak256(abi.encodePacked(hex"1901", domain, hash)), v, r, s);
        require(signer != address(0), "the signature recovers to no address");
    }

    /// The same from a signed Revocation statement (claims.wac's EIP-712), so anyone can relay it: a signer without
    /// gas, or a watcher holding a revocation its signer published off chain.
    function revokeSigned(bytes calldata statement, uint8 v, bytes32 r, bytes32 s) external {
        split(statement);
        bytes32 hash = keccak256(abi.encode(keccak256("Revocation(bytes statement)"), keccak256(statement)));
        record(signerOf(hash, v, r, s), keccak256(statement));
    }

    function record(address signer, bytes32 key) internal {
        require(revokedAt[signer][key] == 0, "already revoked");
        revokedAt[signer][key] = block.timestamp;
        emit Revoked(signer, key);
    }

    // ------------------------------------------------------------------ rejection lists

    /// A rejection list is the address that keeps it. Unlike a revocation an entry can come off: a list is an opinion,
    /// and opinions get corrected.
    function reject(bytes calldata subject, bytes32 reason) external {
        split(subject);
        bytes32 key = keccak256(subject);
        rejections[msg.sender][key] = Rejection(block.timestamp, reason);
        emit Rejected(msg.sender, key, true, reason);
    }

    function unreject(bytes calldata subject) external {
        split(subject);
        bytes32 key = keccak256(subject);
        delete rejections[msg.sender][key];
        emit Rejected(msg.sender, key, false, 0);
    }

    /// The CID of claims.wac's Rejection statement `{kind: "rejection", subject, reason}`: its DAG-CBOR encoding
    /// (keys in DAG-CBOR's order: kind, reason, subject; the subject a tag-42 link), hashed with sha2-256.
    function rejectionId(bytes calldata subject, string calldata reason) public pure returns (bytes memory) {
        split(subject);
        uint256 n = bytes(reason).length;
        bytes memory head;
        if (n < 24) head = abi.encodePacked(uint8(0x60 + n));
        else if (n < 256) head = abi.encodePacked(uint8(0x78), uint8(n));
        else if (n < 65536) head = abi.encodePacked(uint8(0x79), uint16(n));
        else { require(n < 2 ** 32, "reason too long"); head = abi.encodePacked(uint8(0x7a), uint32(n)); }
        bytes memory block_ = abi.encodePacked(hex"a3646b696e646972656a656374696f6e66726561736f6e", head, reason,
                                               hex"677375626a656374d82a582500", subject);
        return abi.encodePacked(hex"01711220", sha256(block_));
    }

    /// A Rejection statement signed by a list's keeper, relayed by anyone: the subject goes on the signer's list, with
    /// the reason's keccak256 as its reason. A rejection its signer has revoked cannot be relayed again; to reject
    /// again after withdrawing, a keeper signs a new rejection (another reason is another statement).
    function rejectSigned(bytes calldata subject, string calldata reason, uint8 v, bytes32 r, bytes32 s) external {
        split(subject);
        bytes32 hash = keccak256(abi.encode(keccak256("Rejection(bytes subject,string reason)"), keccak256(subject), keccak256(bytes(reason))));
        address signer = signerOf(hash, v, r, s);
        require(revokedAt[signer][keccak256(rejectionId(subject, reason))] == 0, "that rejection was revoked by its signer");
        bytes32 key = keccak256(subject);
        rejections[signer][key] = Rejection(block.timestamp, keccak256(bytes(reason)));
        emit Rejected(signer, key, true, keccak256(bytes(reason)));
    }

    /// A signed Revocation of a Rejection statement, relayed by anyone: the revocation is recorded (permanently, as any
    /// revocation), and the subject comes off the signer's list if that rejection is still the entry there.
    function unrejectSigned(bytes calldata subject, string calldata reason, uint8 v, bytes32 r, bytes32 s) external {
        bytes memory id = rejectionId(subject, reason);
        address signer = signerOf(keccak256(abi.encode(keccak256("Revocation(bytes statement)"), keccak256(id))), v, r, s);
        record(signer, keccak256(id));
        bytes32 key = keccak256(subject);
        if (rejections[signer][key].reason == keccak256(bytes(reason))) {
            delete rejections[signer][key];
            emit Rejected(signer, key, false, 0);
        }
    }

    // ------------------------------------------------------------------ delayed names

    /// Fold anything whose time has come into the current slots. Readers do not depend on it.
    function settle(Name storage n) internal {
        if (n.pendingCodec != 0 && block.timestamp >= n.effectiveAt) {
            (n.codec, n.digest) = (n.pendingCodec, n.pendingDigest);
            (n.pendingCodec, n.pendingDigest, n.effectiveAt) = (0, 0, 0);
        }
        if (n.delayAt != 0 && block.timestamp >= n.delayAt) {
            (n.delay, n.pendingDelay, n.delayAt) = (n.pendingDelay, 0, 0);
        }
    }

    /// The first CID for a name takes effect at once, and sets the delay every later change waits.
    function claim(string calldata name, bytes calldata cid, uint256 delay) external {
        Name storage n = names[msg.sender][keccak256(bytes(name))];
        require(n.codec == 0, "already claimed");
        (n.codec, n.digest) = split(cid);
        n.delay = delay;
        emit Proposed(msg.sender, keccak256(bytes(name)), cid, block.timestamp);
    }

    /// A change is public at once and effective only after the delay: the window for anyone watching to revoke or
    /// reject before a follower moves. A second proposal replaces the first and starts the wait again.
    function propose(string calldata name, bytes calldata cid) external {
        Name storage n = names[msg.sender][keccak256(bytes(name))];
        require(n.codec != 0, "not claimed");
        settle(n);
        (n.pendingCodec, n.pendingDigest) = split(cid);
        n.effectiveAt = block.timestamp + n.delay;
        emit Proposed(msg.sender, keccak256(bytes(name)), cid, n.effectiveAt);
    }

    /// Withdraw a proposal that has not taken effect.
    function cancel(string calldata name) external {
        Name storage n = names[msg.sender][keccak256(bytes(name))];
        settle(n);
        require(n.pendingCodec != 0, "nothing to cancel");
        (n.pendingCodec, n.pendingDigest, n.effectiveAt) = (0, 0, 0);
    }

    /// A new delay waits out the current one, so a stolen key cannot shorten the window and then use it.
    function proposeDelay(string calldata name, uint256 delay) external {
        Name storage n = names[msg.sender][keccak256(bytes(name))];
        require(n.codec != 0, "not claimed");
        settle(n);
        n.pendingDelay = delay;
        n.delayAt = block.timestamp + n.delay;
        emit DelayProposed(msg.sender, keccak256(bytes(name)), delay, n.delayAt);
    }
}
