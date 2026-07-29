// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {AaveUmbrellaBalanceAdapter} from "src/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {GasStipendLib} from "src/utils/GasStipendLib.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {
    MockErc4626Wrapper,
    MockUmbrellaStakeToken,
    MockAToken,
    MockUmbrellaRewardsController
} from "test/balances/BalanceAdapters/AaveUmbrellaMocks.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title AaveUmbrellaBalanceAdapterTest
/// @notice Unit tests for the dynamic-discovery AaveUmbrellaBalanceAdapter.
/// @dev The adapter discovers the full Umbrella stake-token set at runtime via
///      `RewardsController.getAllAssets()`. Behaviour against real Mainnet contracts is covered by
///      the fork-test companion in `test/balances/BalanceAdapters/fork/AaveUmbrellaBalanceAdapter.fork.t.sol`. These
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
        // Names the PROTOCOL, not the product — Umbrella is one of Aave V3's products and shares
        // ProtocolIds.AAVE_V3 with the Safety Module and the lending instances. The product is in
        // positionLabels() (asserted below). Cross-adapter invariant: test/ProtocolNameConsistency.t.sol.
        assertEq(oracle.protocolName(), "Aave V3");
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

    // ─── IPositionDescribable ─────────────────────────────────────────────────

    /// @dev Configuration-view probe. A registry consumer describing what the calculator is configured for has no
    ///      positionId to pass, so it can only call `positionLabels("")`. This adapter's breadcrumb is
    ///      positionId-INDEPENDENT, so the probe answers with the constant `["Umbrella Module"]`.
    ///
    ///      positionId-independent is NOT the same as single-shape: the adapter emits
    ///      `positionId = abi.encode(stakeToken)` per Umbrella stake token, so several distinct positionIds share
    ///      this one breadcrumb. Adding a stake-token leaf would be an improvement, not a defect — what this test
    ///      pins is only that the probe never silently collapses to `[]`; per the `_labels` empty-leaf convention
    ///      it must keep returning at least the `"Umbrella Module"` category. A deliberate leaf change should
    ///      relax this assertion, not delete it.
    function test_positionLabels_emptyProbe_returnsTheConstantShape() public view {
        string[] memory labels = oracle.positionLabels("");
        assertEq(labels.length, 1);
        assertEq(labels[0], "Umbrella Module");
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
///         Rewards leg emission with the right identity, zero-leg skipping, the assetFilter, the
///         cooldown-driven locked/unlocked Staking split (`isLocked`), and the documented asymmetry
///         where balance methods report an unregistered reserve but getAdapterPositions silently
///         skips it.
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
            assertEq(p.protocolSubId, ProtocolIds.AAVE_V3_UMBRELLA, "protocolSubId == aave-v3-umbrella");
            assertEq(p.protocolId, ProtocolIds.AAVE_V3);
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

    // ─── cooldown / isLocked split ───────────────────────────────────────────────

    /// @dev bob holds 2000e18 stkGHO (no rewards). Activate a cooldown over part of the balance so the staked
    ///      principal splits into a locked leg (isLocked=true — active stake + any cooling/expired cooldown) and,
    ///      when the cooldown is elapsed-and-in-window, an unlocked leg (isLocked=false). Both legs share
    ///      `positionId = abi.encode(stk)` and are told apart by `isLocked`.
    function test_getAdapterPositions_cooldownActive_inWindow_unlockedLeg() public {
        // Cooldown over 500e18 shares; window currently open → withdrawable → unlocked leg.
        vm.warp(1_000_000);
        stkGho.setCooldown(bob, 500e18, uint32(block.timestamp - 10), uint32(1 days));

        INAVCalculator.PositionBalance[] memory positions = oracle.getAdapterPositions(bob, address(gho));
        assertEq(positions.length, 2, "locked (rest) + unlocked (in-window cooldown) legs (no rewards)");

        bytes memory expectedId = abi.encode(address(stkGho));
        uint256 locked;
        uint256 unlocked;
        bool sawLocked;
        bool sawUnlocked;
        for (uint256 i; i < positions.length; ++i) {
            INAVCalculator.PositionBalance memory p = positions[i];
            assertEq(p.balanceAsset.asset, address(gho));
            assertEq(uint8(p.positionKind), uint8(PositionKind.Staking));
            assertFalse(p.isDebt);
            assertEq(p.positionId, expectedId, "both staking legs share the stake-token positionId");
            if (p.isLocked) {
                locked = p.amount;
                sawLocked = true;
            } else {
                unlocked = p.amount;
                sawUnlocked = true;
            }
        }
        assertTrue(sawLocked && sawUnlocked, "both legs present");
        // 2000e18 shares split 1500 locked + 500 unlocked, each * 1.2 (one hop to GHO).
        assertEq(locked, 1500e18 * 12 / 10, "locked = 1500 shares * 1.2");
        assertEq(unlocked, 500e18 * 12 / 10, "unlocked = 500 shares * 1.2");

        // NAV-total invariance: the two staking legs sum to the full staked principal (= the balance method total).
        (uint256 agg,) = oracle.getAdapterBalanceForAsset(bob, address(gho));
        assertEq(locked + unlocked, agg, "sum of staking legs == aggregate staked balance (no rewards)");
    }

    function test_getAdapterPositions_cooldownActive_cooling_allLocked() public {
        // endOfCooldown in the future → still cooling → entire balance non-withdrawable → a single locked leg.
        vm.warp(1_000_000);
        stkGho.setCooldown(bob, 800e18, uint32(block.timestamp + 2 days), uint32(1 days));

        INAVCalculator.PositionBalance[] memory positions = oracle.getAdapterPositions(bob, address(gho));
        assertEq(positions.length, 1, "cooling cooldown is not withdrawable -> a single locked leg");
        assertEq(positions[0].positionId, abi.encode(address(stkGho)));
        assertTrue(positions[0].isLocked, "still cooling -> locked");
        // Full 2000e18 shares * 1.2 (active stake + cooling cooldown both locked).
        assertEq(positions[0].amount, 2000e18 * 12 / 10, "active stake + cooling cooldown both locked");
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

    // ─── redeemValue's failure paths, through the widest-blast-radius caller ──
    //
    // Both review gates flagged that these were untestable: the wrapper mock's `previewRedeem` always
    // succeeded, and the ERC4626RedeemLib suite wires only MorphoVaultsMetaBalanceAdapter. So the caller the
    // PR itself identifies as the widest blast radius — a PLAIN adapter with no per-stake-token isolation,
    // where `_sharesToUnderlying` runs inline in a loop over `getAllAssets()` — had no assertion on either
    // branch.

    /// @notice An unreadable `previewRedeem` on the wa-wrapper drops that stake token's leg and no other.
    /// @dev The "reports 0, caller treats it as no leg" branch. The GHO stake token takes a different path
    ///      (one hop, no wrapper), so it must be entirely unaffected — that is what proves the omission is
    ///      scoped to the failing token rather than the adapter.
    function test_unreadablePreview_dropsOnlyThatStakeTokensLeg() public {
        waUsdc.setPreviewMode(MockErc4626Wrapper.PreviewMode.Revert);

        INAVCalculator.PositionBalance[] memory pos = oracle.getAdapterPositions(alice, address(0));

        uint256 usdcAmt;
        uint256 ghoAmt;
        for (uint256 i; i < pos.length; ++i) {
            if (pos[i].balanceAsset.asset == address(usdc)) usdcAmt += pos[i].amount;
            if (pos[i].balanceAsset.asset == address(gho)) ghoAmt += pos[i].amount;
        }
        assertEq(usdcAmt, EXP_USDC_REWARD, "only the wrapper-hop STAKING leg is dropped; the reward leg stays");
        assertEq(ghoAmt, EXP_GHO_TOTAL, "the other stake token must be untouched");
    }

    /// @notice An unreadable preview must never fall through to a fee-inclusive or pre-hop figure.
    /// @dev The over-report this guards. `_sharesToUnderlying` computes `convertToAssets(shares)` BEFORE the
    ///      wrapper hop, so a regression that returned that pre-hop value would report waUSDC-denominated
    ///      units (1100e6) under USDC's registered-asset record.
    function test_unreadablePreview_doesNotFallThroughToThePreHopAmount() public {
        waUsdc.setPreviewMode(MockErc4626Wrapper.PreviewMode.Revert);
        (uint256 amount,) = oracle.getAdapterBalanceForAsset(alice, address(usdc));
        assertEq(amount, EXP_USDC_REWARD, "must not report the pre-hop waUSDC amount as USDC");
        assertTrue(amount != 1100e6, "1100e6 is the pre-hop figure - reporting it would over-report");
    }

    /// @notice A STARVED preview takes the whole adapter out LOUDLY, not silently.
    /// @dev This adapter has no per-stake-token isolation, so the blast radius is the whole adapter — that is
    ///      architectural, and acceptable only because it is loud. Measured the way `PriceFeedLib` measures it:
    ///      a starve consumes ~63/64 of the forwarded stipend against a 7/8 threshold, so `GasStipendLib`
    ///      scores it exhausted and the read fails visibly rather than returning a short list.
    function test_starvedPreview_isClassifiedExhaustedAtTheAdapterBoundary() public {
        waUsdc.setPreviewMode(MockErc4626Wrapper.PreviewMode.Starve);

        uint256 available = 4_000_000;
        uint256 stipend = GasStipendLib.stipendFrom(available);
        uint256 before = gasleft();
        try oracle.getAdapterPositions{gas: stipend}(alice, address(0)) returns (
            INAVCalculator.PositionBalance[] memory
        ) {
            fail("a starved preview must not return a partial answer");
        } catch {
            uint256 consumed = before - gasleft();
            assertTrue(
                GasStipendLib.exhausted(stipend, consumed),
                "PriceFeedLib's heuristic must score this exhausted, not benign"
            );
        }
    }

    /// @notice A truncated cooldown reply must not be read as a live cooldown.
    /// @dev PINS the `size < 0x60` arm, which the zero-byte test only REACHED. Review found both arms of
    ///      `if (!ok || size < 0x60)` unpinned by mutation: with a zero-length reply the window is zeroed, so
    ///      `cdAmount == 0` short-circuits and deleting the gate produces an identical answer. This fixture
    ///      answers differently on the arm beneath — word 0 is a full-stake cooldown amount and word 1 is
    ///      `block.timestamp`, so without the gate the adapter infers an in-window cooldown from two words and
    ///      emits an UNLOCKED leg. Reaching an arm is not pinning it.
    function test_truncatedCooldownReply_isRejectedNotReadAsLive() public {
        MockTruncatedCooldownStakeToken trunc = new MockTruncatedCooldownStakeToken(address(gho), 1.2e18);
        MockUmbrellaRewardsController c4 = new MockUmbrellaRewardsController();
        c4.addStakeToken(address(trunc));
        AaveUmbrellaBalanceAdapter o4 = new AaveUmbrellaBalanceAdapter(address(c4), address(balances));
        trunc.setBalance(alice, 2000e18);

        INAVCalculator.PositionBalance[] memory pos = o4.getAdapterPositions(alice, address(0));

        assertEq(pos.length, 1, "a truncated reply must yield ONE leg, not a locked/unlocked split");
        assertTrue(pos[0].isLocked, "and it must be the locked leg");
        assertEq(pos[0].amount, 2400e18, "carrying the full principal");
    }

    /// @notice A REVERTING cooldown read must not have its revert payload read as cooldown data.
    /// @dev PINS the `!ok` arm. `require(false, "no cooldown ABI")` returns an `Error(string)` payload of 100
    ///      bytes, which is >= 0x60 — so the size gate does NOT catch it and `!ok` is the only thing that does.
    ///      Without it the staticcall's output window holds the revert payload, whose first word is a large
    ///      non-zero value that would be read as `cdAmount`, inferring a cooldown from an error. The existing
    ///      cooldown tests never reach this because `setCooldown` enables the ABI.
    function test_revertingCooldownRead_payloadIsNotReadAsCooldownData() public {
        MockUmbrellaStakeToken noAbi = new MockUmbrellaStakeToken(address(gho), 1.2e18, "stkNOABI");
        MockUmbrellaRewardsController c5 = new MockUmbrellaRewardsController();
        c5.addStakeToken(address(noAbi));
        AaveUmbrellaBalanceAdapter o5 = new AaveUmbrellaBalanceAdapter(address(c5), address(balances));
        noAbi.setBalance(alice, 2000e18); // cooldownAbiEnabled stays false -> getStakerCooldown reverts

        INAVCalculator.PositionBalance[] memory pos = o5.getAdapterPositions(alice, address(0));

        assertEq(pos.length, 1, "a reverting cooldown read must yield ONE locked leg");
        assertTrue(pos[0].isLocked);
        assertEq(pos[0].amount, 2400e18, "carrying the full principal");
    }

    /// @notice Dirty padding above the declared field widths must not revert the adapter.
    /// @dev The raw cooldown read replaced a decode of NARROWER types (uint192/uint32/uint32) and so inherited
    ///      the job of range-checking them. Without the mask, `endOfCooldown + withdrawalWindow` runs checked
    ///      arithmetic on unmasked words and panics with Panic(0x11) in the caller's frame — past every
    ///      `catch`, and with no per-stake-token isolation that drops every Umbrella leg from the NAV. Exactly
    ///      the uncatchable-revert class the read was rewritten to remove, reintroduced by the rewrite. Found
    ///      in review with a PoC.
    function test_dirtyCooldownPadding_doesNotRevertTheAdapter() public {
        MockDirtyCooldownStakeToken dirty = new MockDirtyCooldownStakeToken(address(gho), 1.2e18);
        MockUmbrellaRewardsController c3 = new MockUmbrellaRewardsController();
        c3.addStakeToken(address(dirty));
        AaveUmbrellaBalanceAdapter o3 = new AaveUmbrellaBalanceAdapter(address(c3), address(balances));
        dirty.setBalance(alice, 2000e18);

        INAVCalculator.PositionBalance[] memory pos = o3.getAdapterPositions(alice, address(0));

        uint256 total;
        for (uint256 i; i < pos.length; ++i) {
            total += pos[i].amount;
        }
        assertGt(pos.length, 0, "the position must still be reported, not lost to a panic");
        // The masked window is 0xffffffff, so the cooldown is long past and the split is real rather than a
        // degradation — what matters is that the full principal survives either way.
        assertApproxEqAbs(total, 2400e18, 1, "the full principal must be reported");
    }

    /// @notice A stake token whose `getStakerCooldown` SUCCEEDS with zero bytes does not take the adapter down.
    /// @dev The same decode-past-the-catch shape `ERC4626RedeemLib` was rewritten for, three lines away in the
    ///      same call chain: a high-level call expecting return data emits no `extcodesize` check, so an empty
    ///      reply made the struct decode revert in the caller's frame, past the `catch`. With no
    ///      per-stake-token isolation that dropped every Umbrella leg. Found in review.
    function test_emptyCooldownReply_degradesToAllLockedRatherThanRevertingTheAdapter() public {
        MockEmptyCooldownStakeToken broken = new MockEmptyCooldownStakeToken(address(gho), 1.2e18);
        MockUmbrellaRewardsController c2 = new MockUmbrellaRewardsController();
        c2.addStakeToken(address(broken));
        AaveUmbrellaBalanceAdapter o2 = new AaveUmbrellaBalanceAdapter(address(c2), address(balances));
        broken.setBalance(alice, 2000e18);

        INAVCalculator.PositionBalance[] memory pos = o2.getAdapterPositions(alice, address(0));
        assertEq(pos.length, 1, "the position must still be reported");
        assertEq(pos[0].amount, 2400e18, "at its full amount");
        assertTrue(pos[0].isLocked, "and degrade to all-locked, which is classification only");
    }
}

/// @notice A stake token whose cooldown snapshot has DIRTY padding above the declared field widths.
/// @dev `CooldownSnapshot` is `(uint192, uint32, uint32)`, so the ABI decoder range-checked every field. A raw
///      read that skips the mask inherits words the decoder would have rejected — and the window arithmetic is
///      CHECKED, so `endOfCooldown + withdrawalWindow` panics with Panic(0x11) in the CALLER's frame, past every
///      `catch`. `amount = 1` clears the no-cooldown early return and `endOfCooldown = 1` keeps the `&&` from
///      short-circuiting, so the add is actually reached.
contract MockDirtyCooldownStakeToken {
    address public immutable asset;
    uint256 public immutable rate;
    string public symbol = "stkDIRTY";

    mapping(address => uint256) public balanceOf;

    constructor(address asset_, uint256 rate_) {
        asset = asset_;
        rate = rate_;
    }

    function setBalance(address account, uint256 shares) external {
        balanceOf[account] = shares;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * rate) / 1e18;
    }

    function getStakerCooldown(address) external pure {
        assembly {
            mstore(0x00, 1) // amount: non-zero, so the no-cooldown early return is not taken
            mstore(0x20, 1) // endOfCooldown: <= block.timestamp, so `&&` does not short-circuit
            mstore(0x40, not(0)) // withdrawalWindow: dirty above bit 32
            return(0x00, 0x60)
        }
    }
}

