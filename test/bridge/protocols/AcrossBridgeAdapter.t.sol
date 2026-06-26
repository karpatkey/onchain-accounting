// SPDX-License-Identifier: UNLICENSED
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
import "src/constants.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/IBridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/bridge/BridgeTestBase.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/bridge/BridgeScenarioHelper.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/bridge/mocks/AcrossProvenanceMocks.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";

/// @title AcrossBridgeAdapterTest
/// @notice Test suite for the Across V3 Bridge Adapter (provenance model, ADR 0012)
contract AcrossBridgeAdapterTest is BridgeScenarioHelper {
    AcrossBridgeAdapter public adapter;
    MockSpokePoolV3 public spokePool;

    int64 public constant DEFAULT_RELAYER_FEE_PCT = 0.01e18; // 1%

    function setUp() public override {
        super.setUp();

        // Deploy mock Across V3 SpokePool
        spokePool = new MockSpokePoolV3();

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
        adapter.grantRole(MANAGER, manager);
        vm.stopPrank();

        // Authorize adapter in BridgeEscrow
        _authorizeAdapter(address(adapter));

        // Setup labels
        vm.label(address(adapter), "AcrossBridgeAdapter");
        vm.label(address(spokePool), "MockSpokePoolV3");
    }

    /// @notice Deploys a destination-chain Across adapter wired to `destEscrow` + `destSpokePool`, grants
    ///         MANAGER, authorizes it on the escrow, and configures the trusted remote sibling for the source
    ///         chain. Under CREATE2 the sibling shares this adapter's address, so the trusted remote for the
    ///         source chain is the destination adapter's own address.
    function _deployDestAdapter(BridgeEscrow destEscrow, MockSpokePoolV3 destSpokePool)
        internal
        returns (AcrossBridgeAdapter destAdapter)
    {
        address destAdapterImpl = address(new AcrossBridgeAdapter());
        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                destAdapterImpl,
                abi.encodeCall(
                    AcrossBridgeAdapter.initialize,
                    (admin, address(destEscrow), address(destSpokePool), DEFAULT_RELAYER_FEE_PCT, "1.0.0")
                )
            ));
        destAdapter = AcrossBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        destAdapter.grantRole(MANAGER, manager);
        destEscrow.authorizeAdapter(address(destAdapter));
        // Trusted remote for the source chain is the (CREATE2 same-address) sibling adapter.
        destAdapter.setTrustedRemoteAdapter(SOURCE_CHAIN_ID, bytes32(uint256(uint160(address(destAdapter)))));
        vm.stopPrank();
    }

    // ============ Bridge Initiation Tests ============

    function test_bridge_initiatesAcrossDeposit() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        _approveToken(address(usdc), address(bridgeEscrow), amount);

        // Create invoice data
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Transfer tokens to BridgeEscrow (simulating depositAndBridge)
        vm.prank(account);
        require(usdc.transfer(address(bridgeEscrow), amount), "transfer failed");

        // BridgeEscrow approves adapter (new pattern: approval instead of transfer)
        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);

        // Initiate bridge (adapter will pull tokens in _bridge() and call depositV3)
        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);

        // Verify messagePayload was stored
        bytes32 invoiceId = invoiceData.invoiceId;
        bytes memory storedPayload = adapter.getMessagePayload(invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "MessagePayload should be stored");

        // Verify a V3 deposit was created with this adapter as the destination recipient
        assertEq(spokePool.depositId(), 1, "one V3 deposit created");
        (, address recipient,,,,,,) = spokePool.deposits(1);
        assertEq(recipient, address(adapter), "recipient must be the sibling adapter, not the escrow");
    }

    function test_bridge_initiatesNativeTokenDeposit() public {
        uint256 amount = 1 ether;

        // Register native ETH (address(0)) for WETH symbol
        vm.startPrank(admin);
        bridgeEscrow.registerAsset(WETH_SYMBOL, address(0));
        vm.stopPrank();

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Fund adapter with ETH (simulating BridgeEscrow sending ETH)
        vm.deal(address(adapter), amount);

        // Initiate bridge with native token: adapter calls spokePool.depositV3{value: amount}()
        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);

        // Verify messagePayload was stored
        bytes32 invoiceId = invoiceData.invoiceId;
        bytes memory storedPayload = adapter.getMessagePayload(invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "MessagePayload should be stored");
        assertEq(address(spokePool).balance, amount, "SpokePool received native input");
    }

    function test_bridge_initiatesNativeTokenDepositWithEeeAddress() public {
        uint256 amount = 1 ether;

        // Register native ETH using ERC-7528 address (0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)
        address nativeAddressErc7528 = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        vm.startPrank(admin);
        bridgeEscrow.registerAsset(WETH_SYMBOL, nativeAddressErc7528);
        vm.stopPrank();

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Fund adapter with ETH
        vm.deal(address(adapter), amount);

        // Initiate bridge with native token (using EEE address)
        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);

        // Verify messagePayload was stored
        bytes32 invoiceId = invoiceData.invoiceId;
        bytes memory storedPayload = adapter.getMessagePayload(invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "MessagePayload should be stored");
    }

    function test_bridge_revertsIfNotCalledByBridgeEscrow() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not BridgeEscrow
        adapter.bridge(messagePayload);
    }

    // ============ Bridge Completion Tests (MANAGER fallback path) ============

    function test_completeBridge_releasesTokensOnDestinationChain() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        // Set up destination chain environment
        (BridgeEscrow destBridgeEscrow, bytes memory messagePayload) =
            _setupDestinationChainForCompletion(invoiceData, address(usdc));

        MockSpokePoolV3 destSpokePool = new MockSpokePoolV3();
        AcrossBridgeAdapter destAdapter = _deployDestAdapter(destBridgeEscrow, destSpokePool);

        // New model: the adapter (recipient) holds the delivered tokens; funded pass-through pulls from it.
        usdc.mint(address(destAdapter), amount);

        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));
        assertFalse(
            destBridgeEscrow.isInvoiceCompleted(invoiceHash), "Invoice should not be completed before completion"
        );

        uint256 initialPortfolioBalance = usdc.balanceOf(account);

        bytes memory protocolData = abi.encode(uint32(123), uint256(SOURCE_CHAIN_ID));

        vm.prank(manager);
        destAdapter.completeBridge(messagePayload, protocolData);

        assertEq(usdc.balanceOf(account) - initialPortfolioBalance, amount, "Account should receive tokens");
        assertEq(usdc.balanceOf(address(destAdapter)), 0, "Adapter should have zero balance after release");
        assertEq(usdc.balanceOf(address(destBridgeEscrow)), 0, "Escrow holds no standing balance");
        assertTrue(destBridgeEscrow.isInvoiceCompleted(invoiceHash), "Invoice should be marked as completed");
    }

    /// @notice MANAGER completion reverts when the source chain is not a configured trusted remote.
    function test_completeBridge_revertsForUntrustedSource() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        (BridgeEscrow destBridgeEscrow, bytes memory messagePayload) =
            _setupDestinationChainForCompletion(invoiceData, address(usdc));

        MockSpokePoolV3 destSpokePool = new MockSpokePoolV3();
        AcrossBridgeAdapter destAdapter = _deployDestAdapter(destBridgeEscrow, destSpokePool);

        // Clear the trusted remote so source authentication fails.
        vm.prank(admin);
        destAdapter.setTrustedRemoteAdapter(SOURCE_CHAIN_ID, bytes32(0));

        usdc.mint(address(destAdapter), amount);

        bytes memory protocolData = abi.encode(uint32(123), uint256(SOURCE_CHAIN_ID));

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IAcrossBridgeAdapter.InvalidBridgeData.selector));
        destAdapter.completeBridge(messagePayload, protocolData);
    }

    // ============ Realistic round-trip (source payload + delivery via genuine SpokePool fill) ============

    /// @notice Full round-trip: depositAndBridge on source → payload from deposit → fill on destination
    ///         SpokePool which delivers tokens to the adapter and calls handleV3AcrossMessage directly.
    function test_realistic_fullRoundTrip_sourcePayloadAndDeliveryViaFillDeposit() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();

        // ---------- SOURCE CHAIN ----------
        _approveToken(address(usdc), address(bridgeEscrow), amount);
        vm.prank(account);
        bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, amount, address(adapter));

        // Payload must come from the deposit the adapter created (realistic: same as production)
        bytes memory messagePayload = spokePool.getDepositMessage(spokePool.depositId());
        uint256 portfolioBalanceBeforeRelease = usdc.balanceOf(account);
        assertGt(messagePayload.length, 0, "messagePayload from source deposit");
        assertEq(spokePool.depositId(), 1, "one deposit on source");

        // ---------- DESTINATION CHAIN ----------
        vm.chainId(uint256(DEST_CHAIN_ID));

        BridgeEscrow destBridgeEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        MockSpokePoolV3 destSpokePool = new MockSpokePoolV3();
        AcrossBridgeAdapter destAdapter = _deployDestAdapter(destBridgeEscrow, destSpokePool);

        // Relay fill: recipient = dest adapter (the genuine protocol delivers tokens to the adapter).
        uint256 relayDepositId = destSpokePool.addRelayDeposit(address(destAdapter), messagePayload);
        usdc.mint(address(destSpokePool), amount);

        // Delivery via the SpokePool: tokens to adapter, then handleV3AcrossMessage on the adapter.
        destSpokePool.fillDeposit(relayDepositId, address(usdc), amount);

        bytes32 expectedInvoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(messagePayload).checksum24)));
        assertTrue(destBridgeEscrow.isInvoiceCompleted(expectedInvoiceHash), "invoice completed");
        assertEq(usdc.balanceOf(account) - portfolioBalanceBeforeRelease, amount, "account received bridged amount");
        assertEq(usdc.balanceOf(address(destAdapter)), 0, "adapter balance zero after release");
        assertEq(usdc.balanceOf(address(destBridgeEscrow)), 0, "escrow holds no standing balance");
    }

    function test_completeBridge_validatesChecksum() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        (BridgeEscrow destBridgeEscrow,) = _setupDestinationChainForCompletion(invoiceData, address(usdc));

        MockSpokePoolV3 destSpokePool = new MockSpokePoolV3();
        AcrossBridgeAdapter destAdapter = _deployDestAdapter(destBridgeEscrow, destSpokePool);

        // Adapter holds funds so the failure is the checksum, not a missing-balance error.
        usdc.mint(address(destAdapter), amount);

        // Corrupt messagePayload (invalid checksum). Wire format is 4 slots: invoiceId, amount, nonce, meta.
        bytes memory corruptedPayload = abi.encode(
            invoiceData.invoiceId,
            invoiceData.amount,
            uint256(invoiceData.nonce),
            bytes32(uint256(invoiceData.timestamp) << 192 | uint256(uint192(invoiceData.checksum24)) ^ 1)
        );

        bytes memory protocolData = abi.encode(uint32(123), uint256(SOURCE_CHAIN_ID));

        vm.prank(manager);
        vm.expectRevert(); // Should revert because checksum is invalid (in releaseByInvoiceId)
        destAdapter.completeBridge(corruptedPayload, protocolData);
    }

    function test_completeBridge_revertsIfNotManager() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        (BridgeEscrow destBridgeEscrow, bytes memory messagePayload) =
            _setupDestinationChainForCompletion(invoiceData, address(usdc));

        MockSpokePoolV3 destSpokePool = new MockSpokePoolV3();
        AcrossBridgeAdapter destAdapter = _deployDestAdapter(destBridgeEscrow, destSpokePool);

        bytes memory protocolData = abi.encode(uint32(123), uint256(SOURCE_CHAIN_ID));

        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not manager
        destAdapter.completeBridge(messagePayload, protocolData);
    }

    // ============ Across V3 Receiver Tests (adapter is the direct protocol receiver) ============

    /// @notice Auto path: the genuine SpokePool delivers tokens to the adapter and calls handleV3AcrossMessage,
    ///         which authenticates and releases. The payload is stored and retrievable.
    function test_handleV3AcrossMessage_releasesAndStoresPayload() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(DEST_CHAIN_ID));
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        MockSpokePoolV3 destSpokePool = new MockSpokePoolV3();
        AcrossBridgeAdapter destAdapter = _deployDestAdapter(destEscrow, destSpokePool);

        uint256 relayDepositId = destSpokePool.addRelayDeposit(address(destAdapter), messagePayload);
        usdc.mint(address(destSpokePool), amount);

        uint256 before = usdc.balanceOf(account);
        destSpokePool.fillDeposit(relayDepositId, address(usdc), amount);

        assertEq(usdc.balanceOf(account) - before, amount, "account received bridged amount");
        bytes memory storedPayload = destAdapter.getMessagePayload(invoiceData.invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "MessagePayload should be stored via callback");
    }

    /// @notice handleV3AcrossMessage reverts when not called by the SpokePool (only the genuine protocol path).
    function test_handleV3AcrossMessage_revertsWhenNotSpokePool() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IAcrossBridgeAdapter.MessageReceiveFailed.selector));
        adapter.handleV3AcrossMessage(address(usdc), amount, address(this), messagePayload);
    }

    function test_handleV3AcrossMessage_revertsForEmptyMessage() public {
        vm.prank(address(spokePool));
        vm.expectRevert(abi.encodeWithSelector(InvalidCompletionData.selector));
        adapter.handleV3AcrossMessage(address(usdc), 1000, address(this), "");
    }

    /// @notice handleV3AcrossMessage reverts when the delivered token does not match the invoice asset.
    function test_handleV3AcrossMessage_revertsForTokenMismatch() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(DEST_CHAIN_ID));
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        MockSpokePoolV3 destSpokePool = new MockSpokePoolV3();
        AcrossBridgeAdapter destAdapter = _deployDestAdapter(destEscrow, destSpokePool);

        // Deliver DAI but the invoice is for USDC.
        dai.mint(address(destAdapter), amount);
        vm.prank(address(destSpokePool));
        vm.expectRevert(abi.encodeWithSelector(IAcrossBridgeAdapter.InvalidBridgeData.selector));
        destAdapter.handleV3AcrossMessage(address(dai), amount, address(this), messagePayload);
    }

    /// @notice handleV3AcrossMessage reverts when the delivered amount is below the invoice amount.
    function test_handleV3AcrossMessage_revertsForAmountShortfall() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(DEST_CHAIN_ID));
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        MockSpokePoolV3 destSpokePool = new MockSpokePoolV3();
        AcrossBridgeAdapter destAdapter = _deployDestAdapter(destEscrow, destSpokePool);

        vm.prank(address(destSpokePool));
        vm.expectRevert(abi.encodeWithSelector(IAcrossBridgeAdapter.InvalidBridgeData.selector));
        destAdapter.handleV3AcrossMessage(address(usdc), amount - 1, address(this), messagePayload);
    }

    /// @notice handleV3AcrossMessage reverts when the source chain is not a configured trusted remote.
    function test_handleV3AcrossMessage_revertsForUntrustedSource() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(DEST_CHAIN_ID));
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        MockSpokePoolV3 destSpokePool = new MockSpokePoolV3();
        AcrossBridgeAdapter destAdapter = _deployDestAdapter(destEscrow, destSpokePool);

        // Remove the trusted remote so source authentication fails even though the SpokePool delivered tokens.
        vm.prank(admin);
        destAdapter.setTrustedRemoteAdapter(SOURCE_CHAIN_ID, bytes32(0));

        usdc.mint(address(destAdapter), amount);
        vm.prank(address(destSpokePool));
        vm.expectRevert(abi.encodeWithSelector(IAcrossBridgeAdapter.InvalidBridgeData.selector));
        destAdapter.handleV3AcrossMessage(address(usdc), amount, address(this), messagePayload);
    }

    // ============ Configuration Tests ============

    function test_setSpokePool_updatesSpokePool() public {
        MockSpokePoolV3 newSpokePool = new MockSpokePoolV3();

        vm.prank(admin);
        adapter.setSpokePool(address(newSpokePool));

        assertEq(address(adapter.spokePool()), address(newSpokePool), "SpokePool should be updated");
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

        assertEq(adapter.defaultRelayerFeePct(), newFee, "Relayer fee should be updated");
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
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Store payload via the genuine SpokePool delivery path
        vm.chainId(uint256(DEST_CHAIN_ID));
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        MockSpokePoolV3 destSpokePool = new MockSpokePoolV3();
        AcrossBridgeAdapter destAdapter = _deployDestAdapter(destEscrow, destSpokePool);

        uint256 relayDepositId = destSpokePool.addRelayDeposit(address(destAdapter), messagePayload);
        usdc.mint(address(destSpokePool), amount);
        destSpokePool.fillDeposit(relayDepositId, address(usdc), amount);

        bytes memory storedPayload = destAdapter.getMessagePayload(invoiceData.invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "Stored payload should match");
    }

    // ============ ERC165 Tests ============

    function test_supportsInterface_returnsTrueForIAcrossV3Receiver() public view {
        bytes4 interfaceId = type(IAcrossV3Receiver).interfaceId;
        assertTrue(adapter.supportsInterface(interfaceId), "Should support IAcrossV3Receiver");
    }
}
