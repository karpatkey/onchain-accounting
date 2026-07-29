// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    ConvexCurveLPStakingMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/ConvexCurveLPStakingMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title ConvexCurveLPStakingMetaForkTest
/// @notice Fork tests for ConvexCurveLPStakingMetaBalanceAdapter against real mainnet contracts.
///
/// Pools under test (from karpatkey mainnet config):
///   - weETH/WETH  rewarder 0x5411CC583f0b51104fA523eEF9FC77A29DF80F58  lpToken 0xDB74dfDD3...
///   - crvUSD/USDC rewarder 0x44D8FaB7CD8b7877D5F79974c2F501aF6E65AbBA  lpToken 0x4DEcE678...
///   - crvUSD/USDT rewarder 0xD1DdB0a0815fD28932fBb194C84003683AF8a824  lpToken 0x390f3595...
///   - RLUSD/USDC  rewarder 0x5A71E7e04F8725fD42a216949E7099ebd08A42E3  lpToken 0xD001aE43...
contract ConvexCurveLPStakingMetaForkTest is BalanceAdapterTestBase {
    // ── Mainnet constants ─────────────────────────────────────────────────────

    address public constant CONVEX_BOOSTER = 0xF403C135812408BFbE8713b5A23a04b3D48AAE31;
    address public constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address public constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    // Rewarders (BaseRewardPool) — from karpatkey chain config
    address public constant REWARDER_WEETH_WETH = 0x5411CC583f0b51104fA523eEF9FC77A29DF80F58;
    address public constant REWARDER_CRVUSD_USDC = 0x44D8FaB7CD8b7877D5F79974c2F501aF6E65AbBA;
    address public constant REWARDER_CRVUSD_USDT = 0xD1DdB0a0815fD28932fBb194C84003683AF8a824;
    address public constant REWARDER_RLUSD_USDC = 0x5A71E7e04F8725fD42a216949E7099ebd08A42E3;

    // LP tokens (underlying Curve pools, same as CurvePoolsMeta instances)
    address public constant LP_WEETH_WETH = 0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5;
    address public constant LP_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    address public constant LP_CRVUSD_USDT = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address public constant LP_RLUSD_USDC = 0xD001aE433f254283FeCE51d4ACcE8c53263aa186;

    // Registered assets
    address public constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;

    uint256 public constant FORK_BLOCK = 25_600_000;

    ConvexCurveLPStakingMetaBalanceAdapter public meta;

    // Real holder with staked LP in the crvUSD/USDC rewarder at FORK_BLOCK. Position verified live on
    // mainnet across 25,000,000 → 25,630,000 (~47,478 LP, ~637 CRV earned at the pin), so it is a
    // long-lived fixture rather than a transient one. If it ever exits, `test_fixture_isLive` fails
    // LOUDLY — see the note on that test for why this file no longer skips instead.
    address public constant CRVUSD_USDC_STAKER = 0xBf623bA2566BBD0BF8A5eB7ba15cAF16D7CF1b75;

    function setUp() public override {
        super.setUp();
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        address[] memory assets = new address[](9);
        assets[0] = CRV;
        assets[1] = CVX;
        assets[2] = WEETH;
        assets[3] = WETH;
        assets[4] = CRVUSD;
        assets[5] = USDC;
        assets[6] = USDT;
        assets[7] = RLUSD;
        assets[8] = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC duplicate guard
        balances = _deployBalancesForAdapter(assets);

        meta = new ConvexCurveLPStakingMetaBalanceAdapter(CONVEX_BOOSTER, CVX, address(balances));
    }

    function _instances(address[] memory rewarders) internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](rewarders.length);
        for (uint256 i; i < rewarders.length; ++i) {
            ins[i] = bytes32(uint256(uint160(rewarders[i])));
        }
    }

    function _single(address r) internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(r)));
    }

    // ─── LP resolution via Booster ────────────────────────────────────────────

    /// @notice Verifies that the Booster correctly resolves the LP token for each rewarder.
    function test_booster_resolvesLpToken() public view {
        // Meta-adapter resolves LP from pid(); if it can produce Staking legs, LP was resolved.
        // Use CRVUSD_USDC_STAKER who has staked LP.
        uint256 staked = _staked(REWARDER_CRVUSD_USDC, CRVUSD_USDC_STAKER);
        assertGt(staked, 0, "fixture staker must hold staked LP at FORK_BLOCK");

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(CRVUSD_USDC_STAKER, _single(REWARDER_CRVUSD_USDC), address(0));

        uint256 staking = _countKind(pos, PositionKind.Staking);
        assertGt(staking, 0, "LP resolved and decomposed");
    }

    // ─── Pool decomposition ───────────────────────────────────────────────────

    function test_crvUsdUsdc_stakedDecomposesProRata() public view {
        uint256 staked = _staked(REWARDER_CRVUSD_USDC, CRVUSD_USDC_STAKER);
        assertGt(staked, 0, "fixture staker must hold staked LP at FORK_BLOCK");

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(CRVUSD_USDC_STAKER, _single(REWARDER_CRVUSD_USDC), address(0));

        uint256 staking = _countKind(pos, PositionKind.Staking);
        assertGt(staking, 0, "at least one Staking leg");
        _assertAllValidKinds(pos);
    }

    // ─── CRV + CVX rewards ────────────────────────────────────────────────────

    function test_crvEarned_reportedExactly() public view {
        uint256 staked = _staked(REWARDER_CRVUSD_USDC, CRVUSD_USDC_STAKER);
        assertGt(staked, 0, "fixture staker must hold staked LP at FORK_BLOCK");

        // Read CRV earned directly from the rewarder for comparison
        (bool ok, bytes memory data) =
            REWARDER_CRVUSD_USDC.staticcall(abi.encodeWithSignature("earned(address)", CRVUSD_USDC_STAKER));
        uint256 crvExpected = (ok && data.length >= 32) ? abi.decode(data, (uint256)) : 0;
        assertGt(crvExpected, 0, "fixture staker must have earned CRV at FORK_BLOCK");

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(CRVUSD_USDC_STAKER, _single(REWARDER_CRVUSD_USDC), address(0));

        uint256 crvReported;
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].balanceAsset.asset == CRV) crvReported += pos[i].amount;
        }
        assertEq(crvReported, crvExpected, "CRV amount matches rewarder.earned()");
    }

    function test_cvxDerived_fromCrv() public view {
        uint256 staked = _staked(REWARDER_CRVUSD_USDC, CRVUSD_USDC_STAKER);
        assertGt(staked, 0, "fixture staker must hold staked LP at FORK_BLOCK");

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(CRVUSD_USDC_STAKER, _single(REWARDER_CRVUSD_USDC), address(0));

        uint256 crvAmt;
        uint256 cvxAmt;
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].balanceAsset.asset == CRV) crvAmt += pos[i].amount;
            if (pos[i].balanceAsset.asset == CVX) cvxAmt += pos[i].amount;
        }
        assertGt(crvAmt, 0, "adapter must report the earned CRV, which the CVX leg is derived from");
        assertGt(cvxAmt, 0, "CVX derived and > 0 when CRV earned");
    }

    // ─── Multi-instance fan-out ───────────────────────────────────────────────

    function test_allFour_rewarders_fanOut() public view {
        address[] memory rs = new address[](4);
        rs[0] = REWARDER_WEETH_WETH;
        rs[1] = REWARDER_CRVUSD_USDC;
        rs[2] = REWARDER_CRVUSD_USDT;
        rs[3] = REWARDER_RLUSD_USDC;

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(CRVUSD_USDC_STAKER, _instances(rs), address(0));

        // This used to be `assertGe(pos.length, 0)`, which is a tautology — `pos.length` is a uint256, so it
        // could never fail, and the "at least no revert" property it claimed to check is supplied by the call
        // itself. Assert what the fan-out actually has to do: reach the one rewarder this staker uses, and
        // report exactly the legs a single-instance read reports for it, with the other three contributing
        // nothing rather than reverting or duplicating.
        assertGt(pos.length, 0, "the fan-out must surface the staker's crvUSD/USDC legs");

        INAVCalculator.PositionBalance[] memory single =
            meta.getAdapterPositionsForInstances(CRVUSD_USDC_STAKER, _single(REWARDER_CRVUSD_USDC), address(0));
        assertEq(pos.length, single.length, "the three empty rewarders must add no legs");
        for (uint256 i; i < pos.length; ++i) {
            assertEq(pos[i].positionId, abi.encode(REWARDER_CRVUSD_USDC), "every leg belongs to the one rewarder");
        }
    }

    /// @notice The fixture itself, asserted once and loudly.
    /// @dev This file previously guarded every test with `if (staked == 0) return;`. At its old pinned block the
    ///      staker held nothing, so all five staked-gated tests took the early return and the sixth was a
    ///      tautology — the whole file asserted NOTHING while reporting green, for a meta-adapter that is
    ///      deployed on mainnet with a governed instance set. A pinned fixture going stale must fail, not skip:
    ///      a skip is indistinguishable from a pass, and that is precisely how the coverage was lost.
    function test_fixture_isLive() public view {
        assertGt(_staked(REWARDER_CRVUSD_USDC, CRVUSD_USDC_STAKER), 0, "staked LP fixture is stale");
        (bool ok, bytes memory data) =
            REWARDER_CRVUSD_USDC.staticcall(abi.encodeWithSignature("earned(address)", CRVUSD_USDC_STAKER));
        assertTrue(ok && data.length >= 32, "rewarder must answer earned()");
        assertGt(abi.decode(data, (uint256)), 0, "earned-CRV fixture is stale");
    }

    // ─── Identity ─────────────────────────────────────────────────────────────

    function test_positionId_isRewarder() public view {
        uint256 staked = _staked(REWARDER_CRVUSD_USDC, CRVUSD_USDC_STAKER);
        assertGt(staked, 0, "fixture staker must hold staked LP at FORK_BLOCK");

        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(CRVUSD_USDC_STAKER, _single(REWARDER_CRVUSD_USDC), address(0));

        assertGt(pos.length, 0);
        for (uint256 i; i < pos.length; ++i) {
            assertEq(pos[i].protocolSubId, ProtocolIds.CONVEX_CURVE_LP_STAKING);
            assertEq(pos[i].protocolId, ProtocolIds.CONVEX);
            assertEq(pos[i].positionId, abi.encode(REWARDER_CRVUSD_USDC));
        }
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _staked(address rewarder, address account) internal view returns (uint256) {
        (bool ok, bytes memory data) = rewarder.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        return (ok && data.length >= 32) ? abi.decode(data, (uint256)) : 0;
    }

    function _countKind(INAVCalculator.PositionBalance[] memory pos, PositionKind k) internal pure returns (uint256 n) {
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].positionKind == k) n++;
        }
    }

    function _assertAllValidKinds(INAVCalculator.PositionBalance[] memory pos) internal pure {
        for (uint256 i; i < pos.length; ++i) {
            uint8 k = uint8(pos[i].positionKind);
            assertTrue(k == uint8(PositionKind.Staking) || k == uint8(PositionKind.Rewards));
        }
    }
}
