// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {AaveV3SafetyModuleBalanceAdapter} from "src/balances/BalanceAdapters/AaveV3SafetyModuleBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal StakedTokenV3-shaped mock exposing the cooldown ABI the adapter optionally reads
///         (`stakersCooldowns`, `getCooldownSeconds`, `UNSTAKE_WINDOW`) plus the balance/redeem/rewards
///         getters. `vm.etch`ed onto one Safety Module stake-token constant so the adapter's hardcoded
///         table resolves to this code.
contract MockStakeTokenV3 {
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) private _rewards;
    mapping(address => uint40) private _cdTimestamp;
    mapping(address => uint216) private _cdAmount;
    uint256 private _cooldownSeconds;
    uint256 private _unstakeWindow;
    // NOTE: field initializers don't survive `vm.etch` (only runtime code is copied, not constructor-set
    // storage), so the redeem rate is configured explicitly via `setRate` after etching.
    uint256 private _rateWad;

    function setBalance(address account, uint256 shares) external {
        balanceOf[account] = shares;
    }

    function setRate(uint256 rateWad_) external {
        _rateWad = rateWad_;
    }

    function setRewards(address account, uint256 amount) external {
        _rewards[account] = amount;
    }

    function setCooldown(address account, uint40 ts, uint216 amount) external {
        _cdTimestamp[account] = ts;
        _cdAmount[account] = amount;
    }

    function setWindows(uint256 cooldownSeconds_, uint256 unstakeWindow_) external {
        _cooldownSeconds = cooldownSeconds_;
        _unstakeWindow = unstakeWindow_;
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return (shares * _rateWad) / 1e18;
    }

    function getTotalRewardsBalance(address staker) external view returns (uint256) {
        return _rewards[staker];
    }

    function stakersCooldowns(address account) external view returns (uint40, uint216) {
        return (_cdTimestamp[account], _cdAmount[account]);
    }

    function getCooldownSeconds() external view returns (uint256) {
        return _cooldownSeconds;
    }

    // solhint-disable-next-line func-name-mixedcase
    function UNSTAKE_WINDOW() external view returns (uint256) {
        return _unstakeWindow;
    }
}

