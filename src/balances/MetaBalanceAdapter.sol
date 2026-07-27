// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalanceAdapter} from "./IBalanceAdapter.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {IMetaBalanceAdapter} from "./IMetaBalanceAdapter.sol";
import {IPositionDescribable} from "./IPositionDescribable.sol";
import {IPositionEnumerable} from "./IPositionEnumerable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {LabelLib} from "./LabelLib.sol";
import {ProtocolNames} from "src/utils/ProtocolNames.sol";
import {RegisteredAssetLib} from "./RegisteredAssetLib.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {InvalidArgumentsWithContext} from "src/errors.sol";

/// @title MetaBalanceAdapter
/// @author KPK
/// @notice Abstract base for meta balance adapters — one immutable adapter serving every instance of a
///         protocol. Concrete adapters implement the per-instance hooks (`_instancePositions`, `_instanceAssets`),
///         the identity hooks (`_protocolBrand`, `_protocolId`, `_protocolSubId`), and `positionLabels`; this base
///         provides the ERC165 wiring, the empty no-op `IBalanceAdapter` methods, the per-instance fan-out
///         with revert isolation, the shared `_leg` builder, and shared NAVCalculator registry helpers.
/// @dev The instance set lives on NAVCalculator (ADR 0010). The adapter reads its own set via
///      `NAV_CALCULATOR.getMetaInstances(address(this))` and holds no instance state or admin functions of its
///      own — it stays immutable. `getAdapterPositionsForInstances` is also exposed for explicit/off-chain queries.
abstract contract MetaBalanceAdapter is IMetaBalanceAdapter, IPositionDescribable, IPositionEnumerable {
    //
    // State
    //

    /// @notice NAVCalculator reference, used for the registered-asset registry.
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    /// @dev No `protocolName_`: the display name is derived from `_protocolId()` (see `protocolName()`), so there is
    ///      no deployment-time string to supply, mis-spell, or let drift between two adapters of one protocol.
    constructor(address navCalculator_) {
        AddressCheckLib.requireContract(navCalculator_, "NAVCalculator");
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // IERC165
    //

    /// @inheritdoc IERC165
    /// @dev `public` rather than `external` so an adapter advertising a further interface can override and
    ///      `super`-chain — Solidity cannot reach an `external` function through `super`, which would force the
    ///      override to re-declare this whole list and silently drift from it. Matches the same fix on
    ///      {BalanceAdapterBase} and the {AssistedCoordCache} precedent. {IPositionEnumerable} is in the list
    ///      because this base implements it for every meta-adapter (see `positionIds`).
    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IMetaBalanceAdapter).interfaceId || interfaceId == type(IBalanceAdapter).interfaceId
            || interfaceId == type(IPositionDescribable).interfaceId
            || interfaceId == type(IPositionEnumerable).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // IPositionEnumerable
    //

    /// @inheritdoc IPositionEnumerable
    /// @dev Implemented once here for the whole meta family: the shape set of a meta-adapter *is* its governed
    ///      instance set, which lives on the NAVCalculator (ADR 0010), so this reads
    ///      `getMetaInstances(address(this))` and maps each coordinate through {_instancePositionId}.
    ///      Adding or removing an instance is a MANAGER config TX, so this tracks configuration with no adapter
    ///      state and no admin surface — the adapter stays immutable.
    ///
    ///      **This is what makes {_instancePositionId} load-bearing.** {IPositionEnumerable} requires each
    ///      returned id to be byte-identical to the `PositionBalance.positionId` the adapter actually emits, so
    ///      every concrete adapter MUST ensure this hook agrees with what its `_instancePositions` passes to
    ///      {_leg}. An adapter that derives its positionId from something other than the raw coordinate — Aave
    ///      V3, whose coordinate is a ProtocolDataProvider but whose positionId is the Pool resolved from it —
    ///      must override the hook. See the hook's own docs.
    ///
    ///      Returns the ids in `getMetaInstances` order, but no ordering is promised and consumers must not rely
    ///      on it: this is not index-aligned with `getAdapterPositions`, which omits instances an account has no
    ///      position in and may emit several legs sharing one id. Join on the bytes.
    ///
    ///      A listed shape means the instance is configured, NOT that the account holds anything in it, nor that
    ///      the instance's assets are registered for pricing.
    ///
    ///      **Per-instance revert isolation, like every other fan-out on this base.** {IPositionEnumerable}
    ///      requires this function not to revert, and deriving a positionId is not inherently safe: the default
    ///      hook reverts on a malformed coordinate, and Aave V3's override reads the chain to resolve its Pool.
    ///      Without isolation one bad coordinate — which `addMetaInstances` does not prevent, since it never
    ///      checks the coordinate is a contract — would drop the enumeration for every OTHER instance too, and do
    ///      it silently: an adapter that reverts here is indistinguishable, through the consumer's fail-open
    ///      staticcall, from one with nothing configured. That is the exact ambiguity this interface exists to
    ///      remove. A failing instance is therefore dropped and the rest still enumerate — under-report, never
    ///      over-report, the same direction the position fan-out degrades in.
    ///
    ///      Declared `public`, not `external`, for the same reason `supportsInterface` above is: a fork adapter
    ///      that needs to extend or narrow the enumeration can then `super.positionIds()` instead of copying this
    ///      body — a copy would silently keep the old behaviour if this one changes (as it just did, gaining the
    ///      isolation), which is exactly the drift this interface exists to prevent.
    function positionIds() public view virtual override returns (bytes[] memory ids) {
        bytes32[] memory instances = NAV_CALCULATOR.getMetaInstances(address(this));
        bytes[] memory buf = new bytes[](instances.length);
        uint256 n;
        for (uint256 i; i < instances.length; ++i) {
            try this.instancePositionId(instances[i]) returns (bytes memory id) {
                buf[n++] = id;
            } catch {
                // Coordinate could not be resolved — drop this shape, keep the others.
            }
        }
        ids = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = buf[i];
        }
    }

    //
    // IPositionDescribable
    //

    /// @inheritdoc IPositionDescribable
    /// @dev Derived from the adapter's own `_protocolId()`, so "same protocolId ⇒ same protocolName" holds **by
    ///      construction** for every meta adapter: the name is a pure function of the typed identity the adapter
    ///      already declares, not a separate constructor argument that could disagree with it. This is what a
    ///      display name being a *product* name (the Aave Umbrella bug) is now structurally unable to be.
    function protocolName() external pure virtual override returns (string memory) {
        return ProtocolNames.forProtocolId(_protocolId());
    }

    /// @inheritdoc IPositionDescribable
    /// @dev Abstract — each concrete meta-adapter derives the breadcrumb from `positionId` (decode the instance
    ///      coordinate, read its on-chain name/symbol) and returns `_labels("Category", leaf)`. Display only; the
    ///      ephemeral per-item id (if any) is the typed `PositionBalance.positionInstanceId`, not a label.
    function positionLabels(bytes calldata positionId) external view virtual override returns (string[] memory);

    //
    // IBalanceAdapter
    //
    // NAVCalculator calls getAdapterPositions(account, assetFilter) on every adapter uniformly. A meta-adapter
    // services it by reading its NAV-configured instance set and fanning out — no special routing in NAV.
    // getAdapterBalances / getAdapterBalanceForAsset are not used by the NAV path and return empty.
    //

    /// @inheritdoc IBalanceAdapter
    /// @dev Reads the NAV-configured instance set for this adapter and fans out over it (ADR 0010).
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        virtual
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return _positionsForInstances(account, NAV_CALCULATOR.getMetaInstances(address(this)), assetFilter);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address)
        external
        view
        virtual
        override
        returns (address[] memory, uint256[] memory, bool[] memory)
    {
        return (new address[](0), new uint256[](0), new bool[](0));
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address, address) external view virtual override returns (uint256, bool) {
        return (0, false);
    }

    /// @inheritdoc IBalanceAdapter
    function underlyingAssetsSupported() external view virtual override returns (address[] memory) {
        return _assetsForInstances(NAV_CALCULATOR.getMetaInstances(address(this)));
    }

    //
    // IMetaBalanceAdapter
    //

    /// @inheritdoc IMetaBalanceAdapter
    function getAdapterPositionsForInstances(address account, bytes32[] calldata instances, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return _positionsForInstances(account, instances, assetFilter);
    }

    /// @inheritdoc IMetaBalanceAdapter
    function underlyingAssetsSupportedForInstances(bytes32[] calldata instances)
        external
        view
        override
        returns (address[] memory)
    {
        return _assetsForInstances(instances);
    }

    //
    // Internal fan-out
    //

    /// @notice Aggregates positions across `instances`, isolating a faulty instance so it cannot zero out the batch.
    function _positionsForInstances(address account, bytes32[] memory instances, address assetFilter)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        INAVCalculator.PositionBalance[][] memory perInstance = new INAVCalculator.PositionBalance[][](instances.length);
        uint256 total = 0;
        for (uint256 i = 0; i < instances.length; i++) {
            try this.instancePositions(account, instances[i], assetFilter) returns (
                INAVCalculator.PositionBalance[] memory p
            ) {
                perInstance[i] = p;
                total += p.length;
            } catch {
                perInstance[i] = new INAVCalculator.PositionBalance[](0);
            }
        }

        positions = new INAVCalculator.PositionBalance[](total);
        uint256 k = 0;
        for (uint256 i = 0; i < instances.length; i++) {
            for (uint256 j = 0; j < perInstance[i].length; j++) {
                positions[k++] = perInstance[i][j];
            }
        }
    }

    /// @notice Aggregates the underlying assets across `instances`.
    function _assetsForInstances(bytes32[] memory instances) internal view returns (address[] memory assets) {
        address[][] memory perInstance = new address[][](instances.length);
        uint256 total = 0;
        for (uint256 i = 0; i < instances.length; i++) {
            try this.instanceAssets(instances[i]) returns (address[] memory a) {
                perInstance[i] = a;
                total += a.length;
            } catch {
                perInstance[i] = new address[](0);
            }
        }

        assets = new address[](total);
        uint256 k = 0;
        for (uint256 i = 0; i < instances.length; i++) {
            for (uint256 j = 0; j < perInstance[i].length; j++) {
                assets[k++] = perInstance[i][j];
            }
        }
    }

    //
    // External wrappers (enable per-instance revert isolation via `this.` staticcall)
    //

    /// @notice External wrapper around the concrete per-instance position logic.
    /// @dev Called via `this.` inside `_positionsForInstances` so a single bad instance is isolated.
    function instancePositions(address account, bytes32 instance, address assetFilter)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return _instancePositions(account, instance, assetFilter);
    }

    /// @notice External wrapper around the concrete per-instance asset enumeration.
    function instanceAssets(bytes32 instance) external view returns (address[] memory) {
        return _instanceAssets(instance);
    }

    /// @notice External wrapper around the concrete per-instance positionId derivation.
    /// @dev Called via `this.` inside `positionIds` so a single bad coordinate is isolated, exactly as
    ///      `instancePositions` isolates the position fan-out. {_instancePositionId} is not inherently safe to call
    ///      in a loop: the base default reverts via `_toAddress` on a coordinate with dirty high bits, and an
    ///      override may read the chain — Aave V3's resolves the Pool through two external calls, so a codeless,
    ///      reverting or undecodable coordinate reverts here too (none of which `try`/`catch` would catch if it
    ///      were called inline).
    function instancePositionId(bytes32 instance) external view returns (bytes memory) {
        return _instancePositionId(instance);
    }

    //
    // Hooks implemented by concrete adapters
    //

    /// @notice Computes the positions for a single instance. Implementations should return an EMPTY array (not
    ///         revert) for instances whose asset is unregistered or whose balance is zero.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        virtual
        returns (INAVCalculator.PositionBalance[] memory);

    /// @notice Returns the underlying asset(s) for a single instance.
    function _instanceAssets(bytes32 instance) internal view virtual returns (address[] memory);

    //
    // Identity hooks (overridden per adapter)
    //

    /// @notice The adapter's `protocolBrand` — the version-stripped brand roll-up (e.g. `aave`). See ProtocolIds.
    function _protocolBrand() internal pure virtual returns (bytes32);

    /// @notice The adapter's `protocolId` — the ecosystem/version roll-up (e.g. `aave-v3`). See ProtocolIds.
    function _protocolId() internal pure virtual returns (bytes32);

    /// @notice The adapter's `protocolSubId` — the per-product slug; the protocol component of the stable
    ///         reconciliation key (e.g. `aave-v3-lending`). See ProtocolIds.
    function _protocolSubId() internal pure virtual returns (bytes32);

    //
    // Shared helpers
    //

    /// @notice Assembles a single `PositionBalance` with this adapter's identity (the `_protocol*` hooks +
    ///         `balanceAdapter = address(this)`), `isLocked = false`, and `positionInstanceId = bytes32(0)`.
    /// @dev The shared leg builder for every meta-adapter — each instance read calls this instead of inlining a
    ///      9-field struct literal (which also keeps per-adapter frames under the via_ir stack limit). Meta-adapter
    ///      positions are never locked and carry no ephemeral per-item id (the instance coordinate lives in
    ///      `positionId`), so those two fields are fixed here.
    function _leg(
        INAVCalculator.Asset memory asset,
        uint256 amount,
        bool isDebt,
        bytes memory positionId,
        PositionKind kind
    ) internal view returns (INAVCalculator.PositionBalance memory leg) {
        leg.balanceAsset = asset;
        leg.balanceAdapter = address(this);
        leg.amount = amount;
        leg.isDebt = isDebt;
        leg.protocolBrand = _protocolBrand();
        leg.protocolId = _protocolId();
        leg.protocolSubId = _protocolSubId();
        leg.positionId = positionId;
        leg.positionKind = kind;
        // isLocked defaults false; positionInstanceId defaults bytes32(0).
    }

    /// @notice Assembles the `[category, leaf]` label pair returned by each meta-adapter's `positionLabels`, applying
    ///         the fail-open empty-leaf convention in one place (IPositionDescribable): a leaf that could not be derived
    ///         (empty string, e.g. a reverting `name()`/`symbol()` read) is dropped so consumers never render
    ///         a blank trailing breadcrumb segment, while the known `category` is preserved. If both are empty,
    ///         returns an empty array. Mirrors `ERC20DefaultBalanceAdapter`'s single-segment collapse, generalised to
    ///         the category+leaf shape every meta-adapter uses.
    /// @dev Centralising this here keeps the convention identical across all meta-adapters instead of being
    ///      re-decided per adapter; concrete adapters derive `leaf` then `return _labels("Category", leaf);`.
    function _labels(string memory category, string memory leaf) internal pure returns (string[] memory) {
        if (bytes(leaf).length == 0) {
            if (bytes(category).length == 0) return new string[](0);
            string[] memory only = new string[](1);
            only[0] = category;
            return only;
        }
        string[] memory out = new string[](2);
        out[0] = category;
        out[1] = leaf;
        return out;
    }

    /// @notice Decodes an address-keyed bytes32 instance coordinate into an address (vault / pool / DataProvider).
    /// @dev Reverts if the high 96 bits are non-zero rather than silently truncating, so a malformed coordinate
    ///      surfaces as an error (isolated per-instance by the fan-out) instead of querying a different address.
    ///      Adapters whose coordinate is a raw bytes32 (e.g. Morpho market ids) do not use this helper.
    function _toAddress(bytes32 instance) internal pure returns (address) {
        if (uint256(instance) >> 160 != 0) revert InvalidArgumentsWithContext("instance: not an address");
        return address(uint160(uint256(instance)));
    }

    /// @notice Returns the positionId bytes for a given instance coordinate.
    /// @dev Default: encodes the instance as an address (address-keyed protocols).
    ///      Override when the coordinate is a raw bytes32 (e.g. Morpho market IDs, Balancer V2 poolIds).
    ///
    ///      **This hook must agree with what the adapter emits — it is not merely a convenience.** {positionIds}
    ///      maps the governed instance set through it to satisfy {IPositionEnumerable}'s byte-identity
    ///      guarantee, so `_instancePositionId(instance)` MUST equal the `positionId` that `_instancePositions`
    ///      passes to {_leg} for that instance. Computing the positionId inline while leaving this hook on its
    ///      default is a silent break: the enumeration would advertise ids no position ever carries and the
    ///      configuration-view join would return nothing, with every test still green.
    ///
    ///      An adapter whose positionId is derived from the coordinate rather than being it — Aave V3, whose
    ///      coordinate is a ProtocolDataProvider but whose positionId is the Pool resolved from it — therefore
    ///      overrides this hook and calls it from `_instancePositions` instead of re-deriving inline. (One
    ///      positionId per instance; reserves are distinguished by balanceAsset + positionKind.)
    function _instancePositionId(bytes32 instance) internal view virtual returns (bytes memory) {
        return abi.encode(_toAddress(instance));
    }

    /// @notice Joins the ERC20 symbols of `tokens` with "/" — e.g. `[USDC, WETH]` → `"USDC/WETH"`,
    ///         `[USDC, USDT, DAI]` → `"USDC/USDT/DAI"`.
    /// @dev Fail-open (runs in the lazy, verbose-only `positionLabels` path): a token with no code or whose
    ///      `symbol()` reverts yields `"?"` rather than reverting the whole labels read. Mirrors
    ///      `CurvePoolLib.coinSymbols`; used by the AMM-pool meta-adapters whose label leaf is the underlying
    ///      token set (Balancer V2/V3). Returns "" for an empty `tokens` array.
    function _joinTokenSymbols(address[] memory tokens) internal view returns (string memory result) {
        for (uint256 i; i < tokens.length; ++i) {
            string memory sym = LabelLib.symbol(tokens[i], "?");
            result = i == 0 ? sym : string.concat(result, "/", sym);
        }
    }

    /// @notice Looks up an asset's registry metadata.
    /// @return asset The Asset struct (zeroed if not found).
    /// @return found True if the asset is registered in NAVCalculator.
    /// @dev Each call re-fetches the full registry via `NAV_CALCULATOR.getRegisteredAssets()`, so a read that
    ///      touches N tokens does N registry fetches. Threading a single pre-fetched registry snapshot down from
    ///      `PriceFeedLib`/`NAVCalculator` through `getAdapterPositions` (a 3-arg overload carrying
    ///      `INAVCalculator.Asset[] memory registeredAssets`) to eliminate that N×M re-fetch was implemented and
    ///      then **deliberately reverted**. Reasons: (1) NAV is consumed off-chain/asynchronously (ADR 0017), so
    ///      the gas saved on the populated path has no real-world value — there is no atomic on-chain consumer
    ///      paying for it; and (2) eagerly fetching + ABI-copying the registry into every adapter call **regressed
    ///      the empty-account path** from <100k to ~166k gas (the team's `gasOptimization_emptyAccount` guard),
    ///      because adapters that early-return for empty accounts previously never fetched the registry at all.
    ///      Net: a measurable regression on the common cheap path for a saving that does not matter. See
    ///      `BALANCE_ADAPTERS.md` §"Rejected: registry fetch-once threading". Do not re-thread the registry unless
    ///      NAV becomes a synchronous on-chain consumer.
    function _getAssetInfo(address asset) internal view returns (INAVCalculator.Asset memory, bool found) {
        // Shared registry lookup (RegisteredAssetLib.find) — one find implementation across the layer.
        return RegisteredAssetLib.find(NAV_CALCULATOR.getRegisteredAssets(), asset);
    }

    /// @notice The filter-then-registry gate every per-instance read applies before emitting a leg: a token is
    ///         eligible when it matches `assetFilter` (or no filter is set) AND is registered in NAVCalculator.
    /// @dev Combines the `assetFilter` short-circuit with `_getAssetInfo` so concrete adapters write one call instead
    ///      of re-deciding the order each time. Returns a zeroed `assetInfo` when ineligible.
    function _eligible(address token, address assetFilter)
        internal
        view
        returns (INAVCalculator.Asset memory assetInfo, bool eligible)
    {
        if (assetFilter != address(0) && token != assetFilter) return (assetInfo, false);
        (assetInfo, eligible) = _getAssetInfo(token);
    }

    /// @notice Builds the `positionLabels` `[category, leaf]` for an address-keyed `positionId`, reading the
    ///         instance's on-chain `name()` (or `symbol()` when `useSymbol`) live and fail-open to "" — the
    ///         single-address label shape shared by the vault/market/lending meta-adapters (Morpho, Euler, Fluid,
    ///         Gearbox markets, Compound comets). Returns an empty array for a short/malformed positionId; the
    ///         empty-leaf collapse is handled by {_labels}.
    function _addressLabels(bytes calldata pid, string memory category, bool useSymbol)
        internal
        view
        returns (string[] memory)
    {
        if (pid.length < 32) return new string[](0);
        address addr = abi.decode(pid, (address));
        string memory leaf = useSymbol ? LabelLib.symbol(addr, "") : LabelLib.name(addr, "");
        return _labels(category, leaf);
    }
}
