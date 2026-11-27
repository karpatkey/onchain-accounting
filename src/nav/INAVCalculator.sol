// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalances} from "src/balances/IBalances.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

/// @title INAVCalculator
/// @notice Interface for the NAV Calculator contract. Defines the full API for asset registration, price feeds,
///         balance adapters, and NAV/position queries in one or more quote currencies.
/// @dev Extends IBalances for adapter registry and IPrices for price feed types. Implementations are typically
///      UUPS-upgradeable and use AccessControl (MANAGER for mutations, DEFAULT_ADMIN_ROLE for upgrades).
/// @author KPK
interface INAVCalculator is IBalances {
    /// @notice A balance adapter consumed the gas stipend the NAV read forwarded to it without answering.
    /// @dev Deliberately NOT folded into the read's fail-open path. A revert means "this adapter has nothing to
    ///      report"; running out of gas means "this adapter's answer is unknown", and reporting an unknown answer
    ///      as an empty one drops the adapter's legs — a dropped debt leg RAISES the reported NAV.
    ///
    ///      Declared here rather than alongside the shared errors so it reaches consumers: it is raised inside a
    ///      DELEGATECALLed library, and an error a contract never names itself does not appear in that contract's
    ///      ABI. Callers generate against this interface and the NAVCalculator implementing it, so a revert they
    ///      can actually decode has to be part of it.
    ///
    ///      `adapter` names the adapter that was running, which is not always the adapter at fault: the stipend is
    ///      a share of what the READ still holds, so an under-funded call starves whichever adapter happens to be
    ///      reached last. `stipend` and `consumed` are what separate the two cases. A large `stipend` fully
    ///      consumed means that adapter is genuinely runaway; a small `stipend` means the read itself was short of
    ///      gas and the fix is to supply more.
    /// @param adapter The adapter that was executing when its gas ran out.
    /// @param stipend The budget the classification was measured against: 63/64 of what the read held just before
    ///        the call. It is NOT precisely what the EVM forwarded — the same 63/64 rule is applied again at the
    ///        CALL itself, to a figure already reduced by building the calldata — so on a genuine exhaustion
    ///        `consumed` lands a few tens of gas ABOVE it. Read the two as a ratio, not as a balance.
    /// @param consumed Gas the call actually cost this frame, including the call overhead.
    error AdapterGasExhausted(address adapter, uint256 stipend, uint256 consumed);

    /// @notice One governed instance of a meta-adapter consumed its gas stipend without answering.
    /// @dev The {AdapterGasExhausted} sibling, one frame in. A meta-adapter isolates each instance behind its own
    ///      `try`/`catch` so a single faulty instance cannot zero out the batch, and that isolation has the same
    ///      blind spot: an instance that runs out of gas is indistinguishable from one that reverted, and recording
    ///      it as "no positions" drops its legs while the meta-adapter still RETURNS SUCCESSFULLY — so the caller
    ///      sees a complete-looking answer. A dropped debt leg raises the reported NAV.
    ///
    ///      Raised rather than swallowed. `PriceFeedLib` keys on this selector explicitly rather than re-deriving
    ///      exhaustion from gas, so a cheap early raise here cannot be re-scored as a benign revert one frame out.
    ///
    ///      `instance` is where the budget ran out, which is NOT the same as where it went. The fan-out gives each
    ///      instance a share of whatever its predecessors left, so a single runaway instance early in the governed
    ///      set can leave the NEXT one too little and get it named instead. Read the pair together: a large
    ///      `stipend` fully consumed means that instance is genuinely runaway; a small `stipend` means it was
    ///      starved by something before it, or the read was under-funded to begin with. Removing the named instance
    ///      is the wrong first move when `stipend` is small.
    /// @param adapter The meta-adapter that was fanning out. Overwritten by `PriceFeedLib` with the address it
    ///        actually called, so it is trustworthy even when the rest of the payload is not.
    /// @param instance The governed instance coordinate whose read ran out of gas — see the caveat above.
    /// @param stipend The budget the classification was measured against: 63/64 of what the fan-out held just
    ///        before the call. As with {AdapterGasExhausted} it is NOT precisely what the EVM forwarded — the same
    ///        rule is applied again at the CALL — so `consumed` lands slightly above it. A ratio, not a balance.
    /// @param consumed Gas the instance call actually cost, including the fan-out's call overhead.
    error InstanceGasExhausted(address adapter, bytes32 instance, uint256 stipend, uint256 consumed);

    /// @notice {getAccountNavForAdapters} was given an empty adapter list.
    /// @dev Not silently answered with a zero NAV. An empty slice is indistinguishable from "this portion of the
    ///      portfolio is worth nothing", and a caller that built its slice list from a stale or mis-parsed source
    ///      would read that zero as a real answer and reassemble a NAV that is short by exactly the adapters it
    ///      forgot to ask for. Declared here rather than in `src/errors.sol` for the same reason as
    ///      {AdapterGasExhausted}: it is raised inside a DELEGATECALLed library, so it only reaches consumers'
    ///      generated ABIs by being named in this interface.
    error EmptyAdapterSlice();

    /// @notice {getAccountNavForAdapters} was given an adapter that is not in the global registry.
    /// @dev The registry is `getAllAdapters()` — the exact list the complete read scans — so "registered" here
    ///      means "would have been included in `getAccountNav`". Rejected rather than skipped: an unregistered
    ///      address (a decommissioned adapter, a typo, an address from another chain) has no positions to report,
    ///      so skipping it would return a well-formed slice whose `value` is silently missing whatever the caller
    ///      believed that address covered — and whose `adaptersCovered` would then have to either echo an address
    ///      that contributed nothing or omit one the caller asked for. Both mislead the coverage check that
    ///      `adaptersCovered` exists to support.
    /// @param adapter The supplied address that is not a registered balance adapter.
    error AdapterNotRegistered(address adapter);

    /// @notice A non-USD quote asset has no usable price at all, so no value can be expressed in it.
    /// @dev Raised by every read that converts into a quote asset (`getAccountNav`, `getAccountNavVerbose`,
    ///      `getAccountPositions`, `getAccountPositionsVerbose`, `getAccountPositionsForAsset`,
    ///      `getAccountPositionsForAssetVerbose`, `getAccountNavForAdapters`, `calculateValue`) when
    ///      every one of the quote asset's feeds is unusable: reverting or non-positive answers, or a last update
    ///      older than {MAX_STALE_PRICE_AGE}. A quote asset that is merely STALE does not revert: values are converted
    ///      at its last-known price and `quoteAssetStale` is set (ADR 0029). Callers that must always get a number
    ///      can fall back to the USD quote, `address(0)`, which never raises this. The asset-filtered
    ///      `getAccountPositionsForAsset(/Verbose)` return an empty list without reading the quote when the account
    ///      holds nothing in that asset.
    /// @param quoteAsset The quote asset with no usable price.
    error QuoteAssetUnpriceable(address quoteAsset);

    /// @notice {getAccountNavForAdapters} was given the same adapter twice in one slice.
    /// @dev A repeated adapter is queried twice and its positions summed twice, so the slice over-reports by that
    ///      adapter's whole value. Rejected rather than deduplicated, because a duplicate means the caller's
    ///      partition logic is wrong and the same defect will be producing overlaps ACROSS slices — which this
    ///      contract cannot see and silently deduplicating here would hide. Cross-slice overlap is what
    ///      `PartialNAV.adaptersCovered` is for.
    /// @param adapter The address that appeared more than once.
    error DuplicateAdapterInSlice(address adapter);

    //
    // Structs
    //

    /// @notice Registered asset metadata used by the NAV/Pricing registry and balance adapters.
    /// @param asset Token address (or NATIVE_ADDRESS for chain native token).
    /// @param symbol Display symbol (e.g. "ETH", "USDC").
    /// @param decimals Number of decimals for amounts.
    struct Asset {
        address asset;
        string symbol;
        uint8 decimals;
    }

