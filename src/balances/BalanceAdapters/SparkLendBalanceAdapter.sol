// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterBase} from "../BalanceAdapterBase.sol";
import {IBalanceAdapter} from "../IBalanceAdapter.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {IPositionDescribable} from "../IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
import {AssetNotFound} from "src/errors.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Spark Lend Balance Adapter
/// @author KPK
/// @notice Reports per-reserve Supply/Collateral and Borrow positions for an account in Spark Lend.
///         Reads the reserve list from the Protocol Data Provider and emits up to two legs per
///         reserve (aToken balance → Supplied/Collateral, total debt → Borrowed).
///         The Borrow leg sums variable and stable debt: Aave/Spark deprecated NEW stable borrows, but
///         legacy stable debt can persist, so it is included to avoid understating debt (see `_reserveData`).
contract SparkLendBalanceAdapter is BalanceAdapterBase {
    /// @notice Aave's `ReserveConfiguration.MAX_RESERVES_COUNT` — the user-configuration bitmap packs 2 bits
    ///         per reserve into one word, so it addresses ids 0..127.
    uint256 private constant MAX_RESERVES = 128;

    IProtocolDataProvider public immutable DATA_PROVIDER;
    /// @notice Spark Pool address — used as the `positionId` (one position per instance; the reserve is not
    ///         encoded — reserves are distinguished by `balanceAsset` + `positionKind`).
    address public immutable POOL;
    INAVCalculator public immutable NAV_CALCULATOR;

    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.SPARK;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.SPARK;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.SPARK_LEND;

    constructor(address dataProvider_, address navCalculator_) {
        AddressCheckLib.requireContract(dataProvider_, "DataProvider");
        AddressCheckLib.requireContract(navCalculator_, "NAVCalculator");
        DATA_PROVIDER = IProtocolDataProvider(dataProvider_);
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
        POOL = IAavePoolAddressesProvider(IAaveAddressesProviderSource(dataProvider_).ADDRESSES_PROVIDER()).getPool();
    }

    // ─── IERC165 ─────────────────────────────────────────────────────────────

    // ─── IPositionDescribable ─────────────────────────────────────────────────

    function protocolName() external pure returns (string memory) {
        return "Spark";
    }

    function positionLabels(bytes calldata) external pure override returns (string[] memory) {
        string[] memory out = new string[](2);
        out[0] = "Market";
        out[1] = "SparkLend";
        return out;
    }

    // ─── IBalanceAdapter ────────────────────────────────────────────────

    function underlyingAssetsSupported() external view override returns (address[] memory) {
        return _reserveAddresses();
    }

    /// @notice Net supply-minus-debt per asset (for callers that want a signed scalar, not split legs).
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        returns (uint256 amount, bool isDebt)
    {
        if (asset == address(0) || !_isReserve(asset)) return (0, false);
        (uint256 supply, uint256 debt,) = _reserveData(account, asset);
        return supply >= debt ? (supply - debt, false) : (debt - supply, true);
    }

    /// @notice Net supply-minus-debt for all reserves with non-zero balance.
    function getAdapterBalances(address account)
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
            uint256 net;
            bool d;
            if (supply >= debt) {
                net = supply - debt;
            } else {
                net = debt - supply;
                d = true;
            }
            tmpA[n] = reserves[i];
            tmpV[n] = net;
            tmpD[n] = d;
            ++n;
        }
        assets = new address[](n);
        amounts = new uint256[](n);
        isDebtArr = new bool[](n);
        for (uint256 i; i < n; ++i) {
            assets[i] = tmpA[i];
            amounts[i] = tmpV[i];
            isDebtArr[i] = tmpD[i];
        }
    }

    /// @notice Separate Supply/Collateral and Borrow legs per reserve (main NAV path).
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address[] memory reserves = _reserveAddresses();
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        address[] memory regAddrs = new address[](reg.length);
        for (uint256 i; i < reg.length; ++i) {
            regAddrs[i] = reg[i].asset;
        }

        // A borrow this adapter cannot report must never leave the account's supplies standing alone: the
        // position would count as pure credit and NAV be over-reported by the whole borrow. Unregistered
        // reserves are dropped from `active` below, so without this an unregistered borrow simply vanishes.
        // Checked independently of `assetFilter` — a filtered view showing a supply while hiding an
        // unreportable borrow over-reports the same way.
        if (_hasUnreportableDebt(account, regAddrs)) return new INAVCalculator.PositionBalance[](0);

        address[] memory active = ArrayLib.intersection(reserves, regAddrs);
        if (active.length == 0) return new INAVCalculator.PositionBalance[](0);

        // Filter to single asset if requested
        if (assetFilter != address(0)) {
            bool found;
            for (uint256 i; i < active.length; ++i) {
                if (active[i] == assetFilter) {
                    found = true;
                    break;
                }
            }
            if (!found) return new INAVCalculator.PositionBalance[](0);
            active = new address[](1);
            active[0] = assetFilter;
        }

        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](active.length * 2);
        uint256 n;
        // positionId is the Spark Pool — one position per instance; reserves are distinguished by
        // balanceAsset + positionKind (the reserve is NOT in positionId).
        bytes memory pid = abi.encode(POOL);
        for (uint256 i; i < active.length; ++i) {
            address asset = active[i];
            (uint256 supply, uint256 debt, bool asCollateral) = _reserveData(account, asset);
            if (supply == 0 && debt == 0) continue;

            INAVCalculator.Asset memory meta = _assetMeta(asset, reg);

            if (supply > 0) {
                tmp[n++] = INAVCalculator.PositionBalance({
                    balanceAsset: meta,
                    balanceAdapter: address(this),
                    amount: supply,
                    isDebt: false,
                    protocolBrand: PROTOCOL_BRAND,
                    protocolId: PROTOCOL_ID,
                    protocolSubId: PROTOCOL_SUB_ID,
                    positionId: pid,
                    positionKind: asCollateral ? PositionKind.Collateral : PositionKind.Supplied,
                    isLocked: false,
                    positionInstanceId: bytes32(0)
                });
            }
            if (debt > 0) {
                tmp[n++] = INAVCalculator.PositionBalance({
                    balanceAsset: meta,
                    balanceAdapter: address(this),
                    amount: debt,
                    isDebt: true,
                    protocolBrand: PROTOCOL_BRAND,
                    protocolId: PROTOCOL_ID,
                    protocolSubId: PROTOCOL_SUB_ID,
                    positionId: pid,
                    positionKind: PositionKind.Borrowed,
                    isLocked: false,
                    positionInstanceId: bytes32(0)
                });
            }
        }

        positions = new INAVCalculator.PositionBalance[](n);
        for (uint256 i; i < n; ++i) {
            positions[i] = tmp[i];
        }
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    /// @notice True iff the account borrows any reserve whose asset is NOT registered on the NAV, i.e. a debt
    ///         this adapter would silently drop.
    /// @dev Uses Aave's user-configuration bitmap (SparkLend is an Aave V3 fork): one call identifies exactly
    ///      which reserves the account borrows, so only those are checked. Falls back to scanning every
    ///      unregistered reserve's debt if the bitmap is unavailable.
    function _hasUnreportableDebt(address account, address[] memory regAddrs) private view returns (bool) {
        // `try` does NOT catch Solidity's "call to non-contract address" check — it runs in this frame, so a
        // code-less pool would revert the whole read rather than fall back. Check explicitly first.
        if (POOL.code.length == 0) return _hasUnreportableDebtByScanSpark(account, regAddrs);

        IAavePool.UserConfigurationMap memory cfg;
        try IAavePool(POOL).getUserConfiguration(account) returns (IAavePool.UserConfigurationMap memory c) {
            cfg = c;
        } catch {
            return _hasUnreportableDebtByScanSpark(account, regAddrs);
        }
        if (cfg.data == 0) return false; // no supplies and no borrows

        // Resolve each BORROWED reserve by its stored id — see the Aave adapter for why `getReservesList()`
        // must not be indexed positionally, and why this lookup is a low-level staticcall rather than sitting
        // inside the `try` above (a revert in a success block is not caught by that statement's `catch`).
        for (uint256 id; id < MAX_RESERVES; ++id) {
            if (cfg.data & (1 << (id * 2)) == 0) continue; // not borrowing reserve `id`
            (bool ok, bytes memory ret) =
                POOL.staticcall(abi.encodeWithSelector(IAavePool.getReserveAddressById.selector, uint16(id)));
            if (!ok || ret.length < 32) return _hasUnreportableDebtByScanSpark(account, regAddrs);
            // Mask rather than `abi.decode(ret, (address))`: that reverts on a word with dirty upper bits,
            // and a revert here would escape the fallback this branch exists to reach.
            address asset = address(uint160(abi.decode(ret, (uint256))));
            if (asset == address(0)) continue; // dropped reserve
            if (_contains(regAddrs, asset)) continue; // reportable
            // Confirm real debt before suppressing — the borrowing bit can outlive the debt (see the Aave
            // adapter), and suppressing on a stale bit would erase the whole position and disagree with the
            // scan fallback, which requires debt > 0.
            (, uint256 debt,) = _reserveData(account, asset);
            if (debt > 0) return true;
        }
        return false;
    }

    /// @notice Fallback for a pool without the configuration bitmap: check every unregistered reserve for debt.
    function _hasUnreportableDebtByScanSpark(address account, address[] memory regAddrs) private view returns (bool) {
        address[] memory all = _reserveAddresses();
        for (uint256 i; i < all.length; ++i) {
            if (_contains(regAddrs, all[i])) continue; // reportable, cannot be silently dropped
            (, uint256 debt,) = _reserveData(account, all[i]);
            if (debt > 0) return true;
        }
        return false;
    }

    function _contains(address[] memory xs, address x) private pure returns (bool) {
        for (uint256 i; i < xs.length; ++i) {
            if (xs[i] == x) return true;
        }
        return false;
    }

    function _reserveAddresses() internal view returns (address[] memory addrs) {
        IProtocolDataProvider.TokenData[] memory tokens = DATA_PROVIDER.getAllReservesTokens();
        addrs = new address[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            addrs[i] = tokens[i].tokenAddress;
        }
    }

    function _isReserve(address asset) internal view returns (bool) {
        IProtocolDataProvider.TokenData[] memory tokens = DATA_PROVIDER.getAllReservesTokens();
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i].tokenAddress == asset) return true;
        }
        return false;
    }

    /// @dev `debt` is `variableDebt + stableDebt`. SparkLend is an Aave V3 fork: Aave V3 deprecated NEW stable
    ///      borrows but legacy stable debt can persist, so dropping `currentStableDebt` (the 2nd `getUserReserveData`
    ///      return) would understate the Borrow leg and overstate NAV. Mirrors `AaveV3InstancesMetaBalanceAdapter`.
    function _reserveData(address account, address asset)
        internal
        view
        returns (uint256 aTokenBalance, uint256 debt, bool asCollateral)
    {
        uint256 stableDebt;
        uint256 variableDebt;
        (aTokenBalance, stableDebt, variableDebt,,,,,, asCollateral) = DATA_PROVIDER.getUserReserveData(asset, account);
        debt = variableDebt + stableDebt;
    }

    function _assetMeta(address asset, INAVCalculator.Asset[] memory reg)
        internal
        pure
        returns (INAVCalculator.Asset memory)
    {
        (INAVCalculator.Asset memory a, bool found) = RegisteredAssetLib.find(reg, asset);
        if (!found) revert AssetNotFound();
        return a;
    }
}

// ─── Interfaces ───────────────────────────────────────────────────────────────

interface IAavePool {
    /// @notice Aave's per-user reserve bitmap: bit 2*i = borrowing reserve i, bit 2*i+1 = using it as collateral.
    struct UserConfigurationMap {
        uint256 data;
    }

    function getUserConfiguration(address user) external view returns (UserConfigurationMap memory);

    /// @notice Reserve address by its STORED id — the key the bitmap uses. `getReservesList()` is NOT
    ///         equivalent: it compacts out dropped reserves and truncates, so its indices drift from the ids.
    function getReserveAddressById(uint16 id) external view returns (address);
}

interface IProtocolDataProvider {
    struct TokenData {
        string symbol;
        address tokenAddress;
    }

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
