// SPDX-License-Identifier: BUSL-1.1
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
        address impl = address(new MockBridgeAdapter(address(0)));
        address payable proxy = payable(address(
                UnsafeUpgrades.deployUUPSProxy(
                    impl, abi.encodeCall(MockBridgeAdapter.initialize, (admin, address(bridgeEscrow), "Mock", "1.0.0"))
                )
            ));
        adapter = MockBridgeAdapter(proxy);
        vm.label(address(adapter), "MockBridgeAdapter");

        vm.startPrank(admin);
        adapter.grantRole(adapter.MANAGER_ROLE(), manager);
        vm.stopPrank();
    }

    // ============ initialize front-run guard ============

    /// @notice With a non-zero expectedInitializer baked in, only that address can initialize — a
    ///         front-runner that pre-deploys/races the deterministic address cannot capture admin.
    function test_initialize_onlyExpectedInitializerCanInitialize() public {
        address guard = makeAddr("pinnedDeployer");
        address attacker = makeAddr("frontRunner");

        // Deploy directly (production shape, not a proxy) with a pinned initializer.
        MockBridgeAdapter guarded = new MockBridgeAdapter(guard);

        // A caller other than the pinned initializer is rejected.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        guarded.initialize(attacker, address(bridgeEscrow), "Mock", "1.0.0");

        // The pinned initializer succeeds and the supplied admin receives DEFAULT_ADMIN_ROLE.
        vm.prank(guard);
        guarded.initialize(admin, address(bridgeEscrow), "Mock", "1.0.0");
        assertTrue(guarded.hasRole(bytes32(0), admin), "admin should hold DEFAULT_ADMIN_ROLE");
    }

    // ============ bridge() ============

    function test_bridge_onlyAcceptsBridgeEscrowAsCaller() public {
        uint256 amount = BRIDGE_AMOUNT;
        InvoiceDataLib.InvoiceData memory data =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(data);

        vm.prank(makeAddr("random"));
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        adapter.bridge(messagePayload);
    }

    function test_bridge_successWhenCalledByEscrow() public {
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        require(usdc.transfer(address(bridgeEscrow), BRIDGE_AMOUNT), "transfer failed");
        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), BRIDGE_AMOUNT);

        InvoiceDataLib.InvoiceData memory data =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, BRIDGE_AMOUNT);
        bytes memory messagePayload = InvoiceDataLib.encode(data);

        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);
        assertEq(adapter.bridgeProvider(), "Mock", "Provider name should match");
        assertEq(adapter.version(), "1.0.0", "Version should match");
    }

    // ============ completeBridge() ============
    // completeBridge is tested in adapter-specific tests (Across, CCTP, etc.) because it records the delivery into escrow custody and requires valid messagePayload + destination escrow. We test revert when not manager and when empty payload.

    function test_completeBridge_revertsWhenNotManager() public {
        InvoiceDataLib.InvoiceData memory data =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, BRIDGE_AMOUNT);
        bytes memory messagePayload = InvoiceDataLib.encode(data);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        adapter.completeBridge(messagePayload, "");
    }

    function test_completeBridge_revertsWhenMessagePayloadEmpty() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(InvalidCompletionData.selector));
        adapter.completeBridge("", "");
    }

    // ============ recoverStuckAssets ============

    // ADR 0012 (H11): recoverStuckAssets `to` MUST be the escrow or an escrow-authorized account.
    // `account` is authorized in setUp; use it as the recovery recipient.

    function test_recoverStuckAssets_erc20Success() public {
        usdc.mint(address(adapter), 5000e6);
        address to = account; // escrow-authorized recipient
        uint256 toBalanceBefore = usdc.balanceOf(to);

        vm.prank(manager);
        adapter.recoverStuckAssets(address(usdc), 5000e6, to);

        assertEq(usdc.balanceOf(to), toBalanceBefore + 5000e6, "Recipient should receive tokens");
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have zero balance");
    }

    function test_recoverStuckAssets_nativeSuccess() public {
        vm.deal(address(adapter), 2 ether);
        address to = account; // escrow-authorized recipient
        uint256 toBalanceBefore = to.balance;

        vm.prank(manager);
        adapter.recoverStuckAssets(address(0), 2 ether, to);

        assertEq(to.balance, toBalanceBefore + 2 ether, "Recipient should receive ETH");
        assertEq(address(adapter).balance, 0, "Adapter should have zero ETH");
    }

    function test_recoverStuckAssets_toEscrowSucceeds() public {
        usdc.mint(address(adapter), 1000e6);
        uint256 escrowBefore = usdc.balanceOf(address(bridgeEscrow));

        vm.prank(manager);
        adapter.recoverStuckAssets(address(usdc), 1000e6, address(bridgeEscrow));

        assertEq(usdc.balanceOf(address(bridgeEscrow)), escrowBefore + 1000e6, "Escrow should receive tokens");
    }

    function test_RevertWhen_recoverStuckAssets_notManager() public {
        usdc.mint(address(adapter), 1000e6);
        vm.prank(unauthorized);
        vm.expectRevert();
        adapter.recoverStuckAssets(address(usdc), 1000e6, account);
    }

    /// @notice ADR 0012 (H11): recovering to an arbitrary (non-authorized) address reverts NotAuthorized.
    function test_RevertWhen_recoverStuckAssets_toUnauthorizedRecipient() public {
        usdc.mint(address(adapter), 1000e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        adapter.recoverStuckAssets(address(usdc), 1000e6, makeAddr("arbitrary"));
    }

    function test_RevertWhen_recoverStuckAssets_toZero() public {
        // address(0) is not an authorized account, so the H11 recipient check rejects it.
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        adapter.recoverStuckAssets(address(usdc), 1, address(0));
    }

    function test_RevertWhen_recoverStuckAssets_amountZero() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(InvalidArguments.selector));
        adapter.recoverStuckAssets(address(usdc), 0, account);
    }

    function test_RevertWhen_recoverStuckAssets_insufficientBalance() public {
        usdc.mint(address(adapter), 100e6);
        vm.prank(manager);
        vm.expectRevert(); // InsufficientBalance
        adapter.recoverStuckAssets(address(usdc), 200e6, account);
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
        address to = account; // ADR 0012 (H11): recipient must be escrow-authorized
        uint256 toBalanceBefore = usdc.balanceOf(to);

        vm.prank(manager);
        adapter.recoverStuckAssets(address(usdc), amount, to);

        assertEq(usdc.balanceOf(to), toBalanceBefore + amount, "Recipient should receive full amount");
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter balance should be zero");
    }
}