    /// @notice Balance-only position data returned by balance adapters (no pricing).
    /// @dev NAVCalculator enriches these with pricing to produce Position structs.
    /// @param balanceAsset Asset metadata (address, symbol, decimals). The token `amount` is denominated in.
    /// @param balanceAdapter Address of the adapter that reported this position. Provenance / audit trail — NOT part of identity.
    /// @param amount Balance magnitude (always positive); sign is implied by isDebt.
    /// @param isDebt True if debt (subtract from NAV), false if credit (add to NAV). Canonical NAV-sign signal.
    /// @param protocolBrand `keccak256` of the protocol brand slug (version-stripped, e.g. `aave`, `balancer`; see
    ///        `src/utils/ProtocolIds.sol`). The broadest roll-up layer — several `protocolId`s share it
    ///        (`aave-v3` → `aave`; `balancer-v2` + `balancer-v3` → `balancer`). Display/grouping only; NOT part of the
    ///        stable identity key. Equals `protocolId` for unversioned protocols.
    /// @param protocolId `keccak256` of the broad protocol-ecosystem slug (e.g. `aave-v3`, `curve`; see
    ///        `src/utils/ProtocolIds.sol`). A roll-up / grouping key only — several `protocolSubId`s share it
    ///        (e.g. `aave-v3-lending` + `aave-v3-safety-module` both roll up to `aave-v3`). NOT part of the stable
    ///        identity key (it is functionally determined by `protocolSubId`).
    /// @param protocolSubId `keccak256` of the specific protocol-product slug (e.g. `aave-v3-lending`; see
    ///        `src/utils/ProtocolIds.sol`). Selects the `positionId` ABI-decode schema — one sub-slug implies exactly
    ///        one schema — and is the protocol component of the stable identity key. Equals `protocolId` for
    ///        single-product ecosystems.
    /// @param positionId ABI-encoded position identifier. Decode schema is determined by `protocolSubId`.
    ///        e.g. for AAVE_V3_LENDING: `abi.encode(address pool)`.
    ///        Full schema table: see `src/utils/ProtocolIds.sol` and docs/howto/position-identity-schema.md.
    /// @param positionKind Semantic discriminator (Wallet / Supplied / Borrowed / Collateral / Staking / Rewards / Fees).
    ///        Together with `protocolSubId` and `positionId` forms the stable per-chain identity key
    ///        `(chainId, protocolSubId, positionId, balanceAsset.asset, positionKind)`.
    /// @param isLocked True if this leg is NOT withdrawable right now (the pending portion of a withdrawal queue, or a
    ///        staked amount in/awaiting its unstaking cooldown); false if fully liquid / claimable now. Withdrawal-queue
    ///        and cooldown adapters keep a STATIC, timeless `positionId` (the queue/manager/asset/vault/stake-token
    ///        coordinate) and split an account's holding into up to two legs — a claimable leg (`isLocked=false`) and a
    ///        locked leg (`isLocked=true`). `isLocked` is a **mutable per-leg attribute, NOT part of the identity key**:
    ///        a leg flips `true→false` as its portion finalizes/unlocks, so keying on it would split one economic
    ///        position into two keys over its lifetime. The claimable and locked legs therefore share ONE key and are
    ///        **summed** in reconciliation (the sum is the full holding); read `isLocked` per leg for the
    ///        claimable-vs-locked breakdown. `false` for every adapter except withdrawal-queue / cooldown legs.
    /// @param positionInstanceId OPTIONAL EPHEMERAL per-item coordinate as a `bytes32` — a Uniswap V3 / PancakeSwap V3
    ///        NFT id, a withdrawal/exit request id, or a StakeWise exit ticket (each a `uint256` widened to `bytes32`).
    ///        `bytes32(0)` for adapters with no per-item granularity. It is the SOLE ephemeral identity field, by
    ///        design: the **stable** reconciliation key
    ///        `(chainId, protocolSubId, positionId, balanceAsset.asset, positionKind)` deliberately EXCLUDES it,
    ///        so the legs of one anchor sum and identity survives item churn. A consumer that wants per-item
    ///        granularity MAY append `positionInstanceId` to the key — gaining one position per item, at the cost of an
    ///        **ephemeral** key (it blinks in/out as items are minted/burned/claimed). Never use it for stable
    ///        identity. (Stable sub-distinguishers like an Aave reserve are NOT here — they live in `balanceAsset`.)
    ///        Typed as `bytes32` (not `bytes`): every current coordinate is a single `uint256`, and a value type keeps
    ///        the position-building/copy loops under the via_ir stack limit.
    struct PositionBalance {
        Asset balanceAsset;
        address balanceAdapter;
        uint256 amount;
        bool isDebt;
        bytes32 protocolBrand;
        bytes32 protocolId;
        bytes32 protocolSubId;
        bytes positionId;
        PositionKind positionKind;
        bool isLocked;
        bytes32 positionInstanceId;
    }

    /// @notice Enriched position including pricing and quote-currency value.
    /// @dev Returned by getAccountPositions and getAccountPositionsForAsset.
    /// @param balanceAsset Asset metadata from registry (canonical symbol/decimals).
    /// @param balanceAdapter Adapter that reported the balance.
    /// @param amount Balance magnitude (positive); sign implied by isDebt.
    /// @param isDebt True if debt, false if credit.
    /// @param quoteAsset Quote currency for value (e.g. USD when address(0)).
    /// @param value Value in quote asset (negative for debt).
    /// @param price Price used (e.g. USD per unit of asset).
    /// @param priceDecimals Decimals of price.
    /// @param stale True if the price was stale at query time.
    /// @param protocolBrand `keccak256` protocol brand slug (broadest grouping). Copied from PositionBalance.
    /// @param protocolId `keccak256` broad ecosystem slug (grouping). Copied from PositionBalance.
    /// @param protocolSubId `keccak256` specific protocol-product slug (identity-key component). Copied from PositionBalance.
    /// @param positionId ABI-encoded position identifier. Copied from PositionBalance.
    /// @param positionKind Semantic discriminator. Copied from PositionBalance.
    /// @param isLocked True if the leg is not withdrawable now (pending/cooling). Copied from PositionBalance.
    /// @param positionInstanceId Ephemeral per-item coordinate (NFT/request/ticket), or empty. Copied from
    ///        PositionBalance; excluded from the stable identity key. See PositionBalance.
    struct Position {
        Asset balanceAsset;
        address balanceAdapter;
        uint256 amount;
        bool isDebt;
        Asset quoteAsset;
        int256 value;
        int256 price;
        uint8 priceDecimals;
        bool stale;
        // True if the quote asset's own price feed was stale. `value` is still in the quote asset, converted at its
        // last-known price (ADR 0029); a quote with no usable price reverts QuoteAssetUnpriceable instead.
        // Mirrors NAV.quoteAssetStale ([9]/S2).
        bool quoteAssetStale;
        bytes32 protocolBrand;
        bytes32 protocolId;
        bytes32 protocolSubId;
        bytes positionId;
        PositionKind positionKind;
        bool isLocked;
        // Ephemeral per-item coordinate copied from PositionBalance (NFT id / request id / ticket as bytes32).
        // bytes32(0) when none. Display/granularity only — excluded from the stable identity key. See PositionBalance.
        bytes32 positionInstanceId;
        // True if the asset's primary price diverged from its monitor feeds beyond the configured tolerance (or,
        // for stablecoins, from the $1 peg). A pricing-quality signal, NOT a validity/staleness flag: `price` and
        // `value` are still populated from the primary. Consumers (e.g. the sub/redeem processor) decide how to react.
        // APPENDED (not inserted mid-struct) so an in-place UUPS upgrade doesn't shift existing fields' ABI offsets.
        bool irregular;
        // True if the quote (unit-of-account) asset's own primary diverged from its monitors — the divergence
        // counterpart to `quoteAssetStale`. Always false for a USD quote.
        bool quoteAssetIrregular;
    }

    /// @notice Position enriched with human-readable display labels.
    /// @dev ⚠️ **NEITHER `protocolName` NOR ANY element of `labels` is necessarily the adapter's own value.**
    ///      `AssetKindRegistry` holds an optional per-ADAPTER protocol name plus a per-ADAPTER, per-SEGMENT `labels`
    ///      override, and {PriceFeedLib.toVerbose} applies both in preference to the adapter's reply.
    ///
    ///      ⚠️ **Two earlier revisions of this line were narrower than the code, in the same direction each time.**
    ///      The first said the computed leaf was never overridable; the second said only `labels[0]` was. Both are now
    ///      false: {IAssetKindRegistry.setAdapterLabels} writes at ANY index, bounded only by
    ///      `min(reply.length, override.length)` — so the honest statement is that a segment comes from the adapter
    ///      **unless an operator overrode that index**, and `""` at an index is how an operator declines to.
    ///
    ///      What the override CANNOT do is change the array's LENGTH: it never writes past the adapter's own reply and
    ///      never extends it, so `labels.length` is always the adapter's answer. (The one exception is
    ///      `getAdapterDisplayInfo`, whose empty-reply case is deliberately grown — see
    ///      `PriceFeedLib.adapterDisplayInfo`.)
    ///
    ///      Which segments an operator SHOULD write is a property of the adapter, not of this struct;
    ///      `src/balances/BALANCE_ADAPTERS.md` §6.2 carries the per-adapter sweep, and
    ///      `ERC20DefaultBalanceAdapter` is the one adapter that must not be overridden at all (its single element is
    ///      the computed token symbol, not a category). `AdapterLabelOverrides.t.sol
    ///      ::test_labelsOverride_onLeafOnlyAdapter_replacesTheLeaf_documentedHazard` asserts that hazard.
    ///      Consumers must not treat these strings as identity in any case; see {IPositionDescribable}.
    /// @dev Returned by verbose read methods. Labels are sourced from the adapter's `IPositionDescribable`
    ///      implementation (`positionLabels(positionId)`, via a fail-open staticcall) and are empty otherwise. MUST NOT
    ///      be used for identity, indexing, or reconciliation — use the typed fields on `position` for those purposes.
    struct VerbosePosition {
        Position position;
        string protocolName; // e.g. "Aave V3", "Morpho"
        // Ordered display hierarchy BELOW the protocol, leaf last (arbitrary depth, may be empty), e.g.
        // ["Market", "wstETH/USDC"] or ["AMM Liquidity Pool", "WETH/USDC 0.05%"]. Full breadcrumb = [protocolName,
        // ...labels]. Sourced from IPositionDescribable.positionLabels(positionId); display only. The ephemeral
        // per-item id (NFT/request/ticket) is NOT here — it is the typed `position.positionInstanceId` field.
        string[] labels;
    }

