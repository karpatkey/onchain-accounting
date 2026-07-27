// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {
    GearboxV3CreditAccountsMetaBalanceAdapter,
    CollateralDebtData,
    CollateralCalcTask
} from "src/balances/MetaBalanceAdapters/GearboxV3CreditAccountsMetaBalanceAdapter.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {RawReplier, RawReplyLib} from "test/mocks/RawReplier.sol";

/// @notice ERC20-shaped collateral token mock with a settable per-holder balance (the adapter reads
///         `balanceOf(creditAccount)` for each enabled collateral token).
contract MockGearboxToken {
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;

    constructor(string memory symbol_, uint8 decimals_) {
        symbol = symbol_;
        decimals = decimals_;
    }

    function setBalance(address holder, uint256 amount) external {
        balanceOf[holder] = amount;
    }
}

/// @notice Minimal Gearbox V3 credit account: just the `creditManager()` back-pointer the adapter resolves.
contract MockCreditAccount {
    address public creditManager;

    constructor(address creditManager_) {
        creditManager = creditManager_;
    }
}

/// @notice Minimal Gearbox V3 CreditManager: per-account borrower / enabled-token mask / debt parts, a token-by-mask
///         registry, an underlying, and revert toggles to exercise the adapter's graceful-degradation paths.
contract MockCreditManager {
    string public name;
    address public underlying;

    mapping(uint256 mask => address token) public tokenByMask;
    mapping(address ca => address) public borrowerOf;
    mapping(address ca => uint256) public maskOf;
    mapping(address ca => uint256) public principalOf;
    mapping(address ca => uint256) public interestOf;
    mapping(address ca => uint256) public feesOf;

    bool public debtReverts;
    bool public infoReverts;

    constructor(string memory name_, address underlying_) {
        name = name_;
        underlying = underlying_;
    }

    function setToken(uint256 bit, address token) external {
        tokenByMask[bit] = token;
    }

    function setAccount(address ca, address borrower, uint256 mask, uint256 debt) external {
        borrowerOf[ca] = borrower;
        maskOf[ca] = mask;
        principalOf[ca] = debt;
    }

    function setDebtParts(address ca, uint256 principal, uint256 interest, uint256 fees) external {
        principalOf[ca] = principal;
        interestOf[ca] = interest;
        feesOf[ca] = fees;
    }

    function setDebtReverts(bool v) external {
        debtReverts = v;
    }

    function setInfoReverts(bool v) external {
        infoReverts = v;
    }

    function getTokenByMask(uint256 mask) external view returns (address) {
        return tokenByMask[mask];
    }

    function creditAccountInfo(address ca)
        external
        view
        returns (uint256, uint256, uint128, uint128, uint256, uint16, uint64, address)
    {
        if (infoReverts) revert("info");
        return (0, 0, 0, 0, maskOf[ca], 0, 0, borrowerOf[ca]);
    }

    function calcDebtAndCollateral(address ca, CollateralCalcTask)
        external
        view
        returns (CollateralDebtData memory cdd)
    {
        if (debtReverts) revert("debt");
        cdd.debt = principalOf[ca];
        cdd.accruedInterest = interestOf[ca];
        cdd.accruedFees = feesOf[ca];
    }
}

