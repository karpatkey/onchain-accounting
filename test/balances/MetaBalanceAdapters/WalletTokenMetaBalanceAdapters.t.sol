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
