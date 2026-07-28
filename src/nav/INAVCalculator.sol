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
        // True if the quote asset's own price feed was stale. When true, `value` is in USD (8dp) even though
        // `quoteAsset` is non-zero — the quote conversion was skipped. Mirrors NAV.quoteAssetStale ([9]/S2).
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
    /// @param stalePriceAssets Assets whose prices were stale at query time.
    /// @param irregularPriceAssets Assets whose primary price diverged from their monitor feeds beyond tolerance
    ///        (or, for stablecoins, from the $1 peg) at query time. A pricing-quality signal, not a staleness flag —
    ///        `value` is still computed from the primary prices. Consumers decide how to react.
    /// @param sequencerDown True if the L2 sequencer was down or in grace period (L2 only).
    /// @param quoteAssetStale True if the quote asset's own price feed was stale. When true the value field
    ///        is in USD (fallback) even though quoteAsset is non-zero — callers must check this flag before
    ///        interpreting value as being in the requested quote currency.
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
        bool quoteAssetIrregular;
    }

    /// @notice Price data for the freshest non-stale feed selected for an asset.
    /// @dev When multiple feeds are registered, these fields describe the winning (freshest) feed.
    /// When all feeds are stale, fields describe the first registered feed and stale == true.
    /// @param priceFeed Address of the selected price feed contract.
    /// @param priceType Feed type (Chainlink, Custom, Redstone, or API3).
    /// @param price Current price (e.g. USD per unit); 0 when stale.
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
    /// @param stale True if all feeds are stale or the L2 sequencer is down.
    /// @param sequencerDown True if L2 sequencer is down (L2 only).
    /// @param healthyFeedCount Number of registered feeds that passed all staleness gates on this read.
    ///        A value below the total registered feed count signals partial redundancy collapse and
    ///        should trigger off-chain alerting.
    /// @param irregular True if the primary price diverged from the worst-case (furthest) healthy monitor feed
    ///        beyond the configured divergence tolerance, or (stablecoins) from the $1 peg beyond the peg tolerance.
    /// @param divergenceBps Worst-case basis-point gap between the primary price and any single healthy monitor
    ///        price (0 when there are no healthy monitors or the primary is stale).
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

    /// @notice Adds an additional price feed for an already registered asset.
    /// @dev Reverts with PriceFeedAlreadyRegistered if the feed address is already registered for this asset.
    /// @param asset Registered asset address.
    /// @param priceFeed Price feed address (cannot be zero).
    /// @param priceType Chainlink, Custom, Redstone, or API3.
    /// @param chainlinkHeartbeat Staleness window in seconds (must be non-zero for all types).
    function addPriceFeed(address asset, address priceFeed, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external;

    /// @notice Adds a monitor (divergence-only) feed for an asset. Monitor feeds NEVER price the NAV; they are read
    ///         only to detect divergence between the primary price and the worst-case (furthest) healthy monitor price.
    /// @dev Requires the asset's divergence tolerance to be set first (>0), else reverts DivergenceToleranceRequired.
    ///      Monitor feeds must report NAV_DECIMALS decimals (else MonitorFeedDecimalsMismatch). Reverts
    ///      MonitorFeedAlreadyRegistered on a duplicate.
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
    /// @return assets Array of Asset (address, symbol, decimals).
    function getRegisteredAssets() external view returns (Asset[] memory assets);

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

    /// @notice Returns all positions for an account with pricing in the quote currency.
    /// @param account Account address.
    /// @param quoteAsset Quote currency; address(0) for USD.
    /// @return positions Array of enriched Position structs.
    function getAccountPositions(address account, address quoteAsset)
        external
        view
        returns (Position[] memory positions);

    /// @notice Returns positions for an account filtered by a single asset.
    /// @param account Account address.
    /// @param asset Asset to filter by (must be registered).
    /// @param quoteAsset Quote currency; address(0) for USD.
    /// @return positions Array of enriched Position structs for the asset.
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
    /// @param account Account address.
    /// @param asset Asset to filter by (must be registered).
    /// @param quoteAsset Quote currency; address(0) for USD.
    /// @return Array of VerbosePosition structs for the asset (enriched Position plus protocolName and display labels).
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
    /// @return primaryPrice The primary feed's price, normalized to NAV_DECIMALS (0 if the primary is stale).
    /// @return monitorMedian The median of the healthy monitor prices, NAV_DECIMALS (0 if no healthy monitors).
    /// @return divergenceBps Worst-case basis-point gap between the primary and any single healthy monitor — the
    ///         value `irregular` is thresholded on (0 if no monitors / primary stale).
    /// @return irregular True if divergenceBps exceeds the divergence tolerance, or (stablecoins) the primary
    ///         deviates from $1 beyond the peg tolerance.
    /// @return monitorFeedCount Number of healthy monitor feeds that contributed.
    /// @return primaryStale True if the primary feed is stale (divergence undefined).
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
    /// @return value Sum of values in quote asset (non-negative for valid inputs). When `quoteAssetStale` is
    ///         true, this is denominated in USD (8dp) instead of the requested quote ([9]/S2).
    /// @return quoteAssetStale True if the requested non-USD quote asset's own feed was stale, so `value` fell
    ///         back to USD rather than the quote currency. Always false for a USD quote (address(0)).
    function calculateValue(address[] memory assets, uint256[] memory amounts, address quoteAsset)
        external
        view
        returns (int256 value, bool quoteAssetStale);
}
