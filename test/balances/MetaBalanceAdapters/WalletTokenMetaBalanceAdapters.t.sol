// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {
    LidoStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/LidoStakedEthWalletMetaBalanceAdapter.sol";
import {
    SkySavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/SkySavingsWalletMetaBalanceAdapter.sol";
import {
    ReserveBasketsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/ReserveBasketsWalletMetaBalanceAdapter.sol";
import {
    EthenaSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/EthenaSavingsWalletMetaBalanceAdapter.sol";

/// @dev Minimal stand-in for `ERC20DefaultBalanceAdapter`'s inclusion list — the only member the de-dup guard
///      reads. Kept here rather than reusing the real adapter so the test pins the GUARD, not that adapter.
contract DefaultAdapterStub {
    mapping(address => bool) public included;

    function setIncluded(address a, bool v) external {
        included[a] = v;
    }

    function isSupportedByDefault(address a) external view returns (bool) {
        return included[a];
    }
}

/// @title WalletTokenMetaBalanceAdaptersTest
/// @author KPK
/// @notice Behaviour of the wallet-held yield-token adapter family.
/// @dev The property that makes this migration safe is **value neutrality**: these adapters report the raw
///      `balanceOf` of a token that is itself the registered, priced NAV asset, so the amount is bit-identical
///      to what `ERC20DefaultBalanceAdapter` reported for the same holding. ONLY the identity fields change.
///      A test that checked identity but not the amount would miss the one way this could move NAV.
contract WalletTokenMetaBalanceAdaptersTest is Test {
    Mock_NAVCalculator internal nav;
    Mock_ERC20 internal wstETH;
    Mock_ERC20 internal sDAI;
    address internal alice = address(0xA11CE);

    LidoStakedEthWalletMetaBalanceAdapter internal lido;
    SkySavingsWalletMetaBalanceAdapter internal sky;

    function setUp() public {
        nav = new Mock_NAVCalculator();
        wstETH = new Mock_ERC20("wstETH", 18);
        sDAI = new Mock_ERC20("sDAI", 18);
        nav.registerAsset(address(wstETH), 18, "wstETH");
        nav.registerAsset(address(sDAI), 18, "sDAI");
        lido = new LidoStakedEthWalletMetaBalanceAdapter(address(nav));
        sky = new SkySavingsWalletMetaBalanceAdapter(address(nav));
    }

    function _ins(address token) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = bytes32(uint256(uint160(token)));
    }

    // --- value neutrality -------------------------------------------------------------------------

    /// @notice The reported amount is the RAW balance — no conversion, no preview.
    /// @dev This is the invariant the whole migration rests on. Unlike the ERC-4626 vault adapters, the token
    ///      here IS the registered asset, so any share→asset transformation would change NAV rather than
    ///      merely reclassify it.
    function test_amountIsTheRawBalance() public {
        wstETH.mint(alice, 3.5e18);
        INAVCalculator.PositionBalance[] memory p =
            lido.getAdapterPositionsForInstances(alice, _ins(address(wstETH)), address(0));
        assertEq(p.length, 1);
        assertEq(p[0].amount, 3.5e18, "amount must equal balanceOf exactly");
        assertEq(p[0].balanceAsset.asset, address(wstETH), "balanceAsset must be the token itself");
        assertFalse(p[0].isDebt);
    }

    // --- identity ---------------------------------------------------------------------------------

    /// @notice A wallet-held LST is attributed to its protocol and is no longer `Wallet`.
    function test_identity_lidoIsStaking() public {
        wstETH.mint(alice, 1e18);
        INAVCalculator.PositionBalance[] memory p =
            lido.getAdapterPositionsForInstances(alice, _ins(address(wstETH)), address(0));
        assertEq(p[0].protocolBrand, ProtocolIds.LIDO);
        assertEq(p[0].protocolId, ProtocolIds.LIDO);
        assertEq(p[0].protocolSubId, ProtocolIds.LIDO_STAKED_ETH);
        assertEq(uint256(p[0].positionKind), uint256(PositionKind.Staking));
        assertEq(p[0].positionId, abi.encode(address(wstETH)), "positionId must be abi.encode(token)");
        assertEq(p[0].balanceAdapter, address(lido));
        assertNotEq(p[0].protocolId, ProtocolIds.WALLET, "must no longer read as a wallet holding");
    }

    /// @notice A savings wrapper is `Supplied`, not `Staking` — the par-exit verb differs.
    function test_identity_skyIsSupplied() public {
        sDAI.mint(alice, 100e18);
        INAVCalculator.PositionBalance[] memory p =
            sky.getAdapterPositionsForInstances(alice, _ins(address(sDAI)), address(0));
        assertEq(p[0].protocolSubId, ProtocolIds.SKY_SAVINGS);
        assertEq(uint256(p[0].positionKind), uint256(PositionKind.Supplied));
    }

    /// @notice ETH+ is `Supplied` despite its "LST" config label — the documented judgement call.
    /// @dev Pinned deliberately. Reserve stakes nothing itself; exiting ETH+ at par REDEEMS a basket into
    ///      underlying LSTs, and the staking lives one layer down in those. If someone later "fixes" this to
    ///      Staking on the strength of the label, this test should stop them and send them to the ADR.
    function test_identity_reserveIsSuppliedNotStaking() public {
        Mock_ERC20 ethPlus = new Mock_ERC20("ETH+", 18);
        nav.registerAsset(address(ethPlus), 18, "ETH+");
        ReserveBasketsWalletMetaBalanceAdapter reserve = new ReserveBasketsWalletMetaBalanceAdapter(address(nav));
        ethPlus.mint(alice, 2e18);
        INAVCalculator.PositionBalance[] memory p =
            reserve.getAdapterPositionsForInstances(alice, _ins(address(ethPlus)), address(0));
        assertEq(uint256(p[0].positionKind), uint256(PositionKind.Supplied), "verb rule: redeem, not unstake");
    }

    /// @notice sUSDe is `Staking`, keeping it coherent with the Ethena cooldown adapter's lifecycle.
    function test_identity_ethenaIsStaking() public {
        Mock_ERC20 sUSDe = new Mock_ERC20("sUSDe", 18);
        nav.registerAsset(address(sUSDe), 18, "sUSDe");
        EthenaSavingsWalletMetaBalanceAdapter ethena = new EthenaSavingsWalletMetaBalanceAdapter(address(nav));
        sUSDe.mint(alice, 5e18);
        INAVCalculator.PositionBalance[] memory p =
            ethena.getAdapterPositionsForInstances(alice, _ins(address(sUSDe)), address(0));
        assertEq(uint256(p[0].positionKind), uint256(PositionKind.Staking));
    }

    // --- fail-open behaviour ----------------------------------------------------------------------

    /// @notice A zero balance drops the leg rather than reporting a zero-value row.
    function test_zeroBalanceDropsTheLeg() public view {
        INAVCalculator.PositionBalance[] memory p =
            lido.getAdapterPositionsForInstances(alice, _ins(address(wstETH)), address(0));
        assertEq(p.length, 0);
    }

    /// @notice An UNREGISTERED token yields empty rather than reverting.
    /// @dev `unregisterAsset` does not clear meta instances, so an operator can leave residue here. It must
    ///      degrade to an under-report, not take the whole NAV read down with a revert.
    function test_unregisteredTokenYieldsEmptyNotRevert() public {
        Mock_ERC20 stray = new Mock_ERC20("STRAY", 18);
        stray.mint(alice, 1e18);
        INAVCalculator.PositionBalance[] memory p =
            lido.getAdapterPositionsForInstances(alice, _ins(address(stray)), address(0));
        assertEq(p.length, 0, "unregistered must be skipped, not reverted");
    }

    /// @notice `assetFilter` matches on the token itself, since the token IS the balance asset.
    function test_assetFilter_matchAndMiss() public {
        wstETH.mint(alice, 1e18);
        assertEq(lido.getAdapterPositionsForInstances(alice, _ins(address(wstETH)), address(wstETH)).length, 1);
        assertEq(lido.getAdapterPositionsForInstances(alice, _ins(address(wstETH)), address(sDAI)).length, 0);
    }

    /// @notice One instance failing must not zero out its siblings.
    function test_oneBadInstanceDoesNotZeroTheRest() public {
        wstETH.mint(alice, 1e18);
        Mock_ERC20 stray = new Mock_ERC20("STRAY", 18);
        bytes32[] memory both = new bytes32[](2);
        both[0] = bytes32(uint256(uint160(address(stray)))); // unregistered
        both[1] = bytes32(uint256(uint160(address(wstETH))));
        INAVCalculator.PositionBalance[] memory p = lido.getAdapterPositionsForInstances(alice, both, address(0));
        assertEq(p.length, 1, "the good instance must survive the bad one");
        assertEq(p[0].balanceAsset.asset, address(wstETH));
    }

    // --- de-dup against ERC20DefaultBalanceAdapter -------------------------------------------------

    /// @notice While the default adapter still reports the token, this adapter reports NOTHING.
    /// @dev `registerAsset` unconditionally adds every asset to the default adapter's inclusion list, so a token
    ///      is reported there from the moment it is registered. Without this guard, adding the meta instance
    ///      before calling `excludeAssetFromDefaultAdapter` makes BOTH adapters emit a well-formed leg for the
    ///      same balance under different reconciliation keys, with no health flag — issue #335's species, one
    ///      forgotten transaction away, 17 times over. The guard makes the operator ordering non-load-bearing.
    function test_dedupe_suppressedWhileDefaultAdapterStillReports() public {
        DefaultAdapterStub dflt = new DefaultAdapterStub();
        nav.setErc20DefaultBalanceAdapter(address(dflt));
        LidoStakedEthWalletMetaBalanceAdapter a = new LidoStakedEthWalletMetaBalanceAdapter(address(nav));

        wstETH.mint(alice, 1e18);
        dflt.setIncluded(address(wstETH), true);

        assertEq(
            a.getAdapterPositionsForInstances(alice, _ins(address(wstETH)), address(0)).length,
            0,
            "must not report alongside the default adapter"
        );
    }

    /// @notice Once excluded from the default adapter, the SAME adapter reports it normally.
    /// @dev The other direction, and the one that stops this guard from being a silent kill switch: a fix that
    ///      suppressed unconditionally would pass the test above while reporting nothing, ever.
    function test_dedupe_reportsOnceExcludedFromDefault() public {
        DefaultAdapterStub dflt = new DefaultAdapterStub();
        nav.setErc20DefaultBalanceAdapter(address(dflt));
        LidoStakedEthWalletMetaBalanceAdapter a = new LidoStakedEthWalletMetaBalanceAdapter(address(nav));

        wstETH.mint(alice, 1e18);
        dflt.setIncluded(address(wstETH), false);

        INAVCalculator.PositionBalance[] memory p =
            a.getAdapterPositionsForInstances(alice, _ins(address(wstETH)), address(0));
        assertEq(p.length, 1, "must report once the default adapter has let go");
        assertEq(p[0].amount, 1e18, "and the amount must still be the raw balance");
    }

    /// @notice An unreadable inclusion answer suppresses the leg rather than risking a double-count.
    /// @dev Fail-closed. `alice` is an EOA, so the staticcall returns empty returndata — the shape a wrong or
    ///      self-destructed adapter address produces. Under-reporting is licensed here; over-reporting is not.
    function test_dedupe_failsClosedWhenInclusionUnreadable() public {
        nav.setErc20DefaultBalanceAdapter(alice);
        LidoStakedEthWalletMetaBalanceAdapter a = new LidoStakedEthWalletMetaBalanceAdapter(address(nav));

        wstETH.mint(alice, 1e18);
        assertEq(
            a.getAdapterPositionsForInstances(alice, _ins(address(wstETH)), address(0)).length,
            0,
            "an unreadable answer must suppress, not report"
        );
    }

    /// @notice A NAV that cannot answer at all fails the DEPLOY, not the read.
    /// @dev The stand-in is built BEFORE `expectRevert`: a `new` in the argument list is evaluated first, so an
    ///      inline construction would bind the cheatcode to that creation instead of the one under test — which
    ///      is exactly how the first version of this test passed vacuously.
    function test_dedupe_constructorRevertsWhenNavCannotAnswer() public {
        address notANav = address(new Mock_ERC20("NOT-A-NAV", 18));
        vm.expectRevert();
        new LidoStakedEthWalletMetaBalanceAdapter(notANav);
    }

    /// @notice The RETURN TRIP: re-registering an asset must not revive the default-adapter leg.
    /// @dev Vigilo M-01, PoC-validated against b195a0ce as a $40,000 -> $80,000 silent doubling. `registerAsset`
    ///      unconditionally re-adds the asset to the default adapter's inclusion list and knows nothing about
    ///      meta-instance state, so a correctly-rolled-out token that is later unregistered and re-registered —
    ///      a DOCUMENTED repair, and the only way to move a feed whose decimals differ — came back reported by
    ///      both adapters, with no health flag because both legs are well-formed.
    ///
    ///      The read-time guard closes it: inclusion is re-read on every call, so the moment `registerAsset`
    ///      puts the token back in the default adapter, this adapter stands down again. Nothing about the
    ///      rollout ordering has to be remembered a second time.
    function test_dedupe_reRegistrationDoesNotReviveTheDefaultLeg() public {
        DefaultAdapterStub dflt = new DefaultAdapterStub();
        nav.setErc20DefaultBalanceAdapter(address(dflt));
        LidoStakedEthWalletMetaBalanceAdapter a = new LidoStakedEthWalletMetaBalanceAdapter(address(nav));
        wstETH.mint(alice, 10e18);

        // Correct rollout: excluded from the default adapter, then governed here.
        dflt.setIncluded(address(wstETH), false);
        assertEq(a.getAdapterPositionsForInstances(alice, _ins(address(wstETH)), address(0)).length, 1);

        // The repair: unregisterAsset + registerAsset. The second call re-adds it to the inclusion list.
        dflt.setIncluded(address(wstETH), true);

        assertEq(
            a.getAdapterPositionsForInstances(alice, _ins(address(wstETH)), address(0)).length,
            0,
            "re-registration must not leave BOTH adapters reporting"
        );
    }

    // --- labels -----------------------------------------------------------------------------------

    /// @notice Labels are `[category, symbol]`.
    function test_labelsUseCategoryAndSymbol() public view {
        string[] memory l = lido.positionLabels(abi.encode(address(wstETH)));
        assertEq(l.length, 2);
        assertEq(l[0], "LST");
        assertEq(l[1], "wstETH");
    }

    /// @notice A malformed positionId yields empty rather than reverting — labels are display-only.
    function test_labelsMalformedPositionIdIsEmpty() public view {
        assertEq(lido.positionLabels(hex"1234").length, 0);
    }
}
