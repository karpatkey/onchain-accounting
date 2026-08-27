// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AttestedValueCache} from "src/balances/AttestedBalanceAdapters/AttestedValueCache.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {ProtocolNames} from "src/utils/ProtocolNames.sol";

/// @title Merkl Rewards Balance Adapter (permissionless, proof-verified cache)
/// @author KPK
/// @notice Reports a user's *unclaimed* Merkl reward balances. Merkl distributes rewards via off-chain merkle trees;
///         the on-chain Distributor stores only cumulative *claimed* amounts + the current root (the tree lives
///         off-chain behind an IPFS pointer), so a user's allocation is not derivable on-chain. To make pending
///         allocations queryable from a `view`, this adapter caches per-(user, token) cumulative allocations
///         submitted via `submitProofs`, which **upserts** each proven `(user, token)` entry and leaves omitted
///         tokens untouched — so a submit can never suppress a live entry. Every entry is verified against the live
///         Distributor merkle root, so **no caller can fabricate amounts**. The feeder is trusted only to keep the
///         cache fresh; failure to do so makes NAV under-count rewards, never over-count.
///
/// @dev **The first member of the attested family, holding only the Merkl-specific half.** Everything
///      protocol-independent — the `(value, epoch)` cache and its enumeration, the stale-gated clears, the
///      NAV-version probe, the gas-isolated read fan-out, the preview skeleton — lives in {AttestedValueCache}.
///      What remains here is exactly what a protocol must supply: **what the epoch is** (`getMerkleRoot`), **how an
///      attestation is proven** (Merkl's sorted-pair merkle proof), and **how one token's value becomes legs** (the
///      per-campaign pro-rata split).
///
///      **Permissionless & submit-on-behalf-of.** `submitProofs(user, …)` takes an explicit `user` and is callable
///      by anyone — no roles. Because every write is proof-verified, opening it to anyone adds no fabrication risk
///      *in the amounts*. **That is not the same as "a griefer can do nothing".** The proof binds the per-token
///      cumulative but NOT the campaign split — only the shares' SUM is checked — so a third party holding an
///      account's (public) proof can re-submit it split into up to {MAX_CAMPAIGNS_PER_TOKEN} fabricated legs,
///      inflating a real token's leg COUNT and putting attacker-chosen `campaignId`s on reported positions. It is
///      bounded, never inflates NAV, and is repairable in one transaction — but it is a real fabrication of position
///      *identity*, not nothing.
///
///      Trust model: `docs/decisions/0007-merkl-trust-minimized-cache.md`. Family contract: ADR 0022.
contract MerklRewardsAttestedBalanceAdapter is AttestedValueCache {
    //
    // Type Definitions
    //

    /// @notice One campaign's share of a token's reward, from the Merkl API `breakdowns[]`.
    /// @param campaignId       Merkl campaign id.
    /// @param subCampaignId    Merkl sub-campaign id. With `campaignId` it forms the position's
    ///                         `positionInstanceId` (`keccak256(abi.encode(campaignId, subCampaignId))`).
    ///                         **Duplicates are NOT rejected.** Two legs of the same token can carry an identical
    ///                         `positionInstanceId`. Harmless on-chain — it is excluded from the stable
    ///                         reconciliation key and NAV SUMS legs rather than deduping them — but a downstream
    ///                         consumer keying on the instance coordinate cannot tell a fabricated repeat from a
    ///                         genuine one. Campaign identity is display-grade, not audit-grade.
    /// @param cumulativeAmount This campaign's contribution to the token total. NOT individually proof-backed
    ///                         (Merkl proves only the per-token total); the contract instead enforces that the
    ///                         shares SUM to the proof-verified total, so a hostile submitter can mis-split across
    ///                         campaigns but can never inflate the token total.
    struct CampaignShare {
        bytes32 campaignId;
        bytes32 subCampaignId;
        uint256 cumulativeAmount;
    }

    /// @notice One token's entry in a per-user **upsert** submission: the per-token leaf (proof-verified) plus its
    ///         per-campaign breakdown.
    /// @param campaigns If non-empty, the contract requires `Σ campaigns[i].cumulativeAmount == cumulativeAmount`
    ///                  (fail-loud) — bounding the total to the proof while letting each campaign become its own
    ///                  position. Empty ⇒ one untagged position (`positionInstanceId = bytes32(0)`).
    struct Allocation {
        address token;
        uint256 cumulativeAmount;
        bytes32[] proof;
        CampaignShare[] campaigns;
    }

    //
    // State
    //

    /// @notice Hard cap on campaign shares cached per (user, token). This is the *tight* cap because it is the one
    ///         ATTACKER-CONTROLLED amplifier: the merkle proof binds only the per-token cumulative, NOT the
    ///         individual `campaignId`s, so anyone holding a user's public proof can split that proven total into up
    ///         to this many fabricated legs. It can never add tokens the user does not hold — the token set stays
    ///         proof-bounded — so this is the only multiplier a third party can move.
    /// @dev    **These caps bound the READ COST, not the arithmetic.** There is no overflow or wrong-figure path:
    ///         amounts are proof-bounded, the share sum is *checked*, and `Math.mulDiv` floors, so a token's legs
    ///         always sum to at most its unclaimed total. What an over-large leg count produces is not a wrong
    ///         number but an unaffordable one — and read cost is strongly SUPER-LINEAR in leg count, measured on
    ///         this adapter at 104 registered assets:
    ///             256 legs ->   4,183,404 gas
    ///             512 legs ->  10,341,288
    ///            1024 legs ->  30,005,724
    ///            2048 legs ->  98,675,920
    ///         Each doubling multiplies cost by 2.47x, 2.90x, 3.29x — rising — because memory expansion and the ABI
    ///         encoding of a nested-dynamic `PositionBalance[]` both grow faster than the count. So the figure to
    ///         size a budget against is the PRODUCT of the two caps, never either alone. Lowered 32 -> 8 together
    ///         with {MAX_TOKENS_PER_USER} 256 -> 64: the product falls 8192 -> 512 legs, i.e. a worst case of
    ///         ~10.3M gas instead of order 1e9, which no read could ever pay.
    ///
    ///         **Why these stay FAIL-LOUD rather than degrading like `NAVCalculator._MAX_LABEL_ELEMENTS`.** That cap
    ///         is a READ-side guard on UNTRUSTED returndata, where the NAV cannot control what arrives and must
    ///         degrade. These two are WRITE-side storage admission, enforced by the contract that owns the storage,
    ///         before the data exists. Rejecting at write is precisely what keeps the read bounded, so softening it
    ///         would let an oversized submit silently no-op while the feeder believed it had landed.
    uint256 public constant MAX_CAMPAIGNS_PER_TOKEN = 8;

    /// @notice Upper bound on distinct reward tokens cached per user. Every cached token is proof-verified, so the
    ///         cache can never hold a token the user does not really hold.
    /// @dev    **This cap alone is NOT the read bound** — the leg upper bound is
    ///         `MAX_TOKENS_PER_USER * MAX_CAMPAIGNS_PER_TOKEN` = **512**, and it is that PRODUCT a read budget must
    ///         be sized against. The two bound different things: this one bounds the account's genuine,
    ///         PROOF-BOUNDED token footprint, while {MAX_CAMPAIGNS_PER_TOKEN} bounds the amplification a third party
    ///         CAN inflict on a token the user really holds.
    ///
    ///         Two consequences it does not by itself solve, tracked rather than fixed here: (1) under upsert
    ///         semantics the cache accumulates every token ever proven — stale entries are only removed by the
    ///         permissionless, stale-gated clear, so an account farming Merkl across many root epochs drifts toward
    ///         the cap unless the feeder also garbage-collects; (2) reaching the cap makes a submit carrying a NEW
    ///         token revert, and because a submit is atomic over its whole list, that reverts the refresh of the
    ///         account's OTHER tokens too.
    uint256 public constant MAX_TOKENS_PER_USER = 64;

    /// @dev ⚠️ **UNPROVEN — no test discriminates this constant, and none is claimed to.** Setting it to 0 leaves
    ///      every isolation test passing. Swept 300k/200k/150k/120k/100k/90k/80k/70k on a 2-token fixture and
    ///      4M/2M/1.2M/900k/700k/600k/500k/400k on a 32-leg fixture with the griefer LAST: results byte-identical
    ///      with and without the reserve at every budget. Retained as reasoning, not as a verified guard.
    ///
    ///      A REAL limit the same probe DID find, unfixed by this reserve: with 32 legs already accumulated and a
    ///      griefer valued LAST, the whole read reverts at 2,000,000 gas and below — identically with and without
    ///      the reserve. Per-token isolation does NOT make the read unconditionally survivable. Sizing a read budget
    ///      off the cap remains necessary.
    uint256 private constant _COMPLETION_RESERVE_PER_LEG = 256;

    /// @notice Merkl Distributor (Angle Labs). Same address on every supported EVM chain.
    address public immutable DISTRIBUTOR;

    /// @notice Per-(user, token) campaign breakdown (the submitter-supplied `breakdowns[]`). Each share becomes its
    ///         own NAV position, valued as the token's on-chain unclaimed split pro-rata by the share's cumulative.
    ///         Empty ⇒ one untagged position. Shares of a token sum to the token's verified cumulative.
    mapping(address user => mapping(address token => CampaignShare[])) private _campaigns;

    //
    // Errors
    //

    /// @notice Submitted proof did not verify against the current Distributor merkle root.
    error InvalidProof();

    /// @notice Submitted cumulative amount is strictly less than the cached value for the SAME live root. Merkl
    ///         fixes one cumulative per (user, token) per root, so a lower figure against the root the cached entry
    ///         was proven under indicates a malformed or hostile tree.
    error AmountRegression();

    /// @notice The submitted campaign breakdown does not sum to the proof-verified per-token cumulative.
    error CampaignSumMismatch(address token, uint256 sumOfShares, uint256 tokenCumulative);

    /// @notice More than `MAX_CAMPAIGNS_PER_TOKEN` campaign shares submitted for one token (read-gas bound).
    error TooManyCampaigns(address token, uint256 count);

    //
    // Constructor
    //

    /// @param distributor_   The Merkl Distributor address. Must be a contract.
    /// @param navCalculator_ The NAVCalculator address. Validated by {AttestedValueCache}, including the
    ///                       NAV-version probe — so a NAV that cannot serve `getRegisteredAsset` is refused here
    ///                       too, without this member restating the reasoning.
    /// @dev No admin/assistant roles: permissionless. Everything is immutable except the proof-verified cache.
    constructor(address distributor_, address navCalculator_) AttestedValueCache(navCalculator_) {
        if (distributor_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(distributor_, "Distributor");
        DISTRIBUTOR = distributor_;
    }

    //
    // Mutators (permissionless — every write is proof-verified against the live Distributor root)
    //

    /// @notice Submit Merkl allocations for `user` — each entry **upserts** its `(user, token)` cache; tokens
    ///         omitted from `allocs` are left untouched, so this can never suppress a live entry.
    /// @dev Permissionless: keyed on the explicit `user` arg and callable by anyone — proof-verification is the
    ///      integrity guarantee. **Reverts** `InvalidArguments`, `UninitializedEpoch`, `InvalidProof`,
    ///      `TooManyCampaigns`, `CampaignSumMismatch`, `TooManyAttestations`, or `AmountRegression` — fail-loud and
    ///      atomic, so a bad entry reverts the whole call and leaves the prior set intact.
    function submitProofs(address user, Allocation[] calldata allocs) external {
        if (user == address(0)) revert InvalidArguments();
        _upsertAll(user, allocs);
    }

    /// @notice Batch variant: each user's list is upserted into that user's cache.
    /// @dev **Atomic across accounts (by design):** any single entry that reverts reverts the ENTIRE batch, so no
    ///      account in the call is updated. Deliberate fail-loud handling, but it means a multi-account feeder
    ///      should pre-filter bad entries (or fall back to per-account `submitProofs`) so one account's bad data
    ///      cannot block every other account's fresh proofs.
    function submitProofsBatch(address[] calldata users, Allocation[][] calldata allocs) external {
        if (users.length != allocs.length) revert InvalidArguments();
        for (uint256 i; i < users.length; ++i) {
            if (users[i] == address(0)) revert InvalidArguments();
            _upsertAll(users[i], allocs[i]);
        }
    }

    function _upsertAll(address user, Allocation[] calldata allocs) private {
        for (uint256 i; i < allocs.length; ++i) {
            _submitProof(user, allocs[i].token, allocs[i].cumulativeAmount, allocs[i].proof, allocs[i].campaigns);
        }
    }

    /// @dev Verify one leaf against the live root, then hand the proven figure to the base's single admission point.
    function _submitProof(
        address user,
        address token,
        uint256 cumulativeAmount,
        bytes32[] memory proof,
        CampaignShare[] memory campaigns
    ) private {
        if (user == address(0) || token == address(0)) revert InvalidArguments();

        bytes32 root = _liveEpoch();
        if (root == bytes32(0)) revert UninitializedEpoch();

        // Verify the leaf + bound the (submitter-supplied) breakdown to the proof-verified per-token total. Shared
        // verbatim with the preview via `_checkProofAndCampaigns`, so the write path and the preview share ONE
        // definition of validity. The Σ-shares == cumulative rule is the safety hinge: a submitter can mis-split
        // value across campaigns but can never make the shares sum to more than the proven total.
        _checkProofAndCampaigns(root, user, token, cumulativeAmount, proof, campaigns);

        // Defense in depth: within ONE root, Merkl's tree fixes a single cumulative per (user, token), so a lower
        // proof-verified figure offered against the root the cached entry was proven under is evidence of a
        // malformed or hostile tree — reject it loudly.
        //
        // **GATED ON LIVENESS (`epoch == root`), and that conjunct is load-bearing.** Ungated, this compared against
        // a cached value belonging to a root that is no longer live — an entry that already reads 0 and contributes
        // nothing to NAV. Merkl amounts DO legitimately decrease across a rotation (a disputed or clawed-back
        // campaign, an API correction), so the keeper's next cycle would carry a lower cumulative and revert. A
        // submit is ATOMIC over its whole list, so that one entry rolled back the refresh of every OTHER token in
        // the same call; their cached roots were by then stale too, so all of them read 0 and the account's ENTIRE
        // Merkl contribution silently left NAV. It did not self-heal — every subsequent cycle hit the same revert —
        // and recovery needed a human to hand-run a clear. Gating on liveness keeps the guard exactly where it
        // carries meaning: a stale entry has no authority to veto a figure the LIVE root attests. This cannot
        // over-report — `cumulativeAmount` was proof-verified against that live root immediately above.
        Attestation storage a = attestations[user][token];
        if (a.epoch == root && cumulativeAmount < a.value) revert AmountRegression();

        _upsertAttestation(user, token, cumulativeAmount, root);

        // Replace this token's campaign shares wholesale — a re-submit of the same (user, token) overwrites its
        // prior breakdown cleanly.
        delete _campaigns[user][token];
        for (uint256 i; i < campaigns.length; ++i) {
            _campaigns[user][token].push(campaigns[i]);
        }
    }

    //
    // Reads — Merkl-specific views
    //

    /// @notice The cached campaign-share breakdown for `(user, token)` (empty if submitted untagged).
    /// @dev Display/debug. The shares sum to the proof-verified per-token cumulative.
    function campaignsOf(address user, address token) external view returns (CampaignShare[] memory) {
        return _campaigns[user][token];
    }

    function protocolName() external pure returns (string memory) {
        return ProtocolNames.MERKL;
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `["Claimable Rewards"]` — a static category (the reward token is in `balanceAsset`). The argument is
    ///      ignored; the per-leg Merkl campaign coordinate is carried on `positionInstanceId`, not as a label.
    function positionLabels(bytes calldata) external pure override returns (string[] memory out) {
        out = new string[](1);
        out[0] = "Claimable Rewards";
        return out;
    }

    //
    // Hooks — the attested family contract
    //

    /// @inheritdoc AttestedValueCache
    /// @dev Decodes the family's opaque `bytes` into `Allocation[]` and verifies every leaf against `epoch` with the
    ///      SAME helper the write path uses, so preview and cache can never disagree on what a valid proof is.
    ///      Fail-loud: a bad proof reverts rather than being skipped.
    ///
    ///      **Campaign identity is submitter-supplied, not proof-bound.** The proof commits only the per-token
    ///      cumulative, so a consumer must treat the per-campaign `positionInstanceId` on returned legs as
    ///      display-grade — the per-token *amount* is the proof-backed figure.
    function _verifyPreviewPayload(bytes32 epoch, address account, bytes calldata data)
        internal
        view
        override
        returns (address[] memory assets, uint256[] memory values, bytes[] memory ctxs)
    {
        Allocation[] memory allocs = abi.decode(data, (Allocation[]));
        uint256 n = allocs.length;
        // Enforce the cap HERE, immediately after the decode and BEFORE the verification loop. The base re-checks it
        // on the returned arrays as defence in depth, but by then every proof in an oversized payload would already
        // have been verified — so an over-cap caller would pay the full merkle cost only to be rejected.
        if (n > MAX_TOKENS_PER_USER) revert TooManyAttestations(account, n);
        assets = new address[](n);
        values = new uint256[](n);
        ctxs = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            _checkProofAndCampaigns(
                epoch, account, allocs[i].token, allocs[i].cumulativeAmount, allocs[i].proof, allocs[i].campaigns
            );
            assets[i] = allocs[i].token;
            values[i] = allocs[i].cumulativeAmount;
            ctxs[i] = abi.encode(allocs[i].campaigns);
        }
    }

    /// @inheritdoc AttestedValueCache
    /// @dev Merkl's `getMerkleRoot()` accounts for the dispute window: during one, or with a non-zero `disputer`, it
    ///      returns `lastTree.merkleRoot` (the previous root). The root is therefore NOT monotonic and can return to
    ///      a previous value — which is why staleness is a straight equality check and never an extrapolation.
    function _liveEpoch() internal view override returns (bytes32) {
        return IMerklDistributor(DISTRIBUTOR).getMerkleRoot();
    }

    /// @inheritdoc AttestedValueCache
    /// @dev Live `cumulative − Distributor.claimed(account, asset)`, floored at 0.
    ///
    ///      **Not revert-free, deliberately.** The Distributor read is unguarded and its returndata ABI-decoded, so
    ///      this reverts if the Distributor ever returns something *undecodable* (it is an upgradeable proxy under
    ///      Angle governance). On the NAV path a plain revert means this adapter's leg set drops out — an
    ///      under-report, the safe direction, but silent.
    ///
    ///      **A `Claim` reshape can go either way, and WHICH way is decided by the reward token's DECIMALS.** An
    ///      earlier version of this note claimed a field reorder to `(uint48 timestamp, uint208 amount, bytes32
    ///      root)` always decodes cleanly and over-reports, citing a fully-claimed 1000e18 account reporting
    ///      `999999999999999998766`. **That measurement was wrong.** The reorder also moves the real `amount` into
    ///      the slot read as `uint48`, and the ABI decoder range-validates it. Re-measured against a mock returning
    ///      the reordered words raw:
    ///
    ///        - `claimed = 1000e18`  → `1000e18 > 2**48-1` → **decode REVERTS** (no over-report; fails open instead)
    ///        - `claimed = 2**48`    → **decode REVERTS**
    ///        - `claimed = 2**48-1`  → decodes → over-reports `281474976709421`
    ///        - `claimed = 2**40`    → decodes → over-reports `1099511626542`
    ///        - field *append*       → decodes, extra word ignored, value UNCHANGED and correct
    ///
    ///      So the reorder over-report is gated on `real_claimed < 2**48` (281,474,976,710,655 raw units). At 18
    ///      decimals that is 0.00028 tokens — effectively unreachable, so the read reverts and fails open. At **6**
    ///      decimals it is ~281.47M units, i.e. every realistic balance — and Merkl does run USDC/USDT campaigns.
    ///
    ///      This adds no new trust assumption (Angle already controls the root and can inflate any leaf — ADR 0007
    ///      accepts that explicitly), which is why it stays documented rather than guarded. Anyone revisiting that
    ///      decision should start from the accurate predicate above, and note that a cheap guard DOES exist:
    ///      binding the discarded middle field as `(uint208 claimedAmt, uint48 claimedAt,)` and rejecting
    ///      `claimedAt > block.timestamp` has no false positives on the honest layout and, under a reorder, fires
    ///      exactly when the over-report would exceed `block.timestamp`.
    ///
    ///      It is deliberately NOT fail-open-to-0: the clears gate on this value, so a fail-open would let anyone
    ///      clear another account's LIVE entries during a Distributor hiccup — converting a read-availability
    ///      problem into the permissionless-suppression vector the stale-gate exists to close.
    function _liveValue(address account, address asset, uint256 attestedValue)
        internal
        view
        override
        returns (uint256)
    {
        (uint208 claimedAmt,,) = IMerklDistributor(DISTRIBUTOR).claimed(account, asset);
        if (attestedValue <= uint256(claimedAmt)) return 0;
        return attestedValue - uint256(claimedAmt);
    }

    /// @inheritdoc AttestedValueCache
    /// @dev **Load-bearing:** the per-campaign split uses `liveValue` (not `attestedValue`) as the `Math.mulDiv`
    ///      numerator, so the legs of a token always sum to at most its unclaimed total — the over-report guard.
    ///      Empty shares ⇒ one untagged leg. `ctx` is empty on the cache path (shares come from storage) and
    ///      carries the caller-supplied breakdown on the preview path, so both paths build identical legs.
    ///
    ///      positionId is the Distributor (the claim target / trust anchor), NOT the reward token — the token is
    ///      already carried by `balanceAsset`, so encoding it here would be redundant with the reconciliation key.
    ///      Multiple reward tokens from the same Distributor share this positionId and are distinguished by
    ///      `balanceAsset.asset` (same model as Aave V3 = abi.encode(pool)).
    function _assetLegs(
        address account,
        address asset,
        INAVCalculator.Asset memory meta,
        uint256 liveValue,
        uint256 attestedValue,
        bytes memory ctx
    ) internal view override returns (INAVCalculator.PositionBalance[] memory legs) {
        CampaignShare[] memory shares =
            ctx.length == 0 ? _campaigns[account][asset] : abi.decode(ctx, (CampaignShare[]));

        bytes memory pid = abi.encode(DISTRIBUTOR); // identical for every leg of every token
        if (shares.length == 0) {
            legs = new INAVCalculator.PositionBalance[](1);
            legs[0] = _row(meta, liveValue, pid, bytes32(0)); // untagged single position
            return legs;
        }
        if (attestedValue == 0) return new INAVCalculator.PositionBalance[](0); // defensive: nothing to split

        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](shares.length);
        uint256 n;
        for (uint256 i; i < shares.length; ++i) {
            uint256 legAmount = Math.mulDiv(liveValue, shares[i].cumulativeAmount, attestedValue);
            if (legAmount == 0) continue;
            tmp[n++] = _row(meta, legAmount, pid, keccak256(abi.encode(shares[i].campaignId, shares[i].subCampaignId)));
        }
        legs = new INAVCalculator.PositionBalance[](n);
        for (uint256 i; i < n; ++i) {
            legs[i] = tmp[i];
        }
    }

    /// @inheritdoc AttestedValueCache
    function _cachedLegCount(address account, address asset) internal view override returns (uint256) {
        uint256 c = _campaigns[account][asset].length;
        return c == 0 ? 1 : c;
    }

    /// @inheritdoc AttestedValueCache
    function _previewLegCount(bytes memory ctx) internal pure override returns (uint256) {
        uint256 c = abi.decode(ctx, (CampaignShare[])).length;
        return c == 0 ? 1 : c;
    }

    /// @inheritdoc AttestedValueCache
    /// @dev Drops the campaign breakdown in lockstep with the attestation, so no orphan shares survive a clear.
    function _deleteAttestation(address account, address asset) internal override {
        super._deleteAttestation(account, asset);
        delete _campaigns[account][asset];
    }

    function _maxAssetsPerAccount() internal pure override returns (uint256) {
        return MAX_TOKENS_PER_USER;
    }

    function _maxLegsPerAsset() internal pure override returns (uint256) {
        return MAX_CAMPAIGNS_PER_TOKEN;
    }

    function _completionReservePerLeg() internal pure override returns (uint256) {
        return _COMPLETION_RESERVE_PER_LEG;
    }

    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.MERKL;
    }

    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.MERKL;
    }

    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.MERKL;
    }

    function _positionKind() internal pure override returns (PositionKind) {
        return PositionKind.Rewards;
    }

    //
    // Internal — proof
    //

    /// @dev The single source of truth for proof + campaign-shape validity, used by BOTH the cache write and the
    ///      cache-free preview (each then adds its own extra acceptance rule: submit the cache-only
    ///      `AmountRegression`; preview the duplicate-asset guard, applied by the base). Verifies the per-token leaf
    ///      `keccak256(abi.encode(account, token, cumulativeAmount))` against `root`, then bounds any breakdown to
    ///      at most {MAX_CAMPAIGNS_PER_TOKEN} shares that SUM to the proven total.
    function _checkProofAndCampaigns(
        bytes32 root,
        address account,
        address token,
        uint256 cumulativeAmount,
        bytes32[] memory proof,
        CampaignShare[] memory campaigns
    ) private pure {
        bytes32 leaf = keccak256(abi.encode(account, token, cumulativeAmount));
        if (!_verifyMerklProof(leaf, proof, root)) revert InvalidProof();

        uint256 nCampaigns = campaigns.length;
        if (nCampaigns > MAX_CAMPAIGNS_PER_TOKEN) revert TooManyCampaigns(token, nCampaigns);
        if (nCampaigns != 0) {
            uint256 sumShares;
            for (uint256 i; i < nCampaigns; ++i) {
                // CHECKED arithmetic, deliberately: this is the line that stops a wraparound forging
                // `sumShares == cumulativeAmount` from shares that are individually enormous.
                sumShares += campaigns[i].cumulativeAmount;
            }
            if (sumShares != cumulativeAmount) revert CampaignSumMismatch(token, sumShares, cumulativeAmount);
        }
    }

    /// @dev Replicates Merkl's `_verifyProof` byte-for-byte: sorted-pair, `keccak256(abi.encode(a, b))`. The use of
    ///      `abi.encode` (32-byte padded) rather than `abi.encodePacked` is the key deviation from OpenZeppelin's
    ///      `MerkleProof.verify` and we MUST match it for proofs from the Merkl API to verify.
    function _verifyMerklProof(bytes32 leaf, bytes32[] memory proof, bytes32 root) private pure returns (bool) {
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