/// @title GearboxV3CreditAccountsMetaBalanceAdapter unit tests (no fork)
/// @notice Borrow-side Gearbox V3: per credit account, one Borrowed leg (debt in the pool underlying) + one
///         Collateral leg per enabled token (balanceOf), keyed on the credit account as the meta instance.
contract GearboxV3CreditAccountsMetaBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    GearboxV3CreditAccountsMetaBalanceAdapter adapter;

    MockGearboxToken usdc; // pool underlying (debt)
    MockGearboxToken weth; // collateral, bit 1<<3
    MockGearboxToken wbtc; // collateral, bit 1<<5
    MockCreditManager cm;
    MockCreditAccount ca;

    uint256 constant BIT_WETH = 1 << 3;
    uint256 constant BIT_WBTC = 1 << 5;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        usdc = new MockGearboxToken("USDC", 6);
        weth = new MockGearboxToken("WETH", 18);
        wbtc = new MockGearboxToken("WBTC", 8);
        nav.registerAsset(address(usdc), 6, "USDC");
        nav.registerAsset(address(weth), 18, "WETH");
        nav.registerAsset(address(wbtc), 8, "WBTC");

        cm = new MockCreditManager("Gearbox USDC v3", address(usdc));
        cm.setToken(BIT_WETH, address(weth));
        cm.setToken(BIT_WBTC, address(wbtc));

        ca = new MockCreditAccount(address(cm));

        adapter = new GearboxV3CreditAccountsMetaBalanceAdapter(address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(ca))));
    }

    /// @dev Alice owns `ca` with WETH+WBTC collateral and a USDC debt.
    function _seedAliceFullPosition() internal {
        cm.setAccount(address(ca), alice, BIT_WETH | BIT_WBTC, 1500e6);
        weth.setBalance(address(ca), 2e18);
        wbtc.setBalance(address(ca), 1e8);
    }

    // ----- ERC165 -----

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    // ----- no-arg base methods return empty (instance set lives on NAV) -----

    function test_noArgMethods_returnEmpty() public {
        _seedAliceFullPosition();
        assertEq(adapter.getAdapterPositions(alice, address(0)).length, 0);
        (address[] memory a, uint256[] memory amt, bool[] memory d) = adapter.getAdapterBalances(alice);
        assertEq(a.length, 0);
        assertEq(amt.length, 0);
        assertEq(d.length, 0);
        assertEq(adapter.underlyingAssetsSupported().length, 0);
    }

    // ----- collateral + borrow legs -----

    function test_collateralAndBorrow_legs() public {
        _seedAliceFullPosition();

        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));

        assertEq(pos.length, 3, "two collateral + one borrow");

        // Collateral legs first, in ascending mask-bit order (WETH bit < WBTC bit).
        assertEq(pos[0].balanceAsset.asset, address(weth));
        assertEq(pos[0].amount, 2e18);
        assertFalse(pos[0].isDebt);
        assertTrue(pos[0].positionKind == PositionKind.Collateral);

        assertEq(pos[1].balanceAsset.asset, address(wbtc));
        assertEq(pos[1].amount, 1e8);
        assertFalse(pos[1].isDebt);
        assertTrue(pos[1].positionKind == PositionKind.Collateral);

        // Borrow leg last — debt in the pool underlying (USDC), flagged isDebt.
        assertEq(pos[2].balanceAsset.asset, address(usdc));
        assertEq(pos[2].amount, 1500e6);
        assertTrue(pos[2].isDebt);
        assertTrue(pos[2].positionKind == PositionKind.Borrowed);

        // All legs share the credit-account positionId + Gearbox protocolId; instance id unused.
        for (uint256 i = 0; i < pos.length; i++) {
            assertEq(pos[i].balanceAdapter, address(adapter));
            assertEq(pos[i].positionId, abi.encode(address(ca)));
            assertEq(pos[i].protocolSubId, ProtocolIds.GEARBOX_V3_CREDIT_ACCOUNTS);
            assertEq(pos[i].protocolId, ProtocolIds.GEARBOX_V3);
            assertEq(pos[i].positionInstanceId, bytes32(0));
        }
    }

    function test_debt_includesPrincipalInterestAndFees() public {
        cm.setAccount(address(ca), alice, 0, 0); // borrower + (no collateral); debt set via parts below
        cm.setDebtParts(address(ca), 1000e6, 50e6, 10e6);

        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 1, "borrow only");
        assertEq(pos[0].amount, 1060e6, "principal + interest + fees");
        assertTrue(pos[0].isDebt);
    }

    function test_zeroDebt_collateralOnly() public {
        cm.setAccount(address(ca), alice, BIT_WETH, 0); // collateral, no debt (pure long)
        weth.setBalance(address(ca), 3e18);

        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 1, "collateral only, no borrow leg");
        assertEq(pos[0].balanceAsset.asset, address(weth));
        assertEq(pos[0].amount, 3e18);
        assertTrue(pos[0].positionKind == PositionKind.Collateral);
    }

    // ----- ownership gating -----

    function test_notBorrower_empty() public {
        _seedAliceFullPosition(); // owned by alice
        // Querying bob's NAV must not surface alice's credit account.
        assertEq(adapter.getAdapterPositionsForInstances(bob, _instances(), address(0)).length, 0);
    }

    function test_closedAccount_borrowerZero_empty() public {
        // A closed/liquidated account reads borrower == address(0).
        cm.setAccount(address(ca), address(0), BIT_WETH, 1000e6);
        weth.setBalance(address(ca), 1e18);
        assertEq(adapter.getAdapterPositionsForInstances(alice, _instances(), address(0)).length, 0);
    }

    // ----- never over-report: a failed debt read drops the WHOLE account (not just the borrow leg) -----

    function test_debtReadReverts_dropsWholeAccount() public {
        _seedAliceFullPosition();
        cm.setDebtReverts(true);
        // Collateral is present and readable, but without a valid debt figure we must report NOTHING — reporting
        // collateral with no offsetting debt would overstate equity.
        assertEq(adapter.getAdapterPositionsForInstances(alice, _instances(), address(0)).length, 0);
    }

    function test_infoReverts_empty() public {
        _seedAliceFullPosition();
        cm.setInfoReverts(true);
        assertEq(adapter.getAdapterPositionsForInstances(alice, _instances(), address(0)).length, 0);
    }

    // ----- registry / filter handling -----

    function test_unregisteredCollateral_skipped_othersSurvive() public {
        MockGearboxToken dai = new MockGearboxToken("DAI", 18); // NOT registered on NAV
        uint256 bitDai = 1 << 7;
        cm.setToken(bitDai, address(dai));
        cm.setAccount(address(ca), alice, BIT_WETH | bitDai, 1000e6);
        weth.setBalance(address(ca), 1e18);
        dai.setBalance(address(ca), 9e18);

        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));
        // WETH collateral + USDC borrow survive; unregistered DAI collateral dropped (under-report, never over).
        assertEq(pos.length, 2);
        assertEq(pos[0].balanceAsset.asset, address(weth));
        assertEq(pos[1].balanceAsset.asset, address(usdc));
        assertTrue(pos[1].isDebt);
    }

    function test_zeroCollateralBalance_skipped() public {
        cm.setAccount(address(ca), alice, BIT_WETH | BIT_WBTC, 500e6);
        weth.setBalance(address(ca), 1e18);
        // wbtc balance left at 0 → skipped.
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 2, "one collateral (weth) + borrow; zero-balance wbtc skipped");
        assertEq(pos[0].balanceAsset.asset, address(weth));
        assertEq(pos[1].balanceAsset.asset, address(usdc));
    }

    function test_assetFilter_collateralToken() public {
        _seedAliceFullPosition();
        // Filter to WETH → only the WETH collateral leg.
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(weth));
        assertEq(pos.length, 1);
        assertEq(pos[0].balanceAsset.asset, address(weth));
        assertTrue(pos[0].positionKind == PositionKind.Collateral);
    }

    function test_assetFilter_underlying_onlyBorrow() public {
        _seedAliceFullPosition();
        // Filter to USDC (the debt underlying) → only the borrow leg.
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(usdc));
        assertEq(pos.length, 1);
        assertEq(pos[0].balanceAsset.asset, address(usdc));
        assertTrue(pos[0].isDebt);
        assertTrue(pos[0].positionKind == PositionKind.Borrowed);
    }

    // ----- isolation, labels, assets -----

    function test_badInstance_isolated() public {
        _seedAliceFullPosition();
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead)))); // no code → reverts internally, isolated by fan-out
        ins[1] = bytes32(uint256(uint160(address(ca))));

        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(pos.length, 3, "bad instance isolated; good account's 3 legs returned");
    }

    function test_emptyInstances_returnsEmpty() public view {
        assertEq(adapter.getAdapterPositionsForInstances(alice, new bytes32[](0), address(0)).length, 0);
    }

    function test_positionLabels_returnsCreditManagerName() public {
        _seedAliceFullPosition();
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));
        string[] memory labels = adapter.positionLabels(pos[0].positionId);
        assertEq(labels.length, 2);
        assertEq(labels[0], "Credit Account");
        assertEq(labels[1], "Gearbox USDC v3");
    }

    function test_positionLabels_shortPositionId_empty() public view {
        assertEq(adapter.positionLabels(hex"1234").length, 0);
    }

    function test_underlyingAssetsForInstances() public {
        _seedAliceFullPosition();
        address[] memory assets = adapter.underlyingAssetsSupportedForInstances(_instances());
        // underlying (USDC) + enabled collateral tokens (WETH, WBTC).
        assertEq(assets.length, 3);
        assertEq(assets[0], address(usdc));
        assertEq(assets[1], address(weth));
        assertEq(assets[2], address(wbtc));
    }

    /// @dev The adapter already drops the whole account when the debt cannot be READ. The same must hold when
    ///      the debt is read but cannot be REPORTED — its underlying is not a registered asset — otherwise the
    ///      collateral legs are emitted alone and NAV is over-reported by the entire borrow.
    function test_unreportableDebtUnderlying_suppressesWholeAccount() public {
        _seedAliceFullPosition(); // WETH + WBTC collateral, 1500 USDC debt
        nav.unregisterAssetHelper(address(usdc)); // the pool underlying == the debt asset

        assertEq(
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0)).length,
            0,
            "collateral must not be reported without the unreportable debt"
        );
        assertEq(
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(weth)).length,
            0,
            "assetFilter must not resurrect the unoffset collateral legs"
        );
    }
}

