// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IUniswapV3Pool, INonfungiblePositionManager} from "src/balances/protocols/uniswap/UniswapV3PoolLib.sol";
import {TickMath} from "src/balances/protocols/uniswap/lib/TickMath.sol";
import {LiquidityAmounts} from "src/balances/protocols/uniswap/lib/LiquidityAmounts.sol";
import {FixedPoint128} from "src/balances/protocols/uniswap/lib/FixedPoint128.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Uniswap V3 Pools Meta Balance Adapter
/// @author kpk
/// @notice One immutable adapter that reports an account's Uniswap V3 LP across *any* pool — both the in-range
///         liquidity (`Supplied`) and the unclaimed fees (`Earned`) of the account's NFT positions. The instance
///         coordinate is the pool address, widened to bytes32; the active pool set lives on NAVCalculator
///         (`addMetaInstances`/`removeMetaInstances`). The NonfungiblePositionManager is the chain-level constant pinned in the
///         constructor. Each NFT position gets its own positionId = abi.encode(npm, tokenId).
///         See ADR 0010.
/// @dev `slot0` is read via the `_slot0` virtual hook so forks with a divergent `slot0()` ABI (PancakeSwap V3)
///      override just that read.
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

        (INAVCalculator.Asset memory a0, bool f0reg) = _eligible(token0, assetFilter);
        (INAVCalculator.Asset memory a1, bool f1reg) = _eligible(token1, assetFilter);
        if (!f0reg && !f1reg) return new INAVCalculator.PositionBalance[](0);

        (uint160 sqrtPriceX96, int24 tick) = _slot0(pool);
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

            uint256 liq0;
            uint256 liq1;
            if (liquidity > 0) {
                (liq0, liq1) = LiquidityAmounts.getAmountsForLiquidity(
                    sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(tickLower),
                    TickMath.getSqrtRatioAtTick(tickUpper),
                    liquidity
                );
            }

            (uint256 fee0, uint256 fee1) = _computeFees(
                pool,
                tick,
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

    /// @notice Reads `(sqrtPriceX96, tick)` from the pool's `slot0`.
    /// @dev `virtual` so a fork with a divergent `slot0()` ABI overrides this single read. The first override is
    ///      `PancakeSwapV3PoolsMetaBalanceAdapter` (PancakeSwap V3's `slot0().feeProtocol` is `uint32`, not `uint8`).
    function _slot0(address pool) internal view virtual returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    /// @notice Returns `(assetInfo, eligible)` where eligible == registered AND passes `assetFilter`.
    function _eligible(address token, address assetFilter)
        private
        view
        returns (INAVCalculator.Asset memory assetInfo, bool eligible)
    {
        if (assetFilter != address(0) && token != assetFilter) return (assetInfo, false);
        (assetInfo, eligible) = _getAssetInfo(token);
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
    function _computeFees(
        address pool,
        int24 tickCurrent,
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
            if (tickCurrent < tickLower) {
                fgInside0 = fgOutLower0 - fgOutUpper0;
                fgInside1 = fgOutLower1 - fgOutUpper1;
            } else if (tickCurrent < tickUpper) {
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
