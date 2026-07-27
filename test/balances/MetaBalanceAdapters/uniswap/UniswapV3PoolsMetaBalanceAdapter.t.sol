// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {
    UniswapV3PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolsMetaBalanceAdapter.sol";
import {TickMath} from "src/balances/MetaBalanceAdapters/uniswap/lib/TickMath.sol";
import {FixedPoint128} from "src/balances/MetaBalanceAdapters/uniswap/lib/FixedPoint128.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {
    MockUniswapV3Pool,
    MockPositionManager,
    MockToken
} from "test/balances/MetaBalanceAdapters/uniswap/UniswapV3Mocks.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

/// @title UniswapV3PoolsMetaBalanceAdapter unit tests (no fork)
/// @notice Meta-framework behaviour + Option-A valuation (ADR 0017) for UniswapV3PoolsMeta: the adapter enumerates
///         the account's NPM NFTs on-chain, values the in-range split off the pool's live `slot0`, and reports the
///         FULL unclaimed fees (feeGrowthInside-since-poke + settled tokensOwed). Identity: positionId =
///         abi.encode(pool); the NFT tokenId rides in positionInstanceId.
contract UniswapV3PoolsMetaBalanceAdapterTest is Test {
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
        // Current tick 0 (sqrtPrice = 2^96) is inside every position's [-100, 100] range → both liquidity legs > 0.
        poolA.setSlot0(TickMath.getSqrtRatioAtTick(0), 0);
        poolB.setSlot0(TickMath.getSqrtRatioAtTick(0), 0);

        // One in-range NFT per pool with settled fees (tokensOwed) for deterministic Fees legs.
        _mint(1, address(wbtc), address(weth), 3000, 1_000_000, 42, 1337);
        _mint(2, address(usdc), address(weth), 500, 2_000_000, 7, 99);

        meta = new UniswapV3PoolsMetaBalanceAdapter(address(npm), address(nav));
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

    function _oneInstance(bytes32 instance) internal pure returns (bytes32[] memory one) {
        one = new bytes32[](1);
        one[0] = instance;
    }

    /// @notice Sum of meta legs for a single (pool, token).
    function _metaToken(bytes32 instance, address token) internal view returns (uint256 sum) {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _oneInstance(instance), address(0));
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].balanceAsset.asset == token) sum += p[i].amount;
        }
    }

    /// @notice Fees-kind leg amount for (pool, token); `found` is false if no Fees leg exists for it.
    function _feeLeg(bytes32 instance, address token) internal view returns (uint256 amt, bool found) {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _oneInstance(instance), address(0));
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].balanceAsset.asset == token && p[i].positionKind == PositionKind.Fees) {
                return (p[i].amount, true);
            }
        }
        return (0, false);
    }

    function test_supportsInterface() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
    }

    function test_noArgMethods_returnEmpty() public view {
        assertEq(meta.getAdapterPositions(alice, address(0)).length, 0);
        assertEq(meta.underlyingAssetsSupported().length, 0);
    }

    function test_metaToken_nonZero() public view {
        assertGt(_metaToken(_instances()[0], address(wbtc)), 0);
        assertGt(_metaToken(_instances()[0], address(weth)), 0);
        assertGt(_metaToken(_instances()[1], address(usdc)), 0);
    }

    /// @notice Fans out across pools; every leg carries the adapter as balanceAdapter, is a credit, and (crucially for
    ///         Option-A identity) positionId = abi.encode(pool) while the NFT tokenId rides in positionInstanceId.
    function test_fanOut_acrossPools_andIdentity() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instances(), address(0));
        // poolA: WBTC/WETH supply (2) + WBTC/WETH fees (2); poolB: USDC/WETH supply (2) + USDC/WETH fees (2).
        assertEq(p.length, 8, "4 legs per pool");
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].balanceAdapter, address(meta));
            assertFalse(p[i].isDebt);
        }
        // poolA legs: positionId = abi.encode(pool), positionInstanceId = the NFT tokenId (1).
        assertEq(p[0].positionId, abi.encode(address(poolA)), "poolA positionId = abi.encode(pool)");
        assertEq(p[0].positionInstanceId, bytes32(uint256(1)), "poolA positionInstanceId = tokenId 1");
        // poolB legs: positionId = abi.encode(pool), positionInstanceId = the NFT tokenId (2).
        assertEq(p[4].positionId, abi.encode(address(poolB)), "poolB positionId = abi.encode(pool)");
        assertEq(p[4].positionInstanceId, bytes32(uint256(2)), "poolB positionInstanceId = tokenId 2");
    }

    /// @notice Leg kinds: the first two poolA legs are Supplied (in-range split), the last two are Fees.
    function test_legKinds() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _oneInstance(_instances()[0]), address(0));
        assertEq(p.length, 4);
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Supplied));
        assertEq(uint8(p[1].positionKind), uint8(PositionKind.Supplied));
        assertEq(uint8(p[2].positionKind), uint8(PositionKind.Fees));
        assertEq(uint8(p[3].positionKind), uint8(PositionKind.Fees));
        // No isLocked on any leg: LP liquidity + unclaimed fees are always withdrawable.
        for (uint256 i = 0; i < p.length; i++) {
            assertFalse(p[i].isLocked);
        }
    }

    /// @notice With a clean (zero) fee-growth state, unclaimed fees collapse to the settled `tokensOwed` (42 / 1337).
    function test_fees_zeroGrowth_equalTokensOwed() public view {
        (uint256 wbtcFee, bool f0) = _feeLeg(_instances()[0], address(wbtc));
        (uint256 wethFee, bool f1) = _feeLeg(_instances()[0], address(weth));
        assertTrue(f0 && f1, "both fee legs present");
        assertEq(wbtcFee, 42, "fee == tokensOwed0 when fee-growth is zero");
        assertEq(wethFee, 1337, "fee == tokensOwed1 when fee-growth is zero");
    }

    /// @notice Option-A (ADR 0017): the Fees leg INCLUDES the uncollected-since-poke `feeGrowthInside` component, not
    ///         just settled `tokensOwed`. With an in-range position and a nonzero global fee-growth, the reported fee
    ///         is exactly `feeGrowthInsideDelta · liquidity / 2^128 + tokensOwed`.
    function test_fees_includeFeeGrowthSincePoke() public {
        uint256 q128 = FixedPoint128.Q128;
        // In range (ticks-outside both 0): fgInside0 = fgGlobal0 = 2·Q128; delta over the position's last (0) = 2·Q128.
        poolA.setFeeGrowthGlobal(2 * q128, 0);
        poolA.setTickFeeGrowth(-100, 0, 0);
        poolA.setTickFeeGrowth(100, 0, 0);

        (uint256 wbtcFee, bool found) = _feeLeg(_instances()[0], address(wbtc));
        assertTrue(found, "WBTC fee leg present");
        // 2·Q128 · 1e6 / Q128 + tokensOwed0(42) = 2·1e6 + 42.
        assertEq(wbtcFee, 2 * 1_000_000 + 42, "fee includes feeGrowthInside-since-poke + tokensOwed");
    }

    /// @notice `assetFilter` gates which of the two legs are emitted; a filter of WBTC drops all WETH legs.
    function test_assetFilter() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _oneInstance(_instances()[0]), address(wbtc));
        assertGt(p.length, 0);
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].balanceAsset.asset, address(wbtc));
        }
    }

    /// @notice Valuing the LP split needs BOTH tokens' registrations; unregistering either drops the whole instance
    ///         (a half-priced LP would silently understate NAV).
    function test_unregisteredToken_dropsInstance() public {
        nav.unregisterAssetHelper(address(weth)); // poolA is WBTC/WETH
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _oneInstance(_instances()[0]), address(0));
        assertEq(p.length, 0, "unregistering either token drops the whole instance");
    }

    /// @notice A reverting pool (unreadable slot0) is isolated by the framework's per-instance try/catch; the healthy
    ///         pool's legs still come back.
    function test_revertingPool_isolated() public {
        poolA.setSlot0Reverts(true);
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(p.length, 4, "poolA isolated, poolB's 4 legs returned");
        assertEq(p[0].positionId, abi.encode(address(poolB)));
    }

    function test_badInstance_isolated() public view {
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead)))); // no code → reverts internally, isolated
        ins[1] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(p.length, 4, "bad instance isolated, poolA's 4 legs returned");
    }

    function test_emptyInstances() public view {
        assertEq(meta.getAdapterPositionsForInstances(alice, new bytes32[](0), address(0)).length, 0);
    }

    /// @notice Two NFTs in the SAME pool fan out to 8 legs that share the pool's positionId but carry distinct
    ///         per-NFT positionInstanceIds.
    function test_multipleNftsSamePool() public {
        _mint(3, address(wbtc), address(weth), 3000, 500_000, 1, 2); // second WBTC/WETH NFT
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _oneInstance(_instances()[0]), address(0));
        assertEq(p.length, 8, "two NFTs x 4 legs");
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].positionId, abi.encode(address(poolA)), "shared pool positionId");
        }
        // The two NFTs' ids (1 and 3) both appear across the legs.
        bool saw1;
        bool saw3;
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].positionInstanceId == bytes32(uint256(1))) saw1 = true;
            if (p[i].positionInstanceId == bytes32(uint256(3))) saw3 = true;
        }
        assertTrue(saw1 && saw3, "both NFT ids surface in positionInstanceId");
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory a = meta.underlyingAssetsSupportedForInstances(_instances());
        assertEq(a.length, 4); // [wbtc, weth, usdc, weth]
        assertEq(a[0], address(wbtc));
        assertEq(a[1], address(weth));
        assertEq(a[2], address(usdc));
        assertEq(a[3], address(weth));
    }

    /// @notice Verbose labels: ["AMM Liquidity Pool", "<sym0>/<sym1> <fee>%"] read live off the pool in positionId.
    function test_positionLabels() public view {
        string[] memory labels = meta.positionLabels(abi.encode(address(poolA)));
        assertEq(labels.length, 2);
        assertEq(labels[0], "AMM Liquidity Pool");
        assertEq(labels[1], "WBTC/WETH 0.3%");
    }

    function test_positionLabels_shortId_empty() public view {
        assertEq(meta.positionLabels(hex"00").length, 0);
    }
}
