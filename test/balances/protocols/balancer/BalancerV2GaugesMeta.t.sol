// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BalancerV2GaugesMetaBalanceAdapter} from "src/balances/protocols/balancer/BalancerV2GaugesMeta.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IMetaBalanceOracleAdapter} from "src/balances/IMetaBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MockBalToken, MockBalancerMinter, MockBalancerGauge} from "./BalancerMetaMocks.sol";
import {MockV2Vault, MockV2Pool} from "./BalancerV2MetaMocks.sol";

/// @title BalancerV2GaugesMetaBalanceAdapter unit tests (no fork)
/// @notice Exercises the meta-framework behaviour, the staked-BPT pro-rata math (via a mock V2 Vault), and the
///         extra-reward-token legs. The mock gauge omits the inflation surface, so claimable BAL is caught and
///         yields 0 (BAL leg skipped) — the real BAL inflation math is identical to BalancerV3GaugesMeta and is
///         fork-tested there. The instance coordinate is the gauge address (widened to bytes32).
contract BalancerV2GaugesMetaBalanceAdapterTest is Test {
    using Strings for address;

    Mock_NAVCalculator nav;
    MockV2Vault vault;
    MockV2Pool pool;
    MockBalancerMinter minter;
    MockBalancerGauge gauge;
    BalancerV2GaugesMetaBalanceAdapter adapter;

    MockBalToken tokenX;
    MockBalToken tokenY;
    MockBalToken bal;
    MockBalToken reward;

    bytes32 poolId = bytes32(uint256(0xabc123));

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        tokenX = new MockBalToken("X", 18);
        tokenY = new MockBalToken("Y", 18);
        bal = new MockBalToken("BAL", 18);
        reward = new MockBalToken("RWD", 18);
        nav.registerAsset(address(tokenX), 18, "X");
        nav.registerAsset(address(tokenY), 18, "Y");
        nav.registerAsset(address(bal), 18, "BAL");
        nav.registerAsset(address(reward), 18, "RWD");

        vault = new MockV2Vault();
        pool = new MockV2Pool("B-50X-50Y", poolId);
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenX);
        tokens[1] = address(tokenY);
        uint256[] memory balances = new uint256[](2);
        balances[0] = 1000e18;
        balances[1] = 2000e18;
        vault.setPool(poolId, tokens, balances);
        pool.setTotalSupply(1000e18);

        minter = new MockBalancerMinter(address(bal));
        gauge = new MockBalancerGauge(address(pool));

        adapter = new BalancerV2GaugesMetaBalanceAdapter(address(vault), address(minter), "Balancer V2", address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(gauge))));
    }

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IMetaBalanceOracleAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_noArgMethods_returnEmpty() public view {
        assertEq(adapter.getOraclePositions(alice, address(0)).length, 0);
        assertEq(adapter.underlyingAssetsSupported().length, 0);
    }

    function test_stakingLegs_proRata() public {
        gauge.setBalance(alice, 100e18); // 10% of supply

        INAVCalculator.PositionBalance[] memory pos =
            adapter.getOraclePositionsForInstances(alice, _instances(), address(0));

        assertEq(pos.length, 2, "one Staking leg per pool token (BAL=0, no extra rewards)");

        assertEq(pos[0].underlyingAsset.asset, address(tokenX));
        assertEq(pos[0].amount, 100e18); // 1000e18 * 100e18 / 1000e18
        assertEq(pos[0].positionId, address(gauge).toHexString());
        assertEq(
            pos[0].positionDetail,
            "{\"protocol\":\"Balancer V2\",\"product\":\"LP\",\"name\":\"B-50X-50Y\",\"type\":\"Staking\"}"
        );
        assertEq(pos[1].underlyingAsset.asset, address(tokenY));
        assertEq(pos[1].amount, 200e18);
    }

    function test_extraRewardLeg() public {
        gauge.setBalance(alice, 100e18);
        gauge.addRewardToken(address(reward));
        gauge.setClaimable(alice, address(reward), 7e18);

        INAVCalculator.PositionBalance[] memory pos =
            adapter.getOraclePositionsForInstances(alice, _instances(), address(0));

        assertEq(pos.length, 3, "2 staking + 1 reward");
        assertEq(pos[2].underlyingAsset.asset, address(reward));
        assertEq(pos[2].amount, 7e18);
        assertEq(
            pos[2].positionDetail,
            "{\"protocol\":\"Balancer V2\",\"product\":\"LP\",\"name\":\"B-50X-50Y\",\"type\":\"Rewards\"}"
        );
    }

    function test_zeroStake_onlyRewards() public {
        gauge.addRewardToken(address(reward));
        gauge.setClaimable(alice, address(reward), 3e18);
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getOraclePositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 1, "no stake -> only the reward leg");
        assertEq(pos[0].underlyingAsset.asset, address(reward));
        assertEq(pos[0].amount, 3e18);
    }

    function test_assetFilter() public {
        gauge.setBalance(alice, 100e18);
        gauge.addRewardToken(address(reward));
        gauge.setClaimable(alice, address(reward), 7e18);
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getOraclePositionsForInstances(alice, _instances(), address(reward));
        assertEq(pos.length, 1);
        assertEq(pos[0].underlyingAsset.asset, address(reward));
    }

    function test_unregisteredReward_skipped() public {
        gauge.setBalance(alice, 100e18);
        gauge.addRewardToken(address(reward));
        gauge.setClaimable(alice, address(reward), 7e18);
        nav.unregisterAssetHelper(address(reward));
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getOraclePositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 2, "unregistered reward dropped, staking legs remain");
    }

    function test_badInstance_isolated() public {
        gauge.setBalance(alice, 100e18);
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead)))); // no code -> reverts internally, isolated
        ins[1] = bytes32(uint256(uint160(address(gauge))));
        INAVCalculator.PositionBalance[] memory pos = adapter.getOraclePositionsForInstances(alice, ins, address(0));
        assertEq(pos.length, 2);
    }

    function test_emptyInstances_returnsEmpty() public view {
        assertEq(adapter.getOraclePositionsForInstances(alice, new bytes32[](0), address(0)).length, 0);
    }

    function test_underlyingAssetsForInstances() public {
        gauge.addRewardToken(address(reward));
        address[] memory assets = adapter.underlyingAssetsSupportedForInstances(_instances());
        // tokenX, tokenY, reward, BAL
        assertEq(assets.length, 4);
        assertEq(assets[0], address(tokenX));
        assertEq(assets[1], address(tokenY));
        assertEq(assets[2], address(reward));
        assertEq(assets[3], address(bal));
    }
}
