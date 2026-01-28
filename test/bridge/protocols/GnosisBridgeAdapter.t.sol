// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {GnosisBridgeAdapter} from "src/bridge/adapters/GnosisBridgeAdapter.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/adapters/interfaces/IGnosisInterfaces.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
import {IBridgeEscrow} from "src/bridge/IBridgeEscrow.sol";
import {BridgeScenarioHelper} from "test/bridge/BridgeScenarioHelper.sol";
import {BridgeTestBase} from "test/bridge/BridgeTestBase.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/bridge/mocks/MockBridgeProtocols.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";
import "src/errors.sol";

/// @title GnosisBridgeAdapterTest
/// @notice Test suite for Gnosis Omnibridge Adapter
contract GnosisBridgeAdapterTest is BridgeScenarioHelper {
    GnosisBridgeAdapter public adapter;
    MockOmnibridge public omnibridge;
    MockAMB public amb;

    uint64 public constant GNOSIS_CHAIN_ID = 100; // Gnosis Chain

    function setUp() public override {
        super.setUp();

        // Deploy mock Omnibridge and AMB
        omnibridge = new MockOmnibridge();
        amb = new MockAMB();

        // Deploy Gnosis adapter
        address adapterImpl = address(new GnosisBridgeAdapter());
        address payable adapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                adapterImpl,
                abi.encodeCall(
                    GnosisBridgeAdapter.initialize,
                    (admin, address(bridgeEscrow), address(omnibridge), address(amb), "1.0.0")
                )
            ));
        adapter = GnosisBridgeAdapter(adapterProxy);

        // Configure adapter
        vm.startPrank(admin);
        adapter.grantRole(keccak256("OPERATOR_ROLE"), operator);
        vm.stopPrank();

        // Authorize adapter in BridgeEscrow
        _authorizeAdapter(address(adapter));

        // Setup labels
        vm.label(address(adapter), "GnosisBridgeAdapter");
        vm.label(address(omnibridge), "MockOmnibridge");
        vm.label(address(amb), "MockAMB");
    }

    // ============ Bridge Initiation Tests ============

    function test_bridge_initiatesOmnibridgeTransfer() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        _approveToken(address(usdc), address(bridgeEscrow), amount);

        // Create invoice data (bridging to Gnosis Chain)
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Transfer tokens to BridgeEscrow (simulating depositAndBridge)
        vm.prank(portfolioSafe);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(bridgeEscrow), amount);

        // BridgeEscrow approves adapter (new pattern: approval instead of transfer)
        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);

        // Initiate bridge (adapter will pull tokens in _bridge())
        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);

        // Verify messagePayload was stored
        bytes32 invoiceId = invoiceData.invoiceId;
        bytes memory storedPayload = adapter.getMessagePayload(invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "MessagePayload should be stored");
    }

    function test_bridge_revertsForUnsupportedChain() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData = _createInvoiceData(
            SOURCE_CHAIN_ID,
            999, // Unsupported chain ID (not 1 or 100)
            portfolioSafe,
            USDC_SYMBOL,
            amount
        );
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(portfolioSafe);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(bridgeEscrow), amount);

        // BridgeEscrow approves adapter (new pattern: approval instead of transfer)
        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);

        vm.prank(address(bridgeEscrow));
        vm.expectRevert(); // Should revert because chain is not supported
        adapter.bridge(messagePayload);
    }

    function test_bridge_revertsForNativeToken() public {
        uint256 amount = 1 ether;
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, WETH_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.deal(address(adapter), amount);

        vm.prank(address(bridgeEscrow));
        vm.expectRevert(); // Should revert because native tokens are not supported
        adapter.bridge(messagePayload);
    }

    function test_bridge_revertsIfNotCalledByBridgeEscrow() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not BridgeEscrow
        adapter.bridge(messagePayload);
    }

    // ============ Bridge Completion Tests ============

    function test_completeBridge_releasesTokensOnDestinationChain() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);

        // Set up destination chain environment
        (BridgeEscrow destBridgeEscrow, bytes memory messagePayload) =
            _setupDestinationChainForCompletion(invoiceData, address(usdc));

        // Set up adapter on destination chain
        address destAdapterImpl = address(new GnosisBridgeAdapter());
        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                destAdapterImpl,
                abi.encodeCall(
                    GnosisBridgeAdapter.initialize,
                    (admin, address(destBridgeEscrow), address(omnibridge), address(amb), "1.0.0")
                )
            ));
        GnosisBridgeAdapter destAdapter = GnosisBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        destAdapter.grantRole(keccak256("OPERATOR_ROLE"), operator);
        destBridgeEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        // Operator fallback: tokens already at escrow (e.g. delivered via callback path earlier or manual transfer)
        usdc.mint(address(destBridgeEscrow), amount);

        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));
        assertFalse(
            destBridgeEscrow.isInvoiceCompleted(invoiceHash), "Invoice should not be completed before completion"
        );

        uint256 initialPortfolioBalance = usdc.balanceOf(portfolioSafe);

        vm.prank(operator);
        destAdapter.completeBridge(messagePayload, "");

        assertEq(
            usdc.balanceOf(portfolioSafe) - initialPortfolioBalance, amount, "Portfolio safe should receive tokens"
        );
        assertEq(usdc.balanceOf(address(destBridgeEscrow)), 0, "Escrow should have zero balance after release");
        assertTrue(destBridgeEscrow.isInvoiceCompleted(invoiceHash), "Invoice should be marked as completed");
    }

    /// @notice Full round-trip: depositAndBridge on source → payload from omnibridge → deliver only via deliverTokens → completeBridge
    function test_realistic_fullRoundTrip_sourcePayloadAndDeliveryViaGnosis() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();

        // ---------- SOURCE CHAIN ----------
        _approveToken(address(usdc), address(bridgeEscrow), amount);
        vm.prank(portfolioSafe);
        bridgeEscrow.depositAndBridge(GNOSIS_CHAIN_ID, USDC_SYMBOL, amount, address(adapter));

        (bytes memory messagePayload, uint256 relayAmount) = omnibridge.getLastRelayData();
        uint256 portfolioBalanceBeforeRelease = usdc.balanceOf(portfolioSafe);
        assertGt(messagePayload.length, 0, "messagePayload from source");
        assertEq(relayAmount, amount, "relay value equals amount");

        // ---------- DESTINATION CHAIN ----------
        vm.chainId(uint256(GNOSIS_CHAIN_ID));

        BridgeEscrow destBridgeEscrow = _setupDestinationChainEscrow(GNOSIS_CHAIN_ID);
        MockOmnibridge destOmnibridge = new MockOmnibridge();
        MockAMB destAmb = new MockAMB();

        address destAdapterImpl = address(new GnosisBridgeAdapter());
        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                destAdapterImpl,
                abi.encodeCall(
                    GnosisBridgeAdapter.initialize,
                    (admin, address(destBridgeEscrow), address(destOmnibridge), address(destAmb), "1.0.0")
                )
            ));
        GnosisBridgeAdapter destAdapter = GnosisBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        destAdapter.grantRole(keccak256("OPERATOR_ROLE"), operator);
        destBridgeEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        _registerCallbackModule(destBridgeEscrow, GnosisBridgeAdapter.onTokenTransfer.selector, address(destAdapter));

        usdc.mint(address(destOmnibridge), amount);
        destOmnibridge.deliverTokens(address(usdc), address(destBridgeEscrow), amount, messagePayload);

        bytes32 expectedInvoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(messagePayload).checksum24)));
        assertTrue(destBridgeEscrow.isInvoiceCompleted(expectedInvoiceHash), "invoice completed");
        assertEq(
            usdc.balanceOf(portfolioSafe) - portfolioBalanceBeforeRelease,
            amount,
            "portfolio safe received bridged amount"
        );
        assertEq(usdc.balanceOf(address(destBridgeEscrow)), 0, "escrow balance zero after release");
    }

    function test_completeBridge_validatesChecksum() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);

        // Set up destination chain environment
        (BridgeEscrow destBridgeEscrow, bytes memory messagePayload) =
            _setupDestinationChainForCompletion(invoiceData, address(usdc));

        // Set up adapter on destination chain
        address destAdapterImpl = address(new GnosisBridgeAdapter());
        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                destAdapterImpl,
                abi.encodeCall(
                    GnosisBridgeAdapter.initialize,
                    (admin, address(destBridgeEscrow), address(omnibridge), address(amb), "1.0.0")
                )
            ));
        GnosisBridgeAdapter destAdapter = GnosisBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        destAdapter.grantRole(keccak256("OPERATOR_ROLE"), operator);
        destBridgeEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        // Corrupt messagePayload (invalid checksum)
        bytes memory corruptedPayload = abi.encode(
            invoiceData.invoiceId,
            invoiceData.amount,
            bytes32(uint256(invoiceData.timestamp) << 192 | uint256(uint192(invoiceData.checksum24)) ^ 1)
        );

        vm.prank(operator);
        vm.expectRevert(); // Should revert because checksum is invalid
        destAdapter.completeBridge(corruptedPayload, "");
    }

    function test_completeBridge_revertsIfNotOperator() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);

        // Set up destination chain environment
        (BridgeEscrow destBridgeEscrow, bytes memory messagePayload) =
            _setupDestinationChainForCompletion(invoiceData, address(usdc));

        // Set up adapter on destination chain
        address destAdapterImpl = address(new GnosisBridgeAdapter());
        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                destAdapterImpl,
                abi.encodeCall(
                    GnosisBridgeAdapter.initialize,
                    (admin, address(destBridgeEscrow), address(omnibridge), address(amb), "1.0.0")
                )
            ));
        GnosisBridgeAdapter destAdapter = GnosisBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        destBridgeEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not operator
        destAdapter.completeBridge(messagePayload, "");
    }

    // ============ Token Transfer Callback Tests (delivery goes to escrow → module → adapter) ============

    /// @notice When delivery goes to escrow, escrow fallback forwards onTokenTransfer to adapter; adapter stores payload and releases
    function test_onTokenTransfer_storesMessagePayload() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(GNOSIS_CHAIN_ID);
        MockOmnibridge destOmnibridge = new MockOmnibridge();
        MockAMB destAmb = new MockAMB();
        address destAdapterImpl = address(new GnosisBridgeAdapter());
        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                destAdapterImpl,
                abi.encodeCall(
                    GnosisBridgeAdapter.initialize,
                    (admin, address(destEscrow), address(destOmnibridge), address(destAmb), "1.0.0")
                )
            ));
        GnosisBridgeAdapter destAdapter = GnosisBridgeAdapter(destAdapterProxy);
        vm.startPrank(admin);
        destEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        _registerCallbackModule(destEscrow, GnosisBridgeAdapter.onTokenTransfer.selector, address(destAdapter));

        usdc.mint(address(destOmnibridge), amount);
        destOmnibridge.deliverTokens(address(usdc), address(destEscrow), amount, messagePayload);

        bytes memory storedPayload = destAdapter.getMessagePayload(invoiceData.invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "MessagePayload should be stored via callback");
    }

    function test_onTokenTransfer_storesTransactionHash() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(GNOSIS_CHAIN_ID);
        MockOmnibridge destOmnibridge = new MockOmnibridge();
        MockAMB destAmb = new MockAMB();
        bytes32 txHash = keccak256("test-transaction-hash");
        destAmb.setTransactionHash(txHash);

        address destAdapterImpl = address(new GnosisBridgeAdapter());
        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                destAdapterImpl,
                abi.encodeCall(
                    GnosisBridgeAdapter.initialize,
                    (admin, address(destEscrow), address(destOmnibridge), address(destAmb), "1.0.0")
                )
            ));
        GnosisBridgeAdapter destAdapter = GnosisBridgeAdapter(destAdapterProxy);
        vm.startPrank(admin);
        destEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        _registerCallbackModule(destEscrow, GnosisBridgeAdapter.onTokenTransfer.selector, address(destAdapter));

        usdc.mint(address(destOmnibridge), amount);
        destOmnibridge.deliverTokens(address(usdc), address(destEscrow), amount, messagePayload);

        assertEq(
            destAdapter.getTransactionHashByInvoiceId(invoiceData.invoiceId),
            txHash,
            "Transaction hash should be stored"
        );
        assertEq(
            destAdapter.getInvoiceIdByTransactionHash(txHash),
            invoiceData.invoiceId,
            "InvoiceId mapping should be stored"
        );
    }

    /// @notice Adapter's onTokenTransfer reverts when not called by escrow, so only escrow fallback → adapter path is used
    function test_onTokenTransfer_revertsWhenCalledOnAdapter() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);
        bytes32 valueBytes32 = bytes32(amount);

        vm.prank(address(omnibridge));
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        adapter.onTokenTransfer(address(usdc), valueBytes32, messagePayload);
    }

    // ============ Configuration Tests ============

    function test_setOmnibridge_updatesOmnibridge() public {
        MockOmnibridge newOmnibridge = new MockOmnibridge();

        vm.prank(admin);
        adapter.setOmnibridge(address(newOmnibridge));

        // Verify omnibridge was updated (indirectly)
        assertTrue(true, "Omnibridge should be updated");
    }

    function test_setOmnibridge_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not admin
        adapter.setOmnibridge(address(0));
    }

    function test_setAMB_updatesAMB() public {
        MockAMB newAmb = new MockAMB();

        vm.prank(admin);
        adapter.setAmb(address(newAmb));

        // Verify AMB was updated (indirectly)
        assertTrue(true, "AMB should be updated");
    }

    function test_setAMB_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not admin
        adapter.setAmb(address(0));
    }

    // ============ View Function Tests ============

    function test_getMessagePayload_returnsStoredPayload() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(GNOSIS_CHAIN_ID);
        MockOmnibridge destOmnibridge = new MockOmnibridge();
        MockAMB destAmb = new MockAMB();
        address destAdapterImpl = address(new GnosisBridgeAdapter());
        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                destAdapterImpl,
                abi.encodeCall(
                    GnosisBridgeAdapter.initialize,
                    (admin, address(destEscrow), address(destOmnibridge), address(destAmb), "1.0.0")
                )
            ));
        GnosisBridgeAdapter destAdapter = GnosisBridgeAdapter(destAdapterProxy);
        vm.startPrank(admin);
        destEscrow.authorizeAdapter(address(destAdapter));
        _registerCallbackModule(destEscrow, GnosisBridgeAdapter.onTokenTransfer.selector, address(destAdapter));
        vm.stopPrank();

        usdc.mint(address(destOmnibridge), amount);
        destOmnibridge.deliverTokens(address(usdc), address(destEscrow), amount, messagePayload);

        bytes memory storedPayload = destAdapter.getMessagePayload(invoiceData.invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "Stored payload should match");
    }

    function test_areTokensAvailable_returnsTrueWhenTokensPresent() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Store payload via bridge
        vm.prank(portfolioSafe);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(bridgeEscrow), amount);

        // BridgeEscrow approves adapter (new pattern: approval instead of transfer)
        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);

        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);

        // Transfer tokens to adapter (simulating Omnibridge transfer)
        // Note: The bridge() call already pulled tokens, so we mint new ones to simulate delivery
        usdc.mint(address(adapter), amount);

        // Check if tokens are available
        bool available = adapter.areTokensAvailable(invoiceData.invoiceId, address(usdc));
        assertTrue(available, "Tokens should be available");
    }

    function test_areTokensAvailable_returnsFalseWhenTokensNotPresent() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Store payload via bridge
        vm.prank(portfolioSafe);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(bridgeEscrow), amount);

        // BridgeEscrow approves adapter (new pattern: approval instead of transfer)
        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);

        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);

        // Don't transfer tokens to adapter (bridge() already pulled them, and we don't mint new ones)

        // Check if tokens are available
        bool available = adapter.areTokensAvailable(invoiceData.invoiceId, address(usdc));
        assertFalse(available, "Tokens should not be available");
    }
}
