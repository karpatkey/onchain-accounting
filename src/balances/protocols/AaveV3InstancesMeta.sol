// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
contract AaveV3InstancesMetaBalanceAdapter is MetaBalanceAdapter {
    bytes32 private constant PROTOCOL_ID = ProtocolIds.AAVE_V3_LENDING;

    /// @param protocolName_ Human-readable protocol name (e.g. "Aave V3").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {}

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the instance's ProtocolDataProvider. Emits up to three rows per registered reserve:
    ///      Supply/Collateral (aToken balance), variable Borrow, and stable Borrow. Aave V3 deprecated NEW stable
    ///      borrows but legacy stable debt can persist, and the Aave V2 subclass inherits this — so both the
    ///      variable and stable debt legs are emitted whenever positive (dropping stable debt understates debt and
    ///      overstates NAV). Skips unregistered reserves and respects assetFilter.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        IProtocolDataProvider dp = IProtocolDataProvider(_toAddress(instance));
        address pool = _poolOf(dp);

        IProtocolDataProvider.TokenData[] memory reserves = dp.getAllReservesTokens();
        // up to 3 legs per reserve: supply/collateral + variable debt + stable debt
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](reserves.length * 3);
        uint256 count;

        for (uint256 i = 0; i < reserves.length; i++) {
            address asset = reserves[i].tokenAddress;
            if (assetFilter != address(0) && asset != assetFilter) continue;

            (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(asset);
            if (!found) continue;

            (uint256 aTokenBalance, uint256 stableDebt, uint256 variableDebt,,,,,, bool usageAsCollateral) =
                dp.getUserReserveData(asset, account);

            // positionId is per-reserve (pool + asset); _instancePositionId does not apply.
            bytes memory pid = abi.encode(pool, asset);

            if (aTokenBalance > 0) {
                PositionKind kind = usageAsCollateral ? PositionKind.Collateral : PositionKind.Supplied;
                temp[count++] = _row(assetInfo, aTokenBalance, false, pid, kind);
            }
            if (variableDebt > 0) {
                temp[count++] = _row(assetInfo, variableDebt, true, pid, PositionKind.Borrowed);
            }
            if (stableDebt > 0) {
                temp[count++] = _row(assetInfo, stableDebt, true, pid, PositionKind.Borrowed);
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
    /// @dev Label is "<reserve symbol> position (<market id>)" — the market id (e.g. "Aave Ethereum Market" vs
    ///      "Aave V3 Lido Ethereum") distinguishes instances that share a reserve symbol, since protocolId is the
    ///      same across all instances and positionId carries the market only as the pool address. Falls back to
    ///      "<reserve symbol> position" when the market id is unavailable. `virtual` so the V2 subclass can override.
    function describePosition(bytes calldata pid) external view virtual override returns (string memory) {
        if (pid.length < 64) return "";
        (address pool, address reserve) = abi.decode(pid, (address, address));
        string memory sym;
        try IERC20Metadata(reserve).symbol() returns (string memory s) {
            sym = s;
        } catch {
            return "";
        }
        string memory market = _marketId(pool);
        return
            bytes(market).length == 0 ? string.concat(sym, " position") : string.concat(sym, " position (", market, ")");
    }

    /// @notice Resolves the instance's market id (for the display label) from its pool.
    /// @dev V3 Pool exposes `ADDRESSES_PROVIDER()`; the V2 subclass overrides to use `getAddressesProvider()`.
    ///      Best-effort: returns "" if the pool/provider does not expose the views (label then drops the market).
    function _marketId(address pool) internal view virtual returns (string memory) {
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
            balanceAdapter: address(this),
            amount: amount,
            isDebt: isDebt,
            protocolId: _getProtocolId(),
            positionId: pid,
            positionKind: kind
        });
    }
}
