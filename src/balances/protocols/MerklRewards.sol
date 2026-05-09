// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionType} from "src/utils/PositionType.sol";

/// @title Merkl Rewards Balance Oracle (proof-cached)
/// @author kpk
/// @notice Reports a user's *unclaimed* Merkl reward balances. Merkl distributes rewards via off-chain merkle trees;
///         only cumulative *claimed* amounts live on-chain. To make pending allocations queryable from a `view`
///         function, this adapter caches per-(user, token) cumulative allocations submitted via `submitProof`. Each
///         submission is verified against the live Distributor merkle root, so even the cache's owner cannot
///         fabricate amounts. The owner is trusted only to keep the cache fresh; failure to do so makes NAV
///         under-count rewards but never over-count.
/// @dev Trust model and mutability rationale: see `docs/decisions/0007-merkl-trust-minimized-cache.md`.
contract MerklRewardsBalanceOracle is IBalanceOracleAdapter, Ownable {
    //
    // Type Definitions
    //

    /// @notice One cached allocation entry per (user, token).
    /// @param cumulativeAmount Cumulative amount allocated to `user` for `token` per the merkle leaf.
    /// @param root             Distributor merkle root the proof was verified against. Reads return 0 when this
    ///                         root no longer matches `Distributor.getMerkleRoot()` (conservative stale handling).
    /// @param submittedAt      Timestamp of the most recent successful submission. Doubles as a freshness signal
    ///                         and a "first-time entry" check (zero ⇒ never submitted).
    struct CachedAllocation {
        uint256 cumulativeAmount;
        bytes32 root;
        uint64 submittedAt;
    }

    //
    // State
    //

    /// @notice Merkl Distributor (Angle Labs). Same address on every supported EVM chain.
    address public immutable DISTRIBUTOR;

    /// @notice NAVCalculator — used to look up registered Asset metadata when emitting positions.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Protocol identifier emitted on every PositionBalance (e.g. "Merkl").
    string public PROTOCOL;

    /// @notice JSON metadata base (no closing `}`) emitted on every PositionBalance.
    string public POSITION_DETAIL;

    /// @notice Stable hex identifier for this adapter instance (distributor address).
    string private _positionId;

    /// @notice Cached allocations: `allocations[user][token] = (cumulativeAmount, root, submittedAt)`.
    mapping(address user => mapping(address token => CachedAllocation)) public allocations;

    /// @dev Per-user enumeration list. Populated on first `submitProof` for a (user, token) pair, drained by
    ///      `clearAllocation`. Used to power `getOracleBalances` and `getOraclePositions` without `address(0)`
    ///      asset filtering — Merkl's universe of distributed tokens is open, so the adapter cannot enumerate it
    ///      ahead of time and `underlyingAssetsSupported()` returns empty.
    mapping(address user => address[]) private _userTokens;

    /// @dev `idxPlus1` = index of `token` in `_userTokens[user]` plus 1. Zero ⇒ not present.
    mapping(address user => mapping(address token => uint256)) private _userTokenIdxPlus1;

    //
    // Events
    //

    event AllocationCached(
        address indexed user, address indexed token, uint256 cumulativeAmount, bytes32 root, uint64 submittedAt
    );
    event AllocationCleared(address indexed user, address indexed token);

    //
    // Errors
    //

    /// @notice Submitted proof did not verify against the current Distributor merkle root.
    error InvalidProof();

    /// @notice Distributor's `getMerkleRoot()` returned `bytes32(0)` (uninitialized).
    error UninitializedRoot();

    /// @notice Submitted cumulative amount is strictly less than the cached value. Merkl invariants are monotonic;
    ///         a regression suggests a stale or malformed proof and is rejected as a defense in depth.
    error AmountRegression();

    //
    // Constructor
    //

    /// @param distributor_     The Merkl Distributor address. Must be a contract.
    /// @param navCalculator_   The NAVCalculator address. Must be a contract.
    /// @param protocol_        Protocol identifier (e.g. "Merkl").
    /// @param positionDetail_  JSON metadata base without closing `}`.
    /// @param positionId_      Stable hex identifier for this adapter instance (distributor address).
    /// @param initialOwner_    Owner authorized to call `submitProof` / `clearAllocation`. Should be the OIV Safe.
    constructor(
        address distributor_,
        address navCalculator_,
        string memory protocol_,
        string memory positionDetail_,
        string memory positionId_,
        address initialOwner_
    ) Ownable(initialOwner_) {
        if (distributor_ == address(0) || navCalculator_ == address(0)) {
            revert InvalidArguments();
        }
        require(distributor_.code.length > 0, "Distributor must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        DISTRIBUTOR = distributor_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
        PROTOCOL = protocol_;
        POSITION_DETAIL = positionDetail_;
        _positionId = positionId_;
    }

    //
    // Mutators (onlyOwner)
    //

    /// @notice Verify a Merkl proof and cache the resulting allocation for `(user, token)`.
    /// @dev Reverts on invalid proof, uninitialized root, zero address, or amount regression.
    /// @param user             Account the leaf is for.
    /// @param token            Reward token the leaf is for.
    /// @param cumulativeAmount Cumulative amount in the leaf (`amount` field per Merkl's leaf encoding).
    /// @param proof            Merkle proof from the Merkl API. Verified against `Distributor.getMerkleRoot()`.
    function submitProof(address user, address token, uint256 cumulativeAmount, bytes32[] calldata proof)
        external
        onlyOwner
    {
        _submitProof(user, token, cumulativeAmount, proof);
    }

    /// @notice Batch variant of `submitProof`. All arrays must have the same length.
    function submitProofBatch(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata cumulativeAmounts,
        bytes32[][] calldata proofs
    ) external onlyOwner {
        uint256 n = users.length;
        if (tokens.length != n || cumulativeAmounts.length != n || proofs.length != n) revert ArrayLengthMismatch();
        for (uint256 i; i < n; ++i) {
            _submitProof(users[i], tokens[i], cumulativeAmounts[i], proofs[i]);
        }
    }

    /// @notice Drop a cached allocation. Idempotent.
    /// @dev Useful to garbage-collect tokens that the user has fully claimed or that Merkl no longer distributes.
    ///      Not required for correctness — stale entries already read as 0 from `getOracleBalanceForAsset`.
    function clearAllocation(address user, address token) external onlyOwner {
        if (user == address(0) || token == address(0)) revert InvalidArguments();
        if (allocations[user][token].submittedAt == 0) return; // nothing to clear
        delete allocations[user][token];
        _removeUserToken(user, token);
        emit AllocationCleared(user, token);
    }

    //
    // Reads (view, anyone)
    //

    /// @notice Tokens currently cached for `user`.
    /// @dev Returned regardless of staleness. Filter at the call site using `allocations(user, token).root`
    ///      against `Distributor.getMerkleRoot()` if you need only fresh entries.
    function userTokens(address user) external view returns (address[] memory) {
        return _userTokens[user];
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Open-universe oracle: Merkl distributes arbitrary tokens, so the universe of supported assets is
    ///         not enumerable ahead of time and this returns an empty array. The interface allows this.
    function underlyingAssetsSupported() external pure override returns (address[] memory) {
        return new address[](0);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (account == address(0) || asset == address(0)) return (0, false);
        return (_unclaimed(account, asset), false);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        if (account == address(0)) return (new address[](0), new uint256[](0), new bool[](0));

        address[] memory tokens = _userTokens[account];
        uint256 n = tokens.length;
        address[] memory tmpAssets = new address[](n);
        uint256[] memory tmpAmounts = new uint256[](n);
        uint256 count;

        for (uint256 i; i < n; ++i) {
            uint256 bal = _unclaimed(account, tokens[i]);
            if (bal != 0) {
                tmpAssets[count] = tokens[i];
                tmpAmounts[count] = bal;
                ++count;
            }
        }

        assets = new address[](count);
        amounts = new uint256[](count);
        isDebt = new bool[](count);
        for (uint256 i; i < count; ++i) {
            assets[i] = tmpAssets[i];
            amounts[i] = tmpAmounts[i];
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        INAVCalculator.Asset[] memory registered = NAV_CALCULATOR.getRegisteredAssets();

        address[] memory tokens = _userTokens[account];
        uint256 n = tokens.length;
        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](n);
        uint256 count;

        for (uint256 i; i < n; ++i) {
            address token = tokens[i];
            if (assetFilter != address(0) && token != assetFilter) continue;
            INAVCalculator.Asset memory meta = _findRegisteredAsset(registered, token);
            if (meta.asset == address(0)) continue;
            uint256 bal = _unclaimed(account, token);
            if (bal == 0) continue;
            tmp[count++] = INAVCalculator.PositionBalance({
                underlyingAsset: meta,
                balanceOracle: address(this),
                amount: bal,
                isDebt: false,
                protocol: PROTOCOL,
                positionDetail: PositionType.withType(POSITION_DETAIL, PositionType.REWARDS),
                positionId: _positionId
            });
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; ++i) {
            positions[i] = tmp[i];
        }
    }

    //
    // Internal — write
    //

    function _submitProof(address user, address token, uint256 cumulativeAmount, bytes32[] calldata proof) internal {
        if (user == address(0) || token == address(0)) revert InvalidArguments();

        bytes32 root = IMerklDistributor(DISTRIBUTOR).getMerkleRoot();
        if (root == bytes32(0)) revert UninitializedRoot();

        bytes32 leaf = keccak256(abi.encode(user, token, cumulativeAmount));
        if (!_verifyMerklProof(leaf, proof, root)) revert InvalidProof();

        // Defense in depth: Merkl's tree generator guarantees per-(user, token) cumulative amounts are monotonic.
        // A regression suggests the submitter is feeding stale or wrong data; reject loudly. Owner can clear and
        // resubmit if they really need to override.
        CachedAllocation storage a = allocations[user][token];
        if (cumulativeAmount < a.cumulativeAmount) revert AmountRegression();

        if (a.submittedAt == 0) {
            _userTokens[user].push(token);
            _userTokenIdxPlus1[user][token] = _userTokens[user].length;
        }

        a.cumulativeAmount = cumulativeAmount;
        a.root = root;
        a.submittedAt = uint64(block.timestamp);

        emit AllocationCached(user, token, cumulativeAmount, root, a.submittedAt);
    }

    function _removeUserToken(address user, address token) internal {
        uint256 idxPlus1 = _userTokenIdxPlus1[user][token];
        if (idxPlus1 == 0) return;
        uint256 idx = idxPlus1 - 1;
        address[] storage list = _userTokens[user];
        uint256 lastIdx = list.length - 1;
        if (idx != lastIdx) {
            address lastToken = list[lastIdx];
            list[idx] = lastToken;
            _userTokenIdxPlus1[user][lastToken] = idx + 1;
        }
        list.pop();
        delete _userTokenIdxPlus1[user][token];
    }

    //
    // Internal — math + proof
    //

    /// @dev Returns the unclaimed reward amount for `(account, asset)`, or 0 if the cache is stale or fully claimed.
    ///      Never reverts. Stale handling: if cached `root != Distributor.getMerkleRoot()`, treat as 0 — never
    ///      assume cumulative monotonicity to extrapolate; require a fresh proof against the new root.
    function _unclaimed(address account, address asset) internal view returns (uint256) {
        CachedAllocation memory a = allocations[account][asset];
        if (a.submittedAt == 0) return 0;
        bytes32 currentRoot = IMerklDistributor(DISTRIBUTOR).getMerkleRoot();
        if (a.root != currentRoot) return 0;
        (uint208 claimedAmt,,) = IMerklDistributor(DISTRIBUTOR).claimed(account, asset);
        if (a.cumulativeAmount <= uint256(claimedAmt)) return 0;
        return a.cumulativeAmount - uint256(claimedAmt);
    }

    /// @dev Replicates Merkl's `_verifyProof` byte-for-byte: sorted-pair, `keccak256(abi.encode(a, b))`. The use
    ///      of `abi.encode` (32-byte padded) rather than `abi.encodePacked` is the key deviation from
    ///      OpenZeppelin's `MerkleProof.verify` and we MUST match it for proofs from the Merkl API to verify.
    function _verifyMerklProof(bytes32 leaf, bytes32[] calldata proof, bytes32 root) internal pure returns (bool) {
        bytes32 currentHash = leaf;
        uint256 n = proof.length;
        for (uint256 i; i < n;) {
            bytes32 sibling = proof[i];
            if (currentHash < sibling) {
                currentHash = keccak256(abi.encode(currentHash, sibling));
            } else {
                currentHash = keccak256(abi.encode(sibling, currentHash));
            }
            unchecked {
                ++i;
            }
        }
        return currentHash == root;
    }

    function _findRegisteredAsset(INAVCalculator.Asset[] memory registered, address asset)
        internal
        pure
        returns (INAVCalculator.Asset memory)
    {
        uint256 n = registered.length;
        for (uint256 i; i < n; ++i) {
            if (registered[i].asset == asset) return registered[i];
        }
        return INAVCalculator.Asset({asset: address(0), symbol: "", decimals: 0});
    }
}

/// @notice Minimal interface for Merkl's Distributor (Angle Labs).
/// @dev Reference: https://github.com/AngleProtocol/merkl-contracts/blob/main/contracts/Distributor.sol
interface IMerklDistributor {
    /// @notice Returns the active merkle root, accounting for the dispute window. During a dispute window or with
    ///         a non-zero `disputer`, this returns `lastTree.merkleRoot` (the previous root); otherwise
    ///         `tree.merkleRoot`.
    function getMerkleRoot() external view returns (bytes32);

    /// @notice Auto-generated getter for the public `mapping(address => mapping(address => Claim))` storage.
    /// @return amount      Cumulative amount the `user` has already claimed for `token` (uint208).
    /// @return timestamp   Timestamp of the most recent claim (uint48).
    /// @return merkleRoot  Merkle root the most recent claim was made against.
    function claimed(address user, address token)
        external
        view
        returns (uint208 amount, uint48 timestamp, bytes32 merkleRoot);
}
