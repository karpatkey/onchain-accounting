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

        adapter = new GearboxV3CreditAccountsMetaBalanceAdapter("Gearbox", address(nav));
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
