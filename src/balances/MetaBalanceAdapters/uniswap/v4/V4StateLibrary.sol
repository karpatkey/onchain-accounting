// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IExtsload} from "src/balances/MetaBalanceAdapters/uniswap/v4/IUniswapV4.sol";

/// @title V4StateLibrary
/// @author KPK
/// @notice Uniswap v4-core's `StateLibrary`, trimmed to the reads a liquidity valuer needs and to a bare
///         {IExtsload} (the upstream file drags in `IPoolManager`, `PoolId`, `Position` and `Slot0` for no benefit
///         here). Slot constants and key derivations are byte-identical to upstream.
///
/// @dev **Licence.** Vendored from v4-core's MIT-licensed `src/libraries/StateLibrary.sol`, so this file keeps MIT
///      rather than this repo's default BUSL-1.1 — the same principle that keeps the vendored V3 math under its own
///      GPL-2.0-or-later (`docs/decisions/0008-uniswap-v3-math-libs-gpl-license.md`). MIT is permissive, so unlike
///      the GPL V3 math it does NOT propagate to the adapters that link it.
///
/// @dev **WHY RAW STORAGE.** V4 replaced V3's per-pool contract with one singleton holding
///      `mapping(PoolId => Pool.State) internal _pools` and exposes NO typed getters; `extsload` is the sanctioned
///      read path. `Pool.State`'s layout is therefore load-bearing:
///
///          slot +0  Slot0            sqrtPriceX96 | tick | protocolFee | lpFee   (packed, low-to-high)
///          slot +1  feeGrowthGlobal0X128
///          slot +2  feeGrowthGlobal1X128
///          slot +3  liquidity                                     (uint128)
///          slot +4  mapping(int24 => TickInfo) ticks
///          slot +5  mapping(int16 => uint256)  tickBitmap
///          slot +6  mapping(bytes32 => Position.State) positions
///
///      `TickInfo` is {liquidityGross|liquidityNet} at +0, `feeGrowthOutside0X128` at +1, `feeGrowthOutside1X128` at
///      +2. `Position.State` is {liquidity} at +0, `feeGrowthInside0LastX128` at +1, `feeGrowthInside1LastX128` at +2.
///
/// @dev **VERIFIED AGAINST LIVE 4663** (measured, PoolManager `0x8366a39C…0951`): for tokenId 3214040 in pool
///      `0x5875d407…ae36` the position slot derived here returns liquidity 653246746695797 — exactly what
///      `PositionManager.getPositionLiquidity(3214040)` reports at block 90,186,157. That equality is asserted in
///      `test/balances/MetaBalanceAdapters/fork/UniswapV4SicklePoolsMetaBalanceAdapter.fork.t.sol`, so a future
///      layout change fails loudly rather than silently mispricing.
library V4StateLibrary {
    /// @dev Storage slot of `PoolManager._pools`.
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));

    uint256 internal constant FEE_GROWTH_GLOBAL0_OFFSET = 1;
    uint256 internal constant FEE_GROWTH_GLOBAL1_OFFSET = 2;
    uint256 internal constant LIQUIDITY_OFFSET = 3;
    uint256 internal constant TICKS_OFFSET = 4;
    uint256 internal constant POSITIONS_OFFSET = 6;

    /// @dev `TickInfo.feeGrowthOutside0X128` sits one word past the tick's base slot.
    uint256 internal constant TICK_FEE_GROWTH_OFFSET = 1;

    /// @notice Everything one (pool, position) read needs, decoded.
    struct Snapshot {
        uint160 sqrtPriceX96;
        int24 tickCurrent;
        uint24 protocolFee;
        uint24 lpFee;
        uint128 liquidity;
        uint256 feeGrowthInside0X128;
        uint256 feeGrowthInside1X128;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
    }

    function poolStateSlot(bytes32 poolId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(poolId, POOLS_SLOT));
    }

    /// @dev The `ticks` mapping is keyed by `int24`, which Solidity pads to a SIGN-EXTENDED 32-byte word — hence
    ///      `int256(tick)`, not `uint24(tick)`. Robinhood's WETH-USDG V4 pool trades around tick -191000 (measured,
    ///      Oct 2026), so getting this wrong is not a theoretical concern.
    function tickBaseSlot(bytes32 stateSlot, int24 tick) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(int256(tick), bytes32(uint256(stateSlot) + TICKS_OFFSET)));
    }

    /// @dev V4-core `Position.calculatePositionKey`:
    ///      `keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt))` — 20 + 3 + 3 + 32 = 58 packed bytes. For
    ///      a PositionManager-held position `owner` is the PositionManager and `salt` is `bytes32(tokenId)`.
    function positionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
    }

    function positionStateSlot(bytes32 stateSlot, bytes32 posKey) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(posKey, bytes32(uint256(stateSlot) + POSITIONS_OFFSET)));
    }

    /// @notice Read a position's pool price and both sides of its fee accounting in one `extsload`.
    /// @dev Ten discrete slots, one call: the batched array form of `extsload` exists precisely for this.
    function snapshot(
        IExtsload poolManager,
        bytes32 poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal view returns (Snapshot memory s) {
        bytes32 stateSlot = poolStateSlot(poolId);
        bytes32 lowerSlot = tickBaseSlot(stateSlot, tickLower);
        bytes32 upperSlot = tickBaseSlot(stateSlot, tickUpper);
        bytes32 posSlot = positionStateSlot(stateSlot, positionKey(owner, tickLower, tickUpper, salt));

        bytes32[] memory slots = new bytes32[](10);
        slots[0] = stateSlot;
        slots[1] = bytes32(uint256(stateSlot) + FEE_GROWTH_GLOBAL0_OFFSET);
        slots[2] = bytes32(uint256(stateSlot) + FEE_GROWTH_GLOBAL1_OFFSET);
        slots[3] = bytes32(uint256(lowerSlot) + TICK_FEE_GROWTH_OFFSET);
        slots[4] = bytes32(uint256(lowerSlot) + TICK_FEE_GROWTH_OFFSET + 1);
        slots[5] = bytes32(uint256(upperSlot) + TICK_FEE_GROWTH_OFFSET);
        slots[6] = bytes32(uint256(upperSlot) + TICK_FEE_GROWTH_OFFSET + 1);
        slots[7] = posSlot;
        slots[8] = bytes32(uint256(posSlot) + 1);
        slots[9] = bytes32(uint256(posSlot) + 2);

        bytes32[] memory w = poolManager.extsload(slots);

        uint256 slot0 = uint256(w[0]);
        s.sqrtPriceX96 = uint160(slot0);
        // The packed fields ARE an int24/uint24 triple at known offsets; the uint24 hop carries the tick's sign bit.
        // forge-lint: disable-next-line(unsafe-typecast)
        s.tickCurrent = int24(uint24(slot0 >> 160));
        s.protocolFee = uint24(slot0 >> 184);
        s.lpFee = uint24(slot0 >> 208);
        s.liquidity = uint128(uint256(w[7]));
        s.feeGrowthInside0LastX128 = uint256(w[8]);
        s.feeGrowthInside1LastX128 = uint256(w[9]);

        // Upstream `getFeeGrowthInside`, verbatim in behaviour: wrap-around subtraction is intentional and the only
        // correct arithmetic here — fee growth is a monotonically-increasing Q128 counter read modulo 2^256.
        unchecked {
            if (s.tickCurrent < tickLower) {
                s.feeGrowthInside0X128 = uint256(w[3]) - uint256(w[5]);
                s.feeGrowthInside1X128 = uint256(w[4]) - uint256(w[6]);
            } else if (s.tickCurrent >= tickUpper) {
                s.feeGrowthInside0X128 = uint256(w[5]) - uint256(w[3]);
                s.feeGrowthInside1X128 = uint256(w[6]) - uint256(w[4]);
            } else {
                s.feeGrowthInside0X128 = uint256(w[1]) - uint256(w[3]) - uint256(w[5]);
                s.feeGrowthInside1X128 = uint256(w[2]) - uint256(w[4]) - uint256(w[6]);
            }
        }
    }
}
