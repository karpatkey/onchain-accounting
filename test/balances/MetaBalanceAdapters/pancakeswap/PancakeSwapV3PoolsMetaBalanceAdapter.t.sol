// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {
    PancakeSwapV3PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/pancakeswap/PancakeSwapV3PoolsMetaBalanceAdapter.sol";
import {
    UniswapV3PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolsMetaBalanceAdapter.sol";
import {TickMath} from "src/balances/MetaBalanceAdapters/uniswap/lib/TickMath.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {
    MockPancakeV3Pool,
    MockPositionManager,
    MockToken
} from "test/balances/MetaBalanceAdapters/uniswap/UniswapV3Mocks.sol";

/// @title PancakeSwapV3PoolsMetaBalanceAdapter unit tests (no fork)
/// @notice PancakeSwap V3 is a thin subclass of {UniswapV3PoolsMetaBalanceAdapter}; the framework/valuation matrix is
///         covered by the Uniswap suite. This suite pins the two things the subclass changes: the PancakeSwap
///         identity slugs, and the `_slot0` override that decodes PancakeSwap V3's `uint32 feeProtocol` ABI (the
///         inherited Uniswap `uint8` decode would revert on the wider field).
contract PancakeSwapV3PoolsMetaBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    MockPositionManager npm;
    PancakeSwapV3PoolsMetaBalanceAdapter meta;

    MockToken usdc;
    MockToken weth;
    MockPancakeV3Pool pool; // USDC/WETH 0.05%

    address alice = makeAddr("alice");

    // A feeProtocol value that does NOT fit in Uniswap's uint8 — decoding this slot0 tuple with the base's uint8 ABI
    // would revert on the dirty high bits; PancakeSwap's uint32 override must decode it cleanly.
    uint32 constant WIDE_FEE_PROTOCOL = uint32(type(uint8).max) + 1;

    function setUp() public {
        nav = new Mock_NAVCalculator();
        npm = new MockPositionManager();
        usdc = new MockToken("USDC", 6);
        weth = new MockToken("WETH", 18);
        nav.registerAsset(address(usdc), 6, "USDC");
        nav.registerAsset(address(weth), 18, "WETH");

        pool = new MockPancakeV3Pool(address(usdc), address(weth), 500, 10);
        pool.setSlot0(TickMath.getSqrtRatioAtTick(0), 0, WIDE_FEE_PROTOCOL);

        npm.mint(
            alice,
            1,
            MockPositionManager.PositionData({
                token0: address(usdc),
                token1: address(weth),
                fee: 500,
                tickLower: -100,
                tickUpper: 100,
                liquidity: 1_000_000,
                feeGrowthInside0LastX128: 0,
                feeGrowthInside1LastX128: 0,
                tokensOwed0: 7,
                tokensOwed1: 99
            })
        );

        meta = new PancakeSwapV3PoolsMetaBalanceAdapter(address(npm), address(nav));
    }

    function _instance() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(pool))));
    }

    /// @notice The uint32-feeProtocol slot0 decodes cleanly: legs are emitted (proving `_slot0` did not revert) and
    ///         the in-range split + fees come through.
    function test_slot0_uint32FeeProtocol_decodes() public view {
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, _instance(), address(0));
        assertEq(p.length, 4, "2 supply + 2 fee legs");
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Supplied));
        assertGt(p[0].amount, 0);
    }

    /// @notice The base's `_slot0` (uint8 feeProtocol) reverts on the same wide field — proving the override is load-
    ///         bearing, not cosmetic. A Uniswap adapter pointed at a PancakeSwap pool drops the instance.
    function test_baseSlot0_revertsOnWideFeeProtocol() public {
        UniswapV3PoolsMetaBalanceAdapter uni = new UniswapV3PoolsMetaBalanceAdapter(address(npm), address(nav));
        // Framework isolates the reverting instance → empty result (rather than bubbling the ABI-decode revert).
        INAVCalculator.PositionBalance[] memory p = uni.getAdapterPositionsForInstances(alice, _instance(), address(0));
        assertEq(p.length, 0, "uint8 decode of a uint32 feeProtocol reverts; instance isolated to empty");
    }

    /// @notice Legs carry the PancakeSwap identity slugs (not the inherited Uniswap ones).
    function test_pancakeIdentitySlugs() public view {
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, _instance(), address(0));
        assertGt(p.length, 0);
        assertEq(p[0].protocolBrand, ProtocolIds.PANCAKESWAP);
        assertEq(p[0].protocolId, ProtocolIds.PANCAKESWAP_V3);
        assertEq(p[0].protocolSubId, ProtocolIds.PANCAKESWAP_V3);
        // positionId is still abi.encode(pool); the NFT id rides in positionInstanceId.
        assertEq(p[0].positionId, abi.encode(address(pool)));
        assertEq(p[0].positionInstanceId, bytes32(uint256(1)));
    }

    /// @notice Option-A (ADR 0017): fees include the feeGrowthInside-since-poke component + settled tokensOwed.
    function test_fees_includeFeeGrowthSincePoke() public {
        uint256 q128 = 1 << 128;
        pool.setFeeGrowthGlobal(2 * q128, 0); // in range, ticks-outside 0 → fgInside0 = 2·Q128
        pool.setTickFeeGrowth(-100, 0, 0);
        pool.setTickFeeGrowth(100, 0, 0);

        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, _instance(), address(0));
        uint256 usdcFee;
        bool found;
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].balanceAsset.asset == address(usdc) && p[i].positionKind == PositionKind.Fees) {
                usdcFee = p[i].amount;
                found = true;
            }
        }
        assertTrue(found, "USDC fee leg present");
        assertEq(usdcFee, 2 * 1_000_000 + 7, "fee = feeGrowthInside-delta + tokensOwed0");
    }
}
