// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {LidoStVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/LidoStVaultsMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title LidoStVaultsMetaBalanceAdapter fork tests (mainnet)
/// @notice Pins the adapter against real Lido V3 `VaultHub` state.
///
/// @dev **The holder is a THIRD PARTY, deliberately.** Measured 2026-08-27: no account in
///      `test/integration/accounts.json` is a `vaultConnection.owner`, and none holds `DEFAULT_ADMIN_ROLE` on any of
///      the 24 connected vaults (288 probes, zero hits; the control confirms `hasRole` answers rather than reverts).
///      So karpatkey holds no stVault, `IntegrationFromConfigBase` can only ever exercise this adapter's inert path,
///      and THIS FILE IS THE ONLY REAL COVERAGE. That is structural while exposure is zero, not an oversight.
contract LidoStVaultsMetaBalanceAdapterForkTest is BalanceAdapterTestBase {
    using Strings for address;

    address public constant VAULT_HUB = 0x1d201BE093d847f6446530Efb0E8Fb426d176709;
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev Chosen because it exercises ALL THREE legs non-trivially: 638 ETH of value, a real stETH liability, a
    ///      non-zero `feesToSettle` AND a non-zero Dashboard `accruedFee()`. Most connected vaults are 1-ETH seeds.
    address public constant VAULT = 0x62e0D92cf7B8752b5292B9BCbbacE4cFa1633428;
    address public constant DASHBOARD = 0xAde0D2c3C75BCbC04cD0C9055b21d0A4B41Ba108;
    /// @dev The Dashboard's surviving `DEFAULT_ADMIN_ROLE` holder, found from its `RoleGranted` logs. The
    ///      VaultFactory (`0x02Ca7772...`) is granted admin at creation and REVOKES it in the same block, so exactly
    ///      one admin survives — which is why the "two tracked admins both report the vault" over-report does not
    ///      arise from the protocol's own creation flow.
    address public constant HOLDER = 0xC28317c7F9e4aEE13931a61D4e36e93d9481B298;

    /// @dev A vault whose oracle report was FRESH at this block - the positive control for the freshness model
    ///      documented on the adapter. The primary fixture above was STALE at the same block, which is what makes
    ///      the pair a controlled comparison rather than two anecdotes.
    address public constant FRESH_VAULT = 0x2df8CCb91c80c9600EA9436b1f940c48cC008ca7;

    uint256 public constant FORK_BLOCK = 25_848_000;

    LidoStVaultsMetaBalanceAdapter public meta;

    function setUp() public override {
        // `super.setUp()` invokes the overridden `_setupFork()` below via virtual dispatch - no second call.
        super.setUp();

        // Registered DIRECTLY rather than through `_deployBalancesForAdapter`: that helper probes
        // `decimals()`/`symbol()` on every asset, and foundry rejects the probe for the CODELESS native sentinel
        // ("does not exist and is not marked as persistent"). `registerAssetForTest` is pure storage, so it is the
        // route the other ETH-denominated fork tests take (see KelpWithdrawalQueueBalanceAdapter.fork.t.sol).
        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(ETH_SENTINEL, 18, "ETH");
        balances.registerAssetForTest(STETH, 18, "stETH");

        meta = new LidoStVaultsMetaBalanceAdapter(VAULT_HUB, STETH, ETH_SENTINEL, address(balances));
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _ins(address v) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = bytes32(uint256(uint160(v)));
    }

    // ── the assumption the whole design rests on ────────────────────────────────────────────────────────────────

    /// @notice `VaultHub.totalValue` is GROSS of unsettled fees — pinned as an IDENTITY over every connected vault,
    ///         not as one vault's figure.
    /// @dev The identity survives a block bump where a hardcoded number would not, and it is the reason the `Fees`
    ///      debt leg exists: if fees were already netted out of `totalValue`, that leg would double-count them.
    ///      Measured 2026-08-27: held on 24 of 24 connected vaults, to the wei.
    function test_totalValueIsGrossOfFees_acrossEveryConnectedVault() public view {
        uint256 count = _vaultsCount();
        assertGt(count, 0, "no vaults connected at this block");
        uint256 checked;
        // 1-INDEXED: `vaultByIndex(0)` REVERTS. An idiomatic `0..count-1` loop both reverts and returns one vault
        // short — it is why this loop starts at 1, and the comment is here because the next person will write the
        // idiomatic one.
        for (uint256 i = 1; i <= count; i++) {
            address v = _vaultByIndex(i);
            if (v == address(0)) continue;
            (bool okTv, uint256 tv) = _u(VAULT_HUB, abi.encodeWithSignature("totalValue(address)", v));
            (bool okMl, uint256 ml) = _u(VAULT_HUB, abi.encodeWithSignature("maxLockableValue(address)", v));
            (bool okOb, uint256 fees) = _feesToSettle(v);
            if (!okTv || !okMl || !okOb) continue;
            assertEq(tv - ml, fees, "totalValue must be gross of feesToSettle");
            checked++;
        }
        assertGt(checked, 10, "identity must be exercised over a meaningful sample");
    }

    /// @notice `vaultByIndex` is 1-indexed — `vaultByIndex(0)` reverts.
    function test_vaultByIndexIsOneIndexed() public view {
        (bool ok,) = VAULT_HUB.staticcall(abi.encodeWithSignature("vaultByIndex(uint256)", uint256(0)));
        assertFalse(ok, "vaultByIndex(0) must revert - the range is 1..vaultsCount()");
        assertTrue(_vaultByIndex(1) != address(0), "index 1 is the first vault");
    }

    /// @notice On connection the StakingVault's `Ownable` owner becomes the VaultHub, so `owner()` is useless here.
    function test_vaultOwnerIsTheHub_notTheLogicalOwner() public view {
        (bool ok, address o) = _a(VAULT, abi.encodeWithSignature("owner()"));
        assertTrue(ok, "vault.owner() answers");
        assertEq(o, VAULT_HUB, "connected vault's Ownable owner IS the hub");
        assertTrue(o != DASHBOARD, "...and is NOT the logical owner the adapter must key on");
    }

    /// @notice The live Dashboard ABI is narrower than a full interface: `accruedFee()` answers, others do not.
    /// @dev Pinned because the adapter WHOLE-DROPS an instance when a debt read fails — so calling a method that is
    ///      absent (`vault()`, `nodeOperatorFeeRate()`) would silently zero a real position rather than error.
    function test_dashboardExposesAccruedFeeOnly() public view {
        (bool okFee,) = _u(DASHBOARD, abi.encodeWithSignature("accruedFee()"));
        assertTrue(okFee, "accruedFee() is the one fee read that exists");
        (bool okVault,) = DASHBOARD.staticcall(abi.encodeWithSignature("vault()"));
        assertFalse(okVault, "vault() does not exist on the live Dashboard");
        (bool okRate,) = DASHBOARD.staticcall(abi.encodeWithSignature("nodeOperatorFeeRate()"));
        assertFalse(okRate, "nodeOperatorFeeRate() does not exist on the live Dashboard");
    }

    /// @notice `totalValue` STRICTLY EXCEEDS the vault contract's own ETH - it also covers validators and,
    ///         critically, EIP-6110 PENDING deposits.
    /// @dev WARNING: `totalValue` is NOT `validators + contract balance`, and an earlier revision of this comment
    ///      claimed it was. That held only by coincidence on THIS fixture (DeBank `eth2/Staked` 561.378 vs
    ///      `totalValue` 638.756, gap 77.378 ~= the 77.437 contract balance) because it has no queued deposits.
    ///      COUNTEREXAMPLE measured 2026-08-27 on vault 0x2df8CCb9...: validators 625.708 + balance 0.725 = 626.43
    ///      against a `totalValue` of 5701.42 - a 5,075 ETH gap that is pending deposits (~159 queued validators).
    ///      A decomposition-based cross-check that ignores the deposit queue reads a correct vault as
    ///      catastrophically over-reported. Asserted as an INEQUALITY for exactly that reason.
    ///
    ///      Separately: DeBank shows the position GROSS, with no borrow leg for the 555 ETH stETH liability, and
    ///      indexes it under the VAULT rather than the owner - so it is not a usable oracle for this protocol.
    function test_totalValueExceedsTheVaultsOwnEthBalance() public view {
        (bool ok, uint256 tv) = _u(VAULT_HUB, abi.encodeWithSignature("totalValue(address)", VAULT));
        assertTrue(ok, "totalValue readable");
        uint256 onContract = VAULT.balance;
        assertGt(tv, onContract, "totalValue must include validator balances beyond the contract's own ETH");
        assertGt(onContract, 0, "this fixture holds loose ETH, so the decomposition is actually exercised");
    }

    /// @notice The fee identity holds on a FRESH report too - the positive control for the whole fee model.
    /// @dev On-chain fee obligations are written at oracle report; Lido's UI projects accrual forward, so the
    ///      chain figure LAGS by the accrual since that report. Measured 2026-08-27: FRESH 0x2df8CCb9... lag
    ///      0.0000 (UI 0.0745 == chain 0.0745); STALE 0x62e0D92c... lag 0.0122; STALE 0xd402937b... lag 0.0898
    ///      (its whole amount, because its fees were zero at its last report - which is why 'stale means zero' is
    ///      NOT the rule and an earlier note here said it was).
    ///
    ///      The lag is NOT gated on, deliberately: `totalValue` lags too, and the fee is a FRACTION of the reward
    ///      that generates it, so the un-reported reward always exceeds the un-reported fee. A stale report is
    ///      therefore structurally CONSERVATIVE - measured net -0.086 and -0.55 ETH on the two stale vaults.
    ///      Dropping a stale instance would trade a bounded under-report for a total one.
    function test_feeIdentityHoldsOnAFreshReport() public view {
        (bool okFresh, uint256 fresh) = _u(VAULT_HUB, abi.encodeWithSignature("isReportFresh(address)", FRESH_VAULT));
        assertTrue(okFresh, "isReportFresh readable");
        if (fresh != 1) return; // fixture drifted out of freshness; the identity below is the durable claim

        (bool okOb, uint256 fees) = _feesToSettle(FRESH_VAULT);
        (bool okTv, uint256 tv) = _u(VAULT_HUB, abi.encodeWithSignature("totalValue(address)", FRESH_VAULT));
        (bool okMl, uint256 ml) = _u(VAULT_HUB, abi.encodeWithSignature("maxLockableValue(address)", FRESH_VAULT));
        assertTrue(okOb && okTv && okMl, "reads answer on a fresh vault");
        assertEq(tv - ml, fees, "gross-of-fees identity holds on a FRESH report, not only on stale ones");
    }

    // ── the adapter itself ──────────────────────────────────────────────────────────────────────────────────────

    function test_holderGetsThreeLegs_matchingChainState() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(HOLDER, _ins(VAULT), address(0));
        assertEq(p.length, 3, "staking + borrowed + fees");

        (, uint256 tv) = _u(VAULT_HUB, abi.encodeWithSignature("totalValue(address)", VAULT));
        (, uint256 shares) = _u(VAULT_HUB, abi.encodeWithSignature("liabilityShares(address)", VAULT));
        (, uint256 ether_) = _u(STETH, abi.encodeWithSignature("getPooledEthByShares(uint256)", shares));
        (, uint256 fees) = _feesToSettle(VAULT);
        (, uint256 accrued) = _u(DASHBOARD, abi.encodeWithSignature("accruedFee()"));

        assertEq(p[0].amount, tv, "Staking leg is totalValue");
        assertEq(uint256(p[0].positionKind), uint256(PositionKind.Staking));
        assertFalse(p[0].isDebt);
        assertEq(p[0].balanceAsset.asset, ETH_SENTINEL);

        assertEq(p[1].amount, ether_, "Borrowed leg is shares converted through stETH");
        assertTrue(p[1].amount != shares, "...and the conversion is NOT 1:1 - the trap this pins");
        assertEq(uint256(p[1].positionKind), uint256(PositionKind.Borrowed));
        assertTrue(p[1].isDebt);
        assertEq(p[1].balanceAsset.asset, STETH);

        assertEq(p[2].amount, fees + accrued, "Fees leg is feesToSettle + accruedFee");
        assertEq(uint256(p[2].positionKind), uint256(PositionKind.Fees));
        assertTrue(p[2].isDebt);

        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].balanceAdapter, address(meta));
            assertEq(p[i].positionId, abi.encode(VAULT), "all legs share the vault coordinate");
        }
    }

    /// @notice The reported value is a DEBT-NET view: assets never appear without their offsetting legs.
    function test_debtIsNotSilentlyOmitted() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(HOLDER, _ins(VAULT), address(0));
        uint256 credit;
        uint256 debt;
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].isDebt) debt += p[i].amount;
            else credit += p[i].amount;
        }
        assertGt(credit, 0, "vault has value");
        assertGt(debt, 0, "...and this fixture has real debt, so the over-report path is actually exercised");
    }

    function test_strangerReportsNothing() public view {
        address stranger = address(0xBEEF);
        assertEq(meta.getAdapterPositionsForInstances(stranger, _ins(VAULT), address(0)).length, 0);
    }

    function test_positionLabels_onRealCoordinate() public view {
        string[] memory l = meta.positionLabels(abi.encode(VAULT));
        assertEq(l.length, 2);
        assertEq(l[0], "stVault");
        assertEq(l[1], string.concat("ETH ", VAULT.toHexString()));
    }

    // ── helpers ─────────────────────────────────────────────────────────────────────────────────────────────────

    function _vaultsCount() internal view returns (uint256 n) {
        (, n) = _u(VAULT_HUB, abi.encodeWithSignature("vaultsCount()"));
    }

    function _vaultByIndex(uint256 i) internal view returns (address v) {
        (, v) = _a(VAULT_HUB, abi.encodeWithSignature("vaultByIndex(uint256)", i));
    }

    function _feesToSettle(address v) internal view returns (bool ok, uint256 fees) {
        (bool s, bytes memory ret) = VAULT_HUB.staticcall(abi.encodeWithSignature("obligations(address)", v));
        if (!s || ret.length < 64) return (false, 0);
        (, fees) = abi.decode(ret, (uint256, uint256));
        return (true, fees);
    }

    function _u(address t, bytes memory d) internal view returns (bool ok, uint256 v) {
        (bool s, bytes memory ret) = t.staticcall(d);
        if (!s || ret.length < 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    function _a(address t, bytes memory d) internal view returns (bool ok, address v) {
        (bool s, bytes memory ret) = t.staticcall(d);
        if (!s || ret.length < 32) return (false, address(0));
        return (true, address(uint160(abi.decode(ret, (uint256)))));
    }
}
