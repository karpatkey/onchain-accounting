// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {AaveUmbrellaBalanceAdapter} from "src/balances/protocols/AaveUmbrellaBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {
    MockErc4626Wrapper,
    MockUmbrellaStakeToken,
    MockAToken,
    MockUmbrellaRewardsController
} from "test/balances/protocols/aaveUmbrella/AaveUmbrellaMocks.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title AaveUmbrellaBalanceAdapterTest
/// @notice Unit tests for the dynamic-discovery AaveUmbrellaBalanceAdapter.
/// @dev The adapter discovers the full Umbrella stake-token set at runtime via
///      `RewardsController.getAllAssets()`. Behaviour against real Mainnet contracts is covered by
///      the fork-test companion in `test/balances/protocols/fork/AaveUmbrella.fork.t.sol`. These
///      unit tests cover the surface that doesn't depend on a live controller: constructor guards,
///      ERC165, and the zero-account / zero-asset early-exit shortcuts (which return empty results
///      before touching the controller, so they work even when the controller is a stub).
contract AaveUmbrellaBalanceAdapterTest is BalanceAdapterTestBase {
    /// @dev Stand-in for the RewardsController. Marked as a contract via deployed bytecode so the
    ///      adapter constructor's `code.length > 0` check passes; its functions are not invoked by
    ///      the early-exit paths exercised here.
    address internal stubRewardsController;

    AaveUmbrellaBalanceAdapter public oracle;

    function setUp() public override {
        super.setUp();
        stubRewardsController = address(new RewardsControllerStub());
        oracle = new AaveUmbrellaBalanceAdapter(stubRewardsController, address(balances));
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    function test_constructor_pinsImmutables() public view {
        assertEq(address(oracle.REWARDS_CONTROLLER()), stubRewardsController);
        assertEq(address(oracle.NAV_CALCULATOR()), address(balances));
        assertEq(oracle.protocolName(), "Aave Umbrella");
    }

    function test_constructor_revertsOnZeroRewardsController() public {
        vm.expectRevert(InvalidArguments.selector);
        new AaveUmbrellaBalanceAdapter(address(0), address(balances));
    }

    function test_constructor_revertsOnZeroNavCalculator() public {
        vm.expectRevert(InvalidArguments.selector);
        new AaveUmbrellaBalanceAdapter(stubRewardsController, address(0));
    }

    function test_constructor_revertsOnNonContractRewardsController() public {
        vm.expectRevert(); // require message; selector check unnecessary
        new AaveUmbrellaBalanceAdapter(makeAddr("eoa-controller"), address(balances));
    }

    function test_constructor_revertsOnNonContractNavCalculator() public {
        vm.expectRevert(); // require message; selector check unnecessary
        new AaveUmbrellaBalanceAdapter(stubRewardsController, makeAddr("eoa-nav"));
    }

    // ─── Zero-account / zero-asset shortcuts (no controller calls expected) ───

    function test_getAdapterBalanceForAsset_returnsZeroForZeroAccount() public view {
        (uint256 amount, bool isDebt) = oracle.getAdapterBalanceForAsset(address(0), address(usdc));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_returnsZeroForZeroAsset() public view {
        (uint256 amount, bool isDebt) = oracle.getAdapterBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalances_returnsEmptyArraysForZeroAccount() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) =
            oracle.getAdapterBalances(address(0));
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_getAdapterPositions_returnsEmptyArrayForZeroAccount() public view {
        // Zero-account shortcut returns [] before touching NAV_CALCULATOR or the controller.
        assertEq(oracle.getAdapterPositions(address(0), address(0)).length, 0);
    }

    // ─── ERC165 ───────────────────────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(bytes4(0xdeadbeef)));
    }
}

/// @dev Minimal contract stub so `RewardsController.code.length > 0` passes in the constructor.
///      Function selectors are irrelevant for the unit tests above (early-exit paths don't call them).
contract RewardsControllerStub {}

/// @title AaveUmbrellaBalanceMathTest
/// @notice Mock-driven coverage of the balance math that the early-exit unit tests above can't reach:
///         the ERC4626 discovery walk (two-hop `stk → wa → bare` vs one-hop `stk → bare`), reward
///         bare-reserve resolution (aToken `UNDERLYING_ASSET_ADDRESS()` vs a plain token), Staking +
///         Rewards leg emission with the right identity, zero-leg skipping, the assetFilter, and the
///         documented asymmetry where balance methods report an unregistered reserve but
///         getAdapterPositions silently skips it.
/// @dev Conversions: a stake token / wrapper with 1e18-scaled `rate` returns `shares * rate / 1e18`.
contract AaveUmbrellaBalanceMathTest is BalanceAdapterTestBase {
    AaveUmbrellaBalanceAdapter internal oracle;
    MockUmbrellaRewardsController internal controller;

    Mock_ERC20 internal gho;
    Mock_ERC20 internal unreg; // a bare reserve NOT registered on the NAV harness

    MockErc4626Wrapper internal waUsdc; // wa* layer over USDC (forces the two-hop walk)
    MockUmbrellaStakeToken internal stkwaUsdc; // stk → waUsdc → USDC
    MockUmbrellaStakeToken internal stkGho; // stk → GHO (one hop, plain underlying)
    MockUmbrellaStakeToken internal stkUnreg; // stk → unreg (unregistered bare reserve)
    MockAToken internal aUsdc; // reward token resolving to USDC

    // Independently-computed expectations (see _stakedUnderlying walk in the adapter). USDC-denominated
    // values are 6-decimal (matching the usdc mock); GHO is 18-decimal. The mock conversion rates are
    // 1e18-scaled and decimal-agnostic (shares * rate / 1e18), so the reserve's own decimals carry through.
    uint256 internal constant EXP_USDC_STAKED = 1155e6; // 1000e6 * 1.1 (stk) * 1.05 (wa)
    uint256 internal constant EXP_USDC_REWARD = 5e6;
    uint256 internal constant EXP_USDC_TOTAL = 1160e6;
    uint256 internal constant EXP_GHO_STAKED = 2400e18; // 2000e18 * 1.2 (one hop)
    uint256 internal constant EXP_GHO_REWARD = 10e18;
    uint256 internal constant EXP_GHO_TOTAL = 2410e18;
    uint256 internal constant EXP_UNREG_TOTAL = 500e18; // 500e18 * 1.0, no rewards (UNREG mock is 18-dec)

    function setUp() public override {
        super.setUp(); // registers usdc/dai/weth on the harness
        gho = _createAndRegisterToken("GHO", 18);
        unreg = new Mock_ERC20("UNREG", 18); // deliberately NOT registered

        waUsdc = new MockErc4626Wrapper(address(usdc), 1.05e18);
        stkwaUsdc = new MockUmbrellaStakeToken(address(waUsdc), 1.1e18, "stkwaUSDC.v1");
        stkGho = new MockUmbrellaStakeToken(address(gho), 1.2e18, "stkGHO.v1");
        stkUnreg = new MockUmbrellaStakeToken(address(unreg), 1e18, "stkUNREG.v1");
        aUsdc = new MockAToken(address(usdc));

        controller = new MockUmbrellaRewardsController();
        controller.addStakeToken(address(stkwaUsdc));
        controller.addStakeToken(address(stkGho));
        controller.addStakeToken(address(stkUnreg));

        oracle = new AaveUmbrellaBalanceAdapter(address(controller), address(balances));

        // alice holds all three stake tokens, with rewards on the two registered ones.
        stkwaUsdc.setBalance(alice, 1000e6); // 6-dec USDC shares
        stkGho.setBalance(alice, 2000e18);
        stkUnreg.setBalance(alice, 500e18);
        controller.setRewards(address(stkwaUsdc), alice, _arr1(address(aUsdc)), _amt1(EXP_USDC_REWARD));
        controller.setRewards(address(stkGho), alice, _arr1(address(gho)), _amt1(EXP_GHO_REWARD));
        // stkUnreg: no rewards configured for alice.

        // bob holds only stkGHO and has NO rewards (covers the zero-reward-leg skip).
        stkGho.setBalance(bob, 2000e18);
    }

    // ─── discovery / dedup ────────────────────────────────────────────────────

    function test_underlyingAssetsSupported_resolvesEachStakeTokenToItsBareReserve() public view {
        address[] memory list = oracle.underlyingAssetsSupported();
        // Three distinct bare reserves resolved: USDC (two-hop), GHO (one-hop), UNREG (one-hop).
        // underlyingAssetsSupported does NOT filter by NAV registration, so UNREG appears here.
        assertEq(list.length, 3, "expected three resolved bare reserves");
        assertTrue(_has(list, address(usdc)), "USDC bare reserve missing (two-hop walk regressed)");
        assertTrue(_has(list, address(gho)), "GHO bare reserve missing");
        assertTrue(_has(list, address(unreg)), "UNREG bare reserve missing");
    }

    function test_underlyingAssetsSupported_dedupesSharedReserve() public {
        // Two stake tokens resolving to the same bare reserve collapse to one entry.
        MockUmbrellaStakeToken stkwaUsdc2 = new MockUmbrellaStakeToken(address(waUsdc), 1e18, "stkwaUSDC2.v1");
        MockUmbrellaRewardsController c = new MockUmbrellaRewardsController();
        c.addStakeToken(address(stkwaUsdc));
        c.addStakeToken(address(stkwaUsdc2));
        AaveUmbrellaBalanceAdapter o = new AaveUmbrellaBalanceAdapter(address(c), address(balances));
        address[] memory list = o.underlyingAssetsSupported();
        assertEq(list.length, 1, "two stake tokens over USDC should dedupe to one reserve");
        assertEq(list[0], address(usdc));
    }

    // ─── balance math (staked + rewards) ───────────────────────────────────────

    function test_getAdapterBalanceForAsset_sumsStakedPlusRewards_twoHop() public view {
        (uint256 amount, bool isDebt) = oracle.getAdapterBalanceForAsset(alice, address(usdc));
        assertEq(amount, EXP_USDC_TOTAL, "USDC = two-hop staked + aToken reward");
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_sumsStakedPlusRewards_oneHop() public view {
        (uint256 amount,) = oracle.getAdapterBalanceForAsset(alice, address(gho));
        assertEq(amount, EXP_GHO_TOTAL, "GHO = one-hop staked + plain-token reward");
    }

    function test_getAdapterBalanceForAsset_reportsUnregisteredReserve() public view {
        // Balance methods do NOT gate on NAV registration (only getAdapterPositions does).
        (uint256 amount,) = oracle.getAdapterBalanceForAsset(alice, address(unreg));
        assertEq(amount, EXP_UNREG_TOTAL, "unregistered bare reserve still summed by balance methods");
    }

    function test_getAdapterBalances_oneEntryPerReserve() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getAdapterBalances(alice);
        assertEq(assets.length, 3, "alice has three distinct underlyings");
        assertEq(_amountFor(assets, amounts, address(usdc)), EXP_USDC_TOTAL);
        assertEq(_amountFor(assets, amounts, address(gho)), EXP_GHO_TOTAL);
        assertEq(_amountFor(assets, amounts, address(unreg)), EXP_UNREG_TOTAL);
        for (uint256 i; i < isDebt.length; ++i) {
            assertFalse(isDebt[i]);
        }
    }

    function test_getAdapterBalances_dedupesWhenTwoStakeTokensShareReserve() public {
        MockUmbrellaStakeToken stkwaUsdc2 = new MockUmbrellaStakeToken(address(waUsdc), 1e18, "stkwaUSDC2.v1");
        MockUmbrellaRewardsController c = new MockUmbrellaRewardsController();
        c.addStakeToken(address(stkwaUsdc));
        c.addStakeToken(address(stkwaUsdc2));
        AaveUmbrellaBalanceAdapter o = new AaveUmbrellaBalanceAdapter(address(c), address(balances));
        stkwaUsdc.setBalance(alice, 1000e6); // → 1155e6 USDC
        stkwaUsdc2.setBalance(alice, 100e6); // → 100e6 * 1.05 = 105e6 USDC
        c.setRewards(address(stkwaUsdc), alice, _arr1(address(aUsdc)), _amt1(EXP_USDC_REWARD));

        (address[] memory assets, uint256[] memory amounts,) = o.getAdapterBalances(alice);
        assertEq(assets.length, 1, "shared reserve collapses to one entry");
        assertEq(assets[0], address(usdc));
        assertEq(amounts[0], EXP_USDC_STAKED + 105e6 + EXP_USDC_REWARD, "summed across both stake tokens");
    }

    // ─── position emission / identity ───────────────────────────────────────────

    function test_getAdapterPositions_emitsStakingAndRewardsLegsWithIdentity() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getAdapterPositions(alice, address(0));
        // USDC Staking + USDC Rewards + GHO Staking + GHO Rewards = 4 (UNREG skipped, unregistered).
        assertEq(positions.length, 4, "expected 4 legs across the two registered reserves");

        bool usdcStaking;
        bool usdcRewards;
        bool ghoStaking;
        bool ghoRewards;
        for (uint256 i; i < positions.length; ++i) {
            INAVCalculator.PositionBalance memory p = positions[i];
            assertEq(p.protocolId, ProtocolIds.AAVE_V3_UMBRELLA, "protocolId == aave-v3-umbrella");
            assertEq(p.balanceAdapter, address(oracle), "balanceAdapter == adapter");
            assertFalse(p.isDebt, "umbrella legs are never debt");

            if (p.balanceAsset.asset == address(usdc) && p.positionKind == PositionKind.Staking) {
                assertEq(p.amount, EXP_USDC_STAKED);
                assertEq(abi.decode(p.positionId, (address)), address(stkwaUsdc), "positionId == stake token");
                usdcStaking = true;
            } else if (p.balanceAsset.asset == address(usdc) && p.positionKind == PositionKind.Rewards) {
                assertEq(p.amount, EXP_USDC_REWARD);
                assertEq(abi.decode(p.positionId, (address)), address(stkwaUsdc));
                usdcRewards = true;
            } else if (p.balanceAsset.asset == address(gho) && p.positionKind == PositionKind.Staking) {
                assertEq(p.amount, EXP_GHO_STAKED);
                assertEq(abi.decode(p.positionId, (address)), address(stkGho));
                ghoStaking = true;
            } else if (p.balanceAsset.asset == address(gho) && p.positionKind == PositionKind.Rewards) {
                assertEq(p.amount, EXP_GHO_REWARD);
                assertEq(abi.decode(p.positionId, (address)), address(stkGho));
                ghoRewards = true;
            }
        }
        assertTrue(usdcStaking && usdcRewards, "missing a USDC leg");
        assertTrue(ghoStaking && ghoRewards, "missing a GHO leg");
    }

    function test_getAdapterPositions_skipsUnregisteredReserve() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getAdapterPositions(alice, address(0));
        for (uint256 i; i < positions.length; ++i) {
            assertTrue(
                positions[i].balanceAsset.asset != address(unreg), "unregistered reserve must not emit a position"
            );
        }
    }

    function test_getAdapterPositions_skipsZeroRewardLeg() public view {
        // bob has staked GHO but no rewards → exactly one (Staking) leg, no Rewards leg.
        INAVCalculator.PositionBalance[] memory positions = oracle.getAdapterPositions(bob, address(0));
        assertEq(positions.length, 1, "no-reward holder should emit only the Staking leg");
        assertEq(uint8(positions[0].positionKind), uint8(PositionKind.Staking));
        assertEq(positions[0].balanceAsset.asset, address(gho));
        assertEq(positions[0].amount, EXP_GHO_STAKED);
    }

    function test_getAdapterPositions_assetFilter_restrictsToReserve() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getAdapterPositions(alice, address(gho));
        assertEq(positions.length, 2, "GHO filter -> Staking + Rewards only");
        for (uint256 i; i < positions.length; ++i) {
            assertEq(positions[i].balanceAsset.asset, address(gho));
        }
    }

    // ─── helpers ────────────────────────────────────────────────────────────────

    function _arr1(address a) private pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _amt1(uint256 v) private pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = v;
    }

    function _has(address[] memory arr, address needle) private pure returns (bool) {
        for (uint256 i; i < arr.length; ++i) {
            if (arr[i] == needle) return true;
        }
        return false;
    }

    function _amountFor(address[] memory assets, uint256[] memory amounts, address needle)
        private
        pure
        returns (uint256)
    {
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == needle) return amounts[i];
        }
        return type(uint256).max; // sentinel: not found → fails the equality assertion
    }
}
