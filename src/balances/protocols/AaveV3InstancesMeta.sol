// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceOracle} from "../MetaBalanceOracle.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IProtocolDataProvider} from "./SparkLend.sol";

/// @notice Minimal views to derive an instance's identity on-chain from its ProtocolDataProvider.
interface IAaveAddressesProviderSource {
    function ADDRESSES_PROVIDER() external view returns (address);
}

interface IAavePoolAddressesProvider {
    function getPool() external view returns (address);
    function getMarketId() external view returns (string memory);
}

/// @title Aave V3 Instances Meta Balance Adapter
/// @author kpk
/// @notice One immutable adapter that reports an account's lending positions across *any* Aave V3 instance (Core,
///         Prime, an L2 market, …). The set of instances to query is configured on NAVCalculator and passed as
///         `bytes32` coordinates — here each coordinate is the instance's **ProtocolDataProvider address** (widened
///         to bytes32). Within an instance, reserves are enumerated trustlessly via `getAllReservesTokens()`, so
///         reserve tokens are NOT separate coordinates. Emits up to two legs per reserve (Supply/Collateral +
///         Borrow), matching the per-instance `AaveV3Instance` adapter. See ADR 0010.
contract AaveV3InstancesMetaBalanceAdapter is MetaBalanceOracle {
    bytes32 private constant PROTOCOL_ID = ProtocolIds.AAVE_V3_LENDING;

    /// @param protocolName_ Human-readable protocol name (e.g. "Aave V3").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocolName_, address navCalculator_) MetaBalanceOracle(protocolName_, navCalculator_) {}

    /// @inheritdoc MetaBalanceOracle
    /// @dev `instance` is the instance's ProtocolDataProvider. Emits up to two rows per registered reserve:
    ///      Supply/Collateral (aToken balance) and Borrow (variable debt). Stable debt is ignored (Aave V3
    ///      deprecated it). Skips unregistered reserves and respects assetFilter.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        IProtocolDataProvider dp = IProtocolDataProvider(_toAddress(instance));
        bytes memory pid = _instancePositionId(instance);

        IProtocolDataProvider.TokenData[] memory reserves = dp.getAllReservesTokens();
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](reserves.length * 2);
        uint256 count;

        for (uint256 i = 0; i < reserves.length; i++) {
            address asset = reserves[i].tokenAddress;
            if (assetFilter != address(0) && asset != assetFilter) continue;

            (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(asset);
            if (!found) continue;

            (uint256 aTokenBalance,, uint256 variableDebt,,,,,, bool usageAsCollateral) =
                dp.getUserReserveData(asset, account);

            if (aTokenBalance > 0) {
                PositionKind kind = usageAsCollateral ? PositionKind.Collateral : PositionKind.Supplied;
                temp[count++] = _row(assetInfo, aTokenBalance, false, pid, kind);
            }
            if (variableDebt > 0) {
                temp[count++] = _row(assetInfo, variableDebt, true, pid, PositionKind.Borrowed);
            }
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceOracle
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        IProtocolDataProvider.TokenData[] memory reserves =
            IProtocolDataProvider(_toAddress(instance)).getAllReservesTokens();
        assets = new address[](reserves.length);
        for (uint256 i = 0; i < reserves.length; i++) {
            assets[i] = reserves[i].tokenAddress;
        }
    }

    /// @inheritdoc MetaBalanceOracle
    /// @dev `virtual` so the Aave V2 subclass can override.
    function describePosition(bytes calldata pid) external view virtual override returns (string memory) {
        if (pid.length < 32) return "";
        return string.concat(_protocolName, " lending");
    }

    /// @inheritdoc MetaBalanceOracle
    function _instancePositionId(bytes32 instance) internal view override returns (bytes memory) {
        return abi.encode(_poolOf(IProtocolDataProvider(_toAddress(instance))));
    }

    /// @notice Resolves the instance's Pool address (encoded as positionId).
    /// @dev `virtual` so the Aave V2 subclass can resolve the pool via `getLendingPool()` instead of `getPool()`
    ///      (V2's LendingPoolAddressesProvider uses the former).
    function _poolOf(IProtocolDataProvider dp) internal view virtual returns (address) {
        return IAavePoolAddressesProvider(IAaveAddressesProviderSource(address(dp)).ADDRESSES_PROVIDER()).getPool();
    }

    /// @notice Returns the protocol id constant for this adapter. Virtual so subclasses can override.
    function _getProtocolId() internal view virtual returns (bytes32) {
        return PROTOCOL_ID;
    }

    /// @notice Assembles a single PositionBalance row with this adapter's identity.
    function _row(INAVCalculator.Asset memory asset, uint256 amount, bool isDebt, bytes memory pid, PositionKind kind)
        internal
        view
        returns (INAVCalculator.PositionBalance memory)
    {
        return INAVCalculator.PositionBalance({
            balanceAsset: asset,
            balanceOracle: address(this),
            amount: amount,
            isDebt: isDebt,
            protocolId: _getProtocolId(),
            positionId: pid,
            positionKind: kind
        });
    }
}
