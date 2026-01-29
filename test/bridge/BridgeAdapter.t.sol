// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {BridgeAdapter} from "src/bridge/BridgeAdapter.sol";
import {IBridgeAdapter} from "src/bridge/IBridgeAdapter.sol";
import {InvoiceDataLib} from "src/bridge/InvoiceDataLib.sol";
import {MockBridgeAdapter} from "test/bridge/mocks/MockBridgeAdapter.sol";
import {BridgeTestBase} from "test/bridge/BridgeTestBase.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";

/// @title BridgeAdapterTest
/// @notice Unit tests for base BridgeAdapter behavior via MockBridgeAdapter
contract BridgeAdapterTest is BridgeTestBase {
    MockBridgeAdapter public adapter;

    function setUp() public override {
        super.setUp();
        _deployAdapter();
        _authorizeAdapter(address(adapter));
    }

    function _deployAdapter() internal {
        address impl = address(new MockBridgeAdapter());
        address payable proxy = payable(address(
                UnsafeUpgrades.deployUUPSProxy(
                    impl, abi.encodeCall(BridgeAdapter.initialize, (admin, address(bridgeEscrow), "Mock", "1.0.0"))
                )
            ));
        adapter = MockBridgeAdapter(proxy);
        vm.label(address(adapter), "MockBridgeAdapter");

        vm.startPrank(admin);
        adapter.grantRole(adapter.OPERATOR_ROLE(), operator);
        vm.stopPrank();
    }

    // ============ bridge() ============

    function test_bridge_onlyAcceptsBridgeEscrowAsCaller() public {
        uint256 amount = BRIDGE_AMOUNT;
        InvoiceDataLib.InvoiceData memory data =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(data);

        vm.prank(makeAddr("random"));
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        adapter.bridge(messagePayload);
    }

    function test_bridge_successWhenCalledByEscrow() public {
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(portfolioSafe);
        require(usdc.transfer(address(bridgeEscrow), BRIDGE_AMOUNT), "transfer failed");
        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), BRIDGE_AMOUNT);

        InvoiceDataLib.InvoiceData memory data =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, BRIDGE_AMOUNT);
        bytes memory messagePayload = InvoiceDataLib.encode(data);

        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);
        assertEq(adapter.bridgeProvider(), "Mock", "Provider name should match");
        assertEq(adapter.version(), "1.0.0", "Version should match");
    }

    // ============ completeBridge() ============
    // completeBridge is tested in adapter-specific tests (Across, CCTP, etc.) because it calls releaseByInvoiceId on escrow and requires valid messagePayload + destination escrow. We test revert when not operator and when empty payload.

    function test_completeBridge_revertsWhenNotOperator() public {
        InvoiceDataLib.InvoiceData memory data =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, BRIDGE_AMOUNT);
        bytes memory messagePayload = InvoiceDataLib.encode(data);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        adapter.completeBridge(messagePayload, "");
    }

    function test_completeBridge_revertsWhenMessagePayloadEmpty() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(InvalidCompletionData.selector));
        adapter.completeBridge("", "");
    }

    // ============ recoverStuckAssets ============

    function test_recoverStuckAssets_erc20Success() public {
        usdc.mint(address(adapter), 5000e6);
        address to = makeAddr("recoveryTo");

        vm.prank(operator);
        adapter.recoverStuckAssets(address(usdc), 5000e6, to);

        assertEq(usdc.balanceOf(to), 5000e6, "Recipient should receive tokens");
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have zero balance");
    }

    function test_recoverStuckAssets_nativeSuccess() public {
        vm.deal(address(adapter), 2 ether);
        address to = makeAddr("recoveryTo");
        uint256 toBalanceBefore = to.balance;

        vm.prank(operator);
        adapter.recoverStuckAssets(address(0), 2 ether, to);

        assertEq(to.balance, toBalanceBefore + 2 ether, "Recipient should receive ETH");
        assertEq(address(adapter).balance, 0, "Adapter should have zero ETH");
    }

    function test_RevertWhen_recoverStuckAssets_notOperator() public {
        usdc.mint(address(adapter), 1000e6);
        vm.prank(unauthorized);
        vm.expectRevert();
        adapter.recoverStuckAssets(address(usdc), 1000e6, makeAddr("to"));
    }

    function test_RevertWhen_recoverStuckAssets_toZero() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(InvalidArguments.selector));
        adapter.recoverStuckAssets(address(usdc), 1, address(0));
    }

    function test_RevertWhen_recoverStuckAssets_amountZero() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(InvalidArguments.selector));
        adapter.recoverStuckAssets(address(usdc), 0, makeAddr("to"));
    }

    function test_RevertWhen_recoverStuckAssets_insufficientBalance() public {
        usdc.mint(address(adapter), 100e6);
        vm.prank(operator);
        vm.expectRevert(); // InsufficientBalance
        adapter.recoverStuckAssets(address(usdc), 200e6, makeAddr("to"));
    }

    // ============ View / ERC165 ============

    function test_bridgeProvider_returnsName() public view {
        assertEq(adapter.bridgeProvider(), "Mock", "Provider name");
    }

    function test_version_returnsVersion() public view {
        assertEq(adapter.version(), "1.0.0", "Version");
    }

    function test_bridgeEscrow_returnsEscrowAddress() public view {
        assertEq(adapter.bridgeEscrow(), address(bridgeEscrow), "Bridge escrow address");
    }

    function test_supportsInterface_IBridgeAdapter() public view {
        assertTrue(adapter.supportsInterface(type(IBridgeAdapter).interfaceId), "Should support IBridgeAdapter");
    }

    // ============ Fuzz ============

    function testFuzz_recoverStuckAssets_erc20(uint96 amount) public {
        amount = uint96(bound(amount, 1, type(uint96).max / 2));
        usdc.mint(address(adapter), amount);
        address to = makeAddr("recoveryTo");

        vm.prank(operator);
        adapter.recoverStuckAssets(address(usdc), amount, to);

        assertEq(usdc.balanceOf(to), amount, "Recipient should receive full amount");
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter balance should be zero");
    }
}
