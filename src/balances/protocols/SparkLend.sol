// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Spark Lend Balance Oracle
/// @author kpk
/// @notice Reports per-reserve Supply/Collateral and Borrow positions for an account in Spark Lend.
///         Reads the reserve list from the Protocol Data Provider and emits up to two legs per
///         reserve (aToken balance → Supplied/Collateral, variable debt → Borrowed).
///         Stable debt is ignored — Aave/Spark deprecated it; all active debt is variable.
contract SparkLendBalanceOracle is IBalanceOracleAdapter {
    IProtocolDataProvider public immutable DATA_PROVIDER;
    /// @notice Spark Pool address — used as the first element of `positionId`.
    address public immutable POOL;
    INAVCalculator public immutable NAV_CALCULATOR;

    constructor(address dataProvider_, address navCalculator_) {
        require(dataProvider_.code.length > 0, "DataProvider must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");
        DATA_PROVIDER = IProtocolDataProvider(dataProvider_);
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
        POOL = IAavePoolAddressesProvider(
            IAaveAddressesProviderSource(dataProvider_).ADDRESSES_PROVIDER()
        ).getPool();
    }

    // ─── IERC165 ─────────────────────────────────────────────────────────────

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ─── IPositionDescribable ─────────────────────────────────────────────────

    function protocolName() external pure returns (string memory) { return "Spark"; }
    function describePosition(bytes calldata) external pure returns (string memory) { return "lending position"; }

    // ─── IBalanceOracleAdapter ────────────────────────────────────────────────

    function underlyingAssetsSupported() external view override returns (address[] memory) {
        return _reserveAddresses();
    }

    /// @notice Net supply-minus-debt per asset (for callers that want a signed scalar, not split legs).
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        returns (uint256 amount, bool isDebt)
    {
        if (asset == address(0) || !_isReserve(asset)) return (0, false);
        (uint256 supply, uint256 debt,) = _reserveData(account, asset);
        return supply >= debt ? (supply - debt, false) : (debt - supply, true);
    }

    /// @notice Net supply-minus-debt for all reserves with non-zero balance.
    function getOracleBalances(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebtArr)
    {
        address[] memory reserves = _reserveAddresses();
        address[] memory tmpA = new address[](reserves.length);
        uint256[] memory tmpV = new uint256[](reserves.length);
        bool[] memory tmpD = new bool[](reserves.length);
        uint256 n;
        for (uint256 i; i < reserves.length; ++i) {
            (uint256 supply, uint256 debt,) = _reserveData(account, reserves[i]);
            if (supply == 0 && debt == 0) continue;
            uint256 net; bool d;
            if (supply >= debt) { net = supply - debt; } else { net = debt - supply; d = true; }
            tmpA[n] = reserves[i]; tmpV[n] = net; tmpD[n] = d; ++n;
        }
        assets = new address[](n); amounts = new uint256[](n); isDebtArr = new bool[](n);
        for (uint256 i; i < n; ++i) { assets[i] = tmpA[i]; amounts[i] = tmpV[i]; isDebtArr[i] = tmpD[i]; }
    }

    /// @notice Separate Supply/Collateral and Borrow legs per reserve (main NAV path).
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address[] memory reserves = _reserveAddresses();
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        address[] memory regAddrs = new address[](reg.length);
        for (uint256 i; i < reg.length; ++i) regAddrs[i] = reg[i].asset;

        address[] memory active = ArrayLib.intersection(reserves, regAddrs);
        if (active.length == 0) return new INAVCalculator.PositionBalance[](0);

        // Filter to single asset if requested
        if (assetFilter != address(0)) {
            bool found;
            for (uint256 i; i < active.length; ++i) {
                if (active[i] == assetFilter) { found = true; break; }
            }
            if (!found) return new INAVCalculator.PositionBalance[](0);
            active = new address[](1);
            active[0] = assetFilter;
        }

        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](active.length * 2);
        uint256 n;
        for (uint256 i; i < active.length; ++i) {
            address asset = active[i];
            (uint256 supply, uint256 debt, bool asCollateral) = _reserveData(account, asset);
            if (supply == 0 && debt == 0) continue;

            INAVCalculator.Asset memory meta = _assetMeta(asset, reg);
            bytes memory pid = abi.encode(POOL, asset);

            if (supply > 0) {
                tmp[n++] = INAVCalculator.PositionBalance({
                    balanceAsset: meta,
                    balanceOracle: address(this),
                    amount: supply,
                    isDebt: false,
                    protocolId: ProtocolIds.SPARK_LEND,
                    positionId: pid,
                    positionKind: asCollateral ? PositionKind.Collateral : PositionKind.Supplied
                });
            }
            if (debt > 0) {
                tmp[n++] = INAVCalculator.PositionBalance({
                    balanceAsset: meta,
                    balanceOracle: address(this),
                    amount: debt,
                    isDebt: true,
                    protocolId: ProtocolIds.SPARK_LEND,
                    positionId: pid,
                    positionKind: PositionKind.Borrowed
                });
            }
        }

        positions = new INAVCalculator.PositionBalance[](n);
        for (uint256 i; i < n; ++i) positions[i] = tmp[i];
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    function _reserveAddresses() internal view returns (address[] memory addrs) {
        IProtocolDataProvider.TokenData[] memory tokens = DATA_PROVIDER.getAllReservesTokens();
        addrs = new address[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) addrs[i] = tokens[i].tokenAddress;
    }

    function _isReserve(address asset) internal view returns (bool) {
        IProtocolDataProvider.TokenData[] memory tokens = DATA_PROVIDER.getAllReservesTokens();
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i].tokenAddress == asset) return true;
        }
        return false;
    }

    function _reserveData(address account, address asset)
        internal
        view
        returns (uint256 aTokenBalance, uint256 variableDebt, bool asCollateral)
    {
        (aTokenBalance,, variableDebt,,,,,, asCollateral) = DATA_PROVIDER.getUserReserveData(asset, account);
    }

    function _assetMeta(address asset, INAVCalculator.Asset[] memory reg)
        internal
        pure
        returns (INAVCalculator.Asset memory)
    {
        for (uint256 i; i < reg.length; ++i) {
            if (reg[i].asset == asset) return reg[i];
        }
        revert("asset not registered");
    }
}

// ─── Interfaces ───────────────────────────────────────────────────────────────

interface IProtocolDataProvider {
    struct TokenData { string symbol; address tokenAddress; }

    function getAllReservesTokens() external view returns (TokenData[] memory);
    function getUserReserveData(address asset, address user)
        external
        view
        returns (
            uint256 currentATokenBalance,
            uint256 currentStableDebt,
            uint256 currentVariableDebt,
            uint256 principalStableDebt,
            uint256 scaledVariableDebt,
            uint256 stableBorrowRate,
            uint256 liquidityRate,
            uint40 stableRateLastUpdated,
            bool usageAsCollateralEnabled
        );
}

interface IAaveAddressesProviderSource {
    function ADDRESSES_PROVIDER() external view returns (address);
}

interface IAavePoolAddressesProvider {
    function getPool() external view returns (address);
}
