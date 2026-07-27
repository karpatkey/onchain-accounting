// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {
    BalancerV3GaugesMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/balancer/BalancerV3GaugesMetaBalanceAdapter.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MockStablePool, MockBalToken, MockBalancerMinter, MockBalancerGauge} from "./BalancerMetaMocks.sol";

/// @title BalancerV3GaugesMetaBalanceAdapter unit tests (no fork)
/// @notice Exercises the meta-framework behaviour, the staked-BPT pool-share Staking legs, and the extra-reward
///         Rewards legs. BAL claimable relies on the gauge inflation surface (omitted by the mock → reverts → 0),
///         so the BAL leg is fork-tested; here only the extra reward token produces a Rewards leg.
contract BalancerV3GaugesMetaBalanceAdapterTest is Test {
    using Strings for address;

    Mock_NAVCalculator nav;
    BalancerV3GaugesMetaBalanceAdapter adapter;

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

        adapter = new BalancerV3GaugesMetaBalanceAdapter(address(minter), address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(gauge))));
    }

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_noArgMethods_returnEmpty() public {
        gauge.setBalance(alice, 100e18);
        assertEq(adapter.getAdapterPositions(alice, address(0)).length, 0);
        assertEq(adapter.underlyingAssetsSupported().length, 0);
    }

    function test_stakingLegs_plusExtraReward() public {
        gauge.setBalance(alice, 100e18); // 10% of supply staked
        gauge.setClaimable(alice, address(extraReward), 7e18);

        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));

        assertEq(pos.length, 3, "two Staking legs + one Rewards leg (BAL is 0 in unit test)");

        // Staking legs (staked-BPT share of each pool token)
        assertEq(pos[0].balanceAsset.asset, address(tokenX));
        assertEq(pos[0].amount, 10e18);
        assertEq(pos[0].positionId, abi.encode(address(gauge)));
        assertEq(pos[1].balanceAsset.asset, address(tokenY));
        assertEq(pos[1].amount, 20e18);

        // Rewards leg (extra reward token)
        assertEq(pos[2].balanceAsset.asset, address(extraReward));
        assertEq(pos[2].amount, 7e18);
        assertFalse(pos[2].isDebt);
    }

    function test_noStake_onlyRewards() public {
        // No staked BPT, but an outstanding reward balance still reports.
        gauge.setClaimable(alice, address(extraReward), 3e18);
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 1);
        assertEq(pos[0].balanceAsset.asset, address(extraReward));
        assertEq(pos[0].amount, 3e18);
    }

    function test_emptyAccount_empty() public view {
        assertEq(adapter.getAdapterPositionsForInstances(alice, _instances(), address(0)).length, 0);
    }

    function test_assetFilter_onlyStakingToken() public {
        gauge.setBalance(alice, 100e18);
        gauge.setClaimable(alice, address(extraReward), 7e18);
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(tokenX));
        assertEq(pos.length, 1);
        assertEq(pos[0].balanceAsset.asset, address(tokenX));
        assertEq(pos[0].amount, 10e18);
    }

    function test_unregisteredReward_skipped() public {
        nav.unregisterAssetHelper(address(extraReward));
        gauge.setBalance(alice, 100e18);
        gauge.setClaimable(alice, address(extraReward), 7e18);
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 2, "only the two registered Staking legs survive");
        assertEq(pos[0].balanceAsset.asset, address(tokenX));
        assertEq(pos[1].balanceAsset.asset, address(tokenY));
    }

    function test_badInstance_isolated() public {
        gauge.setBalance(alice, 100e18);
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead))));
        ins[1] = bytes32(uint256(uint160(address(gauge))));
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(pos.length, 2, "bad gauge isolated, good gauge staking legs returned");
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory assets = adapter.underlyingAssetsSupportedForInstances(_instances());
        // pool tokens (X, Y) + extra reward (RWD) + BAL
        assertEq(assets.length, 4);
        assertEq(assets[0], address(tokenX));
        assertEq(assets[1], address(tokenY));
        assertEq(assets[2], address(extraReward));
        assertEq(assets[3], address(bal));
    }

    /// @dev `positionLabels` is display-only and must never revert, and must never label a coordinate this adapter
    ///      never emitted. Both were reachable before: `abi.decode(pid, (address))` reverts on a word with dirty
    ///      upper 96 bits, and a `pid.length < 32` guard let a foreign MULTI-word coordinate through to be labelled
    ///      from its first word. The decode now goes through `MetaBalanceAdapter._pidAddress`, whose own accept window is
    ///      pinned exhaustively in `test/balances/MetaBalanceAdapterPidGuards.t.sol`; this case pins that THIS
    ///      adapter routes through it.
    ///
    ///      The clean-coordinate assertion is what keeps the rest load-bearing. A shape-valid but unknown
    ///      coordinate still resolves to the category-only label (the fail-open leaf collapse), so a view that
    ///      rejected everything would fail here rather than pass the rejections trivially.

    function test_positionLabels_malformedPositionId_returnsEmpty() public view {
        address coord = address(0xBEEF);

        assertGt(adapter.positionLabels(abi.encode(coord)).length, 0, "one clean word is the accepted shape");

        assertEq(adapter.positionLabels("").length, 0, "empty");
        assertEq(adapter.positionLabels(hex"0102030405060708090a0b0c").length, 0, "truncated");
        uint256 dirty = uint256(uint160(coord)) | (uint256(1) << 255);
        assertEq(adapter.positionLabels(abi.encode(dirty)).length, 0, "dirty upper bits");
        assertEq(adapter.positionLabels(abi.encode(coord, uint256(1))).length, 0, "over-long");
    }
}
