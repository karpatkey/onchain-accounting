// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    GearboxV3CreditAccountsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/GearboxV3CreditAccountsMetaBalanceAdapter.sol";
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
}