/// @notice Returns 64 bytes — two words, one short of the snapshot — with a cooldown that would read as LIVE.
/// @dev Built so the `size < 0x60` arm answers DIFFERENTLY from the arm beneath it, which the zero-byte mock
///      does not: with a zero-length reply the window is still zeroed, so `cdAmount == 0` short-circuits and
///      removing the gate changes nothing. Here word 0 is a real cooldown amount and word 1 is
///      `block.timestamp`, so WITHOUT the gate the adapter infers a live, in-window cooldown from a truncated
///      reply and splits the principal into an unlocked leg. WITH the gate it reports one locked leg. The leg
///      shape is the observable difference. `cdWindow` is word 2, which a 64-byte reply never writes, so it
///      stays the zeroed 0 and `inWindow` reduces to `block.timestamp == cdEnd` — hence returning `timestamp()`.
contract MockTruncatedCooldownStakeToken {
    address public immutable asset;
    uint256 public immutable rate;
    string public symbol = "stkTRUNC";

    mapping(address => uint256) public balanceOf;

    constructor(address asset_, uint256 rate_) {
        asset = asset_;
        rate = rate_;
    }

    function setBalance(address account, uint256 shares) external {
        balanceOf[account] = shares;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * rate) / 1e18;
    }

    function getStakerCooldown(address) external view {
        assembly {
            mstore(0x00, 2000000000000000000000) // amount: the whole stake, so the split is total
            mstore(0x20, timestamp()) // endOfCooldown == now, so `inWindow` is true with a zero window
            return(0x00, 0x40) // 64 bytes — one word short
        }
    }
}

/// @notice A stake token that answers `getStakerCooldown` with ZERO bytes rather than reverting.
/// @dev `try`/`catch` does not intercept this: the call SUCCEEDS and the struct decode reverts in the caller.
contract MockEmptyCooldownStakeToken {
    address public immutable asset;
    uint256 public immutable rate;
    string public symbol = "stkBROKEN";

    mapping(address => uint256) public balanceOf;

    constructor(address asset_, uint256 rate_) {
        asset = asset_;
        rate = rate_;
    }

    function setBalance(address account, uint256 shares) external {
        balanceOf[account] = shares;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * rate) / 1e18;
    }

    function getStakerCooldown(address) external pure {
        assembly {
            return(0x00, 0x00)
        }
    }
}
