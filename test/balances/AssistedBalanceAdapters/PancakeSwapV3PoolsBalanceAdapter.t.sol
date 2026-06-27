// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {
    PancakeSwapV3PoolsBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/PancakeSwapV3PoolsBalanceAdapter.sol";
import {UniswapV3PoolsBalanceAdapter} from "src/balances/AssistedBalanceAdapters/UniswapV3PoolsBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IAssistedBalanceAdapter} from "src/balances/IAssistedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {MockPositionManager, MockToken} from "test/balances/AssistedBalanceAdapters/UniswapV3Mocks.sol";

/// @title PancakeSwapV3PoolsBalanceAdapter unit tests (no fork)
/// @notice The shared assisted tokenId cache / per-NFT principal+fee math / NAV filtering is verified by the Uniswap
///         V3 unit + fork tests and inherited unchanged. PancakeSwap V3 differs in exactly ONE way: `_protocolId`
///         reports `pancakeswap-v3` (not the inherited `uniswap-v3`). The adapter never reads `slot0` (price is
///         reconstructed from the registered oracle feeds), so the inherited Uniswap base works on a PancakeSwap NFT
///         too — see test_uniswapBase_sameLegs_onlyProtocolIdDiffers.
contract PancakeSwapV3PoolsBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    MockPositionManager npm;
    MockToken weth;
    MockToken usdt;
    PancakeSwapV3PoolsBalanceAdapter adapter;

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        npm = new MockPositionManager();
        weth = new MockToken("WETH", 18);
        usdt = new MockToken("USDT", 6);
        nav.registerAsset(address(weth), 18, "WETH");
        nav.registerAsset(address(usdt), 6, "USDT");

        // [2] Reconstructed raw token1/token0 price == 1.0 (sqrtPrice == 2^96, tick 0), in range for [-100, 100].
        nav.setAssetPrice(address(weth), 1e18, 8);
        nav.setAssetPrice(address(usdt), 1e6, 8);

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

        adapter = new PancakeSwapV3PoolsBalanceAdapter(
            address(npm), "PancakeSwap V3", address(nav), address(this), address(this)
        );
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        adapter.submitTokenIds(alice, ids);
    }

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IAssistedBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_nonZeroPrincipal() public view {
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        assertGt(p.length, 0, "legs emitted from reconstructed price");
        uint256 supply;
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].positionKind == PositionKind.Supplied) supply += p[i].amount;
        }
        assertGt(supply, 0, "non-zero in-range principal");
    }

    /// @notice The inherited Uniswap base adapter emits the same legs from the same reconstructed price on a
    ///         PancakeSwap NFT; the ONLY difference is the protocol-id slug.
    function test_uniswapBase_sameLegs_onlyProtocolIdDiffers() public {
        UniswapV3PoolsBalanceAdapter base =
            new UniswapV3PoolsBalanceAdapter(address(npm), "Uniswap V3", address(nav), address(this), address(this));
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        base.submitTokenIds(alice, ids);

        INAVCalculator.PositionBalance[] memory bp = base.getAdapterPositions(alice, address(0));
        INAVCalculator.PositionBalance[] memory pp = adapter.getAdapterPositions(alice, address(0));
        assertGt(bp.length, 0);
        assertEq(bp.length, pp.length, "same legs from the same reconstructed price");
        for (uint256 i = 0; i < bp.length; i++) {
            assertEq(bp[i].protocolId, ProtocolIds.UNISWAP_V3, "base reports uniswap-v3");
            assertEq(pp[i].protocolId, ProtocolIds.PANCAKESWAP_V3, "PCS reports pancakeswap-v3");
            assertEq(bp[i].amount, pp[i].amount, "identical amounts");
        }
    }

    /// @notice `_protocolId` override: every leg reports `pancakeswap-v3` (not the inherited `uniswap-v3`).
    function test_protocolId_isPancakeswapV3() public view {
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        assertGt(p.length, 0);
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].protocolId, ProtocolIds.PANCAKESWAP_V3, "protocolId == pancakeswap-v3");
            assertTrue(p[i].protocolId != ProtocolIds.UNISWAP_V3, "not the inherited uniswap-v3");
        }
    }

    /// @notice positionId schema + identity are inherited unchanged: abi.encode(npm, tokenId), label "NFT #<id>".
    function test_identity_positionId_andLabel() public view {
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        assertGt(p.length, 0);
        assertEq(p[0].positionId, abi.encode(address(npm), uint256(1)));
        string[] memory labels = adapter.positionLabels(abi.encode(address(npm), uint256(1)));
        assertEq(labels.length, 2);
        assertEq(labels[0], "Liquidity Pool");
        assertEq(labels[1], "NFT #1");
    }
}