    /// @notice NAV snapshot bundled with a full verbose position breakdown.
    // forge-lint: disable-next-line(pascal-case-struct)
    struct VerboseNAV {
        NAV nav;
        VerbosePosition[] positions;
    }

    /// @notice NAV snapshot for an account in a given quote currency.
    /// @param value Total portfolio value in quoteAsset (can be negative if net debt).
    /// @param quoteAsset Quote currency; address(0) denotes USD.
    /// @param timestamp Block timestamp of the reading.
    /// @param stalePriceAssets Assets whose prices were stale at query time. Since ADR 0029 a listed asset is
    ///        normally still valued, at its freshest usable stale price; it contributed 0 only when NO feed was usable
    ///        (no feed registered, every read failed, or the last update is at least MAX_STALE_PRICE_AGE old). The two
    ///        cases share this list: tell them apart by the position's `price` (or `getPriceData(asset).price`), which
    ///        is 0 only in the latter.
    /// @param irregularPriceAssets Assets whose primary price diverged from their monitor feeds beyond tolerance
    ///        (or, for stablecoins, from the $1 peg) at query time. A pricing-quality signal, not a staleness flag —
    ///        `value` is still computed from the primary prices. Consumers decide how to react.
    /// @param sequencerDown True if the L2 sequencer was down or in grace period (L2 only).
    /// @param quoteAssetStale True if the quote asset's own price feed was stale. `value` is still in the quote
    ///        asset, converted at its last-known price (ADR 0029) — callers must check this flag before trusting the
    ///        conversion. A quote with no usable price reverts QuoteAssetUnpriceable rather than setting this.
    /// @param monitorsUnhealthyPriceAssets Assets that **have monitor feeds configured but where none of them was
    ///        readable** at query time — every monitor stale, reverting, or reporting a non-positive price. For these
    ///        the divergence check silently did not run: `divergenceBps` is 0 because the arithmetic never executed,
    ///        not because the prices agreed, so absence from `irregularPriceAssets` says nothing about them. Without
    ///        this list "checked and clean" and "checked by nothing that answered" are the same bytes.
    ///
    ///        **This is NOT the "no monitors configured" case.** That is a static configuration property, derivable
    ///        off-chain from **`getMonitorFeedCount(asset) == 0` alone**, and it is deliberately excluded here — an
    ///        asset with nothing configured never appears in this list however long it goes unchecked. What this
    ///        reports is strictly a *runtime* failure of monitors that exist.
    ///
    ///        Do NOT additionally require `getAssetPricing(asset).divergenceToleranceBps == 0` for that derivation:
    ///        the conjunction is UNSATISFIABLE for any asset that ever had a monitor. `_setDivergenceTolerance`
    ///        rejects 0, so once a tolerance is set it can never be returned to zero, while `removeMonitorFeed`
    ///        leaves the tolerance untouched — so an asset whose monitors were all REMOVED has count 0 and a
    ///        non-zero tolerance, and an AND-recipe would silently never flag it. The tolerance only returns to 0
    ///        via full asset unregistration (`_removeAllMonitorFeeds`), by which point the asset is gone anyway.
    ///
    ///        Assets whose own primary is unusable are also excluded — no usable primary feed, sequencer down, or a
    ///        primary whose 8-decimal normalisation degenerates to zero. In all of those the check was suppressed by
    ///        the PRIMARY rather than by the monitors, and naming the monitors would point an operator at the wrong
    ///        contract. A stale primary is excluded too, for every asset: it is still priced and divergence-checked
    ///        (ADR 0029), but the Custom monitors share its base and go stale with it, and `stalePriceAssets` already
    ///        reports that event. An independent direct monitor that is also dead while the primary is stale shows
    ///        here only once the primary is fresh again (an accepted trade-off against hourly noise). Stablecoins
    ///        with a non-zero `pegToleranceBps` may appear here and still be peg-checked — the peg guard is
    ///        monitor-independent — so this flags the loss of the *divergence* check, not necessarily of all checks.
    ///
    ///        **Scope: assets this account holds positions in**, like `stalePriceAssets` and `irregularPriceAssets`.
    ///        It is built from the assets the account's positions touched, NOT from the whole registry, so absence
    ///        means "monitors healthy **or** no position held". A consumer reconciling against the registry-wide
    ///        per-asset view (`getPriceDivergence(asset).monitorFeedCount == 0` is the equivalent there) will see
    ///        differences that are this scoping, not a defect. Note also that `healthCheck()` — which DOES iterate
    ///        the whole registry — deliberately does not carry this array: `NAVCalculator` is 68 bytes from the
    ///        EIP-170 limit, so widening that return was not affordable. `Position.irregular` on
    ///        `getAccountPositions` likewise retains the original ambiguity, with no `NAV` struct alongside to join
    ///        against; use `getAccountNavVerbose` (whose `VerboseNAV` embeds the `NAV`) if you need both.
    // forge-lint: disable-next-line(pascal-case-struct)
    struct NAV {
        int256 value;
        Asset quoteAsset;
        uint64 timestamp;
        Asset[] stalePriceAssets;
        bool sequencerDown;
        bool quoteAssetStale;
        // APPENDED (not inserted mid-struct) so an in-place UUPS upgrade doesn't shift existing fields' ABI offsets.
        Asset[] irregularPriceAssets;
        // True if the quote (unit-of-account) asset's own primary diverged from its monitors beyond tolerance —
        // the divergence counterpart to `quoteAssetStale`. Always false for a USD quote (no quote feed).
        //
        // DECLARED GAP, deliberate: there is no `quoteAssetMonitorsUnhealthy` counterpart to
        // `monitorsUnhealthyPriceAssets` below. For a non-USD quote whose own monitors have ALL gone unreadable, this
        // flag is false for want of data — exactly the ambiguity that array exists to close — and nothing surfaces it.
        //
        // Why it was not added, in order of weight. (1) **Nothing in this repository's configuration exercises it**:
        // `nav-config/assets-and-price-feeds/{1,42161,8453,100}.json` contain no quote keys, and `quoteAsset` is a
        // CALLER-supplied parameter defaulting to USD (`address(0)`), not stored config — so the gap is reachable only
        // by a caller that opts into a non-USD quote. (2) `NAVCalculator` has 68 bytes of EIP-170 headroom; a further
        // struct member plus its computation plausibly exceeds that, and spending the last of the margin on an
        // unexercised path would leave nothing for an urgent fix — after which the next change would need a new proxy
        // rather than an upgrade.
        //
        // Limit of that evidence: it is a claim about THIS repository only. A downstream consumer (share layer,
        // portal, agents, subgraphs) could pass a non-zero `quoteAsset`, which cannot be verified from here. If one
        // does, this gap is worth the bytes and should be revisited.
        //
        // Mitigation meanwhile: a caller using a non-USD quote should read `getPriceDivergence(quoteAsset)` and treat
        // `monitorFeedCount == 0` alongside a usable primary as exactly this condition.
        bool quoteAssetIrregular;
        // APPENDED for the same reason as `irregularPriceAssets` above. This redeploy uses a NEW proxy rather than an
        // in-place upgrade, so nothing forced the append — but moving existing consumers' ABI offsets for a change
        // that did not need to move them is gratuitous, so the convention is honoured anyway.
        Asset[] monitorsUnhealthyPriceAssets;
    }

