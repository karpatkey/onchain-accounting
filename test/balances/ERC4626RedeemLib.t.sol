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

/// @notice Succeeds and returns NOTHING — an ERC-1967 proxy over a code-less implementation.
contract Mock_EmptyPreview {
    fallback() external {
        assembly {
            return(0x00, 0x00)
        }
    }
}

/// @notice Succeeds with fewer than 32 bytes.
contract Mock_ShortPreview {
    fallback() external {
        assembly {
            mstore(0x00, not(0))
            return(0x00, 0x10)
        }
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
    function test_redeemValue_previewStarves_raisesInsteadOfDeletingThePosition() public {
        vault.setMode(Mock_FeeVault.Mode.Starve);

        // Budget chosen so 1/64 of it comfortably funds `convertToAssets` (~2.5k gas) — the residue that made
        // the old gross fallback reachable. Assert that premise rather than assuming it.
        uint256 budget = 2_000_000;
        assertGt(budget / 64, 25_000, "1/64 residue must be able to fund a cheap read");

        (uint8 status,) = harness.valueBounded(address(vault), SHARES, budget);
        assertEq(status, 1, "a starved preview must RAISE, not report a value");
    }

    /// @notice Starvation is distinguishable from a plain revert, so only one of them is loud.
    /// @dev The pair is the point. Returning 0 for BOTH would silently delete a position that was never
    ///      valued — the absorb-your-own-out-of-gas hole this PR closes in `AssistedCoordCache._collect` and
    ///      `FluidVaultLib.aggregate`, which this library was the last site of. Raising for BOTH would fail an
    ///      entire account's NAV read over one unreadable vault. Found in review.
    function test_redeemValue_previewReverts_isNotMisreadAsStarvation() public {
        vault.setMode(Mock_FeeVault.Mode.Revert);
        (uint8 status, uint256 v) = harness.valueBounded(address(vault), SHARES, 2_000_000);
        assertEq(status, 0, "a cheap revert must not be scored as exhaustion");
        assertEq(v, 0, "and must report no leg");
    }

    /// @notice A code-less vault reports no leg instead of reverting.
    /// @dev This inverts an earlier revision, which asserted a REVERT here and justified it with Solidity's
    ///      `extcodesize` precheck. Two things were wrong. The mechanism: a high-level call expecting return
    ///      data emits no `extcodesize` check — the returndata-size check subsumes it — so the call SUCCEEDS
    ///      with zero bytes and the `uint256` decode reverts in the CALLER's frame, past the `catch`. And the
    ///      justification: `AaveUmbrellaBalanceAdapter` reaches this through a WRAPPER address that is only
    ///      ever probed with low-level staticcalls, never high-level called, and `_sharesToUnderlying` runs
    ///      inline inside `getAdapterPositions` with no per-stake-token isolation — so that revert dropped
    ///      every Umbrella staking, cooldown and rewards leg from the NAV, silently. Found in review.
    function test_redeemValue_codelessVault_reportsNoLegRatherThanReverting() public {
        assertEq(harness.value(address(0xDEAD), SHARES), 0, "a code-less vault must degrade, not revert");
    }

    /// @notice A vault that SUCCEEDS with empty returndata degrades too — the ERC-1967 shape.
    /// @dev The trigger the sibling ezETH fix calls "not hypothetical": a proxy whose implementation slot
    ///      points at a code-less address. The delegatecall succeeds and returns nothing.
    function test_redeemValue_emptyReturndata_reportsNoLeg() public {
        Mock_EmptyPreview e = new Mock_EmptyPreview();
        assertEq(harness.value(address(e), SHARES), 0, "empty returndata must report no leg");
    }

    /// @notice A short-but-successful reply is not spliced into a value.
    function test_redeemValue_shortReply_reportsNoLeg() public {
        Mock_ShortPreview sp = new Mock_ShortPreview();
        assertEq(harness.value(address(sp), SHARES), 0, "a 16-byte reply must report no leg");
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
