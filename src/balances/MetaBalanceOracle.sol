// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "./IBalanceOracleAdapter.sol";
import {IMetaBalanceOracleAdapter} from "./IMetaBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title MetaBalanceOracle
/// @author kpk
/// @notice Abstract base for meta balance oracle adapters — one immutable adapter serving every instance of a
///         protocol. Concrete adapters implement two hooks (`_instancePositions`, `_instanceAssets`); this base
///         provides the ERC165 wiring, the empty no-arg `IBalanceOracleAdapter` methods, the per-instance fan-out
///         with revert isolation, and shared NAVCalculator registry helpers.
/// @dev Instances are passed in by NAVCalculator at query time (see IMetaBalanceOracleAdapter). The adapter holds
///      no instance set and no admin functions — it stays immutable.
abstract contract MetaBalanceOracle is IMetaBalanceOracleAdapter {
    //
    // State
    //

    /// @notice Protocol identifier emitted on every PositionBalance (e.g. "Morpho"). Set once at construction.
    string internal _protocol;

    /// @notice NAVCalculator reference, used for the registered-asset registry.
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param protocol_ Protocol identifier (e.g. "Morpho").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocol_, address navCalculator_) {
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");
        _protocol = protocol_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // IERC165
    //

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure virtual override returns (bool) {
        return interfaceId == type(IMetaBalanceOracleAdapter).interfaceId
            || interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // IBalanceOracleAdapter — no-arg variants
    //
    // A meta-adapter holds no instance set locally, so the no-arg methods return empty. NAVCalculator detects the
    // meta interface at registration and always routes through the instance-aware methods below.
    //

    /// @inheritdoc IBalanceOracleAdapter
    function getOraclePositions(address, address)
        external
        view
        virtual
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return new INAVCalculator.PositionBalance[](0);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalances(address)
        external
        view
        virtual
        override
        returns (address[] memory, uint256[] memory, bool[] memory)
    {
        return (new address[](0), new uint256[](0), new bool[](0));
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address, address) external view virtual override returns (uint256, bool) {
        return (0, false);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view virtual override returns (address[] memory) {
        return new address[](0);
    }

    //
    // IMetaBalanceOracleAdapter
    //

    /// @inheritdoc IMetaBalanceOracleAdapter
    function getOraclePositionsForInstances(address account, bytes32[] calldata instances, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        // Gather per-instance results first, isolating a faulty instance so it cannot zero out the whole batch.
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

    /// @inheritdoc IMetaBalanceOracleAdapter
    function underlyingAssetsSupportedForInstances(bytes32[] calldata instances)
        external
        view
        override
        returns (address[] memory assets)
    {
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
    /// @dev Called via `this.` inside `getOraclePositionsForInstances` so a single bad instance is isolated.
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
    // Shared helpers
    //

    /// @notice Decodes a bytes32 instance coordinate into an address (vault / pool / instance address).
    function _toAddress(bytes32 instance) internal pure returns (address) {
        return address(uint160(uint256(instance)));
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
