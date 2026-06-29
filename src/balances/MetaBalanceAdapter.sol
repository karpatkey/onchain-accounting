// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalanceAdapter} from "./IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "./IMetaBalanceAdapter.sol";
import {IPositionDescribable} from "./IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {LabelLib} from "./LabelLib.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title MetaBalanceAdapter
/// @author KPK
/// @notice Abstract base for meta balance adapters — one immutable adapter serving every instance of a
///         protocol. Concrete adapters implement the per-instance hooks (`_instancePositions`, `_instanceAssets`),
///         the identity hooks (`_protocolBrand`, `_protocolId`, `_protocolSubId`), and `positionLabels`; this base
///         provides the ERC165 wiring, the empty no-arg `IBalanceAdapter` methods, the per-instance fan-out
///         with revert isolation, the shared `_leg` builder, and shared NAVCalculator registry helpers.
/// @dev The instance set lives on NAVCalculator (ADR 0010). The adapter reads its own set via
///      `NAV_CALCULATOR.getMetaInstances(address(this))` and holds no instance state or admin functions of its
///      own — it stays immutable. `getAdapterPositionsForInstances` is also exposed for explicit/off-chain queries.
abstract contract MetaBalanceAdapter is IMetaBalanceAdapter, IPositionDescribable {
    //
    // State
    //

    /// @notice Human-readable protocol name for IPositionDescribable (e.g. "Morpho"). Set once at construction.
    string internal _protocolName;

    /// @notice NAVCalculator reference, used for the registered-asset registry.
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param protocolName_ Human-readable protocol name for verbose reads (e.g. "Morpho").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocolName_, address navCalculator_) {
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");
        _protocolName = protocolName_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // IERC165
    //

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure virtual override returns (bool) {
        return interfaceId == type(IMetaBalanceAdapter).interfaceId || interfaceId == type(IBalanceAdapter).interfaceId
            || interfaceId == type(IPositionDescribable).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // IPositionDescribable
    //

    /// @inheritdoc IPositionDescribable
    function protocolName() external view virtual override returns (string memory) {
        return _protocolName;
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
        require(uint256(instance) >> 160 == 0, "instance: not an address");
        return address(uint160(uint256(instance)));
    }

    /// @notice Returns the positionId bytes for a given instance coordinate.
    /// @dev Default: encodes the instance as an address (address-keyed protocols).
    ///      Override when the coordinate is a raw bytes32 (e.g. Morpho market IDs, Balancer V2 poolIds).
    ///      Adapters whose positionId is not the default-encoded instance coordinate do NOT use this hook —
    ///      they compute positionId inline in _instancePositions, e.g. Aave V3: abi.encode(pool) — the instance Pool
    ///      resolved from the DataProvider coordinate (one positionId per instance; reserves are distinguished by
    ///      balanceAsset + positionKind). (Uniswap V3 / PancakeSwap V3 are no longer meta-adapters — they are
    ///      assisted adapters keyed on abi.encode(pool); see UniswapV3PoolsAssistedBalanceAdapter.)
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
    function _getAssetInfo(address asset) internal view returns (INAVCalculator.Asset memory, bool found) {
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == asset) return (reg[i], true);
        }
        return (INAVCalculator.Asset({asset: address(0), symbol: "", decimals: 0}), false);
    }
}
