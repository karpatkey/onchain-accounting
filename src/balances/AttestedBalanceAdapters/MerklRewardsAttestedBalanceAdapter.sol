// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IAttestedBalanceAdapter} from "src/balances/IAttestedBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {ProtocolNames} from "src/utils/ProtocolNames.sol";

/// @title Merkl Rewards Balance Adapter (permissionless, proof-verified cache)
/// @author KPK
/// @notice Reports a user's *unclaimed* Merkl reward balances. Merkl distributes rewards via off-chain merkle trees;
///         the on-chain Distributor stores only cumulative *claimed* amounts + the current root (the full tree lives
///         off-chain behind an IPFS pointer), so a user's allocation is not derivable on-chain. To make pending
///         allocations queryable from a `view`, this adapter caches per-(user, token) cumulative allocations submitted
///         via `submitProofs`, which **upserts** each proven `(user, token)` entry (adds or refreshes it) and leaves
///         omitted tokens untouched — so a submit can never suppress a live entry. Every entry is verified against the
///         live Distributor merkle root, so **no caller can fabricate amounts** — a submission only lands if its proof
///         validates against Merkl's real root for that exact `(user, token, cumulativeAmount)` leaf. The feeder is
///         trusted only to keep the cache fresh; failure to do so makes NAV under-count rewards, never over-count.
/// @dev **Permissionless & submit-on-behalf-of.** `submitProofs(user, …)` takes an explicit `user` and is callable by
///      anyone — no roles, no AccessControl. The intended feeder is a keeper EOA (cron job) that periodically submits
///      the tracked accounts' allocations, but because every write is proof-verified, opening it to anyone adds no
///      fabrication risk: the worst a griefer can do is pay gas to cache a user's *real* Merkl allocation (bounded to
///      that user's actual reward footprint). This is the permissionless "v2" ADR 0007 anticipated. It does NOT use
///      the coordinate-cache {IAssistedBalanceAdapter} family — that marker is `msg.sender`-keyed and caches
///      coordinates never amounts, and Merkl is neither (it submits on-behalf-of and caches a proof-verified amount);
///      its "under-report only" guarantee rests on proof-verification + stale-root→0 instead. `clearAllocation` is
///      **stale-gated** (removable only once an entry contributes 0 to NAV), so no caller can suppress a live entry.
///      Trust model + mutability rationale: see `docs/decisions/0007-merkl-trust-minimized-cache.md`.
///
///      **Family: {IAttestedBalanceAdapter} (attested), NOT {IAssistedBalanceAdapter} (coordinate cache).** The feeder
///      submits proven per-(user, token) allocations on-behalf-of, from a plain keeper EOA — there is no `delegatecall`
///      assistant contract, and each write is an upsert (never drops an omitted entry). Integrity is the per-write
///      merkle-proof check ("attestation"), not `msg.sender`-keying or live-ownership re-verification; the
///      "under-report only" guarantee rests on proof-verification + stale-root→0.
contract MerklRewardsAttestedBalanceAdapter is IAttestedBalanceAdapter, IPositionDescribable {
    //
    // Type Definitions
    //

    /// @notice One cached allocation entry per (user, token) — the proof-verified per-token total.
    /// @param cumulativeAmount Cumulative amount allocated to `user` for `token` per the merkle leaf (the per-token
    ///                         total, aggregated across all campaigns; this is what the proof attests).
    /// @param root             Distributor merkle root the proof was verified against. Reads return 0 when this
    ///                         root no longer matches `Distributor.getMerkleRoot()` (conservative stale handling).
    ///                         Also the entry's **presence sentinel**: a stored entry always has `root != 0` (the
    ///                         `UninitializedRoot` check rejects a zero root), so `root == 0` ⇔ nothing cached.
    /// @param submittedAt      Timestamp of the most recent successful submission — a freshness signal for operators
    ///                         only. Deliberately NOT used as the presence check: that would rest on
    ///                         `block.timestamp != 0` rather than on an invariant this contract enforces.
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
    ///         try/catch). This is the *tight* cap because it is the one attacker-controlled amplifier: the merkle
    ///         proof binds only the per-token cumulative total, NOT the individual `campaignId`s, so anyone holding a
    ///         user's (public) per-token proof can split that proven total into up to this many fabricated campaign
    ///         legs — a griefer can inflate a *real* token's leg count by this factor (but never add tokens the user
    ///         doesn't really hold — the token set stays proof-bounded). Kept low to cap that amplification while still
    ///         leaving headroom for a diversified LP earning one token across many pools. A real token has a handful of
    ///         campaigns; enforced fail-loud at submit.
    uint256 public constant MAX_CAMPAIGNS_PER_TOKEN = 32;

    /// @notice Upper bound on distinct reward tokens cached per user. Bounds the read-side fan-out (the position/
    ///         balance loops iterate `_userTokens[user]`), mirroring the sibling assisted adapters' per-account caps.
    ///         A real portfolio's Merkl reward-token footprint is a handful; enforced fail-loud when a *new* token is
    ///         first cached (a refresh of an existing token is unaffected). Every cached token is proof-verified, so
    ///         the cache can never hold a token the user does not really hold.
    /// @dev    **This cap alone is NOT the read bound.** The position read emits one leg per cached *campaign share*,
    ///         so the leg upper bound is `MAX_TOKENS_PER_USER * MAX_CAMPAIGNS_PER_TOKEN` = 8192 — and the campaign
    ///         multiplier is the factor that is NOT proof-bound (only the shares' SUM is checked), so a third party
    ///         holding a user's public per-token proof can inflate a real token's leg count 32x. Do not size a read
    ///         budget off 256. See the note on {MAX_CAMPAIGNS_PER_TOKEN} and ADR 0022.
    ///
    ///         Two consequences the cap does not by itself solve, both tracked rather than fixed here: (1) under
    ///         upsert semantics `_userTokens` accumulates every token ever proven — stale entries are only removed by
    ///         a permissionless, stale-gated `clearAllocation`, so an account farming Merkl across many root epochs
    ///         drifts toward the cap unless the feeder also garbage-collects; (2) reaching the cap makes a submit
    ///         carrying a NEW token revert `TooManyTokens`, and because a submit is atomic over its whole list, that
    ///         reverts the refresh of the account's OTHER tokens too.
    uint256 public constant MAX_TOKENS_PER_USER = 256;

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

    /// @dev Per-user enumeration list. Populated on first `submitProofs` entry for a (user, token) pair, drained by
    ///      `clearAllocation`. Used to power `getAdapterBalances` and `getAdapterPositions` without `address(0)`
    ///      asset filtering — Merkl's universe of distributed tokens is open, so the adapter cannot enumerate it
    ///      ahead of time and `underlyingAssetsSupported()` returns empty.
    mapping(address user => address[]) private _userTokens;

    /// @dev `idxPlus1` = index of `token` in `_userTokens[user]` plus 1. Zero ⇒ not present.
    mapping(address user => mapping(address token => uint256)) private _userTokenIdxPlus1;

    //
    // Events
    //

    /// @notice Emitted on every `(user, token)` upsert.
    /// @param submitter The caller that fed this allocation (`msg.sender`). Recorded for off-chain
    ///                  attribution/monitoring ONLY — submission is permissionless, so this is NOT an
    ///                  authorization check and carries no privilege; integrity comes from the merkle proof.
    event AllocationCached(
        address indexed user,
        address indexed token,
        address indexed submitter,
        uint256 cumulativeAmount,
        bytes32 root,
        uint64 submittedAt,
        uint256 campaignCount
    );
    event AllocationCleared(address indexed user, address indexed token);
    event AccountCleared(address indexed user);

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

    /// @notice Adding this token would exceed `MAX_TOKENS_PER_USER` distinct cached tokens for `user`.
    error TooManyTokens(address user, uint256 count);

    /// @notice `clearAllocation` was called on an entry that still contributes to NAV (cached root matches the live
    ///         root AND it has an unclaimed balance). Clearing is GC for dead entries only — a live entry can only be
    ///         *refreshed* via `submitProofs` (upsert), never suppressed. This is what makes the permissionless clear safe: no
    ///         caller can zero out another account's valid reward (the fix for the old `ASSISTANT_ROLE` L-02 vector).
    error AllocationStillLive(address user, address token);

    /// @notice `clearAllocation` was called on a `(user, token)` with nothing cached.
    error NothingToClear();

    //
    // Constructor
    //

    /// @param distributor_     The Merkl Distributor address. Must be a contract.
    /// @param navCalculator_   The NAVCalculator address. Must be a contract.
    /// @dev No admin/assistant roles: the adapter is permissionless (see contract NatSpec). Everything is immutable
    ///      except the proof-verified allocation cache.
    constructor(address distributor_, address navCalculator_) {
        if (distributor_ == address(0) || navCalculator_ == address(0)) {
            revert InvalidArguments();
        }
        AddressCheckLib.requireContract(distributor_, "Distributor");
        AddressCheckLib.requireContract(navCalculator_, "NAVCalculator");

        DISTRIBUTOR = distributor_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // Mutators (permissionless — every write is proof-verified against the live Distributor root)
    //

    /// @notice Submit Merkl allocations for `user` — each entry **upserts** its `(user, token)` cache (adds or
    ///         refreshes it); tokens omitted from `allocs` are left untouched, so this can never suppress a live
    ///         entry. The feeder typically submits the user's full current allocation set each cycle, but a partial
    ///         list is safe (it only add/refreshes what it carries). Each entry's proof is verified against the live
    ///         Distributor merkle root, so no caller can fabricate amounts.
    /// @dev Permissionless (no roles): keyed on the explicit `user` arg and callable by anyone — proof-verification is
    ///      the integrity guarantee, so a submission for `user` only lands if its proof validates against Merkl's live
    ///      root for that user's leaf. Each entry is an **upsert** of that `(user, token)`; entries omitted from
    ///      `allocs` are left untouched, so a caller can only add or refresh proven data — it can NEVER suppress a
    ///      live entry it omits (removal is only via the stale-gated `clearAllocation`/`clearAccount`). **Reverts**
    ///      `InvalidArguments` (zero user/token), `UninitializedRoot`, `InvalidProof`, `AmountRegression` (a proven
    ///      cumulative below the cached one), `CampaignSumMismatch`, or `TooManyCampaigns` — fail-loud and atomic, so
    ///      a bad entry reverts the whole call and leaves the prior set intact.
    /// @param user        Account the allocations are for.
    /// @param allocs      The (token, cumulativeAmount, proof, campaigns) entries to add/refresh for `user`.
    function submitProofs(address user, Allocation[] calldata allocs) external {
        if (user == address(0)) revert InvalidArguments();
        _upsert(user, allocs);
    }

    /// @notice Batch variant: for each user, their allocation list is **upserted** into that user's cache (each entry
    ///         adds/refreshes its `(user, token)`; omitted entries are never suppressed). `users` and `allocs` must
    ///         have the same length.
    /// @dev **Atomic across accounts (by design):** any single entry that reverts — `InvalidProof`, `AmountRegression`
    ///      (a proven cumulative below the cached one), `CampaignSumMismatch`, `TooManyCampaigns`, or a zero
    ///      user/token — reverts the ENTIRE batch, so no account in the call is updated. This is deliberate
    ///      fail-loud handling (a regression/invalid proof signals bad data worth halting on, not silently skipping),
    ///      but it means a multi-account feeder should pre-filter regressed/invalid entries (or fall back to
    ///      per-account `submitProofs`) so one account's bad data can't block every other account's fresh proofs.
    function submitProofsBatch(address[] calldata users, Allocation[][] calldata allocs) external {
        if (users.length != allocs.length) revert InvalidArguments();
        for (uint256 i; i < users.length; ++i) {
            if (users[i] == address(0)) revert InvalidArguments();
            _upsert(users[i], allocs[i]);
        }
    }

    /// @notice Drop a cached allocation — **stale-gated GC**. Permissionless, but reverts `AllocationStillLive` if the
    ///         entry still contributes to NAV (cached root matches the live root AND it has an unclaimed balance): a
    ///         live entry can only be *replaced* via `submitProofs`, never cleared, so no caller can suppress another
    ///         account's valid reward. Clears entries that are stale (root rotated) or fully claimed.
    /// @dev Garbage-collects tokens whose proof no longer validates or that the user has fully claimed — keeps storage
    ///      and the per-user enumeration list bounded. Not required for correctness (such entries already read as 0).
    function clearAllocation(address user, address token) external {
        if (user == address(0) || token == address(0)) revert InvalidArguments();
        if (allocations[user][token].root == bytes32(0)) revert NothingToClear();
        if (_unclaimed(user, token) != 0) revert AllocationStillLive(user, token);
        delete allocations[user][token];
        delete _campaigns[user][token];
        _removeUserToken(user, token);
        emit AllocationCleared(user, token);
    }

    /// @inheritdoc IAttestedBalanceAdapter
    /// @dev Stale-gated **bulk** GC: reverts `AllocationStillLive` on the first of `account`'s tokens that still
    ///      contributes to NAV, so a live set can never be suppressed — it clears only when the whole set is dead
    ///      (every token already reads 0: stale root or fully claimed). Reverts `NothingToClear` if nothing is cached.
    function clearAccount(address account) external override {
        if (account == address(0)) revert InvalidArguments();
        address[] memory toks = _userTokens[account];
        if (toks.length == 0) revert NothingToClear();
        for (uint256 i; i < toks.length; ++i) {
            if (_unclaimed(account, toks[i]) != 0) revert AllocationStillLive(account, toks[i]);
        }
        _clearUser(account);
        emit AccountCleared(account);
    }

    /// @dev Upsert each proven entry into `user`'s cache: verify each leaf against the live Distributor root and
    ///      overwrite that `(user, token)` entry (fail-loud — a bad entry reverts the whole call, leaving the prior
    ///      set intact). Does NOT clear the prior set — entries omitted from `allocs` are left untouched, so a caller
    ///      can only add or refresh proven data, never suppress a live entry it omits. Removal is only via the
    ///      stale-gated `clearAllocation`/`clearAccount`.
    function _upsert(address user, Allocation[] calldata allocs) private {
        for (uint256 i; i < allocs.length; ++i) {
            _submitProof(user, allocs[i].token, allocs[i].cumulativeAmount, allocs[i].proof, allocs[i].campaigns);
        }
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
    /// @dev Advertises {IAttestedBalanceAdapter} (its family marker) + {IBalanceAdapter} + {IPositionDescribable} +
    ///      {IERC165}. It is attested, NOT a coordinate-cache {IAssistedBalanceAdapter} member, so that marker is not
    ///      advertised.
    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IAttestedBalanceAdapter).interfaceId
            || interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IPositionDescribable).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function protocolName() external pure returns (string memory) {
        return ProtocolNames.MERKL;
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `["Claimable Rewards"]` — a static category (the reward token is in `balanceAsset`). The argument is
    ///      ignored; the per-leg Merkl campaign coordinate is carried on the position's `positionInstanceId`
    ///      (`bytes32(0)` for an untagged token), not surfaced as a label.
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

        // Nothing cached for this account (the overwhelmingly common case, since this adapter is registered globally
        // and queried for every account): return before the self-call, so an empty cache does not pay for the extra
        // frame OR for `buildPositionsSelf`'s whole-registry `getRegisteredAssets()` copy. Mirrors the sibling plain
        // adapters, which all early-return before that fetch (e.g. StaderWithdrawalQueueBalanceAdapter's empty-id
        // check, LidoWithdrawalQueue's `balanceOf == 0`). The registry copy is super-linear in registered assets, and
        // it is charged against the per-adapter stipend `PriceFeedLib._getAdapterPositions` forwards.
        if (tokensToProcess.length == 0) return new INAVCalculator.PositionBalance[](0);

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

    /// @notice Builds one `Rewards` PositionBalance row. Extracted from the row-building loop so the 11-field
    ///         struct lives in its own stack frame (keeps the loop under the via_ir stack limit).
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
        // Field-by-field (not an 11-field struct literal) to stay under the via_ir stack limit on the hot path.
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

        // Defense in depth: Merkl's tree generator guarantees per-(user, token) cumulative amounts are monotonic
        // (lifetime-cumulative, non-decreasing across roots). A regression suggests stale or wrong data; reject
        // loudly. A legitimately lower value can only arise after a root rotation, which makes the cached entry stale
        // (reads 0) and thus clearable via `clearAllocation` before a fresh submit.
        CachedAllocation storage a = allocations[user][token];
        if (cumulativeAmount < a.cumulativeAmount) revert AmountRegression();

        // Campaign breakdown: bound the (submitter-supplied) per-campaign shares to the proof-verified per-token
        // total — Σ shares MUST equal `cumulativeAmount`. This is the safety hinge: a submitter can mis-split value
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

        // "Is this a NEW (user, token)?" — keyed on `root`, NOT on `submittedAt`. This branch is the only thing
        // standing between the contract and a DUPLICATE entry in `_userTokens`, which would make `buildPositionsSelf`
        // run `_appendTokenLegs` twice for one token and report its unclaimed amount twice — an OVER-report, the one
        // direction this family forbids. `root` is a sentinel the contract enforces itself (`UninitializedRoot` above
        // rejects a zero root, so any stored entry has `root != 0`), whereas `submittedAt != 0` rests on
        // `block.timestamp != 0` — true on every live chain, but an incidental property of the environment rather
        // than an invariant of this code, and therefore the wrong thing to hang an over-report guard on.
        if (a.root == bytes32(0)) {
            uint256 n = _userTokens[user].length;
            if (n >= MAX_TOKENS_PER_USER) revert TooManyTokens(user, n);
            _userTokens[user].push(token);
            _userTokenIdxPlus1[user][token] = _userTokens[user].length;
        }

        a.cumulativeAmount = cumulativeAmount;
        a.root = root;
        a.submittedAt = uint64(block.timestamp);

        // Replace this token's campaign shares wholesale (a re-submit of the same (user, token) overwrites its prior
        // breakdown cleanly — the upsert only ever touches the token(s) named in the submission).
        delete _campaigns[user][token];
        for (uint256 i; i < nCampaigns; ++i) {
            _campaigns[user][token].push(campaigns[i]);
        }

        emit AllocationCached(user, token, msg.sender, cumulativeAmount, root, a.submittedAt, nCampaigns);
    }

    /// @dev Delete a user's entire cached allocation set (storage only, no event). Used by the stale-gated
    ///      `clearAccount` after it has verified every entry is dead (reads 0); never called from the submit path.
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
    ///      Stale handling: if cached `root != Distributor.getMerkleRoot()`, treat as 0 — never assume cumulative
    ///      monotonicity to extrapolate; require a fresh proof against the new root.
    ///
    ///      **Not revert-free, deliberately.** The two Distributor reads below are unguarded and their returndata is
    ///      ABI-decoded, so this reverts if the Distributor ever returns something undecodable (it is an upgradeable
    ///      proxy under Angle governance: a `Claim` struct reshape breaks the decode) — and note that in this repo a
    ///      bare `try`/`catch` would not catch the decode half anyway. Consequences if it ever fires: on the NAV path
    ///      `PriceFeedLib._getAdapterPositions` fails open on a plain revert, so this adapter's whole leg set drops
    ///      out of NAV (an under-report, the safe direction, but silent).
    ///
    ///      It is deliberately NOT made fail-open-to-0, because `clearAllocation`/`clearAccount` gate on this value:
    ///      a `_unclaimed` that returned 0 on a failed read would let anyone clear another account's LIVE entries
    ///      during a Distributor hiccup, converting a read-availability problem into the permissionless-suppression
    ///      vector the stale-gate exists to close. Reading the Distributor honestly, and failing loudly when it
    ///      cannot be read, is the property worth keeping here.
    function _unclaimed(address account, address asset) internal view returns (uint256) {
        CachedAllocation memory a = allocations[account][asset];
        if (a.root == bytes32(0)) return 0;
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