    /// @notice One SLICE of an account's NAV: the same snapshot as {NAV} but covering only the balance adapters
    ///         named in the request, plus the list of adapters it actually covered.
    /// @dev Returned by {getAccountNavForAdapters}. Deliberately a DISTINCT type from {NAV}, not a reuse of it,
    ///      and that is the whole safety property of this API: a partial result must not be assignable, passable
    ///      or decodable where a complete NAV is expected. A `PartialNAV` that type-checked as a `NAV` would let a
    ///      caller hand one slice to a consumer that believes it holds the whole portfolio — the exact silent
    ///      under-report pagination exists to make impossible. The cost is that a caller must reassemble
    ///      explicitly; that cost is the point.
    ///
    ///      **Field order mirrors {NAV} exactly for its first eight fields, including NAV's own appended ones, so
    ///      a decoder written for `NAV` maps 1:1 onto this struct's prefix.** `adaptersCovered` is appended last.
    ///      Keep it that way: any future field goes at the END of this struct (see the APPENDED note on {NAV}),
    ///      and any field appended to {NAV} must be appended here too — BEFORE `adaptersCovered` if the prefix
    ///      correspondence is to survive, which means moving `adaptersCovered` and accepting the ABI shift, or
    ///      accepting that the prefix correspondence ends there. Prefer the latter: shifting a field's offset in a
    ///      struct a live off-chain reassembler decodes is worse than losing a documentation convenience.
    /// @param value Net value of THIS SLICE's positions in `quoteAsset`, signed (negative if the slice is net
    ///        debt). **This is the one field that sums.** Debt legs are already negative, and prices are per-asset
    ///        and independent of which adapter reported the position, so the arithmetic is exact: summing `value`
    ///        over a partition of `getAllAdapters()` reproduces `getAccountNav().value` bit-for-bit, with no
    ///        tolerance and no rounding slack. Every other field below does NOT sum.
    ///
    ///        **One precondition, and it is not theoretical: no adapter may have been GAS-STARVED in either read.**
    ///        Some adapters fail open inside their own frame and return SUCCESSFULLY having dropped legs —
    ///        `AssistedCoordCache._collect` isolates each cached coordinate behind an UNCAPPED
    ///        `try this.valueCoordSelf(…)`/`catch {}`, and `ERC20DefaultBalanceAdapter` records 0 for an asset whose
    ///        `balanceOf` staticcall fails. Nothing upstream can see that; see the "Scope, stated plainly" note on
    ///        `PriceFeedLib._getAdapterPositions`.
    ///
    ///        The per-adapter stipend is a share of what the READ still holds at the moment that adapter is reached,
    ///        and `computeNav` scans the supplied array IN ORDER. So the stipend depends on **slice composition AND
    ///        ORDERING**, not merely on how few adapters a slice names. Both directions are reachable:
    ///        a singleton slice gives its adapter more gas than the full scan did and may value legs the complete
    ///        read dropped; a multi-adapter slice that places an adapter BEHIND an expensive one can starve it below
    ///        what the complete read gave it. The second case is not hypothetical — `getAllAdapters()[0]` is
    ///        permanently `ERC20DefaultBalanceAdapter` (pushed in `initialize`, unremovable, and swap-and-pop only
    ///        ever fills a hole at the removed index, which index 0 can never be), so the complete read already
    ///        hands it the largest stipend any read can and **a slice can only ever give it less.**
    ///
    ///        Which read ends up LARGER is a separate question from which one was starved. The sign of the skew is
    ///        set by the `isDebt` of the dropped legs, not by which read dropped them: a dropped credit leg lowers
    ///        that read, a dropped debt leg raises it.
    ///
    ///        **Therefore: do NOT assume a direction, and do not pick by magnitude either.** "Trust the slice" is
    ///        wrong, and so is "take the lower" — with today's credit-only absorbers starvation can only LOWER a
    ///        read, so "take the lower" would select the starved number every time the two disagree. Nor is
    ///        under-reporting a safe default: a processor pricing shares off a low NAV over-issues to a subscriber.
    ///        Reconcile before publishing either. If a choice must be automated, key it to the SIGNAL rather than
    ///        the magnitude — prefer the read that did not raise {AdapterGasExhausted} / {InstanceGasExhausted}, and
    ///        publish neither if the two disagree while neither raised one. And do not treat the two reads agreeing
    ///        as a health check that passes silently — they agree when nothing was starved, which is the common case
    ///        and therefore uninformative.
    ///
    ///        The property that would keep a starved read from OVER-reporting is: **no adapter emits an
    ///        `isDebt == true` leg from behind ANY fail-open read.** "Any" is load-bearing — a gas CAP makes this
    ///        worse, not better, because an uncapped read can at least be rescued by supplying more gas whereas a
    ///        capped one (`StaticCallLib.PROBE_GAS`) is starved by the cap and drops unconditionally.
    ///        **Three shipped adapters currently break it** — `EulerVaultsMetaBalanceAdapter._safeDebt` (capped
    ///        probe, supply leg survives), `FluidVaultLib.aggregate` (uncapped, drops one NFT's supply and borrow),
    ///        and `GearboxV3CreditAccountsMetaBalanceAdapter._appendBorrow` (narrowly mitigated by a
    ///        `_debtReportable` gate evaluated before the gas is drained). None is introduced or fixed here, and the
    ///        first two over-report the COMPLETE read as much as a slice. See `docs/howto/read-nav-in-slices.md`.
    /// @param quoteAsset Quote currency; `address(0)` denotes USD. Identical in every slice (it is the caller's
    ///        argument), so a reassembler can assert it rather than combine it.
    /// @param timestamp Block timestamp of THIS call. A reassembler MUST check that every slice carries the same
    ///        value: differing timestamps mean the slices were read at different blocks, and a NAV assembled from
    ///        positions priced at different blocks is not a NAV of anything. See the caller contract on
    ///        {getAccountNavForAdapters}.
    /// @param stalePriceAssets Assets whose prices were stale, **restricted to the assets this slice's positions
    ///        touched**. NOT a portfolio-wide list: an asset that is stale but only held through an adapter in
    ///        another slice is absent here and present there. Must be UNIONED across slices, and the union
    ///        de-duplicated — two slices holding the same stale asset each report it.
    /// @param sequencerDown True if the L2 sequencer was down or in grace period (L2 only). Derived from this
    ///        contract's sequencer config, not from the slice, so it is the same in every slice — but it is still
    ///        per-slice data and a caller that reads it on only one slice is relying on that invariant rather than
    ///        checking it. OR it across slices.
    /// @param quoteAssetStale True if the quote asset's own price feed was stale, in which case `value` was
    ///        converted at the quote's last-known price (ADR 0029). Also invariant across slices (it depends on the
    ///        quote asset, not the adapters) — which makes it *more* dangerous to ignore, not less: if it is true,
    ///        every slice's conversion used that stale price. OR it across slices.
    /// @param irregularPriceAssets Assets whose primary price diverged from their monitor feeds beyond tolerance
    ///        (or, for stablecoins, from the $1 peg), **restricted to the assets this slice touched**. Same
    ///        per-slice restriction and same union-and-dedupe requirement as `stalePriceAssets`. This is the depeg
    ///        signal; a slice-local read of it is a slice-local depeg picture.
    /// @param quoteAssetIrregular True if the quote asset's own primary diverged from its monitors. Invariant
    ///        across slices, always false for a USD quote. OR it across slices.
    /// @param monitorsUnhealthyPriceAssets Assets with monitors configured but none readable at query time,
    ///        **restricted to the assets this slice touched**. Same per-slice restriction and same
    ///        union-and-dedupe requirement as `stalePriceAssets` and `irregularPriceAssets` — it is built from the
    ///        same per-asset cache, so the semantics carry over unchanged. Reported on the paginated read
    ///        deliberately: a caller paginates because the complete read does not fit one `eth_call`, i.e. for the
    ///        largest accounts, and those are exactly the ones a monitoring consumer watches — omitting it here
    ///        would hide the signal from the accounts that most need it. A slice-local read is a slice-local
    ///        picture of monitor health, and a union over every slice is required before concluding an asset is
    ///        covered. See {NAV.monitorsUnhealthyPriceAssets} for what the condition does and does not mean.
    /// @param adaptersCovered The adapters this slice actually queried — element-for-element identical to the
    ///        `adapters` argument, order included, because the call reverts rather than silently dropping, adding
    ///        or reordering one. That makes it a machine-checkable record rather than a restatement of the input:
    ///        the guarantee is that nothing came between the request and the scan. Its purpose is reassembly
    ///        verification: concatenate it
    ///        across every slice and compare against `getAllAdapters()`. A missing address means the assembled NAV
    ///        is short by that adapter's positions; a repeated one means it is double-counted. Neither is
    ///        detectable from `value` alone, because a short NAV is a perfectly plausible number.
    // forge-lint: disable-next-line(pascal-case-struct)
    struct PartialNAV {
        int256 value;
        Asset quoteAsset;
        uint64 timestamp;
        Asset[] stalePriceAssets;
        bool sequencerDown;
        bool quoteAssetStale;
        Asset[] irregularPriceAssets;
        bool quoteAssetIrregular;
        // Appended after the {NAV}-mirroring prefix — see the struct-evolution note above. No longer the LAST
        // member: `monitorsUnhealthyPriceAssets` was appended after it, deliberately, so this field keeps its ABI
        // offset. New members go after that one, not here.
        address[] adaptersCovered;
        // Appended after `adaptersCovered` rather than beside its {NAV} siblings: keeping `adaptersCovered` at its
        // existing offset matters more than keeping this struct's prefix a positional mirror of {NAV}, which it stops
        // being the moment {NAV} grows. The two structs stay deliberately DISTINCT types — a partial result must not
        // be decodable where a complete one is expected — so mirroring is a convenience, never a guarantee.
        Asset[] monitorsUnhealthyPriceAssets;
    }

