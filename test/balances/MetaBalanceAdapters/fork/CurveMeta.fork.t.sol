// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {CurvePoolsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/curve/CurvePoolsMetaBalanceAdapter.sol";
import {CurveGaugesMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/curve/CurveGaugesMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

/// @title CurveMetaForkTest
/// @notice Fork tests for CurvePoolsMetaBalanceAdapter and CurveGaugesMetaBalanceAdapter against
///         real mainnet contracts.
///
/// Pools under test:
///   - crvUSD/USDC StableSwap-NG (0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E)
///       self-LP (pool IS the LP token), uint256 coins indices
///   - weETH/WETH TriCrypto-style 2-token pool (actual: ngPool)
///       self-LP, two ETH-denominated coins
///   - 3pool (DAI/USDC/USDT, 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7) - uint256-indexed, LP is 3Crv
///       classic StableSwap, but measured at the pinned block it answers `coins(uint256,0)` and REVERTS on
///       `coins(int128,0)` - so nothing in THIS file exercises the int128 branch (see
///       test_threepool_walletLp_decomposes). An earlier version of this line called it "int128-indexed", which
///       is what the renamed test's @dev retracts; the two lines contradicted each other.
///
/// Gauges under test (same underlying pools):
///   - crvUSD/USDC gauge (0x95f00391cB5EebCd190EB58728B4CE23DbFa6ac1)
///   - weETH/WETH gauge (0x053df3e4D0CeD9a3Bf0494F97E83CE1f13BdC0E2 - 0xca8C7cc4… has NO CODE and is not a gauge)
///   - 3pool gauge (0xbFcF63294aD7105dEa65aA58F8AE5BE2D9d0952A)
///
/// Pinned to a block where the test accounts hold verified positions.
contract CurveMetaForkTest is BalanceAdapterTestBase {
    // ── Mainnet addresses ─────────────────────────────────────────────────────

    // Curve Minter (Ethereum mainnet)
    address public constant CURVE_MINTER = 0xd061D61a4d941c39E5453435B6345Dc261C2fcE0;

    // crvUSD/USDC StableSwap-NG pool (pool IS LP token, uint256 indices)
    address public constant CRVUSD_USDC_POOL = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    address public constant CRVUSD_USDC_GAUGE = 0x95f00391cB5EebCd190EB58728B4CE23DbFa6ac1;
    // Account known to hold gauge-staked LP and claimable rewards at FORK_BLOCK.
    // Re-fixtured: the previous holder (0xc9332cbf…) reads ZERO for both gauge stake and wallet LP at this
    // block, so every test using it took its zero-balance early return and asserted nothing. Verified on
    // mainnet at FORK_BLOCK: gauge stake 16,591,881.2 LP.
    address public constant CRVUSD_USDC_STAKER = 0x989AEb4d175e16225E39E87d0D97A3360524AD80;
    // The gauge itself is the largest holder of the pool's LP token at FORK_BLOCK (19,279,874.4), which is what
    // the wallet-LP decomposition test needs: a real, non-zero LP balance to decompose.
    address public constant CRVUSD_USDC_LP_HOLDER = 0x95f00391cB5EebCd190EB58728B4CE23DbFa6ac1;

    // crvUSD/USDT StableSwap-NG pool
    address public constant CRVUSD_USDT_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address public constant CRVUSD_USDT_GAUGE = 0x4e6bB6B7447B7B2Aa268C16AB87F4Bb48BF57939;

    // RLUSD/USDC StableSwap-NG pool
    address public constant RLUSD_USDC_POOL = 0xD001aE433f254283FeCE51d4ACcE8c53263aa186;
    address public constant RLUSD_USDC_GAUGE = 0xFc3212Bd9Ad9A28Da6B2bd50a2918969C126894F;

    // weETH/WETH NG pool (self-LP, uint256 indices)
    address public constant WEETH_WETH_POOL = 0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5;
    address public constant WEETH_WETH_GAUGE = 0x053df3e4D0CeD9a3Bf0494F97E83CE1f13BdC0E2;
    // Account with weETH/WETH staked LP. Re-fixtured: the previous holder (0x6cF2A2Cb…) reads ZERO at this
    // block. Verified gauge stake at FORK_BLOCK: 5,568.3 LP.
    address public constant WEETH_WETH_STAKER = 0x989AEb4d175e16225E39E87d0D97A3360524AD80;
    // The gauge is the pool-LP holder used by the wallet-LP decomposition test (6,415.2 LP).
    address public constant WEETH_WETH_LP_HOLDER = 0x053df3e4D0CeD9a3Bf0494F97E83CE1f13BdC0E2;

    // 3pool — classic StableSwap, int128 coin indices
    address public constant THREEPOOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address public constant THREEPOOL_GAUGE = 0xbFcF63294aD7105dEa65aA58F8AE5BE2D9d0952A;
    // 3pool is NOT its own LP token - `balanceOf` on the pool REVERTS. 3Crv is a separate CurveTokenV1, which
    // is why the wallet-LP tests here could never have read a non-zero balance from the pool address.
    address public constant THREEPOOL_LP = 0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490;
    // Account holding 3pool LP tokens in wallet. Re-fixtured: the previous holder reads ZERO at this block.
    address public constant THREEPOOL_HOLDER = 0x00000000009726632680FB29d3F7A9734E3010E2;
    // Account with a real 3pool GAUGE stake at FORK_BLOCK: 1,756.5 3Crv. This is the fixture that exercises
    // the getPool regression — 3Crv resolves through none of the heuristics, so before the registry fallback
    // this account's entire staking principal was dropped.
    address public constant THREEPOOL_GAUGE_STAKER = 0x52f541764E6e90eeBc5c21Ff570De0e2D63766B6;

    // Tokens
    address public constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address public constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;

    uint256 public constant FORK_BLOCK = 22_500_000;

    CurvePoolsMetaBalanceAdapter public poolsMeta;
    CurveGaugesMetaBalanceAdapter public gaugesMeta;

    function setUp() public override {
        super.setUp();
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        address[] memory assets = new address[](8);
        assets[0] = CRV;
        assets[1] = CRVUSD;
        assets[2] = USDC;
        assets[3] = WEETH;
        assets[4] = WETH;
        assets[5] = DAI;
        assets[6] = USDT;
        assets[7] = RLUSD;
        balances = _deployBalancesForAdapter(assets);

        poolsMeta = new CurvePoolsMetaBalanceAdapter(address(balances));
        gaugesMeta = new CurveGaugesMetaBalanceAdapter(CURVE_MINTER, CRV, address(balances));
    }

    // ─── CurvePoolsMeta fork tests ────────────────────────────────────────────

    /// @notice crvUSD/USDC pool — StableSwap-NG, uint256 coins, self-LP.
    function test_crvUsdUsdc_walletLp_decomposes() public view {
        uint256 walletLp = _lpBalance(CRVUSD_USDC_POOL, CRVUSD_USDC_LP_HOLDER);
        // A zero fixture is a FAILURE, not a skip. Every one of these guards used to be `if (… == 0) return;`,
        // which is how nine of this file's ten tests silently asserted nothing: all four pinned holders read
        // zero at FORK_BLOCK. If this fires, re-fixture the holder — do not restore the early return.
        assertGt(walletLp, 0, "fixture holds no LP at FORK_BLOCK - re-fixture, do not skip");

        INAVCalculator.PositionBalance[] memory pos =
            poolsMeta.getAdapterPositionsForInstances(CRVUSD_USDC_LP_HOLDER, _pool(CRVUSD_USDC_POOL), address(0));

        assertGt(pos.length, 0, "at least one underlying coin leg");
        _assertAllSupplied(pos);
        _assertSumIsProRata(pos, CRVUSD_USDC_POOL, walletLp);
    }

    /// @notice weETH/WETH pool — 2-token NG pool, uint256 coins.
    function test_weethWeth_walletLp_decomposes() public view {
        uint256 walletLp = _lpBalance(WEETH_WETH_POOL, WEETH_WETH_LP_HOLDER);
        assertGt(walletLp, 0, "fixture holds no LP at FORK_BLOCK - re-fixture, do not skip");

        INAVCalculator.PositionBalance[] memory pos =
            poolsMeta.getAdapterPositionsForInstances(WEETH_WETH_LP_HOLDER, _pool(WEETH_WETH_POOL), address(0));

        assertGt(pos.length, 0);
        _assertAllSupplied(pos);
    }

    /// @notice 3pool — classic StableSwap, separate LP token (3Crv).
    /// @dev Renamed: this was `…_int128` and the header called 3pool "int128-indexed", but measured at the
    ///      pinned block 3pool answers `coins(uint256,0)` = DAI and REVERTS on `coins(int128,0)`, so this test
    ///      exercises the uint256 branch exclusively. The int128 fallback is covered by
    ///      `CurvePoolsMetaBalanceAdapter.t.sol::test_int128Pool_coinsAndBalances_readCorrectly`, which builds a
    ///      `MockCurvePoolInt128` - just not here. An earlier version of this line pointed at
    ///      "MockLegacyStableSwapPool", a symbol that exists nowhere in the repo; the substance held but the
    ///      pointer was dead, which is the same defect class this diff retracts twice elsewhere.
    function test_threepool_walletLp_decomposes() public view {
        uint256 walletLp = _lpBalance(THREEPOOL_LP, THREEPOOL_HOLDER);
        assertGt(walletLp, 0, "fixture holds no LP at FORK_BLOCK - re-fixture, do not skip");

        INAVCalculator.PositionBalance[] memory pos =
            poolsMeta.getAdapterPositionsForInstances(THREEPOOL_HOLDER, _pool(THREEPOOL), address(0));

        // TRIPWIRE for a KNOWN, DELIBERATE under-report. `CurvePoolLib.getLpToken` does not resolve legacy
        // StableSwap pools, so 3pool's wallet LP (the separate 3Crv) decomposes to NOTHING even though this
        // holder demonstrably holds it. A registry fallback that fixes this was written, measured working, and
        // deliberately dropped: `getLpToken` also feeds CurvePoolsMetaBalanceAdapter, and resolving the LP
        // re-arms an ERC20Default double-count for operators who registered the LP to work around this very
        // gap. Under-report is the safe direction; that would have been an over-report.
        //
        // This asserts the CURRENT behaviour on purpose, so the successor PR that fixes getLpToken fails here
        // and is forced to update it - see the successor brief in the PR that introduced this note.
        assertEq(pos.length, 0, "3pool wallet LP now decomposes - getLpToken was fixed; update this tripwire");
    }

    /// @notice Pool instance set returned by underlyingAssetsSupported matches coins().
    function test_crvUsdUsdc_instanceAssets_match_coins() public view {
        address[] memory assets = poolsMeta.underlyingAssetsSupportedForInstances(_pool(CRVUSD_USDC_POOL));
        assertGt(assets.length, 0);
        // crvUSD/USDC has exactly 2 coins
        assertEq(assets.length, 2);
    }

    // ─── CurveGaugesMeta fork tests ───────────────────────────────────────────

    /// @notice crvUSD/USDC gauge — staked LP decomposes + CRV lower bound.
    function test_crvUsdUsdc_gauge_stakedAndRewards() public view {
        uint256 staked = _gaugeBalance(CRVUSD_USDC_GAUGE, CRVUSD_USDC_STAKER);
        assertGt(staked, 0, "fixture holds no gauge stake at FORK_BLOCK - re-fixture, do not skip");

        INAVCalculator.PositionBalance[] memory pos =
            gaugesMeta.getAdapterPositionsForInstances(CRVUSD_USDC_STAKER, _gauge(CRVUSD_USDC_GAUGE), address(0));

        assertGt(pos.length, 0);
        uint256 stakedCount = _countKind(pos, PositionKind.Staking);
        assertGt(stakedCount, 0, "staked LP decomposes into underlying coins");
    }

    /// @notice The regression this PR exists for: a real 3pool gauge staker.
    /// @dev 3Crv exposes neither `coins()` nor `minter()` — verified on mainnet, all three probes revert while
    ///      `symbol()` answers "3Crv" — so `CurvePoolLib.getPool` returned `address(0)`, and this adapter gates
    ///      its ENTIRE staking decomposition on `pool != address(0)`. Before the registry fallback this account,
    ///      holding 1,756.5 3Crv in the gauge, reported zero Staking legs: the principal vanished while the
    ///      Rewards legs still emitted, so the position looked live and merely empty. Nothing caught it because
    ///      every test on this path was itself vacuous.
    function test_threepool_gauge_stakedPrincipalIsReported() public view {
        uint256 staked = _gaugeBalance(THREEPOOL_GAUGE, THREEPOOL_GAUGE_STAKER);
        assertGt(staked, 0, "fixture holds no gauge stake at FORK_BLOCK - re-fixture, do not skip");

        INAVCalculator.PositionBalance[] memory pos =
            gaugesMeta.getAdapterPositionsForInstances(THREEPOOL_GAUGE_STAKER, _gauge(THREEPOOL_GAUGE), address(0));

        // Must assert DECOMPOSITION, not merely "a Staking leg exists". This PR gave that weaker condition a
        // second route - the LP-token fallback leg - so a reviewer showed the weaker assertion passes on the
        // UNFIXED library (registry disabled + 3Crv registered => one 3Crv leg). Requiring three legs, none of
        // them the LP token, fails on both unfixed shapes: zero legs (3Crv unregistered) and one LP leg.
        uint256 stakedLegs = _countKind(pos, PositionKind.Staking);
        // assertEq(3) is the real discriminator, mutation-verified: removing the registry fallback fails it
        // 0 != 3. The LP-token check below is defence in depth and is currently UNREACHABLE - 3Crv is not among
        // the assets registered in setUp, so the fallback leg could not be emitted in this fixture even if the
        // library regressed. It becomes live the day 3Crv is registered; it is kept for that, not relied on now.
        assertEq(stakedLegs, 3, "3pool did not decompose into its three coins - getPool(3Crv) unresolved?");
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].positionKind != PositionKind.Staking) continue;
            assertTrue(
                pos[i].balanceAsset.asset != THREEPOOL_LP, "reported the LP token itself - decomposition did not happen"
            );
        }
    }

    /// @notice weETH/WETH gauge — staked LP decomposes.
    function test_weethWeth_gauge_staked() public view {
        uint256 staked = _gaugeBalance(WEETH_WETH_GAUGE, WEETH_WETH_STAKER);
        assertGt(staked, 0, "fixture holds no gauge stake at FORK_BLOCK - re-fixture, do not skip");

        INAVCalculator.PositionBalance[] memory pos =
            gaugesMeta.getAdapterPositionsForInstances(WEETH_WETH_STAKER, _gauge(WEETH_WETH_GAUGE), address(0));

        assertGt(pos.length, 0);
        _assertAllValidPositionKinds(pos);
    }

    /// @notice Asset filter correctly restricts output to the requested token.
    /// @dev The length assertion below is load-bearing: without it an empty result satisfies the loop
    ///      vacuously, which is the same class of defect this file was cleaned of. An earlier revision of this
    ///      comment claimed the assertion existed when it did not - the reviewer was right to call that out.
    function test_crvUsdUsdc_gauge_assetFilter() public view {
        uint256 staked = _gaugeBalance(CRVUSD_USDC_GAUGE, CRVUSD_USDC_STAKER);
        assertGt(staked, 0, "fixture holds no gauge stake at FORK_BLOCK - re-fixture, do not skip");

        INAVCalculator.PositionBalance[] memory pos =
            gaugesMeta.getAdapterPositionsForInstances(CRVUSD_USDC_STAKER, _gauge(CRVUSD_USDC_GAUGE), USDC);

        assertGt(pos.length, 0, "filtered read returned nothing - the loop below would pass vacuously");

        for (uint256 i; i < pos.length; ++i) {
            assertEq(pos[i].balanceAsset.asset, USDC);
        }
    }

    /// @notice protocolId and positionId are correct on-chain.
    function test_gauge_identity() public view {
        uint256 staked = _gaugeBalance(CRVUSD_USDC_GAUGE, CRVUSD_USDC_STAKER);
        assertGt(staked, 0, "fixture holds no gauge stake at FORK_BLOCK - re-fixture, do not skip");

        INAVCalculator.PositionBalance[] memory pos =
            gaugesMeta.getAdapterPositionsForInstances(CRVUSD_USDC_STAKER, _gauge(CRVUSD_USDC_GAUGE), address(0));

        assertGt(pos.length, 0);
        for (uint256 i; i < pos.length; ++i) {
            assertEq(pos[i].positionId, abi.encode(CRVUSD_USDC_GAUGE));
        }
    }

    /// @notice Emitted positions carry a non-empty leaf label built from on-chain symbols.
    function test_positionLabels_crvUsdUsdc_gauge() public view {
        uint256 staked = _gaugeBalance(CRVUSD_USDC_GAUGE, CRVUSD_USDC_STAKER);
        // Historical note: this used to take a graceful skip when gauge staker currently holds 0 (position exited), so a hard non-zero
        // assert would red CI on a stale pin. Pinned holders are refreshed via the integration-snapshot
        // process, failing here is now how a stale fixture is surfaced. (Copilot PR #127.)
        assertGt(staked, 0, "fixture holds no gauge stake at FORK_BLOCK - re-fixture, do not skip");

        INAVCalculator.PositionBalance[] memory pos =
            gaugesMeta.getAdapterPositionsForInstances(CRVUSD_USDC_STAKER, _gauge(CRVUSD_USDC_GAUGE), address(0));
        assertGt(pos.length, 0);
        string[] memory labels = gaugesMeta.positionLabels(pos[0].positionId);
        assertEq(labels.length, 2);
        assertEq(labels[0], "Staking Gauge");
        assertGt(bytes(labels[1]).length, 0);
    }

    function test_positionLabels_threepool() public view {
        uint256 walletLp = _lpBalance(THREEPOOL_LP, THREEPOOL_HOLDER);
        // Historical note: this used to take a graceful skip when 3pool holder currently holds 0 LP (exited), so a hard non-zero assert
        // would red CI on a stale pin. Pinned holders are refreshed via the integration-snapshot process,
        // failing here is now how a stale fixture is surfaced. (Copilot PR #127.)
        assertGt(walletLp, 0, "fixture holds no LP at FORK_BLOCK - re-fixture, do not skip");

        // The positionId comes from the instance, not from a leg: legacy-pool LP is deliberately unresolved
        // (see the tripwire on test_threepool_walletLp_decomposes), so there are no legs to read it from.
        // Labels do not depend on the decomposition, so they are still worth asserting.
        string[] memory labels = poolsMeta.positionLabels(abi.encode(THREEPOOL));
        assertEq(labels.length, 2);
        assertEq(labels[0], "AMM Liquidity Pool");
        assertGt(bytes(labels[1]).length, 0);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _pool(address pool) internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(pool)));
    }

    function _gauge(address g) internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(g)));
    }

    function _lpBalance(address pool, address account) internal view returns (uint256) {
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        if (ok && data.length >= 32) return abi.decode(data, (uint256));
        return 0;
    }

    function _gaugeBalance(address g, address account) internal view returns (uint256) {
        (bool ok, bytes memory data) = g.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        if (ok && data.length >= 32) return abi.decode(data, (uint256));
        return 0;
    }

    function _assertAllSupplied(INAVCalculator.PositionBalance[] memory pos) internal pure {
        for (uint256 i; i < pos.length; ++i) {
            assertEq(uint8(pos[i].positionKind), uint8(PositionKind.Supplied));
        }
    }

    function _assertAllValidPositionKinds(INAVCalculator.PositionBalance[] memory pos) internal pure {
        for (uint256 i; i < pos.length; ++i) {
            uint8 k = uint8(pos[i].positionKind);
            assertTrue(k == uint8(PositionKind.Staking) || k == uint8(PositionKind.Rewards));
        }
    }

    function _countKind(INAVCalculator.PositionBalance[] memory pos, PositionKind kind)
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].positionKind == kind) count++;
        }
    }

    /// @notice Verifies that the sum of leg amounts matches the expected pro-rata value.
    ///         Only checks coins present in the `pos` array (registered assets).
    function _assertSumIsProRata(INAVCalculator.PositionBalance[] memory pos, address pool, uint256 walletLp)
        internal
        view
    {
        // Same vacuous class as the callers' old zero-balance skips, one level down: these used to `return`,
        // so a pool that stopped answering `totalSupply()` silently turned every caller's pro-rata check into
        // a no-op while the test still reported green. Assert instead.
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("totalSupply()"));
        assertTrue(ok && data.length >= 32, "pool does not answer totalSupply - cannot verify pro-rata");
        uint256 ts = abi.decode(data, (uint256));
        assertGt(ts, 0, "pool totalSupply is zero - cannot verify pro-rata");

        for (uint256 i; i < pos.length; ++i) {
            address coin = pos[i].balanceAsset.asset;
            // Find coin index in pool
            for (uint256 j; j < 8; ++j) {
                (bool cok, bytes memory cd) = pool.staticcall(abi.encodeWithSignature("coins(uint256)", j));
                if (!cok || cd.length < 32) break; // uint256-indexed pools only; int128 pools never reach here

                address c = abi.decode(cd, (address));
                if (c == address(0)) break;
                if (c == coin) {
                    (bool bok, bytes memory bd) = pool.staticcall(abi.encodeWithSignature("balances(uint256)", j));
                    // The coin already matched, so this is the leg's only amount check. Breaking here would
                    // skip it silently - the same vacuity class this helper was hardened against, one level in.
                    assertTrue(bok && bd.length >= 32, "matched coin has no balances() - cannot verify pro-rata");
                    uint256 poolBal = abi.decode(bd, (uint256));
                    uint256 expected = (poolBal * walletLp) / ts;
                    assertEq(pos[i].amount, expected, "pro-rata amount matches");
                    break;
                }
            }
        }
    }
}
