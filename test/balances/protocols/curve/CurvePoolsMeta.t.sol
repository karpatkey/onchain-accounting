// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {CurvePoolsMetaBalanceAdapter} from "src/balances/protocols/curve/CurvePoolsMeta.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {
    MockCurveToken,
    MockCurvePool,
    MockCurvePoolWithSeparateLp,
    MockCurveLpToken,
    MockCurvePoolInt128
} from "test/balances/protocols/curve/CurveMocks.sol";

contract CurvePoolsMetaBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    CurvePoolsMetaBalanceAdapter meta;

    MockCurveToken usdc;
    MockCurveToken dai;
    MockCurveToken weth;

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        usdc = new MockCurveToken("USDC", 6);
        dai = new MockCurveToken("DAI", 18);
        weth = new MockCurveToken("WETH", 18);
        nav.registerAsset(address(usdc), 6, "USDC");
        nav.registerAsset(address(dai), 18, "DAI");
        nav.registerAsset(address(weth), 18, "WETH");

        meta = new CurvePoolsMetaBalanceAdapter("Curve", address(nav));
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _instance(address pool) internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(pool)));
    }

    // ─── interface ────────────────────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
    }

    // ─── self-LP pool (classic StableSwap / TriCryptoNG pattern) ─────────────

    function test_selfLp_walletBalance_decomposedProRata() public {
        // Pool IS the LP token; 50/50 USDC/DAI split, 1000 LP total
        address[] memory coins = new address[](2);
        coins[0] = address(usdc);
        coins[1] = address(dai);
        MockCurvePool pool = new MockCurvePool(coins);
        pool.setPoolBalance(0, 500e6); // 500 USDC
        pool.setPoolBalance(1, 500e18); // 500 DAI
        pool.setTotalSupply(1_000e18);
        pool.setWalletBalance(alice, 100e18); // 10% of pool

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(pool)), address(0));

        assertEq(pos.length, 2);
        // 10% of 500 USDC = 50 USDC
        assertEq(pos[0].balanceAsset.asset, address(usdc));
        assertEq(pos[0].amount, 50e6);
        assertEq(uint8(pos[0].positionKind), uint8(PositionKind.Supplied));
        assertFalse(pos[0].isDebt);
        // 10% of 500 DAI = 50 DAI
        assertEq(pos[1].balanceAsset.asset, address(dai));
        assertEq(pos[1].amount, 50e18);
    }

    function test_selfLp_positionIdentity() public {
        address[] memory coins = new address[](2);
        coins[0] = address(usdc);
        coins[1] = address(dai);
        MockCurvePool pool = new MockCurvePool(coins);
        pool.setWalletBalance(alice, 100e18);

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(pool)), address(0));
        assertGt(pos.length, 0);
        assertEq(pos[0].protocolId, ProtocolIds.CURVE_POOL);
        assertEq(pos[0].positionId, abi.encode(address(pool)));
        assertEq(pos[0].balanceAdapter, address(meta));
    }

    function test_selfLp_noWalletBalance_empty() public {
        address[] memory coins = new address[](2);
        coins[0] = address(usdc);
        coins[1] = address(dai);
        MockCurvePool pool = new MockCurvePool(coins);
        // no wallet balance set

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(pool)), address(0));
        assertEq(pos.length, 0);
    }

    function test_selfLp_assetFilter_onlyMatchingCoin() public {
        address[] memory coins = new address[](2);
        coins[0] = address(usdc);
        coins[1] = address(dai);
        MockCurvePool pool = new MockCurvePool(coins);
        pool.setWalletBalance(alice, 100e18);

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(pool)), address(usdc));
        assertEq(pos.length, 1);
        assertEq(pos[0].balanceAsset.asset, address(usdc));
    }

    function test_selfLp_unregisteredCoin_skipped() public {
        // weth is registered, but use a new unregistered token
        MockCurveToken unregistered = new MockCurveToken("UNKN", 18);
        address[] memory coins = new address[](2);
        coins[0] = address(usdc);
        coins[1] = address(unregistered);
        MockCurvePool pool = new MockCurvePool(coins);
        pool.setWalletBalance(alice, 100e18);

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(pool)), address(0));
        assertEq(pos.length, 1); // only USDC
        assertEq(pos[0].balanceAsset.asset, address(usdc));
    }

    function test_selfLp_threeCoinPool() public {
        address[] memory coins = new address[](3);
        coins[0] = address(usdc);
        coins[1] = address(dai);
        coins[2] = address(weth);
        MockCurvePool pool = new MockCurvePool(coins);
        pool.setPoolBalance(0, 300e6);
        pool.setPoolBalance(1, 300e18);
        pool.setPoolBalance(2, 300e18);
        pool.setTotalSupply(900e18);
        pool.setWalletBalance(alice, 90e18); // 10%

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(pool)), address(0));
        assertEq(pos.length, 3);
    }

    // ─── separate LP token (StableSwap-NG factory pattern) ───────────────────

    function test_separateLp_walletBalance_decomposedViaPoolFromMinter() public {
        // Simulates StableSwap-NG factory pattern:
        //   pool.lp_token() → lpToken (separate ERC20)
        //   lpToken.minter() → pool
        // CurvePoolLib.getPool(lpToken) discovers the pool via minter(), then reads coins()/balances().
        address[] memory coins = new address[](2);
        coins[0] = address(usdc);
        coins[1] = address(dai);

        // 1. Deploy LP token with a placeholder minter (will be updated after pool is known)
        MockCurveLpToken lpToken = new MockCurveLpToken(address(0));
        // 2. Deploy pool pointing at the LP token
        MockCurvePoolWithSeparateLp pool = new MockCurvePoolWithSeparateLp(coins, address(lpToken));
        // 3. Now that the pool address is known, point the LP token's minter back at the pool
        lpToken.setMinter(address(pool));

        lpToken.setTotalSupply(1_000e18);
        lpToken.setWalletBalance(alice, 200e18); // 20% of pool

        // Instance coordinate = pool address; pool.lp_token() → lpToken; lpToken.minter() → pool
        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(pool)), address(0));

        assertEq(pos.length, 2);
        assertEq(pos[0].balanceAsset.asset, address(usdc));
        assertEq(pos[1].balanceAsset.asset, address(dai));
        // 20% of 100_000e18 default pool balance
        assertEq(pos[0].amount, 20_000e18);
        assertEq(pos[1].amount, 20_000e18);
    }

    // ─── int128 index pool (legacy Vyper 0.1.x) ──────────────────────────────

    function test_int128Pool_coinsAndBalances_readCorrectly() public {
        address[] memory coins = new address[](2);
        coins[0] = address(usdc);
        coins[1] = address(dai);
        MockCurvePoolInt128 pool = new MockCurvePoolInt128(coins);
        pool.setPoolBalance(0, 400e6);
        pool.setPoolBalance(1, 400e18);
        pool.setTotalSupply(800e18);
        pool.setWalletBalance(alice, 80e18); // 10%

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _instance(address(pool)), address(0));

        assertEq(pos.length, 2);
        assertEq(pos[0].balanceAsset.asset, address(usdc));
        assertEq(pos[0].amount, 40e6); // 10% of 400 USDC
        assertEq(pos[1].balanceAsset.asset, address(dai));
        assertEq(pos[1].amount, 40e18); // 10% of 400 DAI
    }

    // ─── multi-instance fan-out ───────────────────────────────────────────────

    function test_multiPool_fanOut() public {
        address[] memory coins2 = new address[](2);
        coins2[0] = address(usdc);
        coins2[1] = address(dai);
        MockCurvePool poolA = new MockCurvePool(coins2);
        poolA.setWalletBalance(alice, 100e18);

        address[] memory coins1 = new address[](1);
        coins1[0] = address(weth);
        MockCurvePool poolB = new MockCurvePool(coins1);
        poolB.setWalletBalance(alice, 50e18);

        bytes32[] memory instances = new bytes32[](2);
        instances[0] = bytes32(uint256(uint160(address(poolA))));
        instances[1] = bytes32(uint256(uint160(address(poolB))));

        INAVCalculator.PositionBalance[] memory pos = meta.getAdapterPositionsForInstances(alice, instances, address(0));
        assertEq(pos.length, 3); // 2 from poolA + 1 from poolB
    }

    function test_badInstance_isolated() public {
        address[] memory coins = new address[](2);
        coins[0] = address(usdc);
        coins[1] = address(dai);
        MockCurvePool good = new MockCurvePool(coins);
        good.setWalletBalance(alice, 100e18);

        bytes32[] memory instances = new bytes32[](2);
        instances[0] = bytes32(uint256(uint160(address(0xdead)))); // bad instance
        instances[1] = bytes32(uint256(uint160(address(good))));

        INAVCalculator.PositionBalance[] memory pos = meta.getAdapterPositionsForInstances(alice, instances, address(0));
        assertEq(pos.length, 2); // only good pool's coins
    }

    // ─── underlyingAssetsSupported ────────────────────────────────────────────

    function test_instanceAssets_returnsCoins() public {
        address[] memory coins = new address[](2);
        coins[0] = address(usdc);
        coins[1] = address(dai);
        MockCurvePool pool = new MockCurvePool(coins);

        address[] memory assets = meta.underlyingAssetsSupportedForInstances(_instance(address(pool)));
        assertEq(assets.length, 2);
        assertEq(assets[0], address(usdc));
        assertEq(assets[1], address(dai));
    }

    // ─── describePosition ─────────────────────────────────────────────────────

    function test_positionLabels_formatsSymbols() public {
        address[] memory coins = new address[](2);
        coins[0] = address(usdc);
        coins[1] = address(dai);
        MockCurvePool pool = new MockCurvePool(coins);

        string[] memory labels = meta.positionLabels(abi.encode(address(pool)));
        assertEq(labels.length, 2);
        assertEq(labels[0], "Liquidity Pool");
        assertEq(labels[1], "USDC/DAI LP");
    }
}
