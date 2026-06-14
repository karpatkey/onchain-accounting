// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {UniswapV3PoolsMetaBalanceAdapter} from "src/balances/protocols/uniswap/UniswapV3PoolsMeta.sol";
import {TickMath} from "src/balances/protocols/uniswap/lib/TickMath.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {MockUniswapV3Pool, MockPositionManager, MockToken} from "test/balances/protocols/uniswap/UniswapV3Mocks.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

/// @title UniswapV3PoolsMetaBalanceAdapter unit tests (no fork)
/// @notice Meta-framework behaviour and decomposition logic for UniswapV3PoolsMeta.
contract UniswapV3PoolsMetaBalanceAdapterTest is Test {
    using Strings for address;

    Mock_NAVCalculator nav;
    MockPositionManager npm;
    UniswapV3PoolsMetaBalanceAdapter meta;

    MockToken wbtc; // pool A token0
    MockToken weth; // shared token1
    MockToken usdc; // pool B token0
    MockUniswapV3Pool poolA; // WBTC/WETH 0.3%
    MockUniswapV3Pool poolB; // USDC/WETH 0.05%

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        npm = new MockPositionManager();
        wbtc = new MockToken("WBTC", 8);
        weth = new MockToken("WETH", 18);
        usdc = new MockToken("USDC", 6);
        nav.registerAsset(address(wbtc), 8, "WBTC");
        nav.registerAsset(address(weth), 18, "WETH");
        nav.registerAsset(address(usdc), 6, "USDC");

        poolA = new MockUniswapV3Pool(address(wbtc), address(weth), 3000, 60);
        poolB = new MockUniswapV3Pool(address(usdc), address(weth), 500, 10);
        poolA.setSlot0(TickMath.getSqrtRatioAtTick(0), 0);
        poolB.setSlot0(TickMath.getSqrtRatioAtTick(0), 0);

        // In-range NFT in each pool + settled fees (tokensOwed) for deterministic Fees legs.
        _mint(1, address(wbtc), address(weth), 3000, 1_000_000, 42, 1337);
        _mint(2, address(usdc), address(weth), 500, 2_000_000, 7, 99);

        meta = new UniswapV3PoolsMetaBalanceAdapter(address(npm), "Uniswap V3", address(nav));
    }

    function _mint(uint256 id, address t0, address t1, uint24 fee, uint128 liq, uint128 owed0, uint128 owed1) internal {
        npm.mint(
            alice,
            id,
            MockPositionManager.PositionData({
                token0: t0,
                token1: t1,
                fee: fee,
                tickLower: -100,
                tickUpper: 100,
                liquidity: liq,
                feeGrowthInside0LastX128: 0,
                feeGrowthInside1LastX128: 0,
                tokensOwed0: owed0,
                tokensOwed1: owed1
            })
        );
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(poolA))));
        ins[1] = bytes32(uint256(uint160(address(poolB))));
    }

    /// @notice Sum of meta legs for a single (pool, token).
    function _metaToken(bytes32 instance, address token) internal view returns (uint256 sum) {
        bytes32[] memory one = new bytes32[](1);
        one[0] = instance;
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, one, address(0));
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].balanceAsset.asset == token) sum += p[i].amount;
        }
    }

    function test_supportsInterface() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
    }

    function test_noArgMethods_returnEmpty() public view {
        assertEq(meta.getAdapterPositions(alice, address(0)).length, 0);
        assertEq(meta.underlyingAssetsSupported().length, 0);
    }

    function test_metaToken_nonZero() public view {
        uint256 aWbtc = _metaToken(_instances()[0], address(wbtc));
        uint256 aWeth = _metaToken(_instances()[0], address(weth));
        assertGt(aWbtc, 0);
        assertGt(aWeth, 0);

        uint256 bUsdc = _metaToken(_instances()[1], address(usdc));
        assertGt(bUsdc, 0);
    }

    function test_fanOut_acrossPools_andIdentity() public view {
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, _instances(), address(0));
        // poolA: WBTC supply, WETH supply, WBTC fees, WETH fees (4) + poolB: USDC supply, WETH supply, USDC fees, WETH fees (4)
        assertEq(p.length, 8, "4 legs per pool");
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].balanceAdapter, address(meta));
            assertFalse(p[i].isDebt);
        }
        // poolA legs carry positionId = abi.encode(npm, tokenId=1)
        assertEq(p[0].positionId, abi.encode(address(npm), uint256(1)));
        // poolB legs carry positionId = abi.encode(npm, tokenId=2)
        assertEq(p[4].positionId, abi.encode(address(npm), uint256(2)));
    }

    function test_feesLegType() public view {
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, _instances(), address(0));
        // The 3rd/4th poolA legs are Fees (tokensOwed 42/1337).
        assertEq(p[2].amount, 42);
        assertEq(uint8(p[2].positionKind), uint8(PositionKind.Fees));
        assertEq(p[3].amount, 1337);
        assertEq(uint8(p[3].positionKind), uint8(PositionKind.Fees));
    }

    function test_assetFilter() public view {
        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, one, address(wbtc));
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].balanceAsset.asset, address(wbtc));
        }
        assertGt(p.length, 0);
    }

    function test_unregisteredToken_skipped() public {
        nav.unregisterAssetHelper(address(weth));
        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, one, address(0));
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].balanceAsset.asset, address(wbtc), "only WBTC legs survive");
        }
        assertGt(p.length, 0);
    }

    function test_badInstance_isolated() public view {
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead)))); // no code -> reverts internally, isolated
        ins[1] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(p.length, 4, "bad instance isolated, poolA's 4 legs returned");
    }

    function test_emptyInstances() public view {
        assertEq(meta.getAdapterPositionsForInstances(alice, new bytes32[](0), address(0)).length, 0);
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory a = meta.underlyingAssetsSupportedForInstances(_instances());
        assertEq(a.length, 4); // [wbtc, weth, usdc, weth]
        assertEq(a[0], address(wbtc));
        assertEq(a[1], address(weth));
        assertEq(a[2], address(usdc));
        assertEq(a[3], address(weth));
    }
}