/// @title GearboxV3CreditAccountsMetaBalanceAdapter — `positionLabels` fail-open tests
/// @notice `positionLabels` is a verbose/display-only path and MUST NOT revert, whatever the credit manager answers
///         with. `_creditManagerOf` guards the *credit account's* codesize but returns whatever `creditManager()`
///         said, so the resolved manager can be code-less — and a high-level call to it reverts via `extcodesize`
///         before the call, past any `catch`. A manager that answers `name()`/`underlying()` successfully but with
///         undecodable returndata reverts in this frame too, which `catch` also never sees. Each test stages one such
///         shape via {RawReplier} and asserts the label degrades to `["Credit Account"]`.
contract GearboxV3CreditAccountsMetaLabelReadTest is Test {
    /// @dev The gas the whole external `positionLabels` call may consume against a hostile manager. Comfortably above
    ///      the 100k stipends the adapter forwards, and far below what an uncapped probe costs.
    uint256 private constant GAS_CEILING = 1_000_000;

    address public constant CODELESS = 0x3333333333333333333333333333333333333333;

    Mock_NAVCalculator nav;
    GearboxV3CreditAccountsMetaBalanceAdapter adapter;
    MockGearboxToken usdc;
    RawReplier cmReplier;
    MockCreditAccount ca;

    function setUp() public {
        nav = new Mock_NAVCalculator();
        usdc = new MockGearboxToken("USDC", 6);
        nav.registerAsset(address(usdc), 6, "USDC");
        adapter = new GearboxV3CreditAccountsMetaBalanceAdapter(address(nav));

        cmReplier = new RawReplier();
        cmReplier.stageReturn(RawReplyLib.canonicalString("Trade WETH Tier 1"));
        ca = new MockCreditAccount(address(cmReplier));
    }

    function _labelsFor(address creditAccount) internal view returns (string[] memory) {
        return adapter.positionLabels(abi.encode(creditAccount));
    }

    function _assertCollapsed(address creditAccount, string memory why) internal view {
        string[] memory l = _labelsFor(creditAccount);
        assertEq(l.length, 1, why);
        assertEq(l[0], "Credit Account", why);
    }

    // ----- control -----

    function test_labels_canonicalName_renders() public view {
        string[] memory l = _labelsFor(address(ca));
        assertEq(l.length, 2);
        assertEq(l[0], "Credit Account");
        assertEq(l[1], "Trade WETH Tier 1");
    }

    /// @dev With `name()` empty the leaf falls back to the underlying's symbol — the tier-2 path must still work
    ///      through the rewritten readers.
    function test_labels_emptyName_fallsBackToUnderlyingSymbol() public {
        MockCreditManager plain = new MockCreditManager("", address(usdc));
        MockCreditAccount account = new MockCreditAccount(address(plain));
        string[] memory l = _labelsFor(address(account));
        assertEq(l.length, 2);
        assertEq(l[1], "USDC");
    }

    // ----- the credit manager itself -----

    /// @dev The mode the audit flagged: `_creditManagerOf` returns a non-zero but **code-less** manager, so the
    ///      high-level `name()` call reverted at the `extcodesize` precheck before the call was even made.
    function test_labels_codelessCreditManager_collapses() public {
        MockCreditAccount account = new MockCreditAccount(CODELESS);
        _assertCollapsed(address(account), "a code-less credit manager must not revert the label");
    }

    function test_labels_revertingCreditManager_collapses() public {
        cmReplier.stageRevert(4);
        _assertCollapsed(address(ca), "a reverting credit manager must not revert the label");
    }

    // ----- undecodable `name()` returndata (the class `try`/`catch` misses) -----

    /// @dev MKR-era shape: a single `bytes32` word where a `string` was declared.
    function test_labels_bytes32Name_collapses() public {
        cmReplier.stageReturn(RawReplyLib.bytes32String("Trade WETH Tier 1"));
        _assertCollapsed(address(ca), "a bytes32-shaped name must not revert the label");
    }

    /// @dev The proxy-with-code-less-implementation shape: `delegatecall` succeeds and returns nothing.
    function test_labels_emptyReturndataName_collapses() public {
        cmReplier.stageReturn("");
        _assertCollapsed(address(ca), "empty returndata must not revert the label");
    }

    function test_labels_offsetOnlyName_collapses() public {
        cmReplier.stageReturn(RawReplyLib.offsetOnly());
        _assertCollapsed(address(ca), "a head with no length word must not revert the label");
    }

    function test_labels_badOffsetName_collapses() public {
        cmReplier.stageReturn(RawReplyLib.badOffset(0x40, "Trade WETH Tier 1"));
        _assertCollapsed(address(ca), "a non-0x20 offset must not revert the label");
    }

    function test_labels_absurdLengthName_collapses() public {
        cmReplier.stageReturn(RawReplyLib.declaredLength(type(uint256).max, "x"));
        _assertCollapsed(address(ca), "an absurd declared length must not revert the label");
    }

    function test_labels_truncatedPayloadName_collapses() public {
        cmReplier.stageReturn(RawReplyLib.declaredLength(100, "short"));
        _assertCollapsed(address(ca), "a truncated payload must not revert the label");
    }

    // ----- undecodable `underlying()` returndata on the tier-2 fallback -----

    /// @dev `name()` degrades, so the reader falls through to `underlying()` — which here answers with the same
    ///      undecodable blob. `abi.decode(…, (address))` on a 2-byte reply would revert; the reader must not.
    function test_labels_shortUnderlyingWord_collapses() public {
        cmReplier.stageReturn(hex"1234");
        _assertCollapsed(address(ca), "a short underlying() reply must not revert the label");
    }

    // ----- bounds -----

    function test_labels_lengthCapBoundary() public {
        cmReplier.stageReturn(RawReplyLib.stringOfLength(256));
        assertEq(_labelsFor(address(ca)).length, 2, "256 bytes is inside the cap");

        cmReplier.stageReturn(RawReplyLib.stringOfLength(257));
        _assertCollapsed(address(ca), "past the cap the label degrades rather than rendering");
    }

    /// @notice A reply with a large zero-padded tail BEHIND a short, in-cap name must still render.
    /// @dev The Gearbox half of the same deliberate widening — see the twin test on the AaveV3 adapter. The
    ///      hand-rolled reader dropped this leaf; {LabelLib} renders it, which is the behaviour PR #165 landed
    ///      for the real Curve 4096-byte-buffer LP tokens.
    function test_labels_paddedBufferName_renders() public {
        bytes memory tail = new bytes(4096 - 64);
        bytes memory nm = bytes("Gearbox Padded v3");
        for (uint256 i = 0; i < nm.length; i++) {
            tail[i] = nm[i];
        }
        cmReplier.stageReturn(abi.encodePacked(uint256(0x20), nm.length, tail));

        string[] memory l = _labelsFor(address(ca));
        assertEq(l.length, 2, "an in-cap name must survive a large zero-padded tail");
        assertEq(l[1], "Gearbox Padded v3", "the name must decode verbatim");
    }

    function test_labels_oversizedReply_collapses() public {
        cmReplier.stageReturn(RawReplyLib.stringOfLength(2048));
        _assertCollapsed(address(ca), "an oversized reply must not revert or truncate");
    }

    /// @dev The gas cap is load-bearing: a raw `staticcall` assigning `(bool, bytes memory)` always
    ///      `returndatacopy`s the revert payload, which the parameterless `catch {}` this replaced never did.
    function test_labels_giantRevertPayload_isGasBounded() public {
        cmReplier.stageRevert(3_000_000);
        uint256 before = gasleft();
        _assertCollapsed(address(ca), "a giant revert payload must not revert the label");
        assertLt(before - gasleft(), GAS_CEILING, "the probe must be gas-capped");
    }

    function test_labels_gasBurningCreditManager_isGasBounded() public {
        cmReplier.stageBurnGas();
        uint256 before = gasleft();
        _assertCollapsed(address(ca), "a gas-burning credit manager must not revert the label");
        assertLt(before - gasleft(), GAS_CEILING, "the probe must be gas-capped");
    }
}

