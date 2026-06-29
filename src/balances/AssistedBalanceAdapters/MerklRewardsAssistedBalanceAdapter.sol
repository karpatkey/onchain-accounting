// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AssistedBalanceAdapter} from "src/balances/AssistedBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Merkl Rewards Balance Adapter (proof-cached)
/// @author KPK
/// @notice Reports a user's *unclaimed* Merkl reward balances. Merkl distributes rewards via off-chain merkle trees;
///         only cumulative *claimed* amounts live on-chain. To make pending allocations queryable from a `view`
///         function, this adapter caches per-(user, token) cumulative allocations submitted via `submitProofs`. Each
///         submission carries the user's **complete** allocation set and **replaces** the prior cache for that user
///         (the assistant always submits the full list; an omitted token is dropped). Each entry is verified against
///         the live Distributor merkle root, so even the `ASSISTANT_ROLE` holder cannot fabricate amounts. The
///         assistant is trusted only to keep the cache fresh; failure to do so makes NAV under-count rewards but never
///         over-count.
/// @dev Access control follows the assisted-adapter family ({AssistedBalanceAdapter}): `DEFAULT_ADMIN_ROLE`
///      administers roles and `ASSISTANT_ROLE` is authorized to submit/clear allocations. Trust model and
///      mutability rationale: see `docs/decisions/0007-merkl-trust-minimized-cache.md`.
contract MerklRewardsAssistedBalanceAdapter is AssistedBalanceAdapter, IPositionDescribable {
    //
    // Type Definitions
    //

    /// @notice One cached allocation entry per (user, token) — the proof-verified per-token total.
    /// @param cumulativeAmount Cumulative amount allocated to `user` for `token` per the merkle leaf (the per-token
    ///                         total, aggregated across all campaigns; this is what the proof attests).
    /// @param root             Distributor merkle root the proof was verified against. Reads return 0 when this
    ///                         root no longer matches `Distributor.getMerkleRoot()` (conservative stale handling).
    /// @param submittedAt      Timestamp of the most recent successful submission. Doubles as a freshness signal
    ///                         and a "first-time entry" check (zero ⇒ never submitted).
    struct CachedAllocation {
        uint256 cumulativeAmount;
        bytes32 root;
        uint64 submittedAt;
    }

    /// @notice One campaign's share of a token's reward, from the Merkl API `breakdowns[]`. Cached per (user, token)
    ///         to give each reward campaign its own NAV position.
    /// @param campaignId       Merkl campaign id (a `bytes32`).
    /// @param subCampaignId    Merkl sub-campaign id (a `bytes32`; encode/hash Merkl's identifier if not natively
    ///                         32 bytes). Together with `campaignId` it forms the position's `positionInstanceId`
    ///                         (`keccak256(abi.encode(campaignId, subCampaignId))`).
    /// @param cumulativeAmount This campaign's cumulative contribution to the token total. NOT individually
    ///                         proof-backed (Merkl proves only the per-token total); the contract instead enforces
    ///                         that the campaign shares of a token SUM to the proof-verified per-token total, so a
    ///                         faulty assistant can mis-split across campaigns but can never inflate the token total.
    struct CampaignShare {
        bytes32 campaignId;
        bytes32 subCampaignId;
        uint256 cumulativeAmount;
    }

    /// @notice One token's entry in a per-user replace submission: the per-token leaf (proof-verified) plus its
    ///         per-campaign breakdown.
    /// @param token            Reward token the leaf is for.
    /// @param cumulativeAmount Cumulative amount in the leaf (`amount` per Merkl's leaf encoding) — the per-token
    ///                         total, proof-verified.
    /// @param proof            Merkle proof from the Merkl API; verified against the live Distributor root.
    /// @param campaigns        Per-campaign breakdown from the API. If non-empty, the contract requires
    ///                         `Σ campaigns[i].cumulativeAmount == cumulativeAmount` (fail-loud) — bounding the total
    ///                         to the proof while letting each campaign become its own position. Empty ⇒ one untagged
    ///                         position for the whole token (`positionInstanceId = bytes32(0)`).
    struct Allocation {
        address token;
        uint256 cumulativeAmount;
        bytes32[] proof;
        CampaignShare[] campaigns;
    }

    //
    // State
    //

    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.MERKL;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.MERKL;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.MERKL;

    /// @notice Hard cap on campaign shares cached per (user, token). Bounds the per-token read fan-out (each share is
    ///         a leg) so a pathological breakdown can't OOG a NAV read (an OOG there is NOT caught by NAVCalculator's
    ///         try/catch). A real token has a handful of campaigns; enforced fail-loud at submit.
    uint256 public constant MAX_CAMPAIGNS_PER_TOKEN = 64;

    /// @notice Merkl Distributor (Angle Labs). Same address on every supported EVM chain.
    address public immutable DISTRIBUTOR;

    /// @notice NAVCalculator — used to look up registered Asset metadata when emitting positions.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Cached allocations: `allocations[user][token] = (cumulativeAmount, root, submittedAt)` — the
    ///         proof-verified per-token total.
    mapping(address user => mapping(address token => CachedAllocation)) public allocations;

    /// @notice Per-(user, token) campaign breakdown (the assistant-submitted `breakdowns[]`). Each share becomes its
    ///         own NAV position, valued as the token's on-chain unclaimed split pro-rata by the share's cumulative.
    ///         Empty ⇒ one untagged position for the token. Shares of a token sum to the token's verified cumulative.
    mapping(address user => mapping(address token => CampaignShare[])) private _campaigns;

    /// @dev Per-user enumeration list. Populated on first `submitProof` for a (user, token) pair, drained by
    ///      `clearAllocation`. Used to power `getAdapterBalances` and `getAdapterPositions` without `address(0)`
    ///      asset filtering — Merkl's universe of distributed tokens is open, so the adapter cannot enumerate it
    ///      ahead of time and `underlyingAssetsSupported()` returns empty.
    mapping(address user => address[]) private _userTokens;

    /// @dev `idxPlus1` = index of `token` in `_userTokens[user]` plus 1. Zero ⇒ not present.
    mapping(address user => mapping(address token => uint256)) private _userTokenIdxPlus1;

    //
    // Events
    //

    event AllocationCached(
        address indexed user,
        address indexed token,
        uint256 cumulativeAmount,
        bytes32 root,
        uint64 submittedAt,
        uint256 campaignCount
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

    /// @notice The submitted campaign breakdown does not sum to the proof-verified per-token cumulative. Bounding the
    ///         campaign shares to the proven total is what keeps the (assistant-supplied) split from inflating NAV.
    error CampaignSumMismatch(address token, uint256 sumOfShares, uint256 tokenCumulative);

    /// @notice More than `MAX_CAMPAIGNS_PER_TOKEN` campaign shares submitted for one token (read-gas bound).
    error TooManyCampaigns(address token, uint256 count);

    //
    // Constructor
    //

    /// @param distributor_     The Merkl Distributor address. Must be a contract.
    /// @param navCalculator_   The NAVCalculator address. Must be a contract.
    /// @param admin_           Holder of `DEFAULT_ADMIN_ROLE` — administers (grants/revokes) `ASSISTANT_ROLE`. Required.
    /// @param assistant_       Holder of `ASSISTANT_ROLE` — authorized to call `submitProof` / `clearAllocation`.
    ///                         Optional (pass `address(0)` to grant later via `admin_`). Should be the OIV Safe.
    constructor(address distributor_, address navCalculator_, address admin_, address assistant_)
        AssistedBalanceAdapter(admin_, assistant_)
    {
        if (distributor_ == address(0) || navCalculator_ == address(0)) {
            revert InvalidArguments();
        }
        require(distributor_.code.length > 0, "Distributor must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        DISTRIBUTOR = distributor_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // Mutators (onlyRole(ASSISTANT_ROLE))
    //

    /// @notice Submit `user`'s **complete** set of Merkl allocations — this **replaces** the user's cached token set
    ///         entirely (every prior `(user, token)` entry is dropped first), so the assistant always submits the full
    ///         list of the user's currently-allocated reward tokens, not a delta; a token omitted from the list is
    ///         removed from NAV. Each entry's proof is verified against the live Distributor merkle root, so even the
    ///         `ASSISTANT_ROLE` holder cannot fabricate amounts.
    /// @dev **Reverts** `InvalidArguments` (zero user/token), `UninitializedRoot`, or `InvalidProof` — writes are
    ///      fail-loud, and because they revert atomically, a bad list leaves the prior set intact. Monotonicity across
    ///      submits is no longer enforced (the cleared cache makes the `AmountRegression` guard moot across calls); the
    ///      live-root proof verification is the real guarantee. `AmountRegression` still catches a decreasing duplicate
    ///      token within a single list.
    /// @param user        Account the allocations are for.
    /// @param allocs      The user's complete set of (token, cumulativeAmount, proof) entries.
    function submitProofs(address user, Allocation[] calldata allocs) external onlyRole(ASSISTANT_ROLE) {
        _submit(user, abi.encode(allocs)); // friendly typed wrapper → shared replace chokepoint (base)
    }

    /// @notice Batch variant: for each user, their allocation list **replaces** that user's cached set. `users` and
    ///         `allocs` must have the same length.
    function submitProofsBatch(address[] calldata users, Allocation[][] calldata allocs)
        external
        onlyRole(ASSISTANT_ROLE)
    {
        bytes[] memory data = new bytes[](allocs.length);
        for (uint256 i; i < allocs.length; ++i) {
            data[i] = abi.encode(allocs[i]);
        }
        _submitBatch(users, data);
    }

    /// @inheritdoc AssistedBalanceAdapter
    /// @dev Decodes the `Allocation[]` list and replaces `account`'s (the user's) cached token set — clear, then
    ///      verify each leaf against the live Distributor root and store, fail-loud.
    function _applyReplace(address account, bytes memory data) internal override {
        Allocation[] memory allocs = abi.decode(data, (Allocation[]));
        _clearUser(account);
        for (uint256 i; i < allocs.length; ++i) {
            _submitProof(account, allocs[i].token, allocs[i].cumulativeAmount, allocs[i].proof, allocs[i].campaigns);
        }
    }

    /// @notice Drop a cached allocation. Idempotent.
    /// @dev Useful to garbage-collect tokens that the user has fully claimed or that Merkl no longer distributes.
    ///      Not required for correctness — stale entries already read as 0 from `getAdapterBalanceForAsset`.
    function clearAllocation(address user, address token) external onlyRole(ASSISTANT_ROLE) {
        if (user == address(0) || token == address(0)) revert InvalidArguments();
        if (allocations[user][token].submittedAt == 0) return; // nothing to clear
        delete allocations[user][token];
        delete _campaigns[user][token];
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

    /// @notice The cached campaign-share breakdown for `(user, token)` (empty if the token was submitted untagged).
    /// @dev Display/debug. The shares sum to the proof-verified per-token cumulative; each becomes one NAV position
    ///      valued as the token's on-chain unclaimed split pro-rata by the share's cumulative.
    function campaignsOf(address user, address token) external view returns (CampaignShare[] memory) {
        return _campaigns[user][token];
    }

    /// @inheritdoc IERC165
    /// @dev Adds {IPositionDescribable} on top of the interfaces advertised by {AssistedBalanceAdapter}
    ///      ({IAssistedBalanceAdapter}, {IBalanceAdapter}, {IAccessControl}, {IERC165}).
    function supportsInterface(bytes4 interfaceId) public view override(AssistedBalanceAdapter) returns (bool) {
        return interfaceId == type(IPositionDescribable).interfaceId || super.supportsInterface(interfaceId);
    }

    function protocolName() external pure returns (string memory) {
        return "Merkl";
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `["Claimable Rewards"]` — a static category (the reward token is in `balanceAsset`; there is no ephemeral
    ///      per-item id, so `positionInstanceId` is empty for this adapter).
    function positionLabels(bytes calldata) external pure override returns (string[] memory out) {
        out = new string[](1);
        out[0] = "Claimable Rewards";
        return out;
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice Open-universe adapter: Merkl distributes arbitrary tokens, so the universe of supported assets is
    ///         not enumerable ahead of time and this returns an empty array. The interface allows this.
    function underlyingAssetsSupported() external pure override returns (address[] memory) {
        return new address[](0);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (account == address(0) || asset == address(0)) return (0, false);
        return (_unclaimed(account, asset), false);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address account)
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

    /// @inheritdoc IBalanceAdapter
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        // Resolve the token list to value, consuming `assetFilter` here so the build runs without it.
        address[] memory tokensToProcess;
        if (assetFilter != address(0)) {
            if (_userTokenIdxPlus1[account][assetFilter] == 0) return new INAVCalculator.PositionBalance[](0);
            tokensToProcess = new address[](1);
            tokensToProcess[0] = assetFilter;
        } else {
            tokensToProcess = _userTokens[account];
        }

        // Build via an external self-staticcall so the row-building frame's only params are `(account, tokens)` —
        // keeping `getAdapterPositions`'s `assetFilter` param (stack-bottom for its whole body) off the build loop's
        // stack, which otherwise overflows the via_ir limit. Mirrors ERC20DefaultBalanceAdapter.buildPositionsSelf.
        positions = this.buildPositionsSelf(account, tokensToProcess);
    }

    /// @notice External self-call entrypoint for the row-building loop (see `getAdapterPositions`). `msg.sender`-guarded
    ///         to `address(this)` so it is not a usable external surface — it exists only to give the build its own
    ///         stack frame (params `(account, tokens)`, no `assetFilter`). `view`, so the self-call is a staticcall.
    function buildPositionsSelf(address account, address[] calldata tokens)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (msg.sender != address(this)) revert NotAuthorized();
        INAVCalculator.Asset[] memory registered = NAV_CALCULATOR.getRegisteredAssets();
        bytes memory pid = abi.encode(DISTRIBUTOR); // identical for every leg — hoist out of the loop

        // Size the scratch buffer to the leg upper bound: one leg per cached campaign share per token (or one
        // untagged leg for a token with no breakdown). Zero-amount legs drop below it.
        uint256 cap;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 c = _campaigns[account][tokens[i]].length;
            cap += c == 0 ? 1 : c;
        }

        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](cap);
        uint256 count;
        for (uint256 i; i < tokens.length; ++i) {
            (INAVCalculator.Asset memory meta, bool found) = RegisteredAssetLib.find(registered, tokens[i]);
            if (!found) continue;
            count = _appendTokenLegs(account, tokens[i], meta, pid, tmp, count);
        }
        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; ++i) {
            positions[i] = tmp[i];
        }
    }

    /// @dev Appends `account`'s reward leg(s) for one `token` into `temp` (from `n`), returning the new count. The
    ///      token's on-chain unclaimed total (`_unclaimed` = proof-verified cumulative − claimed) is split across the
    ///      token's cached campaign shares pro-rata by each share's cumulative (denominator = the verified per-token
    ///      cumulative, which the shares sum to). With no campaign shares, one untagged leg carries the whole
    ///      unclaimed amount. Each campaign leg's `positionInstanceId = keccak256(abi.encode(campaignId,
    ///      subCampaignId))`. Zero-amount legs are omitted; `mulDiv` rounds down, so the campaign legs sum to ≤ the
    ///      token's unclaimed total (dust under-report, never over). Extracted to keep `buildPositionsSelf` under the
    ///      via_ir stack limit.
    function _appendTokenLegs(
        address account,
        address token,
        INAVCalculator.Asset memory meta,
        bytes memory pid,
        INAVCalculator.PositionBalance[] memory temp,
        uint256 n
    ) private view returns (uint256) {
        uint256 unclaimed = _unclaimed(account, token);
        if (unclaimed == 0) return n;

        CampaignShare[] memory shares = _campaigns[account][token];
        if (shares.length == 0) {
            temp[n++] = _row(meta, unclaimed, pid, bytes32(0)); // untagged single position
            return n;
        }

        uint256 tokenCumulative = allocations[account][token].cumulativeAmount; // == Σ shares[].cumulativeAmount
        if (tokenCumulative == 0) return n; // defensive: nothing to split against (all shares would be 0)
        for (uint256 i; i < shares.length; ++i) {
            uint256 legAmount = Math.mulDiv(unclaimed, shares[i].cumulativeAmount, tokenCumulative);
            if (legAmount == 0) continue;
            temp[n++] = _row(meta, legAmount, pid, keccak256(abi.encode(shares[i].campaignId, shares[i].subCampaignId)));
        }
        return n;
    }

    /// @notice Builds one `Rewards` PositionBalance row. Extracted from the `getAdapterPositions` loop so the 9-field
    ///         struct literal lives in its own stack frame (keeps the loop under the via_ir stack limit).
    /// @dev positionId is the Distributor (the claim target / trust anchor), NOT the reward token — the token is
    ///      already carried by `balanceAsset`, so encoding it here would be redundant with the reconciliation key.
    ///      Multiple reward tokens claimed from the same Distributor share this positionId and are distinguished by
    ///      `balanceAsset.asset` (same model as Aave V3 = abi.encode(pool)). `positionInstanceId` carries the Merkl
    ///      campaign coordinate `keccak256(abi.encode(campaignId, subCampaignId))` (or `bytes32(0)` for an untagged
    ///      token) — display/identity only, NOT proof-backed and NOT part of the stable key.
    function _row(INAVCalculator.Asset memory asset, uint256 amount, bytes memory pid, bytes32 instanceId)
        private
        view
        returns (INAVCalculator.PositionBalance memory row)
    {
        // Field-by-field (not a 9-field struct literal) to stay under the via_ir stack limit on the hot path.
        row.balanceAsset = asset;
        row.balanceAdapter = address(this);
        row.amount = amount;
        row.protocolBrand = PROTOCOL_BRAND;
        row.protocolId = PROTOCOL_ID;
        row.protocolSubId = PROTOCOL_SUB_ID;
        row.positionId = pid;
        row.positionKind = PositionKind.Rewards;
        row.positionInstanceId = instanceId;
        // isDebt, isLocked default false.
    }

    //
    // Internal — write
    //

    function _submitProof(
        address user,
        address token,
        uint256 cumulativeAmount,
        bytes32[] memory proof,
        CampaignShare[] memory campaigns
    ) internal {
        if (user == address(0) || token == address(0)) revert InvalidArguments();

        bytes32 root = IMerklDistributor(DISTRIBUTOR).getMerkleRoot();
        if (root == bytes32(0)) revert UninitializedRoot();

        bytes32 leaf = keccak256(abi.encode(user, token, cumulativeAmount));
        if (!_verifyMerklProof(leaf, proof, root)) revert InvalidProof();

        // Defense in depth: Merkl's tree generator guarantees per-(user, token) cumulative amounts are monotonic.
        // A regression suggests the submitter is feeding stale or wrong data; reject loudly. The assistant can clear
        // and resubmit if they really need to override.
        CachedAllocation storage a = allocations[user][token];
        if (cumulativeAmount < a.cumulativeAmount) revert AmountRegression();

        // Campaign breakdown: bound the (assistant-supplied) per-campaign shares to the proof-verified per-token
        // total — Σ shares MUST equal `cumulativeAmount`. This is the safety hinge: the assistant can mis-split value
        // across campaigns but can never make the shares sum to more than the proven total, so NAV is never inflated.
        // An empty breakdown is allowed (one untagged position for the whole token).
        uint256 nCampaigns = campaigns.length;
        if (nCampaigns > MAX_CAMPAIGNS_PER_TOKEN) revert TooManyCampaigns(token, nCampaigns);
        if (nCampaigns != 0) {
            uint256 sumShares;
            for (uint256 i; i < nCampaigns; ++i) {
                sumShares += campaigns[i].cumulativeAmount;
            }
            if (sumShares != cumulativeAmount) revert CampaignSumMismatch(token, sumShares, cumulativeAmount);
        }

        if (a.submittedAt == 0) {
            _userTokens[user].push(token);
            _userTokenIdxPlus1[user][token] = _userTokens[user].length;
        }

        a.cumulativeAmount = cumulativeAmount;
        a.root = root;
        a.submittedAt = uint64(block.timestamp);

        // Replace the token's campaign shares (the per-user set is fully replaced by the submit chokepoint, but a
        // re-submit of the same token within one list overwrites cleanly here too).
        delete _campaigns[user][token];
        for (uint256 i; i < nCampaigns; ++i) {
            _campaigns[user][token].push(campaigns[i]);
        }

        emit AllocationCached(user, token, cumulativeAmount, root, a.submittedAt, nCampaigns);
    }

    /// @dev Delete a user's entire cached allocation set (storage only, no event). Shared by `submitProofs`/batch as
    ///      the replace-on-submit clear step.
    function _clearUser(address user) private {
        address[] storage toks = _userTokens[user];
        for (uint256 i; i < toks.length; ++i) {
            delete allocations[user][toks[i]];
            delete _userTokenIdxPlus1[user][toks[i]];
            delete _campaigns[user][toks[i]];
        }
        delete _userTokens[user];
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
    function _verifyMerklProof(bytes32 leaf, bytes32[] memory proof, bytes32 root) internal pure returns (bool) {
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
