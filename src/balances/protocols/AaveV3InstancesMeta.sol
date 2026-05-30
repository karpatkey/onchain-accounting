// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceOracle} from "../MetaBalanceOracle.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PositionType} from "src/utils/PositionType.sol";
import {IProtocolDataProvider} from "./AaveV3Instance.sol";

/// @notice Minimal views to derive an instance's identity on-chain from its ProtocolDataProvider.
interface IAaveAddressesProviderSource {
    function ADDRESSES_PROVIDER() external view returns (address);
}

interface IAavePoolAddressesProvider {
    function getPool() external view returns (address);
    function getMarketId() external view returns (string memory);
}

/// @title Aave V3 Instances Meta Balance Oracle
/// @author kpk
/// @notice One immutable adapter that reports an account's lending positions across *any* Aave V3 instance (Core,
///         Prime, an L2 market, …). The set of instances to query is configured on NAVCalculator and passed as
///         `bytes32` coordinates — here each coordinate is the instance's **ProtocolDataProvider address** (widened
///         to bytes32). Within an instance, reserves are enumerated trustlessly via `getAllReservesTokens()`, so
///         reserve tokens are NOT separate coordinates. Emits up to two legs per reserve (Supply/Collateral +
///         Borrow), matching the per-instance `AaveV3Instance` adapter. See ADR 0010.
contract AaveV3InstancesMetaBalanceOracle is MetaBalanceOracle {
    using Strings for address;

    /// @param protocol_ Protocol identifier (e.g. "Aave V3").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocol_, address navCalculator_) MetaBalanceOracle(protocol_, navCalculator_) {}

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
        string memory positionId = _poolOf(dp).toHexString();
        string memory base = _detailBase(dp);

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
                string memory detail = usageAsCollateral
                    ? PositionType.withType(base, PositionType.COLLATERAL)
                    : PositionType.withType(base, PositionType.SUPPLY);
                temp[count++] = _row(assetInfo, aTokenBalance, false, positionId, detail);
            }
            if (variableDebt > 0) {
                temp[count++] =
                    _row(assetInfo, variableDebt, true, positionId, PositionType.withType(base, PositionType.BORROW));
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

    /// @notice Resolves the instance's Pool address (used as positionId — matches the per-instance adapter).
    function _poolOf(IProtocolDataProvider dp) private view returns (address) {
        return IAavePoolAddressesProvider(IAaveAddressesProviderSource(address(dp)).ADDRESSES_PROVIDER()).getPool();
    }

    /// @notice Builds the positionDetail JSON base (no closing `}`), deriving the instance name on-chain from the
    ///         PoolAddressesProvider market id, e.g. `{"protocol":"Aave V3","product":"Lending","name":"<marketId>"`.
    function _detailBase(IProtocolDataProvider dp) private view returns (string memory) {
        string memory marketId =
            IAavePoolAddressesProvider(IAaveAddressesProviderSource(address(dp)).ADDRESSES_PROVIDER()).getMarketId();
        return string.concat("{\"protocol\":\"", _protocol, "\",\"product\":\"Lending\",\"name\":\"", marketId, "\"");
    }

    /// @notice Assembles a single PositionBalance row with this adapter's identity.
    function _row(
        INAVCalculator.Asset memory asset,
        uint256 amount,
        bool isDebt,
        string memory positionId,
        string memory positionDetail
    ) private view returns (INAVCalculator.PositionBalance memory) {
        return INAVCalculator.PositionBalance({
            underlyingAsset: asset,
            balanceOracle: address(this),
            amount: amount,
            isDebt: isDebt,
            protocol: _protocol,
            positionDetail: positionDetail,
            positionId: positionId
        });
    }
}
