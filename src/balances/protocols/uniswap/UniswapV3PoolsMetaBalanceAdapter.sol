// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {
    IUniswapV3Pool,
    INonfungiblePositionManager,
    UniswapV3PoolLib
} from "src/balances/protocols/uniswap/UniswapV3PoolLib.sol";
import {TickMath} from "src/balances/protocols/uniswap/lib/TickMath.sol";
import {LiquidityAmounts} from "src/balances/protocols/uniswap/lib/LiquidityAmounts.sol";
import {FixedPoint128} from "src/balances/protocols/uniswap/lib/FixedPoint128.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Uniswap V3 Pools Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's Uniswap V3 LP across *any* pool — both the in-range
///         liquidity (`Supplied`) and the unclaimed fees (`Earned`) of the account's NFT positions. The instance
///         coordinate is the pool address, widened to bytes32; the active pool set lives on NAVCalculator
///         (`addMetaInstances`/`removeMetaInstances`). The NonfungiblePositionManager is the chain-level constant pinned in the
///         constructor. Each NFT position gets its own positionId = abi.encode(npm, tokenId).
///         See ADR 0010.
/// @dev Manipulation resistance ([2]): the in-range split and the fee-growth branch are driven by a `sqrtPriceX96`
///      *reconstructed from the two tokens' registered oracle prices* (`NAV_CALCULATOR.getPriceData`), NOT the
///      pool's `slot0` spot. This makes reported amounts a pure function of the same oracles NAV prices with, so an
///      attacker who atomically moves the pool price cannot move the reported value (honors the repo's "never trust
///      an AMM spot price" rule). A position whose tokens are unregistered/unpriced/stale is dropped (returns no
///      legs) rather than valued off a manipulable spot. Because `slot0` is no longer read, byte-compatible forks
///      with a divergent `slot0()` ABI (PancakeSwap V3) need no special handling.
///      Licensing: links the GPL-2.0-or-later Uniswap math (TickMath, LiquidityAmounts, FixedPoint128) —
///      combined work is GPL-2.0-or-later (ADR 0008).
contract UniswapV3PoolsMetaBalanceAdapter is MetaBalanceAdapter {
    using Strings for uint256;

    /// @notice Protocol identifier reported on every emitted position. `virtual` so byte-compatible forks
    ///         (PancakeSwap V3) report their own slug while sharing the `(address npm, uint256 tokenId)`
    ///         positionId schema. Defaults to `uniswap-v3`.
    function _protocolId() internal pure virtual returns (bytes32) {
        return ProtocolIds.UNISWAP_V3;
    }

    /// @notice Bounded iteration limit for position discovery (matches the per-instance adapter).
    uint256 internal constant MAX_POSITIONS = 256;

    /// @notice The Uniswap V3 NonfungiblePositionManager (chain-level constant; same for all V3 pools on a chain).
    address public immutable POSITION_MANAGER;

    /// @param positionManager_ The NonfungiblePositionManager address (per-chain canonical NPM).
    /// @param protocolName_ Protocol identifier (e.g. "Uniswap V3").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address positionManager_, string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {
        require(positionManager_.code.length > 0, "PositionManager must be a contract");
        POSITION_MANAGER = positionManager_;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the pool address. For each NFT the account owns in this pool, emits up to 4 legs:
    ///      `Supplied` x2 (in-range liquidity) and `Earned` x2 (unclaimed fees) — dropping zeros and unregistered
    ///      assets, respecting `assetFilter`. Each NFT gets its own positionId = abi.encode(npm, tokenId).
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        address pool = _toAddress(instance);
        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();
        uint24 fee = IUniswapV3Pool(pool).fee();

        // Both tokens must be registered: valuing the LP split needs *both* oracle prices, regardless of which
        // leg(s) `assetFilter` ultimately emits. `assetFilter` only gates emission below (f0reg/f1reg).
        (INAVCalculator.Asset memory a0, bool reg0) = _getAssetInfo(token0);
        (INAVCalculator.Asset memory a1, bool reg1) = _getAssetInfo(token1);
        if (!reg0 || !reg1) return new INAVCalculator.PositionBalance[](0);
        bool f0reg = assetFilter == address(0) || assetFilter == token0;
        bool f1reg = assetFilter == address(0) || assetFilter == token1;
        if (!f0reg && !f1reg) return new INAVCalculator.PositionBalance[](0);

        // [2] Reconstruct the price from the registered oracles instead of reading the manipulable slot0. Drop the
        // whole instance if either feed is missing/zero/stale — an LP can't be valued manipulation-safely without
        // both fair prices (the stale asset is already surfaced in NAV.stalePriceAssets).
        INAVCalculator.PriceFeedData memory pd0 = NAV_CALCULATOR.getPriceData(token0);
        INAVCalculator.PriceFeedData memory pd1 = NAV_CALCULATOR.getPriceData(token1);
        if (pd0.price <= 0 || pd1.price <= 0 || pd0.stale || pd1.stale) {
            return new INAVCalculator.PositionBalance[](0);
        }
        uint160 sqrtPriceX96 = UniswapV3PoolLib.sqrtPriceX96FromOraclePrices(
            uint256(pd0.price), pd0.decimals, a0.decimals, uint256(pd1.price), pd1.decimals, a1.decimals
        );

        uint256 fgGlobal0 = IUniswapV3Pool(pool).feeGrowthGlobal0X128();
        uint256 fgGlobal1 = IUniswapV3Pool(pool).feeGrowthGlobal1X128();

        uint256 nftBalance = INonfungiblePositionManager(POSITION_MANAGER).balanceOf(account);
        uint256 max = nftBalance > MAX_POSITIONS ? MAX_POSITIONS : nftBalance;

        // Up to 4 legs per NFT (liq0, liq1, fee0, fee1).
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](max * 4);
        uint256 count;

        for (uint256 i = 0; i < max; i++) {
            uint256 tokenId = INonfungiblePositionManager(POSITION_MANAGER).tokenOfOwnerByIndex(account, i);

            (
                ,,
                address t0,
                address t1,
                uint24 f,
                int24 tickLower,
                int24 tickUpper,
                uint128 liquidity,
                uint256 fgInside0Last,
                uint256 fgInside1Last,
                uint128 tokensOwed0,
                uint128 tokensOwed1
            ) = INonfungiblePositionManager(POSITION_MANAGER).positions(tokenId);

            // Filter: only positions in this pool.
            if (t0 != token0 || t1 != token1 || f != fee) continue;

            // positionId is per-NFT: each tokenId is an independently managed position (its own tick
            // range and liquidity), same pattern as Aave V3/V2 per-reserve. _instancePositionId does
            // not apply here; see MetaBalanceAdapter.
            bytes memory positionId = abi.encode(POSITION_MANAGER, tokenId);

            // Tick-boundary sqrt ratios, computed once: used for the in-range split AND (via comparison against
            // the reconstructed sqrtPriceX96) the fee-growth branch — `sqrtPriceX96 < getSqrtRatioAtTick(t)` is
            // exactly equivalent to `currentTick < t`, so no reverse tick lookup is needed.
            uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
            uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);

            uint256 liq0;
            uint256 liq1;
            if (liquidity > 0) {
                (liq0, liq1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, liquidity);
            }

            (uint256 fee0, uint256 fee1) = _computeFees(
                pool,
                sqrtPriceX96,
                sqrtLower,
                sqrtUpper,
                fgGlobal0,
                fgGlobal1,
                tickLower,
                tickUpper,
                liquidity,
                fgInside0Last,
                fgInside1Last,
                tokensOwed0,
                tokensOwed1
            );

            if (f0reg && liq0 > 0) temp[count++] = _row(a0, liq0, positionId, PositionKind.Supplied);
            if (f1reg && liq1 > 0) temp[count++] = _row(a1, liq1, positionId, PositionKind.Supplied);
            if (f0reg && fee0 > 0) temp[count++] = _row(a0, fee0, positionId, PositionKind.Fees);
            if (f1reg && fee1 > 0) temp[count++] = _row(a1, fee1, positionId, PositionKind.Fees);
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        address pool = _toAddress(instance);
        assets = new address[](2);
        assets[0] = IUniswapV3Pool(pool).token0();
        assets[1] = IUniswapV3Pool(pool).token1();
    }

    /// @inheritdoc MetaBalanceAdapter
    function describePosition(bytes calldata pid) external view override returns (string memory) {
        (, uint256 tokenId) = abi.decode(pid, (address, uint256));
        return string.concat("NFT #", tokenId.toString());
    }

    function _row(INAVCalculator.Asset memory asset, uint256 amount, bytes memory positionId, PositionKind kind)
        private
        view
        returns (INAVCalculator.PositionBalance memory)
    {
        return INAVCalculator.PositionBalance({
            balanceAsset: asset,
            balanceAdapter: address(this),
            amount: amount,
            isDebt: false,
            protocolId: _protocolId(),
            positionId: positionId,
            positionKind: kind
        });
    }

    /// @notice Computes unclaimed fees for a single NFT position.
    /// @dev Subtractions intentionally wrap (`unchecked`), matching Uniswap's fee accounting (v3 whitepaper 6.3).
    ///      The below/in/above-range branch is selected by comparing the reconstructed `sqrtPriceX96` against the
    ///      range's tick-boundary sqrt ratios — `sqrtPriceX96 < getSqrtRatioAtTick(t)` is exactly equivalent to
    ///      `currentTick < t`. So, like the principal split, fee valuation is driven by the oracle-implied price,
    ///      not the manipulable slot0 tick.
    function _computeFees(
        address pool,
        uint160 sqrtPriceX96,
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint256 fgGlobal0,
        uint256 fgGlobal1,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 fgInside0Last,
        uint256 fgInside1Last,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    ) private view returns (uint256 f0, uint256 f1) {
        (uint256 fgOutLower0, uint256 fgOutLower1) = _ticksFeeGrowthOutside(pool, tickLower);
        (uint256 fgOutUpper0, uint256 fgOutUpper1) = _ticksFeeGrowthOutside(pool, tickUpper);

        unchecked {
            uint256 fgInside0;
            uint256 fgInside1;
            if (sqrtPriceX96 < sqrtLower) {
                fgInside0 = fgOutLower0 - fgOutUpper0;
                fgInside1 = fgOutLower1 - fgOutUpper1;
            } else if (sqrtPriceX96 < sqrtUpper) {
                fgInside0 = fgGlobal0 - fgOutLower0 - fgOutUpper0;
                fgInside1 = fgGlobal1 - fgOutLower1 - fgOutUpper1;
            } else {
                fgInside0 = fgOutUpper0 - fgOutLower0;
                fgInside1 = fgOutUpper1 - fgOutLower1;
            }

            f0 = Math.mulDiv(fgInside0 - fgInside0Last, liquidity, FixedPoint128.Q128) + tokensOwed0;
            f1 = Math.mulDiv(fgInside1 - fgInside1Last, liquidity, FixedPoint128.Q128) + tokensOwed1;
        }
    }

    function _ticksFeeGrowthOutside(address pool, int24 tick) private view returns (uint256 fgOut0, uint256 fgOut1) {
        (,, uint256 _fgOut0, uint256 _fgOut1,,,,) = IUniswapV3Pool(pool).ticks(tick);
        return (_fgOut0, _fgOut1);
    }
}
