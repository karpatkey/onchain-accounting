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
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolLib.sol";
import {TickMath} from "src/balances/MetaBalanceAdapters/uniswap/lib/TickMath.sol";
import {LiquidityAmounts} from "src/balances/MetaBalanceAdapters/uniswap/lib/LiquidityAmounts.sol";

/// @title Uniswap V3 Pools Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's Uniswap V3 LP across *any* pool — both the in-range
///         liquidity (`Supplied`) and the settled `tokensOwed` fees (`Fees`) of the account's NFT positions. The instance
///         coordinate is the pool address, widened to bytes32; the active pool set lives on NAVCalculator
///         (`addMetaInstances`/`removeMetaInstances`). The NonfungiblePositionManager is the chain-level constant pinned in the
///         constructor. Each NFT position gets its own positionId = abi.encode(npm, tokenId).
///         See ADR 0010.
/// @dev Manipulation resistance ([2]): the in-range split is driven by a `sqrtPriceX96`
///      *reconstructed from the two tokens' registered oracle prices* (`NAV_CALCULATOR.getPriceData`), NOT the
///      pool's `slot0` spot. This makes reported amounts a pure function of the same oracles NAV prices with, so an
///      attacker who atomically moves the pool price cannot move the reported value (honors the repo's "never trust
///      an AMM spot price" rule). A position whose tokens are unregistered/unpriced/stale is dropped (returns no
///      legs) rather than valued off a manipulable spot. Because `slot0` is no longer read, byte-compatible forks
///      with a divergent `slot0()` ABI (PancakeSwap V3) need no special handling.
/// @dev Fees ([M-A1]): only the position's settled `tokensOwed` are reported. The uncollected-since-poke component
///      derives from `feeGrowthInside`, which is correct only relative to the pool's REAL tick; deriving it from the
///      oracle-reconstructed tick can pick a branch inconsistent with the on-chain `feeGrowthOutside` anchoring and
///      over-report a phantom fee. Since this adapter intentionally avoids `slot0`, that component is omitted — a
///      conservative under-report that upholds the assisted family's never-over-report invariant. See
///      docs/audits/2026-06-vigilo-adapter-audit.md §M-A1.
///      Licensing: links the GPL-2.0-or-later Uniswap math (TickMath, LiquidityAmounts) —
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
                uint128 liquidity,,,
                uint128 tokensOwed0,
                uint128 tokensOwed1
            ) = INonfungiblePositionManager(POSITION_MANAGER).positions(tokenId);

            // Filter: only positions in this pool.
            if (t0 != token0 || t1 != token1 || f != fee) continue;

            // positionId is per-NFT: each tokenId is an independently managed position (its own tick
            // range and liquidity), same pattern as Aave V3/V2 per-reserve. _instancePositionId does
            // not apply here; see MetaBalanceAdapter.
            bytes memory positionId = abi.encode(POSITION_MANAGER, tokenId);

            // Principal split: tick-boundary sqrt ratios for the in-range amount calc, valued off the
            // oracle-reconstructed sqrtPriceX96 (not the manipulable slot0; `sqrtPriceX96 < getSqrtRatioAtTick(t)`
            // is exactly equivalent to `currentTick < t`).
            uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
            uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);

            uint256 liq0;
            uint256 liq1;
            if (liquidity > 0) {
                (liq0, liq1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, liquidity);
            }

            // Fees: report only the position's settled `tokensOwed` (fees credited at the last mint/collect/burn
            // poke). The uncollected-since-poke component is deliberately NOT computed — it derives from
            // `feeGrowthInside`, which is correct only relative to the pool's REAL tick, while this adapter
            // intentionally avoids `slot0` (manipulation resistance + PancakeSwap V3 ABI compatibility). Deriving
            // it from the oracle tick can select a `feeGrowthInside` branch inconsistent with the on-chain
            // `feeGrowthOutside` anchoring and over-report a phantom fee, so it is omitted — a conservative
            // under-report that upholds the never-over-report invariant (audit M-A1).
            if (f0reg && liq0 > 0) temp[count++] = _row(a0, liq0, positionId, PositionKind.Supplied);
            if (f1reg && liq1 > 0) temp[count++] = _row(a1, liq1, positionId, PositionKind.Supplied);
            if (f0reg && tokensOwed0 > 0) temp[count++] = _row(a0, tokensOwed0, positionId, PositionKind.Fees);
            if (f1reg && tokensOwed1 > 0) temp[count++] = _row(a1, tokensOwed1, positionId, PositionKind.Fees);
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
    /// @dev Returns `["Liquidity Pool", "NFT #<tokenId>"]`.
    function positionLabels(bytes calldata pid) external view virtual override returns (string[] memory) {
        if (pid.length < 64) return new string[](0); // fail-open on malformed positionId (decodes (address, uint256))
        (, uint256 tokenId) = abi.decode(pid, (address, uint256));
        string memory leaf = string.concat("NFT #", tokenId.toString());
        return _labels("Liquidity Pool", leaf);
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
}
