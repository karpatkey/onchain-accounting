// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {EthenaCooldownBalanceAdapter} from "src/balances/BalanceAdapters/EthenaCooldownBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal mock of Ethena's StakedUSDeV2 cooldown record.
/// @dev Mirrors the auto-generated getter for `mapping(address => UserCooldown)` —
///      `cooldowns(addr) → (uint104 cooldownEnd, uint152 underlyingAmount)`.
contract MockStakedUSDe {
    mapping(address => uint104) private _end;
    mapping(address => uint152) private _amount;
    uint24 private _cooldownDuration = 7 days; // non-zero by default (cooldown enabled)

    function setCooldown(address user, uint104 cooldownEnd, uint152 underlyingAmount) external {
        _end[user] = cooldownEnd;
        _amount[user] = underlyingAmount;
    }

    function setCooldownDuration(uint24 d) external {
        _cooldownDuration = d;
    }

    function cooldowns(address user) external view returns (uint104 cooldownEnd, uint152 underlyingAmount) {
        return (_end[user], _amount[user]);
    }

    function cooldownDuration() external view returns (uint24) {
        return _cooldownDuration;
    }
}

/// @title EthenaCooldownBalanceAdapter unit tests
contract EthenaCooldownBalanceAdapterTest is BalanceAdapterTestBase {
    EthenaCooldownBalanceAdapter public adapter;
    MockStakedUSDe public staked;
    Mock_ERC20 public usde;

    function setUp() public override {
        super.setUp();
        staked = new MockStakedUSDe();
        usde = new Mock_ERC20("USDe", 18);
        balances.addSupportedAssetForTest(address(usde));
        adapter = new EthenaCooldownBalanceAdapter(address(staked), address(usde), address(balances));
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroStaked() public {
        vm.expectRevert(InvalidArguments.selector);
        new EthenaCooldownBalanceAdapter(address(0), address(usde), address(balances));
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(InvalidArguments.selector);
        new EthenaCooldownBalanceAdapter(address(staked), address(0), address(balances));
    }

    function test_constructor_revertsWhenStakedNotContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(bytes("StakedUSDeV2 must be a contract"));
        new EthenaCooldownBalanceAdapter(eoa, address(usde), address(balances));
    }

    function test_constructor_revertsWhenNAVNotContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(bytes("NAVCalculator must be a contract"));
        new EthenaCooldownBalanceAdapter(address(staked), address(usde), eoa);
    }

    // ---- Interface ----

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertFalse(adapter.supportsInterface(0xdeadbeef));
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = adapter.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(usde));
    }

    function test_positionLabels() public {
        staked.setCooldown(alice, uint104(block.timestamp + 1 days), 1234e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 1);
        string[] memory labels = positions[0].labels;
        assertEq(labels.length, 1);
        assertEq(labels[0], "Unstaking Cooldown");
    }

    // ---- getAdapterBalanceForAsset ----

    function test_getAdapterBalanceForAsset_zeroAsset() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(usdc));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_zeroAccount() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(address(0), address(usde));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_noCooldownReturnsZero() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(usde));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_activeCooldownReturnsAmount() public {
        staked.setCooldown(alice, uint104(block.timestamp + 1 days), 1234e18);
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(usde));
        assertEq(amount, 1234e18);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_elapsedCooldownStillReported() public {
        // After cooldownEnd the USDe is claimable but still owed until `unstake` zeroes the entry.
        staked.setCooldown(alice, uint104(block.timestamp), 500e18);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(usde));
        assertEq(amount, 500e18);
    }

    // ---- getAdapterBalances ----

    function test_getAdapterBalances_zeroAccount() public view {
        (address[] memory assets,,) = adapter.getAdapterBalances(address(0));
        assertEq(assets.length, 0);
    }

    function test_getAdapterBalances_emptyWhenNoCooldown() public view {
        (address[] memory assets,,) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 0);
    }

    function test_getAdapterBalances_emitsSinglePosition() public {
        staked.setCooldown(alice, uint104(block.timestamp + 1 days), 777e18);
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(usde));
        assertEq(amounts[0], 777e18);
        assertFalse(isDebt[0]);
    }

    // ---- getAdapterPositions ----

    function test_getAdapterPositions_emptyWhenAssetUnregistered() public {
        address unregistered = makeAddr("unregisteredAsset");
        EthenaCooldownBalanceAdapter fresh =
            new EthenaCooldownBalanceAdapter(address(staked), unregistered, address(balances));
        staked.setCooldown(alice, uint104(block.timestamp + 1 days), 1e18);
        INAVCalculator.PositionBalance[] memory positions = fresh.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0, "Unregistered underlying should not produce positions");
    }

    function test_getAdapterPositions_filtersByAsset() public {
        staked.setCooldown(alice, uint104(block.timestamp + 1 days), 1e18);

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(usdc));
        assertEq(positions.length, 0, "Filter mismatch should produce empty");

        positions = adapter.getAdapterPositions(alice, address(usde));
        assertEq(positions.length, 1);
    }

    function test_getAdapterPositions_zeroBalanceProducesEmpty() public view {
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0);
    }

    function test_getAdapterPositions_identity() public {
        staked.setCooldown(alice, uint104(block.timestamp + 1 days), 4242e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, address(usde));
        assertEq(positions[0].balanceAdapter, address(adapter));
        assertEq(positions[0].amount, 4242e18);
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].protocolId, ProtocolIds.ETHENA_COOLDOWN);
        assertEq(
            positions[0].positionId,
            abi.encode(address(adapter.STAKED_USDE())),
            "positionId is the sUSDe anchor for the aggregated cooldown leg"
        );
        assertEq(uint8(positions[0].positionKind), uint8(PositionKind.Supplied));
        // cooldownEnd is in the future → still cooling → locked.
        assertTrue(positions[0].isLocked, "future cooldownEnd -> locked");
    }

    // ---- isLocked status (single leg) ----

    function test_getAdapterPositions_lockedWhileCooling() public {
        // cooldownEnd in the future, cooldown enabled → still cooling → isLocked = true.
        staked.setCooldown(alice, uint104(block.timestamp + 3 days), 100e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].amount, 100e18);
        assertTrue(positions[0].isLocked, "future cooldownEnd -> locked");
    }

    function test_getAdapterPositions_unlockedAfterCooldownElapsed() public {
        // cooldownEnd has passed → claimable now → isLocked = false. The amount is still owed until claimed.
        vm.warp(1_000_000);
        staked.setCooldown(alice, uint104(block.timestamp - 1), 250e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].amount, 250e18);
        assertFalse(positions[0].isLocked, "elapsed cooldownEnd -> claimable -> not locked");
    }

    function test_getAdapterPositions_unlockedWhenCooldownDisabled() public {
        // cooldownDuration == 0 disables the cooldown (instant withdraw) → isLocked = false even if cooldownEnd
        // is in the future. The single leg's amount is unchanged (NAV-total invariance vs the balance methods).
        staked.setCooldownDuration(0);
        staked.setCooldown(alice, uint104(block.timestamp + 5 days), 999e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].amount, 999e18);
        assertFalse(positions[0].isLocked, "cooldownDuration == 0 -> instant withdraw -> not locked");
        // NAV-total invariance: the single leg equals the aggregate balance.
        (uint256 agg,) = adapter.getAdapterBalanceForAsset(alice, address(usde));
        assertEq(positions[0].amount, agg, "leg amount == aggregate balance");
    }
}
