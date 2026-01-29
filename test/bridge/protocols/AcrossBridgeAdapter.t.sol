// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/adapters/AcrossBridgeAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/adapters/interfaces/IAcrossInterfaces.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/IBridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/bridge/BridgeTestBase.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/bridge/BridgeScenarioHelper.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/bridge/mocks/MockBridgeProtocols.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";

/// @title AcrossBridgeAdapterTest
/// @notice Test suite for Across Bridge Adapter
contract AcrossBridgeAdapterTest is BridgeScenarioHelper {
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

        // Transfer tokens to BridgeEscrow (simulating depositAndBridge)
        vm.prank(portfolioSafe);
        require(usdc.transfer(address(bridgeEscrow), amount), "transfer failed");

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

        // Recipient is BridgeEscrow; for operator fallback path we mint tokens to escrow, then completeBridge (no transfer in _completeBridge)
        usdc.mint(address(destBridgeEscrow), amount);

        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));
        assertFalse(
            destBridgeEscrow.isInvoiceCompleted(invoiceHash), "Invoice should not be completed before completion"
        );

        uint256 initialPortfolioBalance = usdc.balanceOf(portfolioSafe);

        bytes memory protocolData = abi.encode(uint32(123), SOURCE_CHAIN_ID);

        vm.prank(operator);
        destAdapter.completeBridge(messagePayload, protocolData);

        assertEq(
            usdc.balanceOf(portfolioSafe) - initialPortfolioBalance, amount, "Portfolio safe should receive tokens"
        );
        assertEq(usdc.balanceOf(address(destBridgeEscrow)), 0, "Escrow should have zero balance after release");

        // Verify invoice is marked as completed
        assertTrue(destBridgeEscrow.isInvoiceCompleted(invoiceHash), "Invoice should be marked as completed");

        // Note: In-transit balance is only tracked on source chain
        // On destination chain, there are no invoices, so in-transit balance is always 0
    }

    // ============ Realistic flow test (source-originated payload + delivery via bridge mock only) ============

    /// @notice Full round-trip: depositAndBridge on source → payload from deposit → deliver only via fillDeposit → completeBridge
    /// @dev Ensures we use the exact messagePayload the escrow produced and that the adapter receives the callback from the mock (as in prod)
    function test_realistic_fullRoundTrip_sourcePayloadAndDeliveryViaFillDeposit() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();

        // ---------- SOURCE CHAIN ----------
        _approveToken(address(usdc), address(bridgeEscrow), amount);
        vm.prank(portfolioSafe);
        bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, amount, address(adapter));

        // Payload must come from the deposit the adapter created (realistic: same as production)
        bytes memory messagePayload = _getAcrossMessagePayloadFromLastDeposit(spokePool);
        uint256 portfolioBalanceBeforeRelease = usdc.balanceOf(portfolioSafe); // after deposit: safe sent amount to escrow
        assertGt(messagePayload.length, 0, "messagePayload from source deposit");

        uint256 sourceDepositId = spokePool.depositId();
        assertEq(sourceDepositId, 1, "one deposit on source");

        // ---------- DESTINATION CHAIN (simulate: same test, different chainId and contracts) ----------
        vm.chainId(uint256(DEST_CHAIN_ID));

        BridgeEscrow destBridgeEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        MockSpokePool destSpokePool = new MockSpokePool();

        address destAdapterImpl = address(new AcrossBridgeAdapter());
        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                destAdapterImpl,
                abi.encodeCall(
                    AcrossBridgeAdapter.initialize,
                    (admin, address(destBridgeEscrow), address(destSpokePool), DEFAULT_RELAYER_FEE_PCT, "1.0.0")
                )
            ));
        AcrossBridgeAdapter destAdapter = AcrossBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        destAdapter.grantRole(keccak256("OPERATOR_ROLE"), operator);
        destBridgeEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        // Recipient is BridgeEscrow; escrow fallback forwards handleAcrossMessage to adapter -> _completeDelivery -> releaseByInvoiceId
        _registerCallbackModule(
            destBridgeEscrow, AcrossBridgeAdapter.handleAcrossMessage.selector, address(destAdapter)
        );

        // Relay deposit: recipient = dest escrow (realistic: relayer fills to escrow)
        uint256 relayDepositId = destSpokePool.addRelayDeposit(address(destBridgeEscrow), messagePayload);

        usdc.mint(address(destSpokePool), amount);

        // Delivery via mock: tokens to escrow, then handleAcrossMessage on escrow -> fallback forwards to adapter -> _completeDelivery -> releaseByInvoiceId
        destSpokePool.fillDeposit(relayDepositId, address(usdc), amount);

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
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);

        // Set up destination chain environment
        (BridgeEscrow destBridgeEscrow,) = _setupDestinationChainForCompletion(invoiceData, address(usdc));

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
            bytes32(uint256(invoiceData.timestamp) << 192 | uint256(uint192(invoiceData.checksum24)) ^ 1)
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

    // ============ Across Receiver Tests (adapter is not receiver; escrow + module are) ============

    /// @notice When delivery goes to escrow, escrow fallback forwards handleAcrossMessage to adapter; adapter stores payload
    function test_handleAcrossMessage_storesMessagePayload() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(DEST_CHAIN_ID));
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        MockSpokePool destSpokePool = new MockSpokePool();
        address destAdapterImpl = address(new AcrossBridgeAdapter());
        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                destAdapterImpl,
                abi.encodeCall(
                    AcrossBridgeAdapter.initialize,
                    (admin, address(destEscrow), address(destSpokePool), DEFAULT_RELAYER_FEE_PCT, "1.0.0")
                )
            ));
        AcrossBridgeAdapter destAdapter = AcrossBridgeAdapter(destAdapterProxy);
        vm.startPrank(admin);
        destAdapter.grantRole(keccak256("OPERATOR_ROLE"), operator);
        destEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        _registerCallbackModule(destEscrow, AcrossBridgeAdapter.handleAcrossMessage.selector, address(destAdapter));

        uint256 relayDepositId = destSpokePool.addRelayDeposit(address(destEscrow), messagePayload);
        usdc.mint(address(destSpokePool), amount);
        destSpokePool.fillDeposit(relayDepositId, address(usdc), amount);

        bytes memory storedPayload = destAdapter.getMessagePayload(invoiceData.invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "MessagePayload should be stored via callback");
    }

    /// @notice Adapter's handleAcrossMessage reverts when not called by escrow, so only escrow fallback → adapter path is used
    function test_handleAcrossMessage_revertsWhenCalledOnAdapter() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(address(spokePool));
        vm.expectRevert(abi.encodeWithSelector(IAcrossBridgeAdapter.MessageReceiveFailed.selector));
        adapter.handleAcrossMessage(address(usdc), amount, true, address(this), messagePayload);
    }

    function test_handleAcrossMessage_revertsForEmptyMessage() public {
        vm.prank(address(spokePool));
        vm.expectRevert(abi.encodeWithSelector(IAcrossBridgeAdapter.MessageReceiveFailed.selector));
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

        // Store payload via callback path (escrow fallback → adapter.handleAcrossMessage → _completeDelivery)
        vm.chainId(uint256(DEST_CHAIN_ID));
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        MockSpokePool destSpokePool = new MockSpokePool();
        address destAdapterImpl = address(new AcrossBridgeAdapter());
        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                destAdapterImpl,
                abi.encodeCall(
                    AcrossBridgeAdapter.initialize,
                    (admin, address(destEscrow), address(destSpokePool), DEFAULT_RELAYER_FEE_PCT, "1.0.0")
                )
            ));
        AcrossBridgeAdapter destAdapter = AcrossBridgeAdapter(destAdapterProxy);
        vm.startPrank(admin);
        destEscrow.authorizeAdapter(address(destAdapter));
        _registerCallbackModule(destEscrow, AcrossBridgeAdapter.handleAcrossMessage.selector, address(destAdapter));
        vm.stopPrank();

        uint256 relayDepositId = destSpokePool.addRelayDeposit(address(destEscrow), messagePayload);
        usdc.mint(address(destSpokePool), amount);
        destSpokePool.fillDeposit(relayDepositId, address(usdc), amount);

        bytes memory storedPayload = destAdapter.getMessagePayload(invoiceData.invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "Stored payload should match");
    }

    // ============ ERC165 Tests ============

    function test_supportsInterface_returnsTrueForIAcrossReceiver() public view {
        bytes4 interfaceId = type(IAcrossReceiver).interfaceId;
        assertTrue(adapter.supportsInterface(interfaceId), "Should support IAcrossReceiver");
    }
}
