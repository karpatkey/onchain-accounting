// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {MockFluidVaultResolver, FluidVaultLibHarness} from "test/balances/MetaBalanceAdapters/FluidVaultMocks.sol";

/// @title FluidVaultLib.aggregate — the starved/unreadable classification
/// @author KPK
/// @notice Pins the two-way split in `aggregate`, which had NO test despite being on its third revision.
/// @dev This logic has been wrong twice. Round 0 skipped every failed per-NFT read, which silently truncated
///      the aggregate and — because a starved read poisons the ones after it — could quietly empty the vault
///      while still RETURNING. Round 1 replaced that with an unconditional `revert`, which escalated a one-NFT
///      omission into dropping the vault's whole collateral+debt pair; for a net-debt vault that RAISES
///      reported NAV, the one direction these adapters may never take. Round 2 splits the two cases.
///
///      Neither of the first two defects was caught by a test, because there was none: a review round proved
///      that reverting the guard to round-0 behaviour left the entire non-fork suite green. These tests exist
///      so the third revision cannot regress the same way — every one of them fails under at least one
///      mutation of the guard.
contract FluidVaultLibAggregateTest is Test {
    MockFluidVaultResolver internal resolver;
    FluidVaultLibHarness internal lib;

    address internal VAULT;
    address internal ALICE;

    function setUp() public {
        VAULT = makeAddr("fluidVault");
        ALICE = makeAddr("alice");
        resolver = new MockFluidVaultResolver();
        lib = new FluidVaultLibHarness();
    }

    function _push(uint256 nftId, uint256 supply, uint256 borrow) internal {
        resolver.pushNft(ALICE, nftId, VAULT, supply, borrow, false);
    }

    // ─── The genuinely-unreadable branch: omit ONE NFT, not the vault ─────────

    /// @notice A cheap revert on one NFT omits only that NFT — the sibling's legs survive.
    /// @dev The round-1 regression pin. Under an unconditional `revert` this returned (0, 0): both the
    ///      collateral AND the debt of the healthy NFT vanished, silently, because the caller's per-instance
    ///      catch scores a cheap revert benign and substitutes an empty leg array.
    function test_cheapRevert_omitsOnlyThatNft_siblingDebtSurvives() public {
        _push(1, 100e18, 1000e6);
        _push(2, 7e18, 70e6);
        resolver.setPosMode(2, MockFluidVaultResolver.PosMode.CheapRevert);

        (uint256 collateral, uint256 debt) = lib.aggregate(VAULT, address(resolver), ALICE);
        assertEq(collateral, 100e18, "healthy NFT's collateral must survive");
        assertEq(debt, 1000e6, "and so must its DEBT - dropping it would raise reported NAV");
    }

    /// @notice The unreadable NFT being FIRST does not stop the loop.
    function test_cheapRevertFirst_loopStillCompletes() public {
        _push(1, 0, 0);
        resolver.setPosMode(1, MockFluidVaultResolver.PosMode.CheapRevert);
        _push(2, 55e18, 550e6);

        (uint256 collateral, uint256 debt) = lib.aggregate(VAULT, address(resolver), ALICE);
        assertEq(collateral, 55e18);
        assertEq(debt, 550e6);
    }

    /// @notice A 383-byte reply is one byte under the prefix and is omitted, not spliced.
    function test_shortReply_isOmittedNotSpliced() public {
        _push(1, 100e18, 1000e6);
        _push(2, 7e18, 70e6);
        resolver.setPosMode(2, MockFluidVaultResolver.PosMode.Short);

        (uint256 collateral, uint256 debt) = lib.aggregate(VAULT, address(resolver), ALICE);
        assertEq(collateral, 100e18);
        assertEq(debt, 1000e6);
    }

    /// @notice An oversized reply is read correctly — the bounded window copies the prefix, discards the tail.
    /// @dev Pins `READ_WINDOW = 416` against the `>= 384` guard and the offsets 288/320 the reader uses. A
    ///      window that truncated into the prefix would read zeros here.
    function test_oversizedReply_prefixReadFaithfully() public {
        _push(1, 42e18, 4200e6);
        resolver.setPosMode(1, MockFluidVaultResolver.PosMode.Oversized);

        (uint256 collateral, uint256 debt) = lib.aggregate(VAULT, address(resolver), ALICE);
        assertEq(collateral, 42e18, "supply at offset 288 must survive an 8KB tail");
        assertEq(debt, 4200e6, "and borrow at offset 320");
    }

    // ─── The starved branch: raise, do not truncate ───────────────────────────

    /// @notice A starved per-NFT read raises rather than returning a partial total.
    function test_starvedNft_raises() public {
        _push(1, 100e18, 1000e6);
        _push(2, 7e18, 70e6);
        resolver.setPosMode(2, MockFluidVaultResolver.PosMode.Starve);

        (uint8 status,,) = lib.aggregateBounded{gas: 3_000_000}(VAULT, address(resolver), ALICE, 2_500_000);
        assertEq(status, 1, "must raise FluidPositionGasExhausted, not truncate");
    }

    /// @notice Starvation on the FIRST NFT raises too — it poisons every read after it.
    /// @dev The worst case under round 0: the residue could not fund the remaining NFTs either, so the whole
    ///      vault read as empty while `aggregate` still returned successfully.
    function test_starvedNftFirst_raises() public {
        _push(1, 0, 0);
        resolver.setPosMode(1, MockFluidVaultResolver.PosMode.Starve);
        _push(2, 55e18, 550e6);

        (uint8 status,,) = lib.aggregateBounded{gas: 3_000_000}(VAULT, address(resolver), ALICE, 2_500_000);
        assertEq(status, 1, "a starved first NFT must raise");
    }

    /// @notice A cheap revert is NOT scored as starvation — the other side of the bracket.
    /// @dev Without this, a fix that raised on every failed read would pass every test above and turn one
    ///      malformed NFT into a failed NAV read for the whole account.
    function test_cheapRevert_isNotScoredStarved() public {
        _push(1, 100e18, 1000e6);
        _push(2, 7e18, 70e6);
        resolver.setPosMode(2, MockFluidVaultResolver.PosMode.CheapRevert);

        (uint8 status, uint256 collateral,) =
            lib.aggregateBounded{gas: 3_000_000}(VAULT, address(resolver), ALICE, 2_500_000);
        assertEq(status, 0, "a cheap revert must not be scored exhausted");
        assertEq(collateral, 100e18, "and must leave the healthy NFT reported");
    }
}
