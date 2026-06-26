// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {
    PancakeSwapV3PoolsMetaBalanceAdapter
} from "src/balances/protocols/pancakeswap/PancakeSwapV3PoolsMetaBalanceAdapter.sol";
import {UniswapV3PoolsMetaBalanceAdapter} from "src/balances/protocols/uniswap/UniswapV3PoolsMetaBalanceAdapter.sol";
import {TickMath} from "src/balances/protocols/uniswap/lib/TickMath.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {MockPositionManager, MockToken} from "test/balances/protocols/uniswap/UniswapV3Mocks.sol";
import {MockPancakeV3Pool} from "test/balances/protocols/pancakeswap/PancakeSwapV3Mocks.sol";

/// @title PancakeSwapV3PoolsMetaBalanceAdapter unit tests (no fork)
/// @notice The shared NFT discovery / principal+fee math / NAV filtering is verified by the Uniswap V3 unit + fork
///         tests and inherited unchanged. Since [2] the adapter reconstructs the price from the registered oracle
///         feeds and no longer reads `slot0`, so PancakeSwap V3 now differs from Uniswap V3 in exactly ONE way:
///         - `_protocolId`: reports `pancakeswap-v3` (not the inherited `uniswap-v3`).
///         (The former `_slot0` override — needed because PancakeSwap declares `slot0().feeProtocol` as `uint32`
///         vs Uniswap's `uint8` — was removed: with no slot0 read, the `uint32 feeProtocol` divergence is moot,
///         and the inherited Uniswap base adapter now works on a PancakeSwap pool too. See
///         test_uniswapBase_sameLegs_onlyProtocolIdDiffers.)
contract PancakeSwapV3PoolsMetaBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    MockPositionManager npm;
    MockToken weth;
    MockToken usdt;
    MockPancakeV3Pool pool; // WETH/USDT 0.05%, slot0().feeProtocol = 222825800 (uint32 > 255)
    PancakeSwapV3PoolsMetaBalanceAdapter meta;

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        npm = new MockPositionManager();
        weth = new MockToken("WETH", 18);
        usdt = new MockToken("USDT", 6);
        nav.registerAsset(address(weth), 18, "WETH");
        nav.registerAsset(address(usdt), 6, "USDT");

        // [2] The adapter reconstructs sqrtPriceX96 from these oracle prices (it no longer reads slot0). Chosen so
        // the reconstructed raw token1/token0 price is exactly 1.0 (sqrtPrice == 2^96, tick 0), keeping the
        // [-100, 100] position in range. WETH(18)/USDT(6): denominator USDT·10^12, numerator WETH → 1e18 == 1e6·1e12.
        nav.setAssetPrice(address(weth), 1e18, 8);
        nav.setAssetPrice(address(usdt), 1e6, 8);

        pool = new MockPancakeV3Pool(address(weth), address(usdt), 500, 10);
        pool.setSlot0(TickMath.getSqrtRatioAtTick(0), 0); // in-range for [-100, 100]

        npm.mint(
            alice,
            1,
            MockPositionManager.PositionData({
                token0: address(weth),
                token1: address(usdt),
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

        meta = new PancakeSwapV3PoolsMetaBalanceAdapter(address(npm), "PancakeSwap V3", address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(pool))));
    }

    function test_supportsInterface() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
    }

    /// @notice The PCS pool yields non-zero in-range principal. (Pre-[2] this exercised the `_slot0` uint32
    ///         override; since [2] the adapter reconstructs the price from oracle feeds and never reads slot0, so
    ///         the pool's `uint32 feeProtocol` is irrelevant — the legs come purely from the reconstructed price.)
    function test_slot0_uint32FeeProtocol_decodes() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertGt(p.length, 0, "legs emitted from reconstructed price");
        uint256 supply;
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].positionKind == PositionKind.Supplied) supply += p[i].amount;
        }
        assertGt(supply, 0, "non-zero in-range principal");
    }

    /// @notice Since [2] neither adapter reads slot0, so the inherited Uniswap base adapter no longer reverts on a
    ///         PancakeSwap pool's `uint32 feeProtocol` — it now emits the same legs from the same reconstructed
    ///         price. The ONLY remaining difference between the two is the protocol-id slug (asserted below and in
    ///         test_protocolId_isPancakeswapV3). This is why the former `_slot0` override could be removed.
    function test_uniswapBase_sameLegs_onlyProtocolIdDiffers() public {
        UniswapV3PoolsMetaBalanceAdapter base =
            new UniswapV3PoolsMetaBalanceAdapter(address(npm), "Uniswap V3", address(nav));
        INAVCalculator.PositionBalance[] memory bp =
            base.getAdapterPositionsForInstances(alice, _instances(), address(0));
        INAVCalculator.PositionBalance[] memory pp =
            meta.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertGt(bp.length, 0, "base adapter no longer reverts on a PCS pool (no slot0 read)");
        assertEq(bp.length, pp.length, "same legs from the same reconstructed price");
        for (uint256 i = 0; i < bp.length; i++) {
            assertEq(bp[i].protocolId, ProtocolIds.UNISWAP_V3, "base reports uniswap-v3");
            assertEq(pp[i].protocolId, ProtocolIds.PANCAKESWAP_V3, "PCS reports pancakeswap-v3");
            assertEq(bp[i].amount, pp[i].amount, "identical amounts");
        }
    }

    /// @notice `_protocolId` override: every leg reports `pancakeswap-v3` (not the inherited `uniswap-v3`).
    function test_protocolId_isPancakeswapV3() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertGt(p.length, 0);
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].protocolId, ProtocolIds.PANCAKESWAP_V3, "protocolId == pancakeswap-v3");
            assertTrue(p[i].protocolId != ProtocolIds.UNISWAP_V3, "not the inherited uniswap-v3");
        }
    }

    /// @notice positionId schema + identity are inherited unchanged: abi.encode(npm, tokenId), label "NFT #<id>".
    function test_identity_positionId_andLabel() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertGt(p.length, 0);
        assertEq(p[0].positionId, abi.encode(address(npm), uint256(1)));
        assertEq(meta.describePosition(abi.encode(address(npm), uint256(1))), "NFT #1");
    }
}
