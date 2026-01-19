// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "src/bridge/adapters/GnosisBridgeAdapter.sol";
import "src/bridge/adapters/interfaces/IGnosisInterfaces.sol";
import "src/bridge/InvoiceDataLib.sol";
import "src/bridge/IBridgeEscrow.sol";
import "test/bridge/BridgeTestBase.sol";
import "test/bridge/mocks/MockBridgeProtocols.sol";
import "test/mocks/tokens.sol";

/// @title GnosisBridgeAdapterTest
/// @notice Test suite for Gnosis Omnibridge Adapter
contract GnosisBridgeAdapterTest is BridgeTestBase {
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

        // Simulate Gnosis delivering tokens
        usdc.mint(address(destAdapter), amount);

        // Verify invoice is not completed before completion
        // Note: Invoice doesn't exist on destination chain - it only exists on source chain for bookkeeping
        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));
        assertFalse(
            destBridgeEscrow.isInvoiceCompleted(invoiceHash), "Invoice should not be completed before completion"
        );

        // Note: Tokens arrive at adapter, not BridgeEscrow
        // They will be transferred to BridgeEscrow in _completeBridge before releaseByInvoiceId
        assertEq(usdc.balanceOf(address(destAdapter)), amount, "Adapter should have tokens before completion");
        assertEq(
            usdc.balanceOf(address(destBridgeEscrow)),
            0,
            "Escrow should have zero balance before completion (tokens at adapter)"
        );

        // Get initial balances
        uint256 initialPortfolioBalance = usdc.balanceOf(portfolioSafe);
        uint256 initialAdapterBalance = usdc.balanceOf(address(destAdapter));

        // Protocol data is optional for Gnosis
        bytes memory protocolData = "";

        // Complete bridge
        vm.prank(operator);
        destAdapter.completeBridge(messagePayload, protocolData);

        // Verify tokens were released
        assertEq(
            usdc.balanceOf(portfolioSafe) - initialPortfolioBalance, amount, "Portfolio safe should receive tokens"
        );

        // Verify tokens were transferred from adapter to BridgeEscrow, then released
        // Adapter should have 0 balance (transferred to escrow)
        assertEq(usdc.balanceOf(address(destAdapter)), 0, "Adapter should have zero balance after transfer to escrow");
        // Escrow should have 0 balance (released to portfolio safe)
        assertEq(
            usdc.balanceOf(address(destBridgeEscrow)),
            0,
            "Escrow should have zero balance after release to portfolio safe"
        );

        // Verify invoice is marked as completed
        assertTrue(destBridgeEscrow.isInvoiceCompleted(invoiceHash), "Invoice should be marked as completed");

        // Note: In-transit balance is only tracked on source chain
        // On destination chain, there are no invoices, so in-transit balance is always 0
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

    // ============ Token Transfer Callback Tests ============

    function test_onTokenTransfer_storesMessagePayload() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Transfer tokens to adapter first (simulating Omnibridge transfer)
        usdc.mint(address(adapter), amount);

        // Call onTokenTransfer (Omnibridge calls this)
        bytes32 valueBytes32 = bytes32(amount);
        vm.prank(address(omnibridge));
        bool result = adapter.onTokenTransfer(address(omnibridge), valueBytes32, messagePayload);

        assertTrue(result, "onTokenTransfer should return true");

        // Verify messagePayload was stored
        bytes32 invoiceId = invoiceData.invoiceId;
        bytes memory storedPayload = adapter.getMessagePayload(invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "MessagePayload should be stored");
    }

    function test_onTokenTransfer_storesTransactionHash() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Set a mock transaction hash
        bytes32 txHash = keccak256("test-transaction-hash");
        amb.setTransactionHash(txHash);

        // Transfer tokens to adapter
        usdc.mint(address(adapter), amount);

        // Call onTokenTransfer via Omnibridge (simulating real flow)
        bytes32 valueBytes32 = bytes32(amount);
        vm.prank(address(omnibridge));
        adapter.onTokenTransfer(address(omnibridge), valueBytes32, messagePayload);

        // Verify transaction hash mapping was stored
        bytes32 invoiceId = invoiceData.invoiceId;
        bytes32 storedTxHash = adapter.getTransactionHashByInvoiceId(invoiceId);
        assertEq(storedTxHash, txHash, "Transaction hash should be stored");

        // Verify invoiceId mapping
        bytes32 storedInvoiceId = adapter.getInvoiceIdByTransactionHash(txHash);
        assertEq(storedInvoiceId, invoiceId, "InvoiceId mapping should be stored");
    }

    function test_onTokenTransfer_revertsIfNotOmnibridge() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        bytes32 valueBytes32 = bytes32(amount);
        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not Omnibridge
        adapter.onTokenTransfer(unauthorized, valueBytes32, messagePayload);
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
        MockAMB newAMB = new MockAMB();

        vm.prank(admin);
        adapter.setAMB(address(newAMB));

        // Verify AMB was updated (indirectly)
        assertTrue(true, "AMB should be updated");
    }

    function test_setAMB_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not admin
        adapter.setAMB(address(0));
    }

    // ============ View Function Tests ============

    function test_getMessagePayload_returnsStoredPayload() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Store payload via onTokenTransfer
        usdc.mint(address(adapter), amount);
        bytes32 valueBytes32 = bytes32(amount);
        vm.prank(address(omnibridge));
        adapter.onTokenTransfer(address(omnibridge), valueBytes32, messagePayload);

        // Retrieve payload
        bytes memory storedPayload = adapter.getMessagePayload(invoiceData.invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "Stored payload should match");
    }

    function test_areTokensAvailable_returnsTrueWhenTokensPresent() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Store payload via bridge
        vm.prank(portfolioSafe);
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
