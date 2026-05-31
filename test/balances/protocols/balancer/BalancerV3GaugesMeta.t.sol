// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BalancerV3GaugesMetaBalanceOracle} from "src/balances/protocols/balancer/BalancerV3GaugesMeta.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IMetaBalanceOracleAdapter} from "src/balances/IMetaBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MockStablePool, MockBalToken, MockBalancerMinter, MockBalancerGauge} from "./BalancerMetaMocks.sol";

/// @title BalancerV3GaugesMetaBalanceOracle unit tests (no fork)
/// @notice Exercises the meta-framework behaviour, the staked-BPT pool-share Staking legs, and the extra-reward
///         Rewards legs. BAL claimable relies on the gauge inflation surface (omitted by the mock → reverts → 0),
///         so the BAL leg is fork-tested; here only the extra reward token produces a Rewards leg.
contract BalancerV3GaugesMetaBalanceOracleTest is Test {
    using Strings for address;

    Mock_NAVCalculator nav;
    BalancerV3GaugesMetaBalanceOracle oracle;

    MockBalToken tokenX;
    MockBalToken tokenY;
    MockBalToken bal;
    MockBalToken extraReward;
    MockStablePool pool;
    MockBalancerMinter minter;
    MockBalancerGauge gauge;

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        tokenX = new MockBalToken("X", 18);
        tokenY = new MockBalToken("Y", 18);
        bal = new MockBalToken("BAL", 18);
        extraReward = new MockBalToken("RWD", 18);
        nav.registerAsset(address(tokenX), 18, "X");
        nav.registerAsset(address(tokenY), 18, "Y");
        nav.registerAsset(address(bal), 18, "BAL");
        nav.registerAsset(address(extraReward), 18, "RWD");

        pool = new MockStablePool("rETH/WETH BPT");
        pool.addToken(address(tokenX), 100e18, 1, 1e18);
        pool.addToken(address(tokenY), 200e18, 1, 1e18);
        pool.setTotalSupply(1000e18);

        minter = new MockBalancerMinter(address(bal));
        gauge = new MockBalancerGauge(address(pool));
        gauge.addRewardToken(address(extraReward));

        oracle = new BalancerV3GaugesMetaBalanceOracle(address(minter), "Balancer V3", address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(gauge))));
    }

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IMetaBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    function test_noArgMethods_returnEmpty() public {
        gauge.setBalance(alice, 100e18);
        assertEq(oracle.getOraclePositions(alice, address(0)).length, 0);
        assertEq(oracle.underlyingAssetsSupported().length, 0);
    }

    function test_stakingLegs_plusExtraReward() public {
        gauge.setBalance(alice, 100e18); // 10% of supply staked
        gauge.setClaimable(alice, address(extraReward), 7e18);

        INAVCalculator.PositionBalance[] memory pos =
            oracle.getOraclePositionsForInstances(alice, _instances(), address(0));

        assertEq(pos.length, 3, "two Staking legs + one Rewards leg (BAL is 0 in unit test)");

        // Staking legs (staked-BPT share of each pool token)
        assertEq(pos[0].underlyingAsset.asset, address(tokenX));
        assertEq(pos[0].amount, 10e18);
        assertEq(pos[0].positionId, address(gauge).toHexString());
        assertEq(
            pos[0].positionDetail,
            "{\"protocol\":\"Balancer V3\",\"product\":\"LP\",\"name\":\"rETH/WETH BPT\",\"type\":\"Staking\"}"
        );
        assertEq(pos[1].underlyingAsset.asset, address(tokenY));
        assertEq(pos[1].amount, 20e18);

        // Rewards leg (extra reward token)
        assertEq(pos[2].underlyingAsset.asset, address(extraReward));
        assertEq(pos[2].amount, 7e18);
        assertFalse(pos[2].isDebt);
        assertEq(
            pos[2].positionDetail,
            "{\"protocol\":\"Balancer V3\",\"product\":\"LP\",\"name\":\"rETH/WETH BPT\",\"type\":\"Rewards\"}"
        );
    }

    function test_noStake_onlyRewards() public {
        // No staked BPT, but an outstanding reward balance still reports.
        gauge.setClaimable(alice, address(extraReward), 3e18);
        INAVCalculator.PositionBalance[] memory pos =
            oracle.getOraclePositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 1);
        assertEq(pos[0].underlyingAsset.asset, address(extraReward));
        assertEq(pos[0].amount, 3e18);
    }

    function test_emptyAccount_empty() public view {
        assertEq(oracle.getOraclePositionsForInstances(alice, _instances(), address(0)).length, 0);
    }

    function test_assetFilter_onlyStakingToken() public {
        gauge.setBalance(alice, 100e18);
        gauge.setClaimable(alice, address(extraReward), 7e18);
        INAVCalculator.PositionBalance[] memory pos =
            oracle.getOraclePositionsForInstances(alice, _instances(), address(tokenX));
        assertEq(pos.length, 1);
        assertEq(pos[0].underlyingAsset.asset, address(tokenX));
        assertEq(pos[0].amount, 10e18);
    }

    function test_unregisteredReward_skipped() public {
        nav.unregisterAssetHelper(address(extraReward));
        gauge.setBalance(alice, 100e18);
        gauge.setClaimable(alice, address(extraReward), 7e18);
        INAVCalculator.PositionBalance[] memory pos =
            oracle.getOraclePositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 2, "only the two registered Staking legs survive");
        assertEq(pos[0].underlyingAsset.asset, address(tokenX));
        assertEq(pos[1].underlyingAsset.asset, address(tokenY));
    }

    function test_badInstance_isolated() public {
        gauge.setBalance(alice, 100e18);
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead))));
        ins[1] = bytes32(uint256(uint160(address(gauge))));
        INAVCalculator.PositionBalance[] memory pos = oracle.getOraclePositionsForInstances(alice, ins, address(0));
        assertEq(pos.length, 2, "bad gauge isolated, good gauge staking legs returned");
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory assets = oracle.underlyingAssetsSupportedForInstances(_instances());
        // pool tokens (X, Y) + extra reward (RWD) + BAL
        assertEq(assets.length, 4);
        assertEq(assets[0], address(tokenX));
        assertEq(assets[1], address(tokenY));
        assertEq(assets[2], address(extraReward));
        assertEq(assets[3], address(bal));
    }
}