/// @title Gearbox tier-2 fallback — the underlying token's `symbol()` must be fail-open too
/// @notice `positionLabels` degrades to the underlying asset's symbol when `name()` is unusable. The address it
///         reads that symbol from comes from the credit manager's own `underlying()`, so it is attacker-chosen:
///         `_safeAddressRead` masks whatever word came back, and the manager itself is only reachable through
///         `creditManager()` on a governed instance — not governed itself. That makes the symbol read the last
///         unguarded hop in the chain.
contract GearboxV3CreditAccountsMetaTier2LeafTest is Test {
    uint256 private constant GAS_CEILING = 1_000_000;

    Mock_NAVCalculator nav;
    GearboxV3CreditAccountsMetaBalanceAdapter adapter;
    RawReplier hostileToken;
    MockCreditManager cm;
    MockCreditAccount ca;

    function setUp() public {
        nav = new Mock_NAVCalculator();
        adapter = new GearboxV3CreditAccountsMetaBalanceAdapter(address(nav));
        hostileToken = new RawReplier();
        // Empty name() forces the tier-2 fallback; underlying() points at the hostile token.
        cm = new MockCreditManager("", address(hostileToken));
        ca = new MockCreditAccount(address(cm));
    }

    function _assertCollapsed(string memory why) internal view {
        string[] memory l = adapter.positionLabels(abi.encode(address(ca)));
        assertEq(l.length, 1, why);
        assertEq(l[0], "Credit Account", why);
    }

    /// @dev The residual decode gap: `symbol()` succeeds with a `bytes32` where a `string` was declared.
    function test_tier2_bytes32Symbol_collapses() public {
        hostileToken.stageReturn(RawReplyLib.bytes32String("USDC"));
        _assertCollapsed("a bytes32-shaped symbol must not revert the label");
    }

    function test_tier2_emptyReturndataSymbol_collapses() public {
        hostileToken.stageReturn("");
        _assertCollapsed("empty symbol returndata must not revert the label");
    }

    function test_tier2_truncatedPayloadSymbol_collapses() public {
        hostileToken.stageReturn(RawReplyLib.declaredLength(100, "short"));
        _assertCollapsed("a truncated symbol payload must not revert the label");
    }

    function test_tier2_absurdLengthSymbol_collapses() public {
        hostileToken.stageReturn(RawReplyLib.declaredLength(type(uint256).max, "x"));
        _assertCollapsed("an absurd declared symbol length must not revert the label");
    }

    /// @dev The gas leak. `NAVCalculator._safeStringArray` staticcalls `positionLabels` with NO `{gas:}` cap, so an
    ///      unbounded hop here drains 63/64 of the whole verbose read, not just this position.
    function test_tier2_gasBurningToken_isGasBounded() public {
        hostileToken.stageBurnGas();
        uint256 before = gasleft();
        _assertCollapsed("a gas-burning underlying token must not revert the label");
        assertLt(before - gasleft(), GAS_CEILING, "the tier-2 symbol probe must be gas-capped");
    }

    /// @dev A well-behaved token still renders, so the hardening did not break tier 2.
    function test_tier2_canonicalSymbol_stillRenders() public {
        hostileToken.stageReturn(RawReplyLib.canonicalString("USDC"));
        string[] memory l = adapter.positionLabels(abi.encode(address(ca)));
        assertEq(l.length, 2);
        assertEq(l[1], "USDC");
    }

    /// @dev `positionLabels` is display-only and must never revert, and must never label a coordinate this adapter
    ///      never emitted. Both were reachable before: `abi.decode(pid, (address))` reverts on a word with dirty
    ///      upper 96 bits, and a `pid.length < 32` guard let a foreign MULTI-word coordinate through to be labelled
    ///      from its first word. The decode now goes through `MetaBalanceAdapter._pidAddress`, whose own accept window is
    ///      pinned exhaustively in `test/balances/MetaBalanceAdapterPidGuards.t.sol`; this case pins that THIS
    ///      adapter routes through it.
    ///
    ///      The clean-coordinate assertion is what keeps the rest load-bearing. A shape-valid but unknown
    ///      coordinate still resolves to the category-only label (the fail-open leaf collapse), so a view that
    ///      rejected everything would fail here rather than pass the rejections trivially.

    function test_positionLabels_malformedPositionId_returnsEmpty() public view {
        address coord = address(0xBEEF);

        assertGt(adapter.positionLabels(abi.encode(coord)).length, 0, "one clean word is the accepted shape");

        assertEq(adapter.positionLabels("").length, 0, "empty");
        assertEq(adapter.positionLabels(hex"0102030405060708090a0b0c").length, 0, "truncated");
        uint256 dirty = uint256(uint160(coord)) | (uint256(1) << 255);
        assertEq(adapter.positionLabels(abi.encode(dirty)).length, 0, "dirty upper bits");
        assertEq(adapter.positionLabels(abi.encode(coord, uint256(1))).length, 0, "over-long");
    }
}
