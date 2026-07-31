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

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title NAV Calculator
/// @notice NAV Calculator.
/// @author KPK
/// @dev EIP-170 budget: this contract runs close to the 24,576-byte runtime limit (CI's `forge build --sizes`
///      enforces it). **As of `NAV.monitorsUnhealthyPriceAssets` it is 68 bytes under** (runtime 24,508 B, measured
///      from `out/NAVCalculator.sol/NAVCalculator.json` under the default profile — the one CI's `--sizes` uses).
///      **Treat this contract as FULL.** For scale: one minimal external getter has measured at 122 B, i.e. already
///      more than the whole remaining budget, so the next addition here needs space reclaimed first rather than
///      found. (This figure was stale by 144 B for a while — it read "325 bytes under / 24,251 B", which predated
///      the paginated-NAV work; the pre-`monitorsUnhealthyPriceAssets` margin was in fact 181 B. If you cite a
///      margin, re-measure it; do not trust a number in a comment, including this one.)
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
    uint256[50] private _gap;

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
        // covered this — it does not: a high-level call to a code-less address reverts at the `extcodesize`
        // precheck, which fires in the CALLING frame before the call is made, so `catch` never sees it and the
        // revert reaches the MANAGER with empty returndata. (This is the one place a `code.length` guard is not
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
    function setPegTolerance(address asset, uint32 pegToleranceBps) external {
        _requireManager();
        _requireAssetExists(asset);
        _setPegTolerance(asset, pegToleranceBps);
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
        return _toVerbose(_computePositions(account, address(0), quoteAsset));
    }

    /// @inheritdoc INAVCalculator
    function getAccountPositionsForAssetVerbose(address account, address asset, address quoteAsset)
        external
        view
        returns (INAVCalculator.VerbosePosition[] memory)
    {
        _validateQuoteAsset(quoteAsset);
        _validateAssetFilter(asset);
        return _toVerbose(_computePositions(account, asset, quoteAsset));
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
        verboseNav.positions = _toVerbose(positions);
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

    /// @notice Enriches a Position[] with human-readable labels from IPositionDescribable on each adapter.
    function _toVerbose(INAVCalculator.Position[] memory pos)
        internal
        view
        returns (INAVCalculator.VerbosePosition[] memory verbose)
    {
        uint256 len = pos.length;
        verbose = new INAVCalculator.VerbosePosition[](len);
        // protocolName() takes no args, so its calldata is identical for every position — encode it once.
        bytes memory protocolNameCall = abi.encodeCall(IPositionDescribable.protocolName, ());
        // protocolName() returns a per-adapter constant, and positions are grouped by adapter (PriceFeedLib
        // concatenates each adapter's positions contiguously), so cache the last adapter's name and only
        // re-staticcall when the adapter changes — one protocolName() call per distinct adapter, not per position.
        // positionLabels() varies by positionId, so it stays per-position.
        address prevAdapter;
        string memory prevName;
        for (uint256 i = 0; i < len; i++) {
            address adapter = pos[i].balanceAdapter;
            if (i == 0 || adapter != prevAdapter) {
                prevName = _safeString(adapter, protocolNameCall);
                prevAdapter = adapter;
            }
            // Labels are derived lazily from positionId (display only, off the NAV hot path) via a fail-open,
            // gas-capped staticcall — an adapter that doesn't implement positionLabels yields an empty array.
            // Field-by-field assignment (not a VerbosePosition literal, which would deep-copy the 17-field Position
            // as one expression) keeps this loop under the via_ir stack limit.
            verbose[i].position = pos[i];
            verbose[i].protocolName = prevName;
            verbose[i].labels =
                _safeStringArray(adapter, abi.encodeCall(IPositionDescribable.positionLabels, (pos[i].positionId)));
        }
    }

    /// @notice Gas stipend for the `decodeStringArray` shim (see `_safeStringArray`). Generous for any legitimate
    ///         label array (a handful of short strings decode in well under this) yet small enough that a
    ///         pathological declared length OOGs within a bounded budget instead of starving the verbose read.
    uint256 private constant _LABEL_DECODE_GAS = 1_000_000;

    /// @notice Gas stipend for the outer `protocolName()` staticcall. Every `protocolName()` in this repo is a
    ///         `pure` constant string, so this is orders of magnitude more than a real one needs; it exists to
    ///         bound a broken or hostile adapter, not to fit a legitimate read.
    uint256 private constant _NAME_READ_GAS = 100_000;

    /// @notice Gas stipend for the outer `positionLabels()` staticcall. An order of magnitude above
    ///         {_NAME_READ_GAS} because a legitimate label leaf does real work: the joined multi-token leaves
    ///         (`_joinTokenSymbols` over a Balancer pool, `CurvePoolLib.coinSymbols` over an 8-coin pool) make
    ///         several `LabelLib` reads plus the pool reads that enumerate them. It is charged **per position**,
    ///         not per read path, so it is deliberately not larger: a portfolio of N positions makes N of these
    ///         calls in one frame, and the stipend times N is what a broken adapter can cost the verbose read.
    uint256 private constant _LABEL_READ_GAS = 1_000_000;

    /// @notice Bytes of `protocolName()` returndata copied into this frame: two ABI head words plus 256 bytes of
    ///         payload, matching `LabelLib`'s own metadata window. A longer name yields "".
    uint256 private constant _NAME_RETURN_BYTES = 320;

    /// @notice Bytes of `positionLabels()` returndata copied into this frame. A typical reply — a category plus a
    ///         leaf — is a few hundred bytes. The worst legitimate one is a joined multi-token leaf, whose
    ///         symbols are each capped at `LabelLib.MAX_METADATA_BYTES`; at eight tokens that is ~2.4 KB encoded,
    ///         inside this window.
    ///
    ///         **The token count is protocol-supplied, not capped, on the Balancer side.**
    ///         `CurvePoolLib.coinSymbols` stops at 8 coins, but `MetaBalanceAdapter._joinTokenSymbols` iterates
    ///         whatever the pool reports, and Balancer V2 permits up to 50 tokens. Live symbols are short, so
    ///         nothing deployed approaches this — but the honest bound is the sum of the symbol lengths, not a
    ///         token count, and a pool with many long symbols would cross it. A reply that does exceed the window
    ///         is truncated, fails to decode and yields no labels: display degrades, NAV does not move.
    uint256 private constant _LABELS_RETURN_BYTES = 4096;

    /// @notice Most elements a `positionLabels()` reply may decode to before it is rejected as implausible.
    /// @dev The output-side companion to {_LABELS_RETURN_BYTES}: see {decodeStringArray} for why bounding the
    ///      input alone does not bound what comes back. Every `positionLabels` in this repo returns a category
    ///      and at most a couple of leaves, so this is many times the real maximum while still being far below
    ///      the count an aliased-offset blob needs to be worth building.
    uint256 private constant _MAX_LABEL_ELEMENTS = 8;

    /// @notice Staticcall bounded in BOTH directions — a gas stipend on the callee and a fixed output window on
    ///         the reply — returning the success flag and the bytes actually copied.
    /// @dev Both bounds are load-bearing and neither substitutes for the other. Same shape as `LabelLib`'s
    ///      metadata reader, for the same two reasons:
    ///
    ///      - **The stipend** bounds what the callee spends. Uncapped, a callee that loops takes 63/64 of
    ///        everything this frame holds, and in `_toVerbose` that frame is the whole verbose read — so one
    ///        broken adapter costs every position's labels and, past a point, the read itself. Note also that a
    ///        raw staticcall assigning `(bool, bytes memory)` `returndatacopy`s a revert payload, which a
    ///        parameterless `catch {}` does not: on the failure path the uncapped raw form is the expensive one,
    ///        reaching ~1e9 gas against a callee that returns megabytes.
    ///      - **The output window** bounds what this frame copies, which a stipend alone does not. A ~200 KB
    ///        reply costs the callee only ~95k of memory expansion — well inside any stipend here — while the
    ///        caller pays `returndatacopy` plus its own monotonically growing memory, charged outside the stipend
    ///        and quadratic in the frame's total. `_toVerbose` reads `positionLabels` once per position in a
    ///        single frame, so that total is exactly the cost that matters: eight such replies in one verbose
    ///        read cost ~8.9M gas without the window and under 3M with it, and the gap widens with position
    ///        count. An explicit output size makes the per-read cost flat instead.
    ///
    ///      `returndatasize()` is reported untruncated, so callers bound their head validation on what was
    ///      actually copied (`ret.length`), never on what the callee claimed to send.
    /// @param target The contract to probe.
    /// @param callData The encoded call.
    /// @param gasStipend Maximum gas forwarded to `target`.
    /// @param maxReturnBytes Maximum bytes copied into this frame's memory, whatever the callee returns.
    /// @return ok The raw staticcall success flag.
    /// @return ret The copied returndata, truncated to `maxReturnBytes`.
    function _boundedRead(address target, bytes memory callData, uint256 gasStipend, uint256 maxReturnBytes)
        private
        view
        returns (bool ok, bytes memory ret)
    {
        // Discard the reply at the call (`outsize = 0`), then copy back only what is both present and wanted.
        // Allocating `maxReturnBytes` up front instead would charge this frame for the worst case on every read,
        // however small the real reply: `_toVerbose` reads once per position in a SINGLE frame, memory cost is
        // quadratic in that frame's total, and the honest path would pay it. Copying after the fact keeps the
        // ceiling while charging only the actual size.
        uint256 size;
        assembly ("memory-safe") {
            ok := staticcall(gasStipend, target, add(callData, 0x20), mload(callData), 0x00, 0x00)
            // `returndatasize()` is the untruncated size — the bound below is on what we choose to take.
            size := returndatasize()
            if gt(size, maxReturnBytes) { size := maxReturnBytes }
        }
        // A failed call's payload is discarded by both callers, so do not pay to carry it. `_toVerbose` runs this
        // once per position in a single frame and Solidity never reclaims memory, so copying revert data would
        // accumulate across the whole position list for something no one reads.
        if (!ok) return (false, ret);
        ret = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(ret, 0x20), 0x00, size)
        }
    }

    /// @notice Fully fail-open string read: staticcalls `target` and returns the decoded string only when the
    ///         returndata is a well-formed ABI string, otherwise "".
    /// @dev A plain `try/catch` only catches a reverting call — it does NOT catch a *successful* call whose
    ///      returndata cannot be decoded into `string` (e.g. a non-contract returning empty data, or a contract
    ///      returning a malformed/short blob), which would revert the whole verbose read. This validates the
    ///      ABI envelope (canonical 0x20 offset + length within bounds) before decoding so the decode itself can
    ///      never revert on bounds. (Bounds, not cost — see the inline note at the guard.)
    ///
    ///      **The bound is the RAW declared length, not `ceil32` of it.** A memory-source `abi.decode` bounds on
    ///      the declared length itself: it needs `64 + strLen <= ret.length`, and reads exactly `strLen` bytes
    ///      (under cancun, an `mcopy` of precisely that many). Verified on solc 0.8.34 / via_ir / cancun —
    ///      `offset = 0x20`, `strLen = 5`, `ret.length = 69` decodes to a 5-character name rather than reverting.
    ///      A `ceil32` bound would be *stricter* than `abi.decode`, rejecting the band
    ///      `64 + strLen <= ret.length < 64 + ceil32(strLen)` — a reply declaring a length whose payload is
    ///      delivered unpadded — and a guard stricter than the thing it protects is a silent drop, not safety.
    ///      solc and vyper always pad an encoded `string` to a word, so that band is reachable only from a
    ///      hand-rolled assembly return or a non-solc toolchain; matching `abi.decode` exactly is still the
    ///      guard worth having.
    ///
    ///      Cost is a separate concern from bounds, and is handled separately: {_boundedRead} caps both what the
    ///      target may spend ({_NAME_READ_GAS}) and what this frame copies ({_NAME_RETURN_BYTES}). The head
    ///      validation is what makes the decode total; the stipend and the output window are what make its cost
    ///      total.
    function _safeString(address target, bytes memory callData) private view returns (string memory) {
        (bool ok, bytes memory ret) = _boundedRead(target, callData, _NAME_READ_GAS, _NAME_RETURN_BYTES);
        if (!ok || ret.length < 64) return ""; // need at least offset(32) + length(32)
        uint256 offset;
        uint256 strLen;
        assembly {
            offset := mload(add(ret, 0x20))
            strLen := mload(add(ret, 0x40))
        }
        // Canonical ABI string: offset == 0x20 and the declared body fits inside the returndata. `ret.length >= 64`
        // is guaranteed by the early return above, so the subtraction cannot underflow. This is exactly the bound
        // `abi.decode` itself applies, so the decode below cannot revert on bounds.
        //
        // That is a bounds claim, not a cost one: it buys that the decode can never allocate beyond what the
        // target actually delivered, and nothing about what the target may spend or send. Cost is bounded
        // separately and unconditionally by `_boundedRead` — `ret.length` is at most {_NAME_RETURN_BYTES}
        // however large the reply was, so `strLen` is bounded by that too, and an over-long name (or a reply
        // whose payload lands outside the copied window) simply yields "".
        if (offset != 0x20 || strLen > ret.length - 64) return "";
        return abi.decode(ret, (string));
    }

    /// @notice Fail-open `string[]` read for `positionLabels`: staticcalls `target` and decodes a `string[]`,
    ///         returning an empty array on a failed/short call or any decode failure rather than reverting the
    ///         whole verbose read. A `string[]` has nested offsets/lengths that are impractical to validate
    ///         inline (as `_safeString` does for a flat string), so the possibly-reverting `abi.decode` is
    ///         isolated behind a try/catch — which needs an external call boundary (`decodeStringArray`).
    /// @dev Three bounds, one per thing an adapter can spend on this frame's behalf; none of them covers what
    ///      the other two do:
    ///      1. {_LABEL_DECODE_GAS} on the shim — returndata declaring a huge `string[]` length forces unbounded
    ///         memory expansion inside `abi.decode` and burns ~63/64 of the remaining gas before reverting. The
    ///         declared array length is independent of the returndata size, which is why `_safeString`'s head
    ///         validation has no analogue here and the decode must be isolated instead.
    ///      2. {_LABEL_READ_GAS} on the call — the shim's cap says nothing about `positionLabels` itself, which
    ///         can loop and never return.
    ///      3. {_LABELS_RETURN_BYTES} on the reply — a gas stipend alone leaves the `returndatacopy` this frame
    ///         pays unbounded; see {_boundedRead}.
    ///      Together they contain a broken adapter to its own positions' labels, which then come back `[]`.
    ///      Legitimate label arrays are far inside all three.
    function _safeStringArray(address target, bytes memory callData) private view returns (string[] memory) {
        (bool ok, bytes memory ret) = _boundedRead(target, callData, _LABEL_READ_GAS, _LABELS_RETURN_BYTES);
        if (!ok || ret.length < 64) return new string[](0); // need at least offset(32) + length(32)
        try this.decodeStringArray{gas: _LABEL_DECODE_GAS}(ret) returns (string[] memory arr) {
            return arr;
        } catch {
            return new string[](0);
        }
    }

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
