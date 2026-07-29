// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {ERC4626RedeemLib} from "src/balances/ERC4626RedeemLib.sol";
import {MorphoVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/MorphoVaultsMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

/// @notice The sub-contract `previewRedeem` reaches into, which never returns.
/// @dev Nesting is the shape that matters. A vault loses its gas inside whatever it reads — a withdraw-queue walk,
///      an interest accrual — not in its own frame, so EIP-150 hands ~1/64 back to the CALLER when the inner call
///      out-of-gasses. That residue is exactly what used to fund the `convertToAssets` fallback.
contract Mock_PreviewSink {
    function burn() external pure {
        assembly {
            for {} 1 {} { mstore(0x00, keccak256(0x00, 0x20)) }
        }
    }
}

/// @notice An ERC4626 vault that charges a 5% redemption fee, with a switchable `previewRedeem` failure mode.
/// @dev The fee is the whole point: `convertToAssets` MUST ignore it (EIP-4626 §4.3) and `previewRedeem` MUST
///      include it, so the two return DIFFERENT numbers. A mock where they agreed would pass whichever branch the
///      library took, which is how this defect survived — there was no test at all, and an equal-valued mock
///      would not have caught it either.
contract Mock_FeeVault is Mock_ERC20 {
    enum Mode {
        Ok,
        Revert,
        Starve
    }

    error PreviewUnavailable();

    Mode public mode;
    address public immutable ASSET;
    Mock_PreviewSink private immutable SINK;

    /// @notice 1 share == 1 asset gross; the fee is taken on redemption only.
    uint256 public constant FEE_BPS = 500;

    constructor(address asset_) Mock_ERC20("mvFEE", 18) {
        ASSET = asset_;
        SINK = new Mock_PreviewSink();
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function asset() external view returns (address) {
        return ASSET;
    }

    /// @notice Gross — ignores the redemption fee, per EIP-4626 §4.3.
    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    /// @notice Fee-net — what a redemption would actually pay.
    function previewRedeem(uint256 shares) external view returns (uint256) {
        if (mode == Mode.Revert) revert PreviewUnavailable();
        if (mode == Mode.Starve) SINK.burn();
        return shares - (shares * FEE_BPS) / 10_000;
    }
}

/// @notice External wrapper so the internal library can be called under an explicit `{gas: …}` budget.
contract RedeemLibHarness {
    function value(address vault, uint256 shares) external view returns (uint256) {
        return ERC4626RedeemLib.redeemValue(vault, shares);
    }

    /// @return status 0 = returned, 1 = reverted. @return out The value when `status == 0`.
    function valueBounded(address vault, uint256 shares, uint256 budget)
        external
        view
        returns (uint8 status, uint256 out)
    {
        try RedeemLibHarness(address(this)).value{gas: budget}(vault, shares) returns (uint256 v) {
            return (0, v);
        } catch {
            return (1, 0);
        }
    }
}

/// @title ERC4626RedeemLib — a failed fee-net read must not become a gross one
/// @author KPK
/// @notice Pins the direction of {ERC4626RedeemLib.redeemValue}'s failure path.
/// @dev `redeemValue` used to fall back from `previewRedeem` to `convertToAssets`. Because EIP-4626 §4.3 makes
///      `convertToAssets` ignore the redemption fee that `previewRedeem` includes, that fallback could only ever
///      report MORE than a redemption would pay — an over-report, invisible downstream (the leg is well-formed,
///      no staleness or gas signal fires, and `getAccountNavVerbose` runs the same math).
///
///      Every assertion below therefore compares against `GROSS`, not just against zero. Asserting `== 0` alone
///      would still pass if someone reinstated the fallback behind a different spelling; asserting `!= GROSS`
///      is what actually kills the mutation.
contract ERC4626RedeemLibTest is Test {
    uint256 internal constant SHARES = 1000e18;
    uint256 internal constant GROSS = 1000e18; // convertToAssets — ignores the fee
    uint256 internal constant NET = 950e18; // previewRedeem  — 5% fee applied

    Mock_ERC20 internal underlying;
    Mock_FeeVault internal vault;
    RedeemLibHarness internal harness;

    function setUp() public {
        underlying = new Mock_ERC20("USDC", 18);
        vault = new Mock_FeeVault(address(underlying));
        harness = new RedeemLibHarness();
        vault.mint(address(this), SHARES);
    }

    // ─── The library itself ───────────────────────────────────────────────────

    /// @notice Happy path reports the FEE-NET figure, not the gross one.
    function test_redeemValue_reportsFeeNet_notGross() public view {
        uint256 v = harness.value(address(vault), SHARES);
        assertEq(v, NET, "must report previewRedeem");
        assertLt(v, GROSS, "fee-net must be strictly below gross, or this suite proves nothing");
    }

    /// @notice A reverting `previewRedeem` reports 0 — it must NOT substitute the gross figure.
    function test_redeemValue_previewReverts_reportsZeroNotGross() public {
        vault.setMode(Mock_FeeVault.Mode.Revert);
        uint256 v = harness.value(address(vault), SHARES);
        assertEq(v, 0, "unreadable preview must contribute nothing");
        assertTrue(v != GROSS, "must not fall back to convertToAssets");
    }

    /// @notice The case that made this a NAV bug rather than a style point: `previewRedeem` running out of gas.
    /// @dev The old fallback was funded by EIP-150. `previewRedeem` burns 63/64 of the frame inside `SINK`, the
    ///      remaining ~1/64 comes back to `redeemValue`, and `convertToAssets` is cheap enough to complete on it —
    ///      so starvation reliably selected the INFLATED branch, precisely when the read was least trustworthy.
    ///      This test asserts the frame still returns (it is not simply OOG-ing) and that what it returns is 0.
    function test_redeemValue_previewStarves_reportsZeroNotGross() public {
        vault.setMode(Mock_FeeVault.Mode.Starve);

        // Budget chosen so 1/64 of it comfortably funds `convertToAssets` (~2.5k gas), which is what makes the
        // starved fallback reachable at all. Assert that premise rather than assuming it.
        uint256 budget = 2_000_000;
        assertGt(budget / 64, 25_000, "1/64 residue must be able to fund the gross read");

        (uint8 status, uint256 v) = harness.valueBounded(address(vault), SHARES, budget);
        assertEq(status, 0, "the frame must survive the starved sub-call, else this proves nothing");
        assertEq(v, 0, "a starved preview must contribute nothing");
        assertTrue(v != GROSS, "starvation must not select the gross figure");
    }

    /// @notice A code-less vault is out of contract for this library — pinned so the boundary stays deliberate.
    /// @dev `try`/`catch` does NOT intercept Solidity's `extcodesize` precheck, so this reverts rather than
    ///      returning 0. That is acceptable only because both call sites high-level-call the vault (`asset()`,
    ///      `balanceOf`) before reaching here. If a caller ever reaches `redeemValue` with an unvalidated
    ///      address, this test is the one that should start failing.
    function test_redeemValue_codelessVault_revertsRatherThanReturningZero() public {
        vm.expectRevert();
        harness.value(address(0xDEAD), SHARES);
    }

    // ─── The wiring ───────────────────────────────────────────────────────────
    //
    // Separate from the body above on purpose. A guard whose body is correct but whose call site was removed
    // leaves the whole suite green; these two tests fail if `MorphoVaultsMetaBalanceAdapter` stops routing
    // through the library, or starts routing through `convertToAssets` directly.

    function _adapter() internal returns (MorphoVaultsMetaBalanceAdapter meta, bytes32[] memory instances) {
        Mock_NAVCalculator nav = new Mock_NAVCalculator();
        nav.registerAsset(address(underlying), 18, "USDC");
        meta = new MorphoVaultsMetaBalanceAdapter(address(nav));
        instances = new bytes32[](1);
        instances[0] = bytes32(uint256(uint160(address(vault))));
    }

    /// @notice The adapter reports the fee-net amount, proving it routes through the library at all.
    function test_wiring_morphoVaults_emitsFeeNetAmount() public {
        (MorphoVaultsMetaBalanceAdapter meta, bytes32[] memory instances) = _adapter();
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(address(this), instances, address(0));
        assertEq(p.length, 1, "one Supplied leg");
        assertEq(p[0].amount, NET, "adapter must report the fee-net figure");
        assertTrue(p[0].amount != GROSS, "adapter must not report the gross figure");
    }

    /// @notice With `previewRedeem` unavailable the adapter emits NO leg — it does not emit an inflated one.
    function test_wiring_morphoVaults_unreadablePreview_dropsTheLeg() public {
        (MorphoVaultsMetaBalanceAdapter meta, bytes32[] memory instances) = _adapter();
        vault.setMode(Mock_FeeVault.Mode.Revert);
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(address(this), instances, address(0));
        assertEq(p.length, 0, "an unvaluable position must be dropped, not reported gross");
    }
}