    /// @notice Price data for the feed selected for an asset: the freshest fresh feed, else the freshest usable
    ///         stale feed (ADR 0029).
    /// @dev When multiple feeds are registered, these fields describe the winning feed (a stale winner included).
    /// When no feed is usable, fields describe the first registered feed, price == 0 and stale == true.
    /// @param priceFeed Address of the selected price feed contract.
    /// @param priceType Feed type (Chainlink, Custom, Redstone, or API3).
    /// @param price Current price (e.g. USD per unit). A stale winner keeps its price; 0 only when no feed is usable.
    /// @param decimals Decimals of the selected feed's output.
    /// @param chainlinkHeartbeat Staleness window (seconds) of the reported feed. For Chainlink/Redstone/API3 this is
    ///        the selected feed's configured heartbeat. For Custom feeds it is the GOVERNING leg's heartbeat — the
    ///        underlying Chainlink leg closest to its own staleness limit — paired with `updatedAt` below. A Custom
    ///        feed that successfully reports no trackable Chainlink leg gives 0; if its freshness read REVERTS this
    ///        field retains the registered config heartbeat (only `updatedAt` falls back to 0), so a non-zero value
    ///        here does not by itself imply a successful read. See ICustomPriceFeed.governingFeedFreshness.
    /// @param updatedAt Last-update timestamp of the reported feed. For Chainlink/Redstone/API3 this is the selected
    ///        feed's `latestRoundData().updatedAt`. For Custom feeds it is the GOVERNING leg's `updatedAt` — a real,
    ///        matched pair with `chainlinkHeartbeat` above. 0 when the feed has no push timestamp or the read reverts.
    /// @dev ADVISORY PAIR — `updatedAt`/`chainlinkHeartbeat` describe only the reported oracle leg's push freshness.
    ///      `stale` (and `sequencerDown`) is the AUTHORITATIVE staleness verdict: it also folds in the rate answer's
    ///      validity, the L2 sequencer state, and the feed's own configured heartbeat gate — none of which the pair
    ///      can express, so the pair can read "fresh" (age < heartbeat) while `stale` is true. Consumers MUST gate on
    ///      `stale`; never recompute a fresh/stale decision from `(updatedAt, chainlinkHeartbeat)` alone.
    /// @param stale True if no feed is fresh (the price may still be a usable stale one) or the L2 sequencer is down.
    /// @param sequencerDown True if L2 sequencer is down (L2 only).
    /// @param healthyFeedCount Number of registered feeds that passed all staleness gates on this read.
    ///        A value below the total registered feed count signals partial redundancy collapse and
    ///        should trigger off-chain alerting.
    /// @param irregular True if the primary price diverged from the worst-case (furthest) healthy monitor feed
    ///        beyond the configured divergence tolerance, or (stablecoins) from the $1 peg beyond the peg tolerance.
    /// @param divergenceBps Worst-case basis-point gap between the primary price and any single healthy monitor
    ///        price (0 when there are no healthy monitors, no usable primary, or the L2 sequencer is down; a stale
    ///        primary is still compared).
    /// @param monitorFeedCount Number of healthy monitor feeds that contributed to the divergence computation.
    struct PriceFeedData {
        address priceFeed;
        IPrices.PriceType priceType;
        int256 price;
        uint8 decimals;
        uint256 chainlinkHeartbeat;
        uint256 updatedAt;
        bool stale;
        bool sequencerDown;
        uint256 healthyFeedCount;
        bool irregular;
        uint256 divergenceBps;
        uint256 monitorFeedCount;
    }

    //
    // Events
    //

    /// @notice Emitted when the Chainlink L2 sequencer uptime feed is updated.
    /// @param oldChainlinkUptimeFeed Previous uptime feed address.
    /// @param newChainlinkUptimeFeed New uptime feed address.
    event ChainlinkUptimeFeedUpdated(address indexed oldChainlinkUptimeFeed, address indexed newChainlinkUptimeFeed);

    /// @notice Emitted when the L2 sequencer grace period is updated.
    /// @param oldSequencerGracePeriod Previous grace period in seconds.
    /// @param newSequencerGracePeriod New grace period in seconds.
    event L2SequencerGracePeriodUpdated(uint256 oldSequencerGracePeriod, uint256 newSequencerGracePeriod);

    /// @notice Emitted when an asset is registered.
    /// @param asset Registered asset address.
    /// @param decimals Asset decimals.
    event AssetRegistered(address indexed asset, uint8 decimals);

    /// @notice Emitted when an asset is unregistered.
    /// @param asset Unregistered asset address.
    event AssetUnregistered(address indexed asset);

    //
    // Errors
    //

    /// @notice Thrown when the L2 sequencer uptime feed is not set but the grace period is being updated.
    error UptimeFeedNotSet();

    //
    // Mutating functions (require MANAGER role)
    //

