// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
import {InvalidArguments} from "src/errors.sol";
import {PositionType} from "src/utils/PositionType.sol";

/// @title Uniswap V2 Balance Oracle
/// @author kpk
/// @notice Returns an LP holder's pro-rata share of both token0 and token1 reserves for a Uniswap V2 pair.
///         One adapter instance per pair (token0/token1 derived from `pair` at construction).
///
/// @dev V2 fee semantics:
///      - Swap fees auto-compound into reserves; there is no separately claimable per-position fee.
///      - When `factory.feeTo()` is non-zero, every `mint`/`burn` first pre-mints new LP to `feeTo`
///        equal to ≈1/6 of the √k growth since the last `mint`/`burn` (formula in `_pendingProtocolMint`).
///        That pending mint is *not yet* in `totalSupply`, so a naive `balance × reserve / totalSupply`
///        slightly over-states an LP's redemption value.
///      - This adapter therefore returns the dilution-adjusted share:
///          amount = balance × reserve / (totalSupply + pendingProtocolMint)
///        which mirrors what an LP would actually receive on `burn`.
///
/// @dev Compatibility: works with the canonical Uniswap V2 ABI and standard forks (e.g. SushiSwap)
///      that preserve the `_mintFee` formula. Forks with custom fee math are out of scope.
contract UniswapV2BalanceOracle is IBalanceOracleAdapter {
    //
    // Type Definitions
    //

    struct AssetBalanceData {
        address asset;
        uint256 amount;
        bool isDebt;
    }

    //
    // State (all immutable after construction)
    //

    /// @notice The Uniswap V2 pair this adapter wraps.
    address public immutable PAIR;

    /// @notice token0 of the pair, cached at construction.
    address public immutable TOKEN0;

    /// @notice token1 of the pair, cached at construction.
    address public immutable TOKEN1;

    /// @notice The V2 factory the pair belongs to (used for `feeTo()` lookups).
    address public immutable FACTORY;

    /// @notice Reference to NAVCalculator for asset registry access.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Protocol identifier for this oracle (e.g. "Uniswap V2").
    string private _protocol;

    /// @notice JSON metadata base (no closing `}`) for this oracle.
    string private _positionDetail;

    /// @notice Stable hex identifier for this adapter instance (pair address).
    string private _positionId;

    //
    // Constructor
    //

    /// @param pair_ The Uniswap V2 pair contract address.
    /// @param protocol_ Protocol identifier (e.g. "Uniswap V2").
    /// @param positionDetail_ JSON metadata base without closing `}`.
    /// @param positionId_ Stable hex identifier for this adapter instance (pair address).
    /// @param navCalculator_ The NAVCalculator contract address.
    constructor(
        address pair_,
        string memory protocol_,
        string memory positionDetail_,
        string memory positionId_,
        address navCalculator_
    ) {
        if (pair_ == address(0)) revert InvalidArguments();
        require(pair_.code.length > 0, "Pair must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        PAIR = pair_;
        TOKEN0 = IUniswapV2Pair(pair_).token0();
        TOKEN1 = IUniswapV2Pair(pair_).token1();
        FACTORY = IUniswapV2Pair(pair_).factory();
        require(TOKEN0 != address(0) && TOKEN1 != address(0), "Pair tokens must be non-zero");
        require(TOKEN0 != TOKEN1, "Pair tokens must differ");

        _protocol = protocol_;
        _positionDetail = positionDetail_;
        _positionId = positionId_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // IERC165
    //

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // IBalanceOracleAdapter
    //

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        return _supportedAssets();
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (account == address(0) || asset == address(0)) return (0, false);
        if (asset != TOKEN0 && asset != TOKEN1) return (0, false);
        return (_calculateBalance(account, asset), false);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        if (account == address(0)) {
            return (new address[](0), new uint256[](0), new bool[](0));
        }

        address[] memory supported = _supportedAssets();
        AssetBalanceData[] memory tempData = new AssetBalanceData[](supported.length);
        uint256 count = 0;

        for (uint256 i = 0; i < supported.length; i++) {
            uint256 balance = _calculateBalance(account, supported[i]);
            if (balance > 0) {
                tempData[count] = AssetBalanceData({asset: supported[i], amount: balance, isDebt: false});
                count++;
            }
        }

        assets = new address[](count);
        amounts = new uint256[](count);
        isDebt = new bool[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = tempData[i].asset;
            amounts[i] = tempData[i].amount;
            isDebt[i] = tempData[i].isDebt;
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @dev Filters reported assets to those registered in the NAVCalculator's asset registry,
    ///      mirroring the pattern used by `CurveBalanceOracle`.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        address[] memory supported = _supportedAssets();
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        address[] memory registeredAssets = new address[](reg.length);
        for (uint256 i = 0; i < reg.length; i++) {
            registeredAssets[i] = reg[i].asset;
        }

        address[] memory eligibleAssets = ArrayLib.intersection(supported, registeredAssets);
        if (eligibleAssets.length == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Apply asset filter
        if (assetFilter != address(0)) {
            bool filterFound = false;
            for (uint256 i = 0; i < eligibleAssets.length; i++) {
                if (eligibleAssets[i] == assetFilter) {
                    filterFound = true;
                    break;
                }
            }
            if (!filterFound) return new INAVCalculator.PositionBalance[](0);

            uint256 balance = _calculateBalance(account, assetFilter);
            if (balance == 0) return new INAVCalculator.PositionBalance[](0);

            positions = new INAVCalculator.PositionBalance[](1);
            positions[0] = INAVCalculator.PositionBalance({
                underlyingAsset: _getAssetInfo(assetFilter),
                balanceOracle: address(this),
                amount: balance,
                isDebt: false,
                protocol: _protocol,
                positionDetail: PositionType.withType(_positionDetail, PositionType.SUPPLY),
                positionId: _positionId
            });
            return positions;
        }

        // No filter — return all eligible assets with non-zero balance
        INAVCalculator.PositionBalance[] memory tempPositions =
            new INAVCalculator.PositionBalance[](eligibleAssets.length);
        uint256 count = 0;

        for (uint256 i = 0; i < eligibleAssets.length; i++) {
            uint256 balance = _calculateBalance(account, eligibleAssets[i]);
            if (balance > 0) {
                tempPositions[count] = INAVCalculator.PositionBalance({
                    underlyingAsset: _getAssetInfo(eligibleAssets[i]),
                    balanceOracle: address(this),
                    amount: balance,
                    isDebt: false,
                    protocol: _protocol,
                    positionDetail: PositionType.withType(_positionDetail, PositionType.SUPPLY),
                    positionId: _positionId
                });
                count++;
            }
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = tempPositions[i];
        }
    }

    //
    // Internal helpers
    //

    /// @notice Returns `[TOKEN0, TOKEN1]`.
    /// @dev Constructor enforces that `TOKEN0 != TOKEN1` and both are non-zero, so no dedup needed.
    function _supportedAssets() internal view returns (address[] memory result) {
        result = new address[](2);
        result[0] = TOKEN0;
        result[1] = TOKEN1;
    }

    /// @notice Computes the LP holder's pro-rata share of `asset`'s reserve, adjusted for the
    ///         pending protocol-fee mint that would dilute holders on the next mint/burn.
    function _calculateBalance(address account, address asset) internal view returns (uint256) {
        if (asset != TOKEN0 && asset != TOKEN1) return 0;

        uint256 balance = IUniswapV2Pair(PAIR).balanceOf(account);
        if (balance == 0) return 0;

        uint256 totalSupply = IUniswapV2Pair(PAIR).totalSupply();
        if (totalSupply == 0) return 0;

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(PAIR).getReserves();
        uint256 reserve = asset == TOKEN0 ? uint256(reserve0) : uint256(reserve1);
        if (reserve == 0) return 0;

        uint256 effectiveSupply = totalSupply + _pendingProtocolMint(reserve0, reserve1, totalSupply);
        return (balance * reserve) / effectiveSupply;
    }

    /// @notice Computes the LP that the V2 pair would mint to `feeTo` on the next mint/burn,
    ///         per Uniswap V2's internal `_mintFee` formula:
    ///             liquidity = ts·(√k − √kLast) / (5·√k + √kLast)
    ///         Returns 0 when `feeTo` is unset, when `kLast == 0` (matches the contract's
    ///         early-out), or when `√k <= √kLast` (no growth → no fee).
    /// @dev `feeTo()` and `kLast()` are read defensively via staticcall: V2 forks that omit
    ///      either getter are treated as "no protocol fee", which is the safe default.
    function _pendingProtocolMint(uint112 reserve0, uint112 reserve1, uint256 totalSupply)
        internal
        view
        returns (uint256)
    {
        (bool feeToOk, address feeTo) = _safeCallAddress(FACTORY, abi.encodeCall(IUniswapV2Factory.feeTo, ()));
        if (!feeToOk || feeTo == address(0)) return 0;

        (bool kLastOk, uint256 kLast) = _safeCallUint(PAIR, abi.encodeCall(IUniswapV2Pair.kLast, ()));
        if (!kLastOk || kLast == 0) return 0;

        uint256 rootK = Math.sqrt(uint256(reserve0) * uint256(reserve1));
        uint256 rootKLast = Math.sqrt(kLast);
        if (rootK <= rootKLast) return 0;

        uint256 numerator = totalSupply * (rootK - rootKLast);
        uint256 denominator = rootK * 5 + rootKLast;
        return numerator / denominator;
    }

    /// @notice Looks up asset metadata from the NAVCalculator registry.
    function _getAssetInfo(address asset) internal view returns (INAVCalculator.Asset memory) {
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == asset) return reg[i];
        }
        revert("Asset not found in NAVCalculator");
    }

    /// @notice Safely staticcalls a function returning uint256.
    function _safeCallUint(address target, bytes memory data) internal view returns (bool success, uint256 result) {
        bytes memory returnData;
        (success, returnData) = target.staticcall(data);
        if (success && returnData.length >= 32) {
            result = abi.decode(returnData, (uint256));
        }
    }

    /// @notice Safely staticcalls a function returning address.
    function _safeCallAddress(address target, bytes memory data) internal view returns (bool success, address result) {
        bytes memory returnData;
        (success, returnData) = target.staticcall(data);
        if (success && returnData.length >= 32) {
            result = abi.decode(returnData, (address));
        }
    }
}

// ---------------------------
// Interface Section
// ---------------------------

/// @notice Minimal Uniswap V2 pair interface.
interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function kLast() external view returns (uint256);
}

/// @notice Minimal Uniswap V2 factory interface.
interface IUniswapV2Factory {
    function feeTo() external view returns (address);
}
