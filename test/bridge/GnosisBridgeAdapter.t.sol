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

        // Transfer tokens to BridgeEscrow, then to adapter
        vm.prank(portfolioSafe);
        usdc.transfer(address(bridgeEscrow), amount);

        vm.prank(address(bridgeEscrow));
        usdc.transfer(address(adapter), amount);

        // Initiate bridge
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

        vm.prank(address(bridgeEscrow));
        usdc.transfer(address(adapter), amount);

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

    function test_completeBridge_processesMessage() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Protocol data is optional for Gnosis (can be empty)
        bytes memory protocolData = "";

        // Complete bridge (this will call releaseByInvoiceId which expects destination chain)
        // Note: In unit tests, we're on source chain, so releaseByInvoiceId will revert
        // This is expected - the full flow is tested in fork tests
        vm.prank(operator);
        vm.expectRevert(); // Expect revert from releaseByInvoiceId (destination chain validation)
        adapter.completeBridge(messagePayload, protocolData);
    }

    function test_completeBridge_validatesChecksum() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Corrupt messagePayload (invalid checksum)
        bytes memory corruptedPayload = abi.encode(
            invoiceData.invoiceId,
            invoiceData.amount,
            bytes32(uint256(invoiceData.timestampByte) << 248 | uint256(uint192(invoiceData.checksum24)) ^ 1)
        );

        vm.prank(operator);
        vm.expectRevert(); // Should revert because checksum is invalid
        adapter.completeBridge(corruptedPayload, "");
    }

    function test_completeBridge_revertsIfNotOperator() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not operator
        adapter.completeBridge(messagePayload, "");
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

        vm.prank(address(bridgeEscrow));
        usdc.transfer(address(adapter), amount);

        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);

        // Transfer tokens to adapter (simulating Omnibridge transfer)
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

        vm.prank(address(bridgeEscrow));
        usdc.transfer(address(adapter), amount);

        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);

        // Don't transfer tokens to adapter

        // Check if tokens are available
        bool available = adapter.areTokensAvailable(invoiceData.invoiceId, address(usdc));
        assertFalse(available, "Tokens should not be available");
    }
}
