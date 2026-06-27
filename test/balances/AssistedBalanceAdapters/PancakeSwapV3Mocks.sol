// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @notice Minimal PancakeSwap V3 pool mock — identical to the Uniswap V3 pool mock except `slot0()` returns
///         `feeProtocol` as `uint32` set to a value > 255 (the real PancakeSwap layout: e.g. the mainnet 0.05%
///         tier is 222825800). A consumer that decodes `feeProtocol` as `uint8` (the inherited Uniswap path)
///         reverts on Solidity 0.8's strict ABI decode once the high bits are set; the
///         `PancakeSwapV3PoolsMeta._slot0` override decodes it as `uint32`. This divergence is what the unit test
///         exercises. Reuses `MockPositionManager` / `MockToken` from `../uniswap/UniswapV3Mocks.sol`.
contract MockPancakeV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;
    uint160 internal _sqrtPriceX96;
    int24 internal _tick;
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    /// @dev PancakeSwap mainnet 0.05%-tier value; > uint8 max (255), so a uint8 `slot0` decode reverts.
    uint32 public constant FEE_PROTOCOL = 222825800;

    struct TickInfo {
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
    }

    mapping(int24 => TickInfo) internal _ticks;

    constructor(address token0_, address token1_, uint24 fee_, int24 tickSpacing_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        tickSpacing = tickSpacing_;
    }

    function setSlot0(uint160 sqrtPriceX96_, int24 tick_) external {
        _sqrtPriceX96 = sqrtPriceX96_;
        _tick = tick_;
    }

    function setFeeGrowthGlobal(uint256 fg0, uint256 fg1) external {
        feeGrowthGlobal0X128 = fg0;
        feeGrowthGlobal1X128 = fg1;
    }

    function setTickFeeGrowth(int24 tick, uint256 fgOut0, uint256 fgOut1) external {
        _ticks[tick] = TickInfo(fgOut0, fgOut1);
    }

    /// @dev `feeProtocol` is `uint32` (PancakeSwap), set > 255 so a `uint8` decode reverts.
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (_sqrtPriceX96, _tick, 0, 0, 0, FEE_PROTOCOL, false);
    }

    function ticks(int24 tick) external view returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool) {
        TickInfo memory info = _ticks[tick];
        return (0, 0, info.feeGrowthOutside0X128, info.feeGrowthOutside1X128, 0, 0, 0, false);
    }
}
