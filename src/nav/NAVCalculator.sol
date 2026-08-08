// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IPrices, Prices} from "src/prices/Prices.sol";
import {PriceFeedLib} from "src/prices/PriceFeedLib.sol";
import {Balances} from "src/balances/Balances.sol";
import {ERC20DefaultBalanceAdapter} from "src/balances/BalanceAdapters/ERC20DefaultBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "./INAVCalculator.sol";
import {NAVRegistryLib} from "./NAVRegistryLib.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {IAssetKindRegistry} from "./IAssetKindRegistry.sol";
import {PegKind, AccrualKind} from "src/utils/AssetKind.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title NAV Calculator
/// @notice NAV Calculator.
/// @author KPK
/// @dev EIP-170 budget: this contract runs close to the 24,576-byte runtime limit (CI's `forge build --sizes`
///      enforces it). **THIS BLOCK IS THE SINGLE AUTHORITY FOR THE EIP-170 BUDGET.** Other files used to restate
///      it and drifted into three mutually contradictory figures; they now point here instead. If you cite a
///      margin, cite this one — and re-measure it, because a number in a comment is never evidence.
///
///      As of {getAdapterDisplayInfo}, measured by `forge build --sizes`:
///        - `NAVCalculator`        24,475 / 24,576 -> **101 bytes** free
///        - `NAVCalculatorV2`      24,567 / 24,576 -> **9 bytes** free
///
///      ⚠️ **9, not 101, is the number that gates a change.** `NAVCalculatorV2` is the UUPS upgrade fixture in
///      `test/nav/NAVCalculator.upgrade.t.sol` — this contract plus one `foo()` function, never deployed — and
///      CI's Build step is literally `forge build --sizes`, which **exits 1** on ANY contract over the limit,
///      `test/` included. Verified by probe: an oversized contract under `test/` produces
///      `Error: some contracts exceed the runtime size limit (EIP-170: 24576 bytes)` and exit code 1. So a change
///      that fits this contract but pushes the fixture over still fails CI, naming a file nobody edited.
///
///      **Treat this contract as FULL.** For scale: one minimal external getter has measured at 122 B — more than
///      the fixture's whole remaining budget — and {getAdapterDisplayInfo} cost 354 B. The next addition here needs
///      space reclaimed first rather than found. (Earlier revisions of this line read "325 bytes under / 24,251 B"
///      and then "68 bytes under / 24,508 B"; both were stale when read.)
///      Measure with a clean
///      `forge build --sizes` before and after anything added here, and assume nothing non-trivial fits: the next
///      substantive read will need the verbose label block (`_toVerbose` / `_safeString` / `_safeStringArray` /
///      `decodeStringArray`) moved out to a separate LENS CONTRACT first. Not to a library — `decodeStringArray`
///      has to be an external function on a contract for `try`/`catch` to reach it, which is why that block is
///      inlined here today. The read/compute engine (NAV, positions, health, value) and the registry storage-mutation
///      loops are deliberately delegated to the external libraries `PriceFeedLib` and `NAVRegistryLib`
///      (DELEGATECALL) to stay under it — NAVCalculator keeps only storage, admin mutations, and thin
///      view wrappers. When adding code here, watch the margin and prefer moving substantial loops into a
///      library; the entry point should build and consume any heavy PositionBalance[]/Position[] arrays
///      *inside* the library, because returning them across the ABI boundary (and piecemeal helper extraction
///      generally) can cost more than the inlined body under `via_ir`. Always measure with a clean
///      `forge build --sizes`. The verbose label-enrichment read path (`get*Verbose` + `_toVerbose`/`_safeString`)
///      is inlined here rather than split into a separate lens contract — it fits today, but it is the block to move
///      out first when it stops fitting (see the margin note above).
contract NAVCalculator is Initializable, UUPSUpgradeable, AccessControlUpgradeable, INAVCalculator, Prices, Balances {
    //
    // State
    //

    /// @notice Asset registry (NAV/Pricing) — ordered list of registered assets (address, symbol, decimals)
    INAVCalculator.Asset[] private _registeredAssets;

    /// @notice Index of asset in _registeredAssets (1-based; 0 = not registered)
    mapping(address asset => uint256) private _assetIndex;

    /// @notice Gap for upgradeability (reserve storage for new state in upgrades)
    /// @dev Was `[50]`. One slot was taken for {assetKindRegistry} below, which is declared AFTER this array on
    ///      purpose: shrinking the gap and appending keeps every pre-existing slot at the index it already had, so
    ///      this is upgrade-safe on the deployed proxies. Declaring the new variable BEFORE the gap would have
    ///      shifted the gap and corrupted nothing today but would break the next append.
    uint256[49] private _gap;

    /// @notice The per-chain {AssetKindRegistry} this NAV reads asset kinds from. Zero until set.
    /// @dev Occupies the slot released from `_gap`. Settable (not immutable) because the NAV is a UUPS proxy that is
    ///      already deployed on 24 chains: an immutable would require a new implementation AND could not be
    ///      initialized without a new `initialize`, which is set-once and would force a new proxy.
    IAssetKindRegistry public assetKindRegistry;

    //
    // Constructor
    //

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializer for UUPS proxy
    /// @param admin_ The initial admin
    /// @param chainlinkL2SequencerUptimeFeed_ The address of the chainlink feed for the sequencer uptime
    /// @param nativeTokenSymbol_ The native token symbol (e.g. "ETH", "xDAI") — fixed at init
    function initialize(address admin_, address chainlinkL2SequencerUptimeFeed_, string memory nativeTokenSymbol_)
        external
        initializer
    {
        __AccessControl_init();
        __Prices_init(chainlinkL2SequencerUptimeFeed_);
        __Balances_init();
        _setNativeTokenSymbol(nativeTokenSymbol_);

        // Pre-register native address in NAV/Pricing registry
        _registerAsset(NATIVE_ADDRESS);
        // Deploy ERC20Default adapter with native in inclusion list (constructor avoids callback to proxy during init).
        // The `new` lives in NAVRegistryLib (DELEGATECALL: address(this) is this proxy) so the adapter's creation
        // bytecode is embedded in that external library, not NAVCalculator's runtime — see ADR + deployDefaultAdapter.
        address[] memory initialAssets = new address[](1);
        initialAssets[0] = NATIVE_ADDRESS;
        _setErc20DefaultBalanceAdapter(NAVRegistryLib.deployDefaultAdapter(initialAssets));

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    //
    // INAVCalculator
    //

    /// @inheritdoc INAVCalculator
    function registerAsset(address asset, address priceFeed, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external
    {
        _requireManager();
        if (asset == address(0)) {
            revert InvalidArguments();
        }
        if (priceFeed == address(0)) {
            revert InvalidArguments();
        }

        // Check if asset already exists
        if (isAssetRegistered(asset)) {
            revert InvalidArguments(); // Asset already registered
        }

        // A code-less `asset` must fail HERE, and with an error that names the problem. `NAVRegistryLib.
        // registerAsset` probes `IERC20Metadata(asset).decimals()` behind a `try`/`catch` that reads as if it
        // covered this — it does not. The OUTCOME is what matters and is unchanged: `catch` never sees it, and the
        // revert reaches the MANAGER with empty returndata.
        //
        // The mechanism, stated correctly because an earlier version of this comment had it backwards: it is NOT an
        // `extcodesize` precheck. `decimals()` expects return data, and since solc 0.8.10 that is precisely the
        // condition under which the existence check is SKIPPED (the pin is 0.8.34). The call therefore SUCCEEDS
        // against a code-less address, returning nothing, and the failure surfaces afterwards in the calling frame
        // when the empty returndata cannot be decoded — which `try`/`catch` does not catch, because it guards the
        // call and not the decoding of what the call returned. (This is the one place a `code.length` guard is not
        // dead code — in front of a LOW-level staticcall it would be, because that succeeds against a code-less
        // address rather than reverting.)
        //
        // `NotAContract` rather than this function's `InvalidArguments`: a mistyped address and a real contract
        // that simply is not ERC20-compatible are different operator problems, and the library already answers
        // the second with `InvalidArguments`. Reusing that selector here would leave the two indistinguishable,
        // which is the whole point of the guard.
        //
        // The guard lives at this call site rather than in the library on purpose: `NAVRegistryLib` is pre-linked
        // at a deterministic CREATE2 address, so changing its bytecode moves the pin, which forces a new
        // implementation and an upgrade on every deployed chain — a disproportionate price for an error-message
        // fix. `NATIVE_ADDRESS` is exempt because it is code-less by construction and takes the library's native
        // branch (it is pre-registered during `initialize`, so in practice it is already rejected above).
        if (asset != NATIVE_ADDRESS) {
            AddressCheckLib.requireContract(asset, "asset");
        }

        // Register asset in NAV/Pricing registry; fetches decimals/symbol from ERC20 (or native); reverts if not ERC20 compatible
        _registerAsset(asset);

        // Register first price feed as part of asset registration
        _addPriceFeed(asset, priceFeed, chainlinkHeartbeat, priceType);

        // Add asset to default adapter's inclusion list so wallet balances are reported
        ERC20DefaultBalanceAdapter(erc20DefaultBalanceAdapter).addSupportedAsset(asset);

        emit AssetRegistered(asset, _getRegisteredAsset(asset).decimals);
    }

    /// @inheritdoc INAVCalculator
    function addPriceFeed(address asset, address priceFeed, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external
    {
        _requireManager();
        if (priceFeed == address(0)) {
            revert InvalidArguments();
        }

        _requireAssetExists(asset);

        _addPriceFeed(asset, priceFeed, chainlinkHeartbeat, priceType);
    }

    /// @inheritdoc INAVCalculator
    function addMonitorFeed(address asset, address priceFeed, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external
    {
        _requireManager();
        if (priceFeed == address(0)) {
            revert InvalidArguments();
        }
        _requireAssetExists(asset);
        _addMonitorFeed(asset, priceFeed, chainlinkHeartbeat, priceType);
    }

    /// @inheritdoc INAVCalculator
    function setDivergenceTolerance(address asset, uint32 divergenceToleranceBps) external {
        _requireManager();
        _requireAssetExists(asset);
        _setDivergenceTolerance(asset, divergenceToleranceBps);
    }

    /// @inheritdoc INAVCalculator
    /// @dev ⚠️ **THIS FIELD NOW DOES TWO JOBS. READ BEFORE ZEROING IT.** `pegToleranceBps` is both a *threshold* ("flag
    ///      drift beyond this") and a *switch* ("this asset should be worth $1 — guard it"), because `AssetKindRegistry`
    ///      derives `PegKind` from it: non-zero means `Pegged`, zero means `Floating`. Retuning a non-zero threshold
    ///      (say 100 -> 250) leaves the classification alone; it is CROSSING ZERO that flips it. So the two jobs are
    ///      independent everywhere except at that boundary — which is precisely where the trap below lives.
    ///
    ///      **The trap:** zeroing the tolerance on a genuine stablecoin for an OPERATIONAL reason — a feed too noisy to
    ///      guard, say — silently reclassifies that asset as `Floating`. Nothing reverts, nothing logs a warning, and
    ///      every off-chain consumer stops believing it is a stablecoin.
    ///
    ///      **The rule:** disabling the $1 guard on an asset that really is pegged needs its OWN field, not a zeroed
    ///      tolerance. No asset needs that today; the point is that the first one to need it must not get it by
    ///      accident. Adding that field is the correct fix — reaching for zero here is not.
    function setPegTolerance(address asset, uint32 pegToleranceBps) external {
        _requireManager();
        _requireAssetExists(asset);
        _setPegTolerance(asset, pegToleranceBps);
    }

    /// @notice Points this NAV at the chain's {AssetKindRegistry}. MANAGER-gated.
    /// @dev Re-settable on purpose: the registry is a plain (non-proxy) contract, so replacing it is a redeploy plus
    ///      this call. Rejects `address(0)` — an unset registry makes {getAssetKind} revert, and clearing it by
    ///      accident would look like a registry outage rather than a config change.
    function setAssetKindRegistry(address registry) external {
        _requireManager();
        if (registry == address(0)) revert InvalidArguments();
        assetKindRegistry = IAssetKindRegistry(registry);
    }

    /// @notice Everything this system publishes about one asset — both classification axes and its display labels — in
    ///         a single call, read through this NAV so callers need one entry point and one round trip.
    /// @dev **This REPLACED `getAssetKind`, which shipped days earlier and was never deployed.** Combining the two
    ///      reads rather than adding a second getter is what makes it affordable: replacing DISPLACES a selector
    ///      instead of adding one, measured at **+87 bytes** against a **+182** floor for any forwarding read at all,
    ///      where adding `getAssetLabels` alongside `getAssetKind` cost +202 and keeping all three cost +479. The shape
    ///      that best matches "the NAV is the single point of entry" was also the cheapest, which is the opposite of
    ///      the usual trade and worth saying out loud.
    ///
    ///      Forwards to {AssetKindRegistry}. Returns the ENUMS rather than raw `uint8`s: solc inserts range
    ///      validation on every enum decoded from returndata, which measured 179 bytes more than a `(uint8, uint8)`
    ///      signature — paid deliberately for a typed ABI, and affordable only because the verbose read path was
    ///      moved into `PriceFeedLib` first.
    ///
    ///      Fail-closed by inheritance, not by re-implementation: the registry reverts `AssetNotClassified` for an
    ///      unclassified asset and this does not soften that into a default. If no registry is set, the call to
    ///      `address(0)` reverts — deliberately louder than returning `(Pegged, None, [])`, which is a real
    ///      classification and would be indistinguishable from a configured answer.
    ///
    ///      **`labels` is NOT bounded here, and that is deliberate rather than overlooked.** {_MAX_LABEL_ELEMENTS}
    ///      guards `positionLabels()` replies from arbitrary, permissionlessly-deployed balance adapters read over a
    ///      low-level `staticcall`. This is a high-level call to a MANAGER-configured registry that enforces
    ///      `MAX_ASSET_LABELS` on the WRITE side, so the bound already exists where it can be enforced once rather
    ///      than re-checked on every read — and a second cap here would cost bytes to defend against an address the
    ///      same MANAGER chose.
    function getAssetInfo(address asset) external view returns (PegKind, AccrualKind, string[] memory) {
        return assetKindRegistry.getAssetInfo(asset);
    }

    /// @notice Every listed adapter's EFFECTIVE display name and positionId-independent breadcrumb — the same
    ///         values the verbose position reads report, including any {AssetKindRegistry} override.
    /// @dev **This exists so the configuration view and the position view cannot disagree.** A consumer that
    ///      enumerates {getAllAdapters} and staticcalls `protocolName()` on each adapter itself bypasses the
    ///      override store and sees the adapter's compile-time constant, while `getAccountPositionsVerbose` reports
    ///      the override — two surfaces silently disagreeing about one adapter, which is the phantom-sibling split
    ///      {IPositionDescribable.protocolName} exists to prevent. Pair this with {getAllAdapters} instead.
    ///
    ///      The body is a single forward into `PriceFeedLib.adapterDisplayInfo`, which shares its precedence helper
    ///      with `toVerbose` — so agreement holds by construction, not by two implementations matching. The work
    ///      lives in the library because this contract is at its EIP-170 limit; only the selector is paid for here.
    /// @param adapters The adapters to describe, typically the result of {getAllAdapters}.
    /// @inheritdoc INAVCalculator
    function getAdapterDisplayInfo(address[] calldata adapters)
        external
        view
        returns (string[] memory names, string[][] memory labels)
    {
        return PriceFeedLib.adapterDisplayInfo(adapters, address(assetKindRegistry));
    }

    /// @inheritdoc INAVCalculator
    function addBalanceAdapters(address[] calldata adapters) external {
        _requireManager();
        _addBalanceAdapters(adapters);
    }

    /// @inheritdoc INAVCalculator
    function addMetaBalanceAdapter(address adapter, bytes32[] calldata instances) external {
        _requireManager();
        if (adapter == address(0)) {
            revert InvalidArguments();
        }
        _addMetaBalanceAdapter(adapter, instances);
    }

    /// @inheritdoc INAVCalculator
    function removePriceFeedAt(address asset, uint256 index) external {
        _requireManager();
        _requireAssetExists(asset);
        _removePriceFeedAt(asset, index);
    }

    /// @inheritdoc INAVCalculator
    function removePriceFeed(address asset, address priceFeed) external {
        _requireManager();
        _requireAssetExists(asset);
        _removePriceFeed(asset, priceFeed);
    }

    /// @inheritdoc INAVCalculator
    function removeMonitorFeedAt(address asset, uint256 index) external {
        _requireManager();
        _requireAssetExists(asset);
        _removeMonitorFeedAt(asset, index);
    }

    /// @inheritdoc INAVCalculator
    function removeMonitorFeed(address asset, address priceFeed) external {
        _requireManager();
        _requireAssetExists(asset);
        _removeMonitorFeed(asset, priceFeed);
    }

    /// @inheritdoc INAVCalculator
    function removeBalanceAdapters(address[] calldata adapters) external {
        _requireManager();
        _removeBalanceAdapters(adapters);
    }

    /// @inheritdoc INAVCalculator
    function addMetaInstances(address adapter, bytes32[] calldata instances) external {
        _requireManager();
        _addMetaInstances(adapter, instances);
    }

    /// @inheritdoc INAVCalculator
    function removeMetaInstances(address adapter, bytes32[] calldata instances) external {
        _requireManager();
        _removeMetaInstances(adapter, instances);
    }

    /// @inheritdoc INAVCalculator
    function excludeAssetFromDefaultAdapter(address asset) external {
        _requireManager();
        _requireAssetExists(asset);
        ERC20DefaultBalanceAdapter(erc20DefaultBalanceAdapter).removeSupportedAsset(asset);
    }

    /// @inheritdoc INAVCalculator
    function includeAssetInDefaultAdapter(address asset) external {
        _requireManager();
        _requireAssetExists(asset);
        ERC20DefaultBalanceAdapter(erc20DefaultBalanceAdapter).addSupportedAsset(asset);
    }

    /// @inheritdoc INAVCalculator
    function unregisterAsset(address underlyingAsset) external {
        _requireManager();

        _requireAssetExists(underlyingAsset);

        // Remove all price feeds if any exist
        if (_priceFeedCount(underlyingAsset) > 0) {
            _removeAllPriceFeeds(underlyingAsset);
        }

        // Clear monitor feeds + pricing metadata (idempotent; also clears _assetPricing).
        _removeAllMonitorFeeds(underlyingAsset);

        // Remove from default adapter's inclusion list (idempotent if not present)
        ERC20DefaultBalanceAdapter(erc20DefaultBalanceAdapter).removeSupportedAsset(underlyingAsset);

        // Remove the asset itself
        _unregisterAsset(underlyingAsset);

        emit AssetUnregistered(underlyingAsset);
    }

    /// @inheritdoc INAVCalculator
    function setChainlinkL2SequencerUptimeFeed(address newChainlinkL2SequencerUptimeFeed) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        address oldChainlinkL2SequencerUptimeFeed = address(chainlinkL2SequencerUptimeFeed);
        chainlinkL2SequencerUptimeFeed = AggregatorV3Interface(newChainlinkL2SequencerUptimeFeed);
        emit ChainlinkUptimeFeedUpdated(oldChainlinkL2SequencerUptimeFeed, newChainlinkL2SequencerUptimeFeed);
    }

    /// @inheritdoc INAVCalculator
    function setChainlinkL2SequencerGracePeriod(uint256 newSequencerGracePeriod) external {
        _requireManager();
        if (address(chainlinkL2SequencerUptimeFeed) == address(0)) {
            revert UptimeFeedNotSet();
        }
        if (newSequencerGracePeriod < 1 hours) {
            revert InvalidArguments();
        }
        uint256 oldSequencerGracePeriod = chainlinkL2SequencerGracePeriod;
        chainlinkL2SequencerGracePeriod = newSequencerGracePeriod;
        emit L2SequencerGracePeriodUpdated(oldSequencerGracePeriod, newSequencerGracePeriod);
    }

    /// @inheritdoc INAVCalculator
    function version() external view override returns (uint64) {
        return _getInitializedVersion();
    }

    /// @inheritdoc INAVCalculator
    function assetCount() external view returns (uint256) {
        return getAssetCount();
    }

    /// @inheritdoc INAVCalculator
    function getAccountNav(address account, address quoteAsset) external view returns (INAVCalculator.NAV memory nav) {
        _validateQuoteAsset(quoteAsset);

        // The full read/compute path (adapter scan → unique assets → price cache → summation) is delegated to
        // PriceFeedLib to keep NAVCalculator under EIP-170; the heavy PositionBalance[] arrays are built and
        // consumed inside the library and never cross the ABI boundary. Sequencer status depends on this
        // contract's config, so it is computed here and passed in.
        return PriceFeedLib.computeNav(
            _priceOracles,
            _monitorFeeds,
            _assetPricing,
            _assetIndex,
            _registeredAssets,
            getAllAdapters(),
            _metaInstanceTotal,
            account,
            quoteAsset,
            _isSequencerDown(),
            _nativeTokenSymbol
        );
    }

    /// @inheritdoc INAVCalculator
    /// @dev **Validate, then call the very same `PriceFeedLib.computeNav` that {getAccountNav} calls**, with the
    ///      validated slice in place of the full registry. There is no separate partial-read entrypoint in the
    ///      library, deliberately: a second copy of that function's body roughly doubles the IR the `via_ir`
    ///      optimizer must process for the largest function in the largest library in this repo, and doing so was
    ///      measured to push CI's whole-project compile past the runner's memory (SIGTERM mid-compile, twice,
    ///      reproducibly, while `main` completed in the same time). Sharing the function is also the stronger
    ///      design: the partition invariant — sum of slices == complete NAV — holds because the two reads are
    ///      literally the same code, not because two implementations agree. It reuses this contract's existing
    ///      `computeNav` argument encoder and `NAV` decoder too, which matters at the margin below.
    ///
    ///      `getAllAdapters()` is passed as the registration authority, which makes "registered" mean exactly "in
    ///      the list {getAccountNav} scans" — one definition, read from storage in the same call, so a slice can
    ///      never be validated against a different registry than the one it is measured against.
    ///
    ///      The intermediate `NAV` never leaves this frame. It must not: it is a PARTIAL result wearing the
    ///      complete result's type for the length of one function body, which is exactly what {PartialNAV} exists
    ///      to prevent anywhere else. Returning `n` from any variant of this function would reintroduce that
    ///      hazard, and so would exposing a `computeNav` result reached through a slice by any other route.
    function getAccountNavForAdapters(address account, address quoteAsset, address[] calldata adapters)
        external
        view
        returns (INAVCalculator.PartialNAV memory partialNav)
    {
        _validateQuoteAsset(quoteAsset);

        address[] memory covered = PriceFeedLib.validateAdapterSlice(getAllAdapters(), adapters);

        INAVCalculator.NAV memory n = PriceFeedLib.computeNav(
            _priceOracles,
            _monitorFeeds,
            _assetPricing,
            _assetIndex,
            _registeredAssets,
            covered,
            // `_metaInstanceTotal` is a WHOLE-REGISTRY quantity being passed alongside `covered`, a SLICE. That is
            // inconsistent on its face and safe only because `computeNav` never reads the parameter (solc reports it
            // unused). Passing it keeps this call site identical to `getAccountNav`'s, which is what lets the two
            // share one argument encoder. **If it is ever given a use — pre-sizing a buffer, say — it must be
            // derived from `allAdapters`, not from the registry**, or the slice and the complete read would allocate
            // differently and `computeNav` would become adapter-set-dependent in exactly the way its own docstring
            // forbids.
            _metaInstanceTotal,
            account,
            quoteAsset,
            _isSequencerDown(),
            _nativeTokenSymbol
        );

        partialNav.value = n.value;
        partialNav.quoteAsset = n.quoteAsset;
        partialNav.timestamp = n.timestamp;
        partialNav.stalePriceAssets = n.stalePriceAssets;
        partialNav.sequencerDown = n.sequencerDown;
        partialNav.quoteAssetStale = n.quoteAssetStale;
        partialNav.irregularPriceAssets = n.irregularPriceAssets;
        partialNav.quoteAssetIrregular = n.quoteAssetIrregular;
        partialNav.adaptersCovered = covered;
        partialNav.monitorsUnhealthyPriceAssets = n.monitorsUnhealthyPriceAssets;
    }

    /// @inheritdoc INAVCalculator
    function getAccountPositions(address account, address quoteAsset)
        external
        view
        returns (INAVCalculator.Position[] memory positions)
    {
        _validateQuoteAsset(quoteAsset);
        return _computePositions(account, address(0), quoteAsset);
    }

    /// @inheritdoc INAVCalculator
    function getAccountPositionsForAsset(address account, address asset, address quoteAsset)
        external
        view
        returns (INAVCalculator.Position[] memory positions)
    {
        _validateQuoteAsset(quoteAsset);
        _validateAssetFilter(asset);
        return _computePositions(account, asset, quoteAsset);
    }

    /// @inheritdoc INAVCalculator
    function getAccountPositionsVerbose(address account, address quoteAsset)
        external
        view
        returns (INAVCalculator.VerbosePosition[] memory)
    {
        _validateQuoteAsset(quoteAsset);
        return PriceFeedLib.toVerbose(_computePositions(account, address(0), quoteAsset), address(assetKindRegistry));
    }

    /// @inheritdoc INAVCalculator
    function getAccountPositionsForAssetVerbose(address account, address asset, address quoteAsset)
        external
        view
        returns (INAVCalculator.VerbosePosition[] memory)
    {
        _validateQuoteAsset(quoteAsset);
        _validateAssetFilter(asset);
        return PriceFeedLib.toVerbose(_computePositions(account, asset, quoteAsset), address(assetKindRegistry));
    }

    /// @inheritdoc INAVCalculator
    function getAccountNavVerbose(address account, address quoteAsset)
        external
        view
        returns (INAVCalculator.VerboseNAV memory verboseNav)
    {
        _validateQuoteAsset(quoteAsset);
        // Single adapter scan produces both the NAV and the position list (see PriceFeedLib.computeNavAndPositions),
        // avoiding the double scan of computing them separately.
        INAVCalculator.Position[] memory positions;
        (verboseNav.nav, positions) = PriceFeedLib.computeNavAndPositions(
            _priceOracles,
            _monitorFeeds,
            _assetPricing,
            _assetIndex,
            _registeredAssets,
            getAllAdapters(),
            _metaInstanceTotal,
            account,
            quoteAsset,
            _isSequencerDown(),
            _nativeTokenSymbol
        );
        verboseNav.positions = PriceFeedLib.toVerbose(positions, address(assetKindRegistry));
    }

    /// @notice Shared entry point for the (filtered) position read path. Keeps the long PriceFeedLib argument
    ///         tuple in one place so the verbose and non-verbose getters cannot drift apart.
    function _computePositions(address account, address assetFilter, address quoteAsset)
        private
        view
        returns (INAVCalculator.Position[] memory)
    {
        return PriceFeedLib.computeAccountPositions(
            _priceOracles,
            _monitorFeeds,
            _assetPricing,
            _assetIndex,
            _registeredAssets,
            getAllAdapters(),
            _metaInstanceTotal,
            account,
            assetFilter,
            quoteAsset,
            _isSequencerDown(),
            _nativeTokenSymbol
        );
    }

    /// @notice Most elements a `positionLabels()` reply may decode to before it is rejected as implausible.
    /// @dev The output-side companion to {_LABELS_RETURN_BYTES}: see {decodeStringArray} for why bounding the
    ///      input alone does not bound what comes back. Every `positionLabels` in this repo returns a category
    ///      and at most a couple of leaves, so this is many times the real maximum while still being far below
    ///      the count an aliased-offset blob needs to be worth building.
    uint256 private constant _MAX_LABEL_ELEMENTS = 8;

    /// @notice External ABI-decode shim so `_safeStringArray` can wrap a possibly-reverting `abi.decode` in
    ///         try/catch (try/catch requires an external call). Internal-only: reverts unless the caller is
    ///         this contract, so it is not a usable public API surface.
    function decodeStringArray(bytes calldata data) external view returns (string[] memory arr) {
        if (msg.sender != address(this)) revert NotAuthorized();
        arr = abi.decode(data, (string[]));
        // Bounding the INPUT does not bound the OUTPUT. `string[]` element offsets may all point at the same
        // payload, so a reply that fits the window decodes to an arbitrary multiple of it — measured at ~30x for
        // a 4 KB blob aliasing one long string. That expansion is returned across this boundary and copied into
        // the verbose read's frame outside {_LABEL_DECODE_GAS}, where memory cost is quadratic and `_toVerbose`
        // repeats it once per position. Rejecting an implausible element count here is what makes the window's
        // containment claim true; the caller's `catch` turns this into the same empty label set as any other
        // malformed reply.
        if (arr.length > _MAX_LABEL_ELEMENTS) revert InvalidArguments();
    }

    /// @inheritdoc INAVCalculator
    function usdDecimals() external pure returns (uint8) {
        return NAV_DECIMALS;
    }

    /// @inheritdoc INAVCalculator
    function getRegisteredAssets() external view override returns (INAVCalculator.Asset[] memory) {
        return _registeredAssets;
    }

    /// @inheritdoc INAVCalculator
    /// @dev Deliberately NOT `return _getRegisteredAsset(asset)` with a try/catch or a pre-check: that helper
    ///      reverts `AssetNotFound`, and re-deriving "absent" from a revert would cost a call frame to learn
    ///      something one `SLOAD` already answers. The index read is the whole lookup.
    function getRegisteredAsset(address asset)
        external
        view
        override
        returns (INAVCalculator.Asset memory assetInfo, bool found)
    {
        uint256 idx = _assetIndex[asset];
        if (idx == 0) return (assetInfo, false);
        return (_registeredAssets[idx - 1], true);
    }

    /// @inheritdoc INAVCalculator
    function getAssetCount() public view override returns (uint256) {
        return _registeredAssets.length;
    }

    /// @inheritdoc INAVCalculator
    function isAssetRegistered(address asset) public view override returns (bool) {
        return _assetIndex[asset] != 0;
    }

    /// @inheritdoc INAVCalculator
    function getPriceData(address underlyingAsset)
        external
        view
        returns (INAVCalculator.PriceFeedData memory priceFeedData)
    {
        _requireAssetExists(underlyingAsset);
        _requirePriceFeedExists(underlyingAsset);

        // Heavy assembly (feed selection + config read + AggregatorV3 updatedAt fetch + divergence vs monitors) is
        // delegated to PriceFeedLib to keep NAVCalculator under EIP-170; sequencer status depends on this contract's
        // config so it is computed here and passed in.
        return PriceFeedLib.buildPriceData(
            _priceOracles, _monitorFeeds, _assetPricing, underlyingAsset, _isSequencerDown(), true
        );
    }

    /// @inheritdoc INAVCalculator
    /// @dev Identical to {getPriceData} but SKIPS the monitor-divergence computation (irregular/divergenceBps/
    ///      monitorFeedCount stay 0/false). For hot callers that only need the price/staleness — notably custom
    ///      feeds reading the NAV-sourced base/USD term (NavBaseUsdLib) once per position — so a base asset's
    ///      monitor reads + sort aren't paid on every derived-asset read.
    function getPriceDataNoDivergence(address underlyingAsset)
        external
        view
        returns (INAVCalculator.PriceFeedData memory priceFeedData)
    {
        _requireAssetExists(underlyingAsset);
        _requirePriceFeedExists(underlyingAsset);
        return PriceFeedLib.buildPriceData(
            _priceOracles, _monitorFeeds, _assetPricing, underlyingAsset, _isSequencerDown(), false
        );
    }

    /// @inheritdoc INAVCalculator
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
        )
    {
        _requireAssetExists(underlyingAsset);
        _requirePriceFeedExists(underlyingAsset);
        return PriceFeedLib.computeDivergence(
            _priceOracles, _monitorFeeds, _assetPricing, underlyingAsset, _isSequencerDown()
        );
    }

    /// @inheritdoc INAVCalculator
    function healthCheck()
        external
        view
        returns (bool sequencerDown, address[] memory stalePriceAssets, address[] memory irregularPriceAssets)
    {
        // Sequencer status depends on this contract's config; the per-asset staleness + divergence scan is delegated
        // to PriceFeedLib to keep NAVCalculator under EIP-170.
        return
            PriceFeedLib.healthCheck(_priceOracles, _monitorFeeds, _assetPricing, _registeredAssets, _isSequencerDown());
    }

    /// @inheritdoc INAVCalculator
    /// @dev Delegates to PriceFeedLib, which scans the same positions path used by getAccountPositions: a
    ///      reverting adapter is skipped so it cannot DoS the scan, while one that exhausts its gas stipend
    ///      reverts with `AdapterGasExhausted` rather than being counted as holding nothing.
    function hasPositions(address account) external view override returns (bool has) {
        return PriceFeedLib.hasPositions(getAllAdapters(), _metaInstanceTotal, _assetIndex, getAssetCount(), account);
    }

    /// @inheritdoc INAVCalculator
    function getAssetsWithPositions(address account) external view override returns (address[] memory) {
        return PriceFeedLib.getAssetsWithPositions(
            getAllAdapters(), _metaInstanceTotal, _assetIndex, getAssetCount(), account
        );
    }

    /// @inheritdoc INAVCalculator
    function calculateValue(address[] memory assetAddresses, uint256[] memory amounts, address quoteAsset)
        external
        view
        override
        returns (int256 value, bool quoteAssetStale)
    {
        return PriceFeedLib.calculateValue(
            _priceOracles, _assetIndex, _registeredAssets, assetAddresses, amounts, quoteAsset, _nativeTokenSymbol
        );
    }

    //
    // UUPSUpgradeable
    //

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(
        address /* newImpl */
    )
        internal
        view
        override(UUPSUpgradeable)
    {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
    }

    //
    // Internal API - Asset registry (NAV/Pricing)
    //

    /// @notice Registers an asset in the NAV/Pricing registry.
    /// Fetches decimals and symbol: for NATIVE_ADDRESS uses 18 and _nativeTokenSymbol;
    /// otherwise requires ERC20-compatible (decimals() and symbol()) and reverts if not.
    function _registerAsset(address asset) internal {
        NAVRegistryLib.registerAsset(_registeredAssets, _assetIndex, asset, _nativeTokenSymbol);
    }

    /// @notice Unregisters an asset from the NAV/Pricing registry
    function _unregisterAsset(address asset) internal {
        NAVRegistryLib.unregisterAsset(_registeredAssets, _assetIndex, asset);
    }

    /// @notice Returns the registered Asset struct from the NAV/Pricing registry (single lookup for decimals + symbol).
    function _getRegisteredAsset(address asset) internal view returns (INAVCalculator.Asset memory) {
        uint256 idx = _assetIndex[asset];
        if (idx == 0) revert AssetNotFound();
        return _registeredAssets[idx - 1];
    }

    //
    // Internal API
    //

    /// @notice Validates that the caller has the MANAGER role, reverts if not
    function _requireManager() internal view {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();
    }

    /// @notice Validates that an asset exists, reverts if not
    /// @param underlyingAsset The asset to validate
    function _requireAssetExists(address underlyingAsset) internal view {
        if (!isAssetRegistered(underlyingAsset)) {
            revert AssetNotFound();
        }
    }

    /// @notice Validates that at least one price feed exists for an asset, reverts if not
    /// @param underlyingAsset The asset to validate
    function _requirePriceFeedExists(address underlyingAsset) internal view {
        if (_priceFeedCount(underlyingAsset) == 0) {
            revert PriceFeedNotSet(underlyingAsset);
        }
    }

    /// @notice Validates quote asset (skips validation for address(0) which represents USD)
    /// @param quoteAsset The quote asset to validate
    function _validateQuoteAsset(address quoteAsset) internal view {
        if (quoteAsset != address(0)) {
            _requirePriceFeedExists(quoteAsset);
        }
    }

    /// @notice Validates asset filter (skips validation for address(0) which means all assets)
    /// @param assetFilter The asset filter to validate
    function _validateAssetFilter(address assetFilter) internal view {
        if (assetFilter != address(0)) {
            _requireAssetExists(assetFilter);
        }
    }

    /// @notice Checks if the L2 sequencer is down
    /// @dev Only checks sequencer status if on L2 (uptime feed is set). On L1, always returns false.
    /// @dev Sequencer downtime is a global issue affecting all prices, not asset-specific. It should be tracked
    /// separately from stale prices.
    /// @return sequencerDown True if the L2 sequencer is down or within grace period, false otherwise
    function _isSequencerDown() internal view returns (bool sequencerDown) {
        // Only check sequencer if on L2 (uptime feed is set)
        if (address(chainlinkL2SequencerUptimeFeed) != address(0)) {
            return checkL2SequencerUptime();
        }
        return false;
    }
}
