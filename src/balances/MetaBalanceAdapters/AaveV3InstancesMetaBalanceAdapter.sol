// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IProtocolDataProvider} from "../BalanceAdapters/SparkLendBalanceAdapter.sol";

/// @notice Minimal views to derive an instance's identity on-chain from its ProtocolDataProvider.
interface IAaveAddressesProviderSource {
    function ADDRESSES_PROVIDER() external view returns (address);
}

interface IAavePoolAddressesProvider {
    function getPool() external view returns (address);
    function getMarketId() external view returns (string memory);
}

/// @title Aave V3 Instances Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's lending positions across *any* Aave V3 instance (Core,
///         Prime, an L2 market, …). The set of instances to query is configured on NAVCalculator and passed as
///         `bytes32` coordinates — here each coordinate is the instance's **ProtocolDataProvider address** (widened
///         to bytes32). Within an instance, reserves are enumerated trustlessly via `getAllReservesTokens()`, so
///         reserve tokens are NOT separate coordinates. Emits up to two legs per reserve (Supply/Collateral +
///         Borrow), matching the per-instance `AaveV3Instance` adapter. See ADR 0010.
contract AaveV3InstancesMetaBalanceAdapter is MetaBalanceAdapter {
    bytes32 private constant PROTOCOL_ID = ProtocolIds.AAVE_V3_LENDING;

    /// @param protocolName_ Human-readable protocol name (e.g. "Aave V3").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {}

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the instance's ProtocolDataProvider. Emits up to two rows per registered reserve:
    ///      Supply/Collateral (aToken balance) and Borrow. Aave V3 deprecated NEW stable borrows but legacy stable
    ///      debt can persist, so the Borrow leg is `variableDebt + stableDebt` (dropping stable debt would understate
    ///      debt and overstate NAV). The two debt kinds are summed into ONE `Borrowed` leg rather than emitted
    ///      separately: they would otherwise share the same `(protocolId, positionId, balanceAsset, positionKind)`
    ///      key and collide, and the sum is what NAV needs anyway. Skips unregistered reserves and respects
    ///      assetFilter.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        IProtocolDataProvider dp = IProtocolDataProvider(_toAddress(instance));
        address pool = _poolOf(dp);
        // positionId is the instance Pool — one position per instance. The reserve is NOT in positionId; each
        // reserve's legs are distinguished by balanceAsset + positionKind (multi-leg convention).
        bytes memory pid = abi.encode(pool);

        IProtocolDataProvider.TokenData[] memory reserves = dp.getAllReservesTokens();
        // up to 2 legs per reserve: supply/collateral + one Borrow (variable + stable summed)
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](reserves.length * 2);
        uint256 count;

        for (uint256 i = 0; i < reserves.length; i++) {
            address asset = reserves[i].tokenAddress;
            if (assetFilter != address(0) && asset != assetFilter) continue;

            (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(asset);
            if (!found) continue;

            (uint256 aTokenBalance, uint256 stableDebt, uint256 variableDebt,,,,,, bool usageAsCollateral) =
                dp.getUserReserveData(asset, account);

            if (aTokenBalance > 0) {
                PositionKind kind = usageAsCollateral ? PositionKind.Collateral : PositionKind.Supplied;
                temp[count++] = _row(assetInfo, aTokenBalance, false, pid, kind);
            }
            // Sum variable + legacy stable debt into a single Borrowed leg. Emitting them separately would
            // produce two rows with an identical reconciliation key (same pool positionId, same reserve
            // balanceAsset, same Borrowed kind), which is not univocal.
            uint256 totalDebt = variableDebt + stableDebt;
            if (totalDebt > 0) {
                temp[count++] = _row(assetInfo, totalDebt, true, pid, PositionKind.Borrowed);
            }
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        IProtocolDataProvider.TokenData[] memory reserves =
            IProtocolDataProvider(_toAddress(instance)).getAllReservesTokens();
        assets = new address[](reserves.length);
        for (uint256 i = 0; i < reserves.length; i++) {
            assets[i] = reserves[i].tokenAddress;
        }
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["Market Instance", <market id>]` — the leaf is the instance's on-chain market id
    ///      (e.g. "Aave Ethereum Market" vs "Aave V3 Lido Ethereum"), which distinguishes instances that share
    ///      the same protocolId. positionId is the instance Pool, so the label is per-instance, not per-reserve
    ///      (the reserve token lives in `balanceAsset`). Collapses to `["Market Instance"]` if the market id is
    ///      unavailable; empty array for a short positionId.
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        if (pid.length < 32) return new string[](0);
        address pool = abi.decode(pid, (address));
        return _labels("Market Instance", _marketId(pool));
    }

    /// @notice Resolves the instance's market id (for the display label) from its pool.
    /// @dev V3 Pool exposes `ADDRESSES_PROVIDER()`.
    ///      Best-effort: returns "" if the pool/provider does not expose the views (label then drops the market).
    function _marketId(address pool) internal view returns (string memory) {
        try IAaveAddressesProviderSource(pool).ADDRESSES_PROVIDER() returns (address ap) {
            try IAavePoolAddressesProvider(ap).getMarketId() returns (string memory m) {
                return m;
            } catch {
                return "";
            }
        } catch {
            return "";
        }
    }

    /// @notice Resolves the instance's Pool address (used as first element of positionId).
    /// @dev V3's LendingPoolAddressesProvider resolves the pool via `getPool()`.
    function _poolOf(IProtocolDataProvider dp) internal view returns (address) {
        return IAavePoolAddressesProvider(IAaveAddressesProviderSource(address(dp)).ADDRESSES_PROVIDER()).getPool();
    }

    /// @notice Returns the protocol id constant for this adapter.
    function _getProtocolId() internal view returns (bytes32) {
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
            balanceAdapter: address(this),
            amount: amount,
            isDebt: isDebt,
            protocolId: _getProtocolId(),
            positionId: pid,
            positionKind: kind
        });
    }
}