    /// @notice Registers an asset and sets its price feed.
    /// @dev Fetches decimals/symbol from ERC20 or uses native token symbol. Adds asset to default adapter inclusion list.
    /// @param asset Asset address to register (cannot be zero).
    /// @param priceFeed Price feed address (cannot be zero).
    /// @param priceType Chainlink, Custom, Redstone, or API3.
    /// @param chainlinkHeartbeat Staleness window in seconds (must be non-zero for all types).
    function registerAsset(address asset, address priceFeed, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external;

    /// @notice Adds a price feed for an already registered asset, or UPDATES the heartbeat of one already there.
    /// @dev UPSERTS. If `priceFeed` is already registered for `asset`, this REWRITES its `chainlinkHeartbeat`
    ///      in place and emits {IPrices-PriceFeedHeartbeatUpdated}; it does NOT revert, and it does NOT emit a
    ///      PriceFeedAdded/PriceFeedRemoved pair. Do not build idempotency on a duplicate reverting.
    ///      Reverts: PriceFeedAlreadyRegistered only when the heartbeat is UNCHANGED; PriceFeedTypeImmutable
    ///      when `priceType` differs from the stored one (a feed's type is identity, not configuration);
    ///      PriceFeedDecimalsMismatch when the feed's live decimals no longer match the stored value.
    /// @param asset Registered asset address.
    /// @param priceFeed Price feed address (cannot be zero).
    /// @param priceType Chainlink, Custom, Redstone, or API3.
    /// @param chainlinkHeartbeat Staleness window in seconds (must be non-zero for all types).
    function addOrModifyPriceFeed(
        address asset,
        address priceFeed,
        IPrices.PriceType priceType,
        uint256 chainlinkHeartbeat
    ) external;

    /// @notice Adds a monitor (divergence-only) feed for an asset. Monitor feeds NEVER price the NAV; they are read
    ///         only to detect divergence between the primary price and the worst-case (furthest) healthy monitor price.
    /// @dev Requires the asset's divergence tolerance to be set first (>0), else reverts DivergenceToleranceRequired.
    ///      Monitor feeds must report NAV_DECIMALS decimals (else MonitorFeedDecimalsMismatch). Reverts
    ///      MonitorFeedAlreadyRegistered only when the heartbeat is UNCHANGED (this UPSERTS an existing monitor's heartbeat, emitting MonitorFeedHeartbeatUpdated).
    /// @param asset Registered asset address.
    /// @param priceFeed Monitor feed address (cannot be zero).
    /// @param priceType Chainlink, Custom, Redstone, or API3.
    /// @param chainlinkHeartbeat Staleness window in seconds (must be non-zero).
    function addMonitorFeed(address asset, address priceFeed, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external;

    /// @notice Sets the asset's divergence tolerance in basis points (must be in (0, 10000]).
    /// @param asset Registered asset address.
    /// @param divergenceToleranceBps Max worst-case primary-vs-any-single-monitor gap before the asset is flagged irregular.
    function setDivergenceTolerance(address asset, uint32 divergenceToleranceBps) external;

    /// @notice Sets the asset's stablecoin peg tolerance in basis points (in [0, 10000]; 0 disables the peg guard).
    /// @param asset Registered asset address.
    /// @param pegToleranceBps Max deviation of the primary price from $1 before the asset is flagged irregular.
    function setPegTolerance(address asset, uint32 pegToleranceBps) external;

    /// @notice Registers one or more **non-meta** balance adapters in the global registry in a single call.
    /// @dev Reverts with InvalidArguments if the list is empty or contains a zero address, DuplicateBalanceAdapter
    ///      if any adapter is already registered, InvalidBalanceAdapter if any adapter does not implement
    ///      IBalanceAdapter, and MetaAdapterNotAllowed if any adapter implements IMetaBalanceAdapter (meta-adapters
    ///      must use addMetaBalanceAdapter). The batch is all-or-nothing.
    /// @param adapters Adapter addresses (each must implement IBalanceAdapter and NOT IMetaBalanceAdapter).
    function addBalanceAdapters(address[] calldata adapters) external;

    /// @notice Registers a meta-adapter (ADR 0010) and seeds its instance set atomically, in one MANAGER call.
    /// @dev The adapter must implement both IBalanceAdapter and IMetaBalanceAdapter (else InvalidBalanceAdapter /
    ///      NotMetaAdapter). Reverts InvalidArguments on a zero adapter, DuplicateBalanceAdapter if already
    ///      registered, and DuplicateMetaInstance on a repeated coordinate. An empty instance list is allowed
    ///      (registers the meta-adapter with no instances yet; seed later via addMetaInstances). Plain adapters use
    ///      addBalanceAdapters; subsequent instance changes use addMetaInstances / removeMetaInstances.
    /// @param adapter The meta-adapter address.
    /// @param instances Instance coordinates to seed (e.g. vault addresses widened to bytes32, or raw bytes32 IDs).
    function addMetaBalanceAdapter(address adapter, bytes32[] calldata instances) external;

    /// @notice Removes the price feed at the given index. Reverts if it is the last feed (CannotRemoveLastFeed).
    /// @param asset Registered asset address.
    /// @param index Index into the asset's feed array.
    function removePriceFeedAt(address asset, uint256 index) external;

    /// @notice Removes the price feed with the given address. Reverts if not found or last feed.
    /// @param asset Registered asset address.
    /// @param priceFeed Feed address to remove.
    function removePriceFeed(address asset, address priceFeed) external;

    /// @notice Removes the monitor feed at the given index. Monitor feeds are optional, so the last one may be removed.
    /// @param asset Registered asset address.
    /// @param index Index into the asset's monitor feed array.
    function removeMonitorFeedAt(address asset, uint256 index) external;

    /// @notice Removes the monitor feed with the given address. Reverts MonitorFeedNotFound if absent.
    /// @param asset Registered asset address.
    /// @param priceFeed Monitor feed address to remove.
    function removeMonitorFeed(address asset, address priceFeed) external;

    /// @notice Removes one or more balance adapters from the global registry in a single call.
    /// @dev Reverts with InvalidArguments if the list is empty. The batch is all-or-nothing — if any adapter is
    ///      not registered (or is the default ERC20 adapter) the whole call reverts.
    /// @param adapters Adapter addresses to remove (none may be the default ERC20 adapter).
    function removeBalanceAdapters(address[] calldata adapters) external;

    /// @notice Adds instance coordinates to a registered meta-adapter's queried set.
    /// @dev This is the governed "which instances to query" registry — adapters themselves stay immutable.
    ///      All-or-nothing: reverts DuplicateMetaInstance if any coordinate is already present or repeated within
    ///      the batch (a duplicate would double-count NAV), InvalidArguments on an empty list, InvalidBalanceAdapter
    ///      if the adapter is not registered, and NotMetaAdapter if the adapter does not implement
    ///      IMetaBalanceAdapter. Coordinate values are otherwise not validated; a
    ///      malformed/unknown coordinate is isolated per-instance by the adapter's fan-out (cannot zero the batch).
    /// @param adapter Registered meta-adapter address.
    /// @param instances Instance coordinates to add (e.g. vault addresses widened to bytes32).
    function addMetaInstances(address adapter, bytes32[] calldata instances) external;

    /// @notice Removes instance coordinates from a registered meta-adapter's queried set.
    /// @dev All-or-nothing: reverts MetaInstanceNotFound if any coordinate is not present (a coordinate repeated
    ///      within the batch also reverts), InvalidArguments on an empty list, InvalidBalanceAdapter if the adapter
    ///      is not registered, and NotMetaAdapter if the adapter does not implement IMetaBalanceAdapter. Order is
    ///      not preserved.
    /// @param adapter Registered meta-adapter address.
    /// @param instances Instance coordinates to remove.
    function removeMetaInstances(address adapter, bytes32[] calldata instances) external;

    /// @notice Excludes an asset from the default adapter so wallet balances are not reported for it.
    /// @param asset Registered asset address.
    function excludeAssetFromDefaultAdapter(address asset) external;

    /// @notice Includes an asset in the default adapter so wallet balances are reported again.
    /// @param asset Registered asset address.
    function includeAssetInDefaultAdapter(address asset) external;

    /// @notice Unregisters an asset: unsets price feed, removes from default adapter list, and removes from registry.
    /// @param underlyingAsset Asset address to unregister.
    function unregisterAsset(address underlyingAsset) external;

    /// @notice Sets the Chainlink L2 sequencer uptime feed (use address(0) on L1).
    /// @dev Requires DEFAULT_ADMIN_ROLE (same privilege level as upgrades). Disabling sequencer-uptime
    ///      detection on an L2 is equivalent in impact to an upgrade, so MANAGER access is not sufficient.
    /// @param newChainlinkL2UptimeFeed New uptime feed address.
    function setChainlinkL2SequencerUptimeFeed(address newChainlinkL2UptimeFeed) external;

    /// @notice Sets the L2 sequencer grace period. Reverts UptimeFeedNotSet if the uptime feed is not set, or
    ///         InvalidArguments if the period is below 1 hour.
    /// @param newSequencerGracePeriod Grace period in seconds (must be at least 1 hour).
    function setChainlinkL2SequencerGracePeriod(uint256 newSequencerGracePeriod) external;

    //
    // View functions — registry
    //

    /// @notice Returns the number of registered assets (alias for getAssetCount).
    /// @return Number of registered assets.
    function assetCount() external view returns (uint256);

    /// @notice Returns whether an asset is registered.
    /// @param asset Asset address to check.
    /// @return True if registered.
    function isAssetRegistered(address asset) external view returns (bool);

    /// @notice Returns all registered assets with metadata.
    /// @dev **O(N), and it is the wrong tool for resolving ONE asset** — use {getRegisteredAsset} for that. This
    ///      copies the entire registry across the ABI boundary, so a caller that resolves M tokens by calling this
    ///      M times pays M full fetches. That pattern measured **6,274,562 gas for a single 50-token Balancer
    ///      instance at 43 registered assets** (18.4M at 100), and it is super-linear rather than linear because
    ///      each call allocates a fresh N-element array that is never freed, so memory expansion grows with the
    ///      square of the token count. At that scale it exhausts the per-adapter gas stipend and turns a NAV read
    ///      into a REVERT.
    /// @return assets Array of Asset (address, symbol, decimals).
    function getRegisteredAssets() external view returns (Asset[] memory assets);

    /// @notice Resolves ONE asset's registry metadata in O(1), without reverting when it is absent.
    /// @dev The single-asset counterpart to {getRegisteredAssets}, added because balance adapters resolve tokens
    ///      one at a time and the array getter makes that quadratic (see its docs for the measured figures).
    ///      Backed by the 1-based `_assetIndex` map the registry already maintains on register/unregister, so this
    ///      is a mapping load plus one array read — flat in the number of registered assets.
    ///
    ///      **Non-reverting by design, and that is the whole reason this is a new function rather than a widened
    ///      visibility on the existing internal lookup.** NAVCalculator's `_getRegisteredAsset` reverts
    ///      `AssetNotFound` for an unregistered asset, which is right for its callers but wrong here: "not
    ///      registered" is an ORDINARY, expected outcome on an adapter's emission path — the adapter simply skips
    ///      that leg. A reverting getter would turn every unregistered token an adapter happens to encounter into
    ///      a failed instance read, converting a skipped leg into a dropped position.
    /// @param asset The asset to resolve.
    /// @return assetInfo The registry entry. Zeroed (`address(0)`, `""`, `0`) when `found` is false — **check
    ///         `found`, do not infer absence from a zero `assetInfo.asset`**, since the two are only equivalent
    ///         while nothing zero-addressed can be registered.
    /// @return found True if `asset` is registered.
    function getRegisteredAsset(address asset) external view returns (Asset memory assetInfo, bool found);

    /// @notice Returns the number of registered assets.
    /// @return Number of registered assets.
    function getAssetCount() external view returns (uint256);

    /// @notice Returns the current implementation version (Initializable storage).
    /// @return Version number.
    function version() external view returns (uint64);

    //
    // View functions — NAV and positions
    //

    /// @notice Computes NAV for an account in the given quote currency.
    /// @param account Account address.
    /// @param quoteAsset Quote currency; address(0) for USD. Must have a price feed if not zero.
    /// @return nav NAV struct (value, quoteAsset, timestamp, stalePriceAssets, sequencerDown, quoteAssetStale).
    function getAccountNav(address account, address quoteAsset) external view returns (NAV memory nav);

    /// @notice Computes the NAV contribution of a CALLER-SUPPLIED SET of balance adapters, so an off-chain caller
    ///         can read a portfolio's NAV in slices and reassemble it.
    /// @dev Exists because {getAccountNav} scans every registered adapter in one `eth_call` and that cost grows
    ///      with the asset registry and the adapter set. Past a node's `eth_call` gas cap the complete read stops
    ///      returning anything at all — not a degraded NAV, no NAV — and there is no smaller question to ask.
    ///      This is that smaller question.
    ///
    ///      **A SET, NOT AN INDEX RANGE, AND THAT IS NOT A STYLE CHOICE.** `getAllAdapters()` is maintained with
    ///      swap-and-pop, so removing any adapter moves the LAST adapter into the removed one's index — always to a
    ///      LOWER index. A caller paging `[0,10)` then `[10,20)` across a governance removal therefore **silently
    ///      SKIPS** the moved adapter: it was at the tail, it lands in a slot the caller has already passed, and it
    ///      is never read. Both pages still look completely well-formed and the total is short by that adapter's
    ///      positions.
    ///
    ///      Precisely because elements only ever move DOWN, a removal cannot make an already-read adapter reappear
    ///      in a later page — so the hazard is a missed adapter, not a double-counted one. (An earlier version of
    ///      this note claimed a double-read; that is not reachable through either removal path.) Naming the adapters
    ///      removes the whole class rather than documenting it away.
    ///
    ///      ### The caller contract
    ///
    ///      **Canonical statement: `docs/howto/read-nav-in-slices.md`.** That document is the single source for the
    ///      reassembly rules, including the worked example and the gas-starvation precondition. What follows is the
    ///      short form, kept here because a consumer generating against this ABI may never open the repo — if the
    ///      two ever disagree, the how-to wins and this block is the bug.
    ///
    ///      Four obligations. The first two this function enforces; the last two it cannot see, and they are
    ///      where a reassembled NAV goes wrong.
    ///
    ///      1. **Every adapter must be registered and appear at most once** — else {AdapterNotRegistered} or
    ///         {DuplicateAdapterInSlice}. An empty list reverts {EmptyAdapterSlice}.
    ///      2. **The slice is queried as one atomic read**, so `value` is internally consistent.
    ///      3. **All slices MUST be read at the same block, and PINNING THE BLOCK NUMBER IN THE REQUEST is the only
    ///         real control.** Pass an explicit block number to every `eth_call` — not `latest`, which lets
    ///         successive calls land on different heads. Positions and prices both move between blocks, so slices
    ///         from different blocks sum to a number that was never any account's NAV, and the sum looks entirely
    ///         reasonable.
    ///
    ///         `PartialNAV.timestamp` is a **cross-check, not the check**, and it is deliberately described that way
    ///         here: equal timestamps do NOT imply the same block. Arbitrum Nitro mints blocks roughly every 250ms,
    ///         so consecutive blocks routinely share a `block.timestamp`, and this contract is deployed there. The
    ///         field therefore catches only the gross case (slices seconds apart) and is blind to the narrow one
    ///         (two blocks inside one second) — which is the case an unpinned paging loop actually produces. There
    ///         is no block number in `PartialNAV` to check instead, by choice: adding one would not fix an unpinned
    ///         caller, and pinning the request already does.
    ///      4. **The union of the slices must cover `getAllAdapters()` exactly once**, and
    ///         `PartialNAV.adaptersCovered` is how that is verified: concatenate it across slices and compare
    ///         against `getAllAdapters()` read at the same block. A missing adapter yields a NAV short by its
    ///         positions; a repeated one double-counts. Re-read `getAllAdapters()` at the pinned block rather than
    ///         trusting a cached list — the registry is governed and can change under a paging loop.
    ///
    ///      ### **Health flags do NOT sum. Ignoring them on ANY slice silently destroys a signal.**
    ///
    ///      `value` is the only field that composes by addition. **`stalePriceAssets`, `irregularPriceAssets` and
    ///      `monitorsUnhealthyPriceAssets` are restricted to the assets THIS slice's positions touched, and
    ///      `sequencerDown`, `quoteAssetStale` and `quoteAssetIrregular` are reported per slice. A caller that checks the flags on one slice, or on
    ///      the last slice, or on a slice it happened to keep, silently loses every staleness, depeg and
    ///      sequencer-down signal carried by the others — and gets a NAV number that looks fine.** That failure
    ///      shape is exactly what this repo's fail-open hardening work was for; it must not be reintroduced at the
    ///      reassembly boundary. **UNION the THREE asset arrays (de-duplicating: two slices holding the same stale
    ///      asset each report it) and OR the three booleans, across every slice, before treating the summed
    ///      `value` as usable.** The third array, `monitorsUnhealthyPriceAssets`, was appended later than this
    ///      instruction was first written — a reassembler that unions only two silently drops the monitor-health
    ///      signal, which is the falsely-reassuring direction and hits precisely the large accounts that must
    ///      paginate.
    ///
    ///      ### A meta-adapter is the atomic unit
    ///
    ///      A slice naming a meta-adapter includes **all** of that adapter's governed instances — every Aave V3
    ///      instance, every Morpho market, every Curve pool. There is no way to page WITHIN one meta-adapter
    ///      through this API, by design: the governed instance set is itself swap-and-pop mutable
    ///      (`addMetaInstances`/`removeMetaInstances`), so an instance-level range would carry the same
    ///      reordering hazard this signature exists to avoid, and an instance-level set would need the adapter to
    ///      accept a filter it does not have. So the finest slice available is one adapter. If a SINGLE
    ///      meta-adapter's read alone exceeds the gas budget, pagination does not help and the problem is that
    ///      adapter's per-instance cost, not the number of adapters — a different problem with a different fix.
    ///
    ///      ### What this does NOT do
    ///
    ///      Pagination reduces the gas of one call. It does not reduce the total gas of reading the whole NAV
    ///      (it slightly increases it — per-call overhead is paid per slice) and it does nothing whatsoever for an
    ///      ON-CHAIN consumer that must read a NAV inside a transaction: that consumer needs one complete answer
    ///      in one frame and cannot reassemble across calls. For those callers the only fixes are reducing the
    ///      cost of the read itself or shrinking the registry. This API is for off-chain readers.
    ///
    ///      One thing it does help, but read the caveat before relying on it: the per-adapter gas stipend is a
    ///      share of what the READ still holds, so an adapter starved into {AdapterGasExhausted} inside the
    ///      complete scan may have ample budget when asked for on its own. A slice can therefore get an answer out
    ///      of a portfolio whose complete read has started reverting.
    ///
    ///      **The caveat: a slice can also convert that loud revert into a silent omission.** Exhaustion is
    ///      classified by `GasStipendLib.exhausted` as `consumed >= stipend - stipend/8` — measured against a
    ///      stipend that is itself a share of the CALLER's budget. An adapter that fails at a roughly fixed cost
    ///      `G` for a non-gas reason is scored "exhausted" (loud {AdapterGasExhausted}) when the full scan's
    ///      stipend is small enough that `G` clears that bar, and scored "benign revert" — fail open, legs dropped,
    ///      nothing flagged — when the slice's larger stipend puts `G` below it. `adaptersCovered` still lists the
    ///      adapter, so the documented coverage check reports full coverage. If a dropped leg is a DEBT leg the
    ///      reassembled NAV over-reports.
    ///
    ///      So: a slice that succeeds where the complete read reverted is **evidence about gas, not a repaired
    ///      answer.** Do not silently promote it to the authoritative NAV.
    ///
    ///      And note what "just give the complete read more gas and compare" does NOT achieve: raising the budget
    ///      raises the stipend, which puts a fixed-cost failure below the same 7/8 bar for the COMPLETE read too.
    ///      Both reads then fail open on the identical adapter and AGREE on the identical wrong number. The signal
    ///      is the {AdapterGasExhausted} disappearing, not the two figures converging.
    ///
    ///      No verbose (labelled) counterpart exists yet. The label paths carry the heavier gas pressure and their
    ///      bounds are being re-derived; a paginated read built against numbers about to change would be wasted.
    /// @param account Account address.
    /// @param quoteAsset Quote currency; `address(0)` for USD. Must have a price feed if non-zero. Pass the SAME
    ///        value to every slice — the per-slice `value`s are otherwise denominated differently and summing them
    ///        is meaningless.
    /// @param adapters The balance adapters to include. Each must be currently registered (in `getAllAdapters()`)
    ///        and may appear only once. Must be non-empty.
    /// @return partialNav The slice's NAV contribution plus `adaptersCovered`. See {PartialNAV} — in particular,
    ///         `value` sums and nothing else does.
    function getAccountNavForAdapters(address account, address quoteAsset, address[] calldata adapters)
        external
        view
        returns (PartialNAV memory partialNav);

    /// @notice Returns all positions for an account with pricing in the quote currency.
    /// @param account Account address.
    /// @param quoteAsset Quote currency; address(0) for USD.
    /// @return positions Array of enriched Position structs.
    function getAccountPositions(address account, address quoteAsset)
        external
        view
        returns (Position[] memory positions);

    /// @notice Returns positions for an account filtered by a single asset.
    /// @dev    **This is a filtered VIEW, not a net position. Do not sum it.** You asked for asset `X`, so you get
    ///         the legs denominated in `X` — a projection of the portfolio onto one asset, deliberately. Summing
    ///         `value` across the result (or netting credit against debt within it) produces a number that is not
    ///         this account's exposure to anything: the legs that offset these — collateral in another asset
    ///         backing a debt in `X`, or the reverse — are outside the filter by construction and are simply
    ///         absent, not netted. A vault borrowing `X` against `Y` shows here as debt in `X` with no sign of the
    ///         `Y` that secures it.
    ///
    ///         This is a documentation contract, not a defect, and the design is what makes it safe: **no NAV
    ///         number in this interface is ever computed with an asset filter.** {getAccountNav},
    ///         {getAccountNavForAdapters} and {getAccountNavVerbose} take no `asset` parameter at all, and the only
    ///         entry points that pass a non-zero filter into the position engine are this function and
    ///         {getAccountPositionsForAssetVerbose} — both of which return `Position[]`, never a `NAV`. So the
    ///         hazard lives entirely in what a CALLER does with the array, which is why it is stated here.
    ///
    ///         For a net figure, use {getAccountNav} (whole portfolio) or {getAccountNavForAdapters} (a validated
    ///         adapter slice, which partitions rather than projects and whose slices therefore do sum).
    /// @param account Account address.
    /// @param asset Asset to filter by (must be registered).
    /// @param quoteAsset Quote currency; address(0) for USD.
    /// @return positions Array of enriched Position structs for the asset. A filtered view — see the note above.
    function getAccountPositionsForAsset(address account, address asset, address quoteAsset)
        external
        view
        returns (Position[] memory positions);

    /// @notice Returns all positions for `account` with human-readable labels.
    /// @param account Account address.
    /// @param quoteAsset Quote currency; address(0) for USD.
    /// @return Array of VerbosePosition structs (enriched Position plus protocolName and display labels).
    function getAccountPositionsVerbose(address account, address quoteAsset)
        external
        view
        returns (VerbosePosition[] memory);

    /// @notice Returns positions filtered by a single asset, with human-readable labels.
    /// @dev    **This is a filtered VIEW, not a net position. Do not sum it.** Identical projection semantics to
    ///         {getAccountPositionsForAsset} — this is that function's result passed through label enrichment, from
    ///         the same `_computePositions` call with the same filter — so the whole note there applies verbatim,
    ///         including the reason it is safe: no NAV in this interface is computed with an asset filter. See
    ///         {getAccountPositionsForAsset}.
    /// @param account Account address.
    /// @param asset Asset to filter by (must be registered).
    /// @param quoteAsset Quote currency; address(0) for USD.
    /// @return Array of VerbosePosition structs for the asset (enriched Position plus protocolName and display
    ///         labels). A filtered view — see the note above.
    function getAccountPositionsForAssetVerbose(address account, address asset, address quoteAsset)
        external
        view
        returns (VerbosePosition[] memory);

    /// @notice Returns the aggregate NAV and full verbose position breakdown in one call.
    /// @param account Account address.
    /// @param quoteAsset Quote currency; address(0) for USD.
    /// @return verboseNav VerboseNAV struct bundling the NAV snapshot with the verbose position list.
    function getAccountNavVerbose(address account, address quoteAsset)
        external
        view
        returns (VerboseNAV memory verboseNav);

    /// @notice Returns the number of decimals used for USD values (e.g. 8).
    /// @return USD decimals.
    function usdDecimals() external view returns (uint8);

    /// @notice Returns detailed price feed data for an asset (primary feed + divergence signal vs its monitors).
    /// @param underlyingAsset Registered asset address.
    /// @return priceFeedData PriceFeedData struct (feed, type, price, decimals, heartbeat, updatedAt, stale,
    ///         sequencerDown, healthyFeedCount, irregular, divergenceBps, monitorFeedCount).
    function getPriceData(address underlyingAsset) external view returns (PriceFeedData memory priceFeedData);

    /// @notice Same as {getPriceData} but WITHOUT the monitor-divergence computation (irregular/divergenceBps/
    ///         monitorFeedCount stay 0/false). For hot callers that only need price/staleness (e.g. custom feeds
    ///         reading the NAV-sourced base/USD term) so a base asset's monitor reads + sort aren't repaid per call.
    /// @param underlyingAsset Registered asset address.
    /// @return priceFeedData PriceFeedData struct with the divergence fields left at their defaults.
    function getPriceDataNoDivergence(address underlyingAsset)
        external
        view
        returns (PriceFeedData memory priceFeedData);

    /// @notice Returns the divergence between an asset's primary price and its monitor feeds.
    /// @param underlyingAsset Registered asset address.
    /// @return primaryPrice The primary feed's price, normalized to NAV_DECIMALS. A stale-but-usable primary reports
    ///         its price (ADR 0029); 0 when no primary feed is usable or the L2 sequencer is down.
    /// @return monitorMedian The median of the healthy monitor prices, NAV_DECIMALS (0 if no healthy monitors).
    /// @return divergenceBps Worst-case basis-point gap between the primary and any single healthy monitor — the
    ///         value `irregular` is thresholded on (0 if no monitors, no usable primary, or sequencer down).
    /// @return irregular True if divergenceBps exceeds the divergence tolerance, or (stablecoins) the primary
    ///         deviates from $1 beyond the peg tolerance.
    /// @return monitorFeedCount Number of healthy monitor feeds that contributed.
    /// @return primaryStale True if no primary feed is fresh or the L2 sequencer is down. Divergence is still computed
    ///         on a stale-but-usable primary (ADR 0029); it is undefined only when the sequencer is down or the primary
    ///         price is 0.
    /// @return primaryAboveMonitors True if the primary sits above the monitor median (a premium); false if
    ///         below/equal — for a claim asset, below is the depeg direction. Meaningful only when
    ///         monitorFeedCount > 0.
    function getPriceDivergence(address underlyingAsset)
        external
        view
        returns (
            int256 primaryPrice,
            int256 monitorMedian,
            uint256 divergenceBps,
            bool irregular,
            uint256 monitorFeedCount,
            bool primaryStale,
            bool primaryAboveMonitors
        );

    /// @notice Returns health status: sequencer down flag and lists of stale-price and irregular-price assets.
    /// @return sequencerDown True if L2 sequencer is down or in grace period (false on L1).
    /// @return stalePriceAssets Addresses of assets with stale prices.
    /// @return irregularPriceAssets Addresses of assets flagged irregular (primary diverged from monitors / peg).
    function healthCheck()
        external
        view
        returns (bool sequencerDown, address[] memory stalePriceAssets, address[] memory irregularPriceAssets);

    /// @notice Returns whether the account has any non-zero balance across adapters and registered assets.
    /// @param account Account address.
    /// @return has True if at least one position has non-zero amount.
    function hasPositions(address account) external view returns (bool has);

    /// @notice Returns the list of assets for which the account has at least one non-zero position.
    /// @param account Account address.
    /// @return assets Array of asset addresses.
    function getAssetsWithPositions(address account) external view returns (address[] memory assets);

    /// @notice Converts a list of (asset, amount) pairs into a total value in the quote currency.
    /// @dev Only positive amounts; zero amounts are skipped. All assets must be registered with a price feed.
    /// @param assets Asset addresses.
    /// @param amounts Corresponding amounts (same length as assets).
    /// @param quoteAsset Quote currency; address(0) for USD.
    /// @return value Sum of values in quote asset (non-negative for valid inputs). Stale assets are valued at
    ///         their last-known price (ADR 0029); this read has no per-asset staleness output, so check healthCheck
    ///         or getPriceData. Reverts QuoteAssetUnpriceable if the non-USD quote has no usable price.
    /// @return quoteAssetStale True if the requested non-USD quote asset's own feed was stale, so `value` was
    ///         converted at its last-known price ([9]/S2). Always false for a USD quote (address(0)).
    function calculateValue(address[] memory assets, uint256[] memory amounts, address quoteAsset)
        external
        view
        returns (int256 value, bool quoteAssetStale);

    /// @notice Every listed adapter's EFFECTIVE display name and positionId-independent breadcrumb — the same values
    ///         the verbose position reads report, including any {AssetKindRegistry} override.
    /// @dev Declared here, not only on the concrete contract, so INTERFACE-TYPED consumers can reach it. That is the
    ///      caller that matters: a consumer holding `INAVCalculator` is exactly the one that would otherwise
    ///      enumerate `getAllAdapters()` and staticcall `protocolName()` on each adapter itself, which is the
    ///      surface split this function exists to close. Leaving it off the interface would have left that consumer
    ///      with no way to reach the fix.
    /// @param adapters The adapters to describe, typically the result of `getAllAdapters()`.
    /// @return names Each adapter's effective protocol name.
    /// @return labels Each adapter's effective breadcrumb, with any {AssetKindRegistry} per-segment override applied.
    ///         Empty when the adapter derives it per position AND no override is set. When the adapter answers
    ///         nothing but an override IS set, this path deliberately GROWS the breadcrumb to the override's leading
    ///         non-empty prefix — so it can be MULTI-segment, not merely a lone category. (It was a lone category
    ///         under the retired scalar `setAdapterLabelCategory`; do not code against that.) When the adapter DOES
    ///         answer, the override is overlaid segment-by-segment and can neither lengthen nor truncate the reply.
    ///         See `PriceFeedLib.adapterDisplayInfo` for why the empty case diverges from the position path.
    function getAdapterDisplayInfo(address[] calldata adapters)
        external
        view
        returns (string[] memory names, string[][] memory labels);
}