/// @title AaveV3SafetyModuleBalanceAdapterTest
/// @notice Unit tests for the hardcoded multi-token AaveV3SafetyModuleBalanceAdapter.
/// @dev The adapter's stake-token addresses are compile-time constants pointing at Mainnet contracts.
///      Without a fork those addresses are EOAs — so any test path that reaches a live
///      `IStakeToken.balanceOf(...)` call must run as a fork test (see the .fork.t.sol companion).
///      Unit tests cover the surface that doesn't touch those externals: constructor guards,
///      ERC165, underlyingAssetsSupported (hardcoded list), and the zero-account / zero-asset
///      shortcuts in the IBalanceAdapter methods.
contract AaveV3SafetyModuleBalanceAdapterTest is BalanceAdapterTestBase {
    AaveV3SafetyModuleBalanceAdapter public adapter;

    function setUp() public override {
        super.setUp();
        adapter = new AaveV3SafetyModuleBalanceAdapter(address(balances));
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    function test_constructor_pinsImmutables() public view {
        assertEq(address(adapter.NAV_CALCULATOR()), address(balances));
    }

    function test_constructor_revertsOnZeroNavCalculator() public {
        vm.expectRevert(InvalidArguments.selector);
        new AaveV3SafetyModuleBalanceAdapter(address(0));
    }

    function test_constructor_revertsOnNonContractNavCalculator() public {
        vm.expectRevert(); // require message; selector check unnecessary
        new AaveV3SafetyModuleBalanceAdapter(makeAddr("eoa"));
    }

    // ─── Hardcoded address table ──────────────────────────────────────────────

    function test_constants_pointAtMainnetAddresses() public view {
        assertEq(adapter.AAVE(), 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9);
        assertEq(adapter.GHO(), 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);
        assertEq(adapter.ABPT(), 0x41A08648C3766F9F9d85598fF102a08f4ef84F84);
        assertEq(adapter.ABPT_V2(), 0x3de27EFa2F1AA663Ae5D458857e731c129069F29);
        assertEq(adapter.STK_AAVE(), 0x4da27a545c0c5B758a6BA100e3a049001de870f5);
        assertEq(adapter.STK_ABPT(), 0xa1116930326D21fB917d5A27F1E9943A9595fb47);
        assertEq(adapter.STK_ABPT_V2(), 0x9eDA81C21C273a82BE9Bbc19B6A6182212068101);
        assertEq(adapter.STK_GHO(), 0x1a88Df1cFe15Af22B3c4c783D4e6F7F9e0C1885d);
    }

    // ─── underlyingAssetsSupported (pure, no external reads) ──────────────────

    function test_underlyingAssetsSupported_returnsFourDeduplicatedAssets() public view {
        // Four stake tokens, all paying AAVE rewards; dedup of (staked ∪ reward) gives:
        // AAVE, GHO, ABPT, ABPT_V2.
        address[] memory list = adapter.underlyingAssetsSupported();
        assertEq(list.length, 4);
        bool sawAave;
        bool sawGho;
        bool sawAbpt;
        bool sawAbptV2;
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == adapter.AAVE()) sawAave = true;
            if (list[i] == adapter.GHO()) sawGho = true;
            if (list[i] == adapter.ABPT()) sawAbpt = true;
            if (list[i] == adapter.ABPT_V2()) sawAbptV2 = true;
        }
        assertTrue(sawAave);
        assertTrue(sawGho);
        assertTrue(sawAbpt);
        assertTrue(sawAbptV2);
    }

    // ─── Zero-account / zero-asset shortcuts ──────────────────────────────────

    function test_getAdapterBalanceForAsset_returnsZeroForZeroAccount() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(address(0), adapter.AAVE());
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_returnsZeroForZeroAsset() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalances_returnsEmptyArraysForZeroAccount() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) =
            adapter.getAdapterBalances(address(0));
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_getAdapterPositions_returnsEmptyArrayForZeroAccount() public view {
        // Zero-account shortcut returns [] before touching NAV_CALCULATOR or any stake token.
        assertEq(adapter.getAdapterPositions(address(0), address(0)).length, 0);
    }

    // ─── ERC165 ───────────────────────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertFalse(adapter.supportsInterface(bytes4(0xdeadbeef)));
    }

    // ─── Cooldown split / isLocked (mocked stake token via vm.etch) ────────────
    //
    // The adapter's stake-token addresses are compile-time constants. We etch a StakedTokenV3-shaped
    // mock onto STK_GHO (staked = GHO, reward = AAVE) and drive getAdapterPositions filtered to GHO so
    // only stkGHO's staked legs are evaluated (the other three constants remain untouched EOAs).

    /// @dev Etch the cooldown mock onto STK_GHO, register GHO so the staked leg counts in NAV, and return a
    ///      handle to drive the etched mock's state.
    function _etchStkGho() internal returns (MockStakeTokenV3 stk) {
        MockStakeTokenV3 impl = new MockStakeTokenV3();
        vm.etch(adapter.STK_GHO(), address(impl).code);
        stk = MockStakeTokenV3(adapter.STK_GHO());
        stk.setRate(1e18); // 1 share = 1 staked token (field initializers don't survive vm.etch)
        balances.addSupportedAssetForTest(adapter.GHO()); // staked token of stkGHO; must be registered to emit
    }

    function test_getAdapterPositions_noCooldown_singleLiveLeg() public {
        MockStakeTokenV3 stk = _etchStkGho();
        stk.setBalance(alice, 1000e18); // no cooldown set → entire balance is live stake
        stk.setWindows(7 days, 2 days);

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, adapter.GHO());
        assertEq(positions.length, 1, "no cooldown -> a single live-stake leg");
        assertEq(positions[0].balanceAsset.asset, adapter.GHO());
        assertEq(uint8(positions[0].positionKind), uint8(PositionKind.Staking));
        assertEq(positions[0].amount, 1000e18);
        assertFalse(positions[0].isLocked, "live stake -> not locked");
        assertEq(positions[0].positionId, abi.encode(adapter.STK_GHO()), "live leg positionId = stake token");
        assertEq(positions[0].protocolId, ProtocolIds.AAVE_V3_SAFETY_MODULE);
    }

    function test_getAdapterPositions_cooldownInWindow_unstakingLegClaimable() public {
        MockStakeTokenV3 stk = _etchStkGho();
        stk.setBalance(alice, 1000e18);
        stk.setWindows(7 days, 2 days);
        // Cooldown over 300 shares; activated 7 days + a bit ago → now inside the unstake window → claimable.
        vm.warp(1_000_000);
        stk.setCooldown(alice, uint40(block.timestamp - 7 days - 1 hours), uint216(300e18));

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, adapter.GHO());
        assertEq(positions.length, 2, "live + unstaking legs");

        uint256 live;
        uint256 unstaking;
        bool sawLive;
        bool sawUnstaking;
        for (uint256 i; i < positions.length; ++i) {
            INAVCalculator.PositionBalance memory p = positions[i];
            assertEq(p.balanceAsset.asset, adapter.GHO());
            assertEq(uint8(p.positionKind), uint8(PositionKind.Staking));
            assertFalse(p.isDebt);
            if (keccak256(p.positionId) == keccak256(abi.encode(adapter.STK_GHO(), uint8(1)))) {
                unstaking = p.amount;
                assertFalse(p.isLocked, "inside the unstake window -> claimable");
                sawUnstaking = true;
            } else {
                assertEq(p.positionId, abi.encode(adapter.STK_GHO()), "live leg positionId");
                live = p.amount;
                assertFalse(p.isLocked, "live stake -> not locked");
                sawLive = true;
            }
        }
        assertTrue(sawLive && sawUnstaking, "both legs present");
        assertEq(live, 700e18, "live = balance - cooldown shares");
        assertEq(unstaking, 300e18, "unstaking = cooldown shares");

        // NAV-total invariance: the two staking legs sum to the full staked principal (rate 1, rewards=0).
        (uint256 agg,) = adapter.getAdapterBalanceForAsset(alice, adapter.GHO());
        assertEq(live + unstaking, agg, "sum of staking legs == aggregate staked balance");
    }

    function test_getAdapterPositions_cooldownCooling_unstakingLegLocked() public {
        MockStakeTokenV3 stk = _etchStkGho();
        stk.setBalance(alice, 1000e18);
        stk.setWindows(7 days, 2 days);
        // Cooldown just activated → unlockStart is in the future → still cooling → unstaking leg locked.
        vm.warp(1_000_000);
        stk.setCooldown(alice, uint40(block.timestamp), uint216(400e18));

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, adapter.GHO());
        assertEq(positions.length, 2);

        bool sawLockedUnstaking;
        for (uint256 i; i < positions.length; ++i) {
            if (keccak256(positions[i].positionId) == keccak256(abi.encode(adapter.STK_GHO(), uint8(1)))) {
                assertTrue(positions[i].isLocked, "still cooling -> unstaking leg locked");
                assertEq(positions[i].amount, 400e18);
                sawLockedUnstaking = true;
            } else {
                assertFalse(positions[i].isLocked, "live leg never locked");
            }
        }
        assertTrue(sawLockedUnstaking, "unstaking leg present and locked");
    }

    function test_getAdapterPositions_cooldownExpiredPastWindow_unstakingLegLocked() public {
        MockStakeTokenV3 stk = _etchStkGho();
        stk.setBalance(alice, 1000e18);
        stk.setWindows(7 days, 2 days);
        // Activated long ago -> past cooldown AND past the unstake window -> re-locked.
        vm.warp(100 days);
        stk.setCooldown(alice, uint40(block.timestamp - 30 days), uint216(250e18));

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, adapter.GHO());
        for (uint256 i; i < positions.length; ++i) {
            if (keccak256(positions[i].positionId) == keccak256(abi.encode(adapter.STK_GHO(), uint8(1)))) {
                assertTrue(positions[i].isLocked, "past the unstake window -> re-locked");
            }
        }
    }
}
