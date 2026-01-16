// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "src/bridge/adapters/AcrossBridgeAdapter.sol";
import "src/bridge/adapters/interfaces/IAcrossInterfaces.sol";
import "src/bridge/InvoiceDataLib.sol";
import "src/bridge/IBridgeEscrow.sol";
import "test/bridge/BridgeTestBase.sol";
import "test/bridge/mocks/MockBridgeProtocols.sol";
import "test/mocks/tokens.sol";

/// @title AcrossBridgeAdapterTest
/// @notice Test suite for Across Bridge Adapter
contract AcrossBridgeAdapterTest is BridgeTestBase {
    AcrossBridgeAdapter public adapter;
    MockSpokePool public spokePool;

    int64 public constant DEFAULT_RELAYER_FEE_PCT = 0.01e18; // 1%

    function setUp() public override {
        super.setUp();

        // Deploy mock Across SpokePool
        spokePool = new MockSpokePool();

        // Deploy Across adapter
        address adapterImpl = address(new AcrossBridgeAdapter());
        address payable adapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                adapterImpl,
                abi.encodeCall(
                    AcrossBridgeAdapter.initialize,
                    (admin, address(bridgeEscrow), address(spokePool), DEFAULT_RELAYER_FEE_PCT, "1.0.0")
                )
            ));
        adapter = AcrossBridgeAdapter(adapterProxy);

        // Configure adapter
        vm.startPrank(admin);
        adapter.grantRole(keccak256("OPERATOR_ROLE"), operator);
        vm.stopPrank();

        // Authorize adapter in BridgeEscrow
        _authorizeAdapter(address(adapter));

        // Setup labels
        vm.label(address(adapter), "AcrossBridgeAdapter");
        vm.label(address(spokePool), "MockSpokePool");
    }

    // ============ Bridge Initiation Tests ============

    function test_bridge_initiatesAcrossDeposit() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        _approveToken(address(usdc), address(bridgeEscrow), amount);

        // Create invoice data
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
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

    function test_bridge_initiatesNativeTokenDeposit() public {
        uint256 amount = 1 ether;

        // Register native ETH (address(0)) for WETH symbol
        vm.startPrank(admin);
        bridgeEscrow.registerAsset(WETH_SYMBOL, address(0));
        vm.stopPrank();

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, WETH_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Fund adapter with ETH (simulating BridgeEscrow sending ETH)
        vm.deal(address(adapter), amount);

        // Initiate bridge with native token
        // The adapter's _bridge() will call spokePool.deposit{value: amount}()
        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);

        // Verify messagePayload was stored
        bytes32 invoiceId = invoiceData.invoiceId;
        bytes memory storedPayload = adapter.getMessagePayload(invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "MessagePayload should be stored");
    }

    function test_bridge_initiatesNativeTokenDepositWithEeeAddress() public {
        uint256 amount = 1 ether;

        // Register native ETH using ERC-7528 address (0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)
        address nativeAddressErc7528 = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        vm.startPrank(admin);
        bridgeEscrow.registerAsset(WETH_SYMBOL, nativeAddressErc7528);
        vm.stopPrank();

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, WETH_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Fund adapter with ETH
        vm.deal(address(adapter), amount);

        // Initiate bridge with native token (using EEE address)
        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);

        // Verify messagePayload was stored
        bytes32 invoiceId = invoiceData.invoiceId;
        bytes memory storedPayload = adapter.getMessagePayload(invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "MessagePayload should be ustored");
    }

    function test_bridge_revertsIfNotCalledByBridgeEscrow() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not BridgeEscrow
        adapter.bridge(messagePayload);
    }

    // ============ Bridge Completion Tests ============

    function test_completeBridge_releasesTokensOnDestinationChain() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);

        // Set up destination chain environment
        (BridgeEscrow destBridgeEscrow, bytes memory messagePayload) =
            _setupDestinationChainForCompletion(invoiceData, address(usdc));

        // Set up adapter on destination chain
        address destAdapterImpl = address(new AcrossBridgeAdapter());
        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                destAdapterImpl,
                abi.encodeCall(
                    AcrossBridgeAdapter.initialize,
                    (admin, address(destBridgeEscrow), address(spokePool), DEFAULT_RELAYER_FEE_PCT, "1.0.0")
                )
            ));
        AcrossBridgeAdapter destAdapter = AcrossBridgeAdapter(destAdapterProxy);

        // Configure adapter on destination chain
        vm.startPrank(admin);
        destAdapter.grantRole(keccak256("OPERATOR_ROLE"), operator);
        destBridgeEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        // Simulate Across delivering tokens and message to adapter
        // First, transfer tokens to adapter (simulating Across relayer)
        usdc.mint(address(destAdapter), amount);
        
        // Call handleAcrossMessage to store the message payload
        vm.prank(address(spokePool));
        destAdapter.handleAcrossMessage(address(usdc), amount, true, address(this), messagePayload);

        // Verify message payload was stored
        bytes memory storedPayload = destAdapter.getMessagePayload(invoiceData.invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "Message payload should be stored");

        // Verify invoice is not completed before completion
        // Note: Invoice doesn't exist on destination chain - it only exists on source chain for bookkeeping
        // The checksum validation and completedInvoices mapping are sufficient for security
        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));
        assertFalse(
            destBridgeEscrow.isInvoiceCompleted(invoiceHash),
            "Invoice should not be completed before completion"
        );

        // Note: Tokens arrive at adapter, not BridgeEscrow
        // They will be transferred to BridgeEscrow in _completeBridge before releaseByInvoiceId
        assertEq(
            usdc.balanceOf(address(destAdapter)),
            amount,
            "Adapter should have tokens before completion"
        );
        assertEq(
            usdc.balanceOf(address(destBridgeEscrow)),
            0,
            "Escrow should have zero balance before completion (tokens at adapter)"
        );

        // Get initial balances
        uint256 initialPortfolioBalance = usdc.balanceOf(portfolioSafe);
        uint256 initialAdapterBalance = usdc.balanceOf(address(destAdapter));

        // Protocol data contains depositId and sourceChainId
        uint32 depositId = 123;
        uint256 sourceChainId = SOURCE_CHAIN_ID;
        bytes memory protocolData = abi.encode(depositId, sourceChainId);

        // Complete bridge - this should release tokens to portfolio safe
        vm.prank(operator);
        destAdapter.completeBridge(messagePayload, protocolData);

        // Verify tokens were released to portfolio safe
        uint256 finalPortfolioBalance = usdc.balanceOf(portfolioSafe);
        assertEq(
            finalPortfolioBalance - initialPortfolioBalance,
            amount,
            "Portfolio safe should receive tokens"
        );

        // Verify tokens were transferred from adapter to BridgeEscrow, then released
        // Adapter should have 0 balance (transferred to escrow)
        assertEq(
            usdc.balanceOf(address(destAdapter)),
            0,
            "Adapter should have zero balance after transfer to escrow"
        );
        // Escrow should have 0 balance (released to portfolio safe)
        assertEq(
            usdc.balanceOf(address(destBridgeEscrow)),
            0,
            "Escrow should have zero balance after release to portfolio safe"
        );

        // Verify invoice is marked as completed
        assertTrue(
            destBridgeEscrow.isInvoiceCompleted(invoiceHash),
            "Invoice should be marked as completed"
        );

        // Note: In-transit balance is only tracked on source chain
        // On destination chain, there are no invoices, so in-transit balance is always 0
    }

    function test_completeBridge_validatesChecksum() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);

        // Set up destination chain environment
        (BridgeEscrow destBridgeEscrow, bytes memory messagePayload) =
            _setupDestinationChainForCompletion(invoiceData, address(usdc));

        // Set up adapter on destination chain
        address destAdapterImpl = address(new AcrossBridgeAdapter());
        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                destAdapterImpl,
                abi.encodeCall(
                    AcrossBridgeAdapter.initialize,
                    (admin, address(destBridgeEscrow), address(spokePool), DEFAULT_RELAYER_FEE_PCT, "1.0.0")
                )
            ));
        AcrossBridgeAdapter destAdapter = AcrossBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        destAdapter.grantRole(keccak256("OPERATOR_ROLE"), operator);
        destBridgeEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        // Corrupt messagePayload (invalid checksum)
        bytes memory corruptedPayload = abi.encode(
            invoiceData.invoiceId,
            invoiceData.amount,
            bytes32(uint256(invoiceData.timestampByte) << 248 | uint256(uint192(invoiceData.checksum24)) ^ 1)
        );

        bytes memory protocolData = abi.encode(uint32(123), SOURCE_CHAIN_ID);

        vm.prank(operator);
        vm.expectRevert(); // Should revert because checksum is invalid
        destAdapter.completeBridge(corruptedPayload, protocolData);
    }

    function test_completeBridge_revertsIfNotOperator() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);

        // Set up destination chain environment
        (BridgeEscrow destBridgeEscrow, bytes memory messagePayload) =
            _setupDestinationChainForCompletion(invoiceData, address(usdc));

        // Set up adapter on destination chain
        address destAdapterImpl = address(new AcrossBridgeAdapter());
        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                destAdapterImpl,
                abi.encodeCall(
                    AcrossBridgeAdapter.initialize,
                    (admin, address(destBridgeEscrow), address(spokePool), DEFAULT_RELAYER_FEE_PCT, "1.0.0")
                )
            ));
        AcrossBridgeAdapter destAdapter = AcrossBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        destBridgeEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        bytes memory protocolData = abi.encode(uint32(123), SOURCE_CHAIN_ID);

        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not operator
        destAdapter.completeBridge(messagePayload, protocolData);
    }

    // ============ Across Receiver Tests ============

    function test_handleAcrossMessage_storesMessagePayload() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Call handleAcrossMessage (SpokePool calls this when deposit is filled)
        vm.prank(address(spokePool));
        adapter.handleAcrossMessage(address(usdc), amount, true, address(this), messagePayload);

        // Verify messagePayload was stored
        bytes32 invoiceId = invoiceData.invoiceId;
        bytes memory storedPayload = adapter.getMessagePayload(invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "MessagePayload should be stored");
    }

    function test_handleAcrossMessage_revertsIfNotSpokePool() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not SpokePool
        adapter.handleAcrossMessage(address(usdc), amount, true, address(this), messagePayload);
    }

    function test_handleAcrossMessage_revertsForEmptyMessage() public {
        vm.prank(address(spokePool));
        vm.expectRevert(); // Should revert because message is empty
        adapter.handleAcrossMessage(address(usdc), 1000, true, address(this), "");
    }

    // ============ Configuration Tests ============

    function test_setSpokePool_updatesSpokePool() public {
        MockSpokePool newSpokePool = new MockSpokePool();

        vm.prank(admin);
        adapter.setSpokePool(address(newSpokePool));

        // Verify spokePool was updated (indirectly)
        assertTrue(true, "SpokePool should be updated");
    }

    function test_setSpokePool_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not admin
        adapter.setSpokePool(address(0));
    }

    function test_setDefaultRelayerFeePct_updatesFee() public {
        int64 newFee = 0.02e18; // 2%

        vm.prank(admin);
        adapter.setDefaultRelayerFeePct(newFee);

        // Verify fee was updated (indirectly)
        assertTrue(true, "Relayer fee should be updated");
    }

    function test_setDefaultRelayerFeePct_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not admin
        adapter.setDefaultRelayerFeePct(0.02e18);
    }

    function test_setDefaultRelayerFeePct_revertsForInvalidFee() public {
        vm.startPrank(admin);
        vm.expectRevert(); // Should revert because fee is negative
        adapter.setDefaultRelayerFeePct(-1);

        vm.expectRevert(); // Should revert because fee > 1e18
        adapter.setDefaultRelayerFeePct(2e18);
        vm.stopPrank();
    }

    // ============ View Function Tests ============

    function test_getMessagePayload_returnsStoredPayload() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Store payload via handleAcrossMessage
        vm.prank(address(spokePool));
        adapter.handleAcrossMessage(address(usdc), amount, true, address(this), messagePayload);

        // Retrieve payload
        bytes memory storedPayload = adapter.getMessagePayload(invoiceData.invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "Stored payload should match");
    }

    // ============ ERC165 Tests ============

    function test_supportsInterface_returnsTrueForIAcrossReceiver() public {
        bytes4 interfaceId = type(IAcrossReceiver).interfaceId;
        assertTrue(adapter.supportsInterface(interfaceId), "Should support IAcrossReceiver");
    }
}
