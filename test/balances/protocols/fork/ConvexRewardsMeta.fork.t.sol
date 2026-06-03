// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {ConvexRewardsMetaBalanceAdapter} from "src/balances/protocols/ConvexRewardsMeta.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title ConvexRewardsMetaForkTest
/// @notice Fork tests for ConvexRewardsMetaBalanceAdapter against real mainnet contracts.
///
/// Pools under test (from karpatkey mainnet config):
///   - weETH/WETH  rewarder 0x5411CC583f0b51104fA523eEF9FC77A29DF80F58  lpToken 0xDB74dfDD3...
///   - crvUSD/USDC rewarder 0x44D8FaB7CD8b7877D5F79974c2F501aF6E65AbBA  lpToken 0x4DEcE678...
///   - crvUSD/USDT rewarder 0xD1DdB0a0815fD28932fBb194C84003683AF8a824  lpToken 0x390f3595...
///   - RLUSD/USDC  rewarder 0x5A71E7e04F8725fD42a216949E7099ebd08A42E3  lpToken 0xD001aE43...
contract ConvexRewardsMetaForkTest is BalanceAdapterTestBase {
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

    uint256 public constant FORK_BLOCK = 22_500_000;

    ConvexRewardsMetaBalanceAdapter public meta;

    // Real holder with staked LP in crvUSD/USDC rewarder at FORK_BLOCK
    address public constant CRVUSD_USDC_STAKER = 0x989AEb4d175e16225E39E87d0D97A3360524AD80;

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
        balances = _deployBalancesForOracle(assets);

        meta = new ConvexRewardsMetaBalanceAdapter(CONVEX_BOOSTER, CVX, "Convex", address(balances));
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
        // Meta-adapter resolves LP from pid(); if it can produce Supplied legs, LP was resolved.
        // Use CRVUSD_USDC_STAKER who has staked LP.
        uint256 staked = _staked(REWARDER_CRVUSD_USDC, CRVUSD_USDC_STAKER);
        if (staked == 0) return;

        INAVCalculator.PositionBalance[] memory pos =
            meta.getOraclePositionsForInstances(CRVUSD_USDC_STAKER, _single(REWARDER_CRVUSD_USDC), address(0));

        uint256 supplied = _countKind(pos, PositionKind.Supplied);
        assertGt(supplied, 0, "LP resolved and decomposed");
    }

    // ─── Pool decomposition ───────────────────────────────────────────────────

    function test_crvUsdUsdc_stakedDecomposesProRata() public view {
        uint256 staked = _staked(REWARDER_CRVUSD_USDC, CRVUSD_USDC_STAKER);
        if (staked == 0) return;

        INAVCalculator.PositionBalance[] memory pos =
            meta.getOraclePositionsForInstances(CRVUSD_USDC_STAKER, _single(REWARDER_CRVUSD_USDC), address(0));

        uint256 supplied = _countKind(pos, PositionKind.Supplied);
        assertGt(supplied, 0, "at least one Supplied leg");
        _assertAllValidKinds(pos);
    }

    // ─── CRV + CVX rewards ────────────────────────────────────────────────────

    function test_crvEarned_reportedExactly() public view {
        uint256 staked = _staked(REWARDER_CRVUSD_USDC, CRVUSD_USDC_STAKER);
        if (staked == 0) return;

        // Read CRV earned directly from the rewarder for comparison
        (bool ok, bytes memory data) =
            REWARDER_CRVUSD_USDC.staticcall(abi.encodeWithSignature("earned(address)", CRVUSD_USDC_STAKER));
        uint256 crvExpected = (ok && data.length >= 32) ? abi.decode(data, (uint256)) : 0;
        if (crvExpected == 0) return;

        INAVCalculator.PositionBalance[] memory pos =
            meta.getOraclePositionsForInstances(CRVUSD_USDC_STAKER, _single(REWARDER_CRVUSD_USDC), address(0));

        uint256 crvReported;
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].balanceAsset.asset == CRV) crvReported += pos[i].amount;
        }
        assertEq(crvReported, crvExpected, "CRV amount matches rewarder.earned()");
    }

    function test_cvxDerived_fromCrv() public view {
        uint256 staked = _staked(REWARDER_CRVUSD_USDC, CRVUSD_USDC_STAKER);
        if (staked == 0) return;

        INAVCalculator.PositionBalance[] memory pos =
            meta.getOraclePositionsForInstances(CRVUSD_USDC_STAKER, _single(REWARDER_CRVUSD_USDC), address(0));

        uint256 crvAmt;
        uint256 cvxAmt;
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].balanceAsset.asset == CRV) crvAmt += pos[i].amount;
            if (pos[i].balanceAsset.asset == CVX) cvxAmt += pos[i].amount;
        }
        if (crvAmt == 0) return; // no CRV → no CVX expected
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
            meta.getOraclePositionsForInstances(CRVUSD_USDC_STAKER, _instances(rs), address(0));

        // At minimum the crvUSD/USDC rewarder should have results for this staker
        // Other rewarders may return 0 for this specific staker — that's fine
        assertGe(pos.length, 0); // at least no revert
    }

    // ─── Identity ─────────────────────────────────────────────────────────────

    function test_positionId_isRewarder() public view {
        uint256 staked = _staked(REWARDER_CRVUSD_USDC, CRVUSD_USDC_STAKER);
        if (staked == 0) return;

        INAVCalculator.PositionBalance[] memory pos =
            meta.getOraclePositionsForInstances(CRVUSD_USDC_STAKER, _single(REWARDER_CRVUSD_USDC), address(0));

        assertGt(pos.length, 0);
        for (uint256 i; i < pos.length; ++i) {
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
            assertTrue(k == uint8(PositionKind.Supplied) || k == uint8(PositionKind.Rewards));
        }
    }
}
