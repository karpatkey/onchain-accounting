// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {EthenaCooldownBalanceAdapter} from "src/balances/protocols/EthenaCooldownBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal interface for Ethena's StakedUSDeV2 used to seed a cooldown.
interface ISUSDe {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function cooldownShares(uint256 shares) external returns (uint256 assets);
    function cooldowns(address account) external view returns (uint104 cooldownEnd, uint152 underlyingAmount);
    function balanceOf(address account) external view returns (uint256);
}

/// @title EthenaCooldownBalanceAdapterForkTest
/// @notice Fork test against Ethena's StakedUSDeV2 on mainnet.
/// @dev No KPK Safe held a live cooldown at FORK_BLOCK (cooldowns are transient, ~24h), so the test seeds a
///      real cooldown on the fork (deal USDe → deposit → cooldownShares) and asserts the adapter reports the
///      exact `cooldowns(account).underlyingAmount` that StakedUSDeV2 itself records — strict equality, delta 0.
contract EthenaCooldownBalanceAdapterForkTest is BalanceAdapterTestBase {
    address public constant MAINNET_SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address public constant MAINNET_USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;

    uint256 public constant FORK_BLOCK = 25_380_000;

    EthenaCooldownBalanceAdapter public adapter;

    function setUp() public override {
        super.setUp();
        _setupFork();
        balances = _deployBalancesForAdapter(MAINNET_USDE);
        adapter = new EthenaCooldownBalanceAdapter(MAINNET_SUSDE, MAINNET_USDE, address(balances));
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    /// @dev Stakes `usdeAmount` USDe into sUSDe for `holder`, then puts all of it into cooldown.
    ///      Returns the ground-truth `underlyingAmount` StakedUSDeV2 recorded for the cooldown.
    function _seedCooldown(address holder, uint256 usdeAmount) internal returns (uint256 groundTruth) {
        deal(MAINNET_USDE, holder, usdeAmount);
        vm.startPrank(holder);
        IERC20(MAINNET_USDE).approve(MAINNET_SUSDE, usdeAmount);
        ISUSDe(MAINNET_SUSDE).deposit(usdeAmount, holder);
        ISUSDe(MAINNET_SUSDE).cooldownShares(ISUSDe(MAINNET_SUSDE).balanceOf(holder));
        vm.stopPrank();
        (, uint152 underlyingAmount) = ISUSDe(MAINNET_SUSDE).cooldowns(holder);
        return uint256(underlyingAmount);
    }

    // ---- Seeded real-protocol position (strict equality vs cooldowns()) ----

    function test_getAdapterBalanceForAsset_matchesCooldown() public {
        address holder = makeAddr("ethenaHolder");
        uint256 groundTruth = _seedCooldown(holder, 10_000e18);
        assertGt(groundTruth, 0, "seed should record a non-zero cooldown");

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(holder, MAINNET_USDE);
        assertEq(amount, groundTruth, "adapter must equal cooldowns().underlyingAmount exactly");
        assertFalse(isDebt);
    }

    function test_getAdapterPositions_matchesCooldown() public {
        address holder = makeAddr("ethenaHolder");
        uint256 groundTruth = _seedCooldown(holder, 10_000e18);

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(holder, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, MAINNET_USDE);
        assertEq(positions[0].balanceAdapter, address(adapter));
        assertEq(positions[0].amount, groundTruth);
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].protocolId, ProtocolIds.ETHENA_COOLDOWN);
        assertEq(positions[0].positionId.length, 0);
        assertEq(uint8(positions[0].positionKind), uint8(PositionKind.Supplied));
    }

    function test_getAdapterBalances_matchesCooldown() public {
        address holder = makeAddr("ethenaHolder");
        uint256 groundTruth = _seedCooldown(holder, 10_000e18);

        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(holder);
        assertEq(assets.length, 1);
        assertEq(assets[0], MAINNET_USDE);
        assertEq(amounts[0], groundTruth);
        assertFalse(isDebt[0]);
    }

    // ---- Empty / negative cases (real fork, no cooldown) ----

    function test_noCooldown_emptyPositions() public {
        address noone = makeAddr("noone");
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(noone, address(0));
        assertEq(positions.length, 0);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(noone, MAINNET_USDE);
        assertEq(amount, 0);
    }

    function test_zeroAddress() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(address(0), MAINNET_USDE);
        assertEq(amount, 0);
    }
}
