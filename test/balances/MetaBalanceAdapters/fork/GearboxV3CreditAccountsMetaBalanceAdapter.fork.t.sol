// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    GearboxV3CreditAccountsMetaBalanceAdapter,
    ICreditManagerV3,
    ICreditAccountV3
} from "src/balances/MetaBalanceAdapters/GearboxV3CreditAccountsMetaBalanceAdapter.sol";
import {RawReplier, RawReplyLib} from "test/mocks/RawReplier.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title GearboxV3CreditAccountsMetaForkTest
/// @notice Fork test for the Gearbox V3 credit-accounts meta-adapter against a real, open mainnet credit account.
/// @dev At the pinned block, credit account `CREDIT_ACCOUNT` (managed by the WETH-market "Tier 2" CreditManager
///      `0x9A0fDF7CdAb4604FC27ebeab4b3D57BD825e8ebe`) is owned by `BORROWER` and holds a leveraged weETH basket
///      against a WETH debt:
///        - collateral: ~99.25 weETH (the only enabled token with a non-zero balance; its enabled WETH balance is 0,
///          so the adapter skips that leg);
///        - debt: ~99.84 WETH (principal + accrued interest + fees from `calcDebtAndCollateral(ca, DEBT_ONLY)`).
///      The adapter therefore emits exactly two legs: one Collateral (weETH) and one Borrowed (WETH). Assertions are
///      kept tolerant to small interest drift around the pin (range checks, not exact wei).
contract GearboxV3CreditAccountsMetaForkTest is BalanceAdapterTestBase {
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // pool underlying (debt)
    address public constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee; // enabled collateral token

    // Real, open Gearbox V3 credit account (the meta instance) + its borrower at the pinned block.
    address public constant CREDIT_ACCOUNT = 0xc5F40BFdd6A94f20a61fd6F2692BA861CCD9aD79;
    address public constant BORROWER = 0xd25B400836FC3376029Bef3831C364E16C780de8;

    uint256 public constant FORK_BLOCK = 25_420_000;

    GearboxV3CreditAccountsMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp();
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        address[] memory assets = new address[](2);
        assets[0] = WETH;
        assets[1] = WEETH;
        balances = _deployBalancesForAdapter(assets);
        meta = new GearboxV3CreditAccountsMetaBalanceAdapter("Gearbox", address(balances));
    }

    function _instance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(CREDIT_ACCOUNT)));
    }

    /// @notice The adapter surfaces the real borrower's collateral (weETH) and borrow (WETH) legs with the right
    ///         signs, kinds, amounts, and identity fields.
    function test_creditAccount_collateralAndBorrowLegs() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(BORROWER, _instance(), address(0));

        // weETH collateral + WETH borrow (the zero-balance WETH collateral leg is skipped).
        assertEq(p.length, 2, "expected one collateral + one borrow leg");

        bool sawCollateral;
        bool sawBorrow;
        for (uint256 i = 0; i < p.length; i++) {
            // Identity + audit-trail fields are uniform across legs.
            assertEq(p[i].balanceAdapter, address(meta), "balanceAdapter must be the adapter");
            assertEq(p[i].positionId, abi.encode(CREDIT_ACCOUNT), "positionId is the credit account");
            assertEq(p[i].protocolBrand, ProtocolIds.GEARBOX, "protocolBrand");
            assertEq(p[i].protocolId, ProtocolIds.GEARBOX_V3, "protocolId");
            assertEq(p[i].protocolSubId, ProtocolIds.GEARBOX_V3_CREDIT_ACCOUNTS, "protocolSubId");
            assertEq(p[i].positionInstanceId, bytes32(0), "positionInstanceId unused for credit accounts");

            if (p[i].positionKind == PositionKind.Collateral) {
                sawCollateral = true;
                assertEq(p[i].balanceAsset.asset, WEETH, "collateral is weETH");
                assertFalse(p[i].isDebt, "collateral leg is not debt");
                // ~99.25 weETH at the pin; tolerate drift with a wide band.
                assertGt(p[i].amount, 90e18, "weETH collateral > 90");
                assertLt(p[i].amount, 110e18, "weETH collateral < 110");
            } else if (p[i].positionKind == PositionKind.Borrowed) {
                sawBorrow = true;
                assertEq(p[i].balanceAsset.asset, WETH, "borrow underlying is WETH");
                assertTrue(p[i].isDebt, "borrow leg is flagged isDebt");
                // ~99.84 WETH (principal + interest + fees) at the pin.
                assertGt(p[i].amount, 90e18, "WETH debt > 90");
                assertLt(p[i].amount, 110e18, "WETH debt < 110");
            } else {
                revert("unexpected position kind");
            }
        }
        assertTrue(sawCollateral, "missing collateral leg");
        assertTrue(sawBorrow, "missing borrow leg");
    }

    /// @notice The credit account is only ever attributed to its real borrower — querying another account yields
    ///         nothing (ownership re-verified on-chain per read).
    function test_notBorrower_returnsEmpty() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(address(0xBEEF), _instance(), address(0));
        assertEq(p.length, 0, "non-borrower must not see the credit account");
    }

    /// @notice The hardened name reader decodes a REAL mainnet CreditManager byte-for-byte the same as a plain
    ///         high-level call does.
    /// @dev The unit tests prove the malformed shapes degrade; this proves the rewrite did not break the canonical
    ///      path against production bytecode.
    function test_positionLabels_realCreditManager_matchesDirectRead() public view {
        address cm = ICreditAccountV3(CREDIT_ACCOUNT).creditManager();
        string memory direct = ICreditManagerV3(cm).name();
        assertGt(bytes(direct).length, 0, "the real credit manager name is non-empty");

        string[] memory labels = meta.positionLabels(abi.encode(CREDIT_ACCOUNT));
        assertEq(labels.length, 2, "category + name");
        assertEq(labels[0], "Credit Account");
        assertEq(labels[1], direct, "label leaf must equal the manager's own name()");
    }

    /// @notice Every uncaught failure mode degrades to `["Credit Account"]` against the real deployed adapter.
    /// @dev The credit account is a governed instance coordinate, but `_creditManagerOf` returns whatever
    ///      `creditManager()` answered — so the manager can be code-less or hostile even when the account is not.
    ///      A `try`/`catch` reader reverts on all of these.
    function test_positionLabels_hostileCreditManager_degradesOnFork() public {
        RawReplier cm = new RawReplier();
        FakeCreditAccount account = new FakeCreditAccount(address(cm));

        bytes[] memory shapes = new bytes[](4);
        shapes[0] = RawReplyLib.bytes32String("Trade WETH Tier 2"); // MKR-era bytes32 string
        shapes[1] = ""; // proxy to a code-less implementation
        shapes[2] = RawReplyLib.offsetOnly(); // head with no length word
        shapes[3] = RawReplyLib.declaredLength(100, "short"); // truncated payload

        for (uint256 i = 0; i < shapes.length; i++) {
            cm.stageReturn(shapes[i]);
            string[] memory labels = meta.positionLabels(abi.encode(address(account)));
            assertEq(labels.length, 1, "must degrade, not revert");
            assertEq(labels[0], "Credit Account");
        }

        // A credit manager with no code at all — the mode the `extcodesize` precheck reverts on, past any `catch`.
        FakeCreditAccount codeless = new FakeCreditAccount(address(0xdead));
        assertEq(meta.positionLabels(abi.encode(address(codeless))).length, 1, "code-less manager must degrade");
    }

    /// @notice A hostile credit manager cannot burn the caller's gas budget through the label path.
    function test_positionLabels_hostileCreditManager_isGasBounded() public {
        RawReplier cm = new RawReplier();
        FakeCreditAccount account = new FakeCreditAccount(address(cm));

        cm.stageBurnGas();
        uint256 before = gasleft();
        meta.positionLabels(abi.encode(address(account)));
        assertLt(before - gasleft(), 1_000_000, "gas-burning manager must be capped");

        cm.stageRevert(3_000_000);
        before = gasleft();
        meta.positionLabels(abi.encode(address(account)));
        assertLt(before - gasleft(), 1_000_000, "giant revert payload must be capped");
    }
}

/// @notice A credit account whose `creditManager()` points wherever the test wants — including at a {RawReplier}.
contract FakeCreditAccount {
    address public creditManager;

    constructor(address creditManager_) {
        creditManager = creditManager_;
    }
}
