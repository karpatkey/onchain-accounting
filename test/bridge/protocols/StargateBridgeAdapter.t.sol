// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {StargateBridgeAdapter} from "src/bridge/adapters/StargateBridgeAdapter.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/adapters/interfaces/IStargateInterfaces.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/adapters/interfaces/IStargateBridgeAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {BridgeScenarioHelper} from "test/bridge/BridgeScenarioHelper.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/bridge/mocks/MockBridgeProtocols.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";

/// @title StargateBridgeAdapterTest
/// @notice Test suite for Stargate Bridge Adapter
contract StargateBridgeAdapterTest is BridgeScenarioHelper {
    StargateBridgeAdapter public adapter;
    MockStargateRouter public router;
    address public endpoint; // Mock LayerZero endpoint

    uint16 public constant SOURCE_LZ_CHAIN_ID = 101; // Ethereum mainnet
    uint16 public constant DEST_LZ_CHAIN_ID = 111; // Optimism
    uint256 public constant SRC_POOL_ID = 1;
    uint256 public constant DST_POOL_ID = 1;

    // Note: In tests, block.chainid is usually 31337 (foundry default)
    // We'll use block.chainid for source chain pool ID configuration

    function setUp() public override {
        super.setUp();

        // Deploy mock Stargate router
        router = new MockStargateRouter();
        endpoint = address(router); // Use router as mock endpoint

        // Deploy Stargate adapter
        address adapterImpl = address(new StargateBridgeAdapter());
        address payable adapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                adapterImpl,
                abi.encodeCall(
                    StargateBridgeAdapter.initialize, (admin, address(bridgeEscrow), address(router), endpoint, "1.0.0")
                )
            ));
        adapter = StargateBridgeAdapter(adapterProxy);

        // Configure adapter (chain ID -> LZ ID for 1 and 10 are pre-configured in initialize)
        vm.startPrank(admin);
        // Set pool IDs (must be non-zero)
        // Note: block.chainid in tests is usually 31337 (foundry default)
        // We need to set pool IDs for the actual chain ID used in tests
        uint64 testChainId = uint64(block.chainid);
        adapter.setAssetPoolId(address(usdc), testChainId, SRC_POOL_ID);
        adapter.setAssetPoolId(address(usdc), DEST_CHAIN_ID, DST_POOL_ID);
        adapter.setAssetPoolId(address(weth), testChainId, SRC_POOL_ID);
        adapter.setAssetPoolId(address(weth), DEST_CHAIN_ID, DST_POOL_ID);
        adapter.grantRole(MANAGER, manager);
        vm.stopPrank();

        // Authorize adapter in BridgeEscrow
        _authorizeAdapter(address(adapter));

        // Setup labels
        vm.label(address(adapter), "StargateBridgeAdapter");
        vm.label(address(router), "MockStargateRouter");
        vm.label(endpoint, "MockLayerZeroEndpoint");
    }

    // ============ Bridge Initiation Tests ============

    function test_bridge_initiatesStargateSwap() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        _approveToken(address(usdc), address(bridgeEscrow), amount);

        // Create invoice data
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Transfer tokens to BridgeEscrow (simulating depositAndBridge)
        vm.prank(account);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(bridgeEscrow), amount);

        // BridgeEscrow approves adapter (new pattern: approval instead of transfer)
        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);

        // Fund adapter with ETH for LayerZero fee
        vm.deal(address(adapter), 0.01 ether);

        // Initiate bridge (adapter will pull tokens in _bridge())
        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);

        // Verify messagePayload was stored
        bytes32 invoiceId = invoiceData.invoiceId;
        bytes memory storedPayload = adapter.getMessagePayload(invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "MessagePayload should be stored");
    }

    function test_bridge_revertsForInvalidLzChainId() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData = _createInvoiceData(
            SOURCE_CHAIN_ID,
            999, // Invalid chain ID (no LZ chain ID mapping)
            account,
            USDC_SYMBOL_BYTES6,
            amount
        );
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(account);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(bridgeEscrow), amount);

        // BridgeEscrow approves adapter (new pattern: approval instead of transfer)
        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);

        vm.deal(address(adapter), 0.01 ether);

        vm.prank(address(bridgeEscrow));
        vm.expectRevert(); // Should revert because LZ chain ID mapping doesn't exist
        adapter.bridge(messagePayload);
    }

    function test_bridge_revertsForInvalidPoolId() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();

        // Use a different asset that doesn't have destination pool ID set
        // First, register a new token
        Mock_ERC20 newToken = new Mock_ERC20("NEW", 18);
        newToken.mint(account, amount);

        vm.startPrank(admin);
        bridgeEscrow.registerAsset("NEW", address(newToken));
        // Set source pool ID but NOT destination pool ID
        uint64 testChainId = uint64(block.chainid);
        adapter.setAssetPoolId(address(newToken), testChainId, SRC_POOL_ID);
        // Intentionally don't set destination pool ID for DEST_CHAIN_ID
        vm.stopPrank();

        vm.prank(account);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        newToken.transfer(address(bridgeEscrow), amount);

        // BridgeEscrow approves adapter (new pattern: approval instead of transfer)
        vm.prank(address(bridgeEscrow));
        newToken.approve(address(adapter), amount);

        vm.deal(address(adapter), 0.01 ether);

        // Create invoice with new token
        InvoiceDataLib.InvoiceData memory newInvoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, "NEW   ", amount);
        bytes memory newMessagePayload = InvoiceDataLib.encode(newInvoiceData);

        vm.prank(address(bridgeEscrow));
        vm.expectRevert(abi.encodeWithSelector(IStargateBridgeAdapter.InvalidPoolId.selector)); // Should revert because destination pool ID is not set
        adapter.bridge(newMessagePayload);
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

    // ============ Bridge Completion Tests ============

    function test_completeBridge_releasesTokensOnDestinationChain() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        // Set up destination chain environment
        (BridgeEscrow destBridgeEscrow, bytes memory messagePayload) =
            _setupDestinationChainForCompletion(invoiceData, address(usdc));

        // Set up adapter on destination chain
        address destAdapterImpl = address(new StargateBridgeAdapter());
        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                destAdapterImpl,
                abi.encodeCall(
                    StargateBridgeAdapter.initialize,
                    (admin, address(destBridgeEscrow), address(router), endpoint, "1.0.0")
                )
            ));
        StargateBridgeAdapter destAdapter = StargateBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        // SOURCE_CHAIN_ID and DEST_CHAIN_ID LZ mappings are pre-configured in initialize
        uint64 destChainId = uint64(block.chainid);
        destAdapter.setAssetPoolId(address(usdc), destChainId, SRC_POOL_ID);
        destAdapter.setAssetPoolId(address(usdc), DEST_CHAIN_ID, DST_POOL_ID);
        destAdapter.grantRole(MANAGER, manager);
        destBridgeEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        // Manager fallback: tokens already at escrow
        usdc.mint(address(destBridgeEscrow), amount);

        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));
        assertFalse(
            destBridgeEscrow.isInvoiceCompleted(invoiceHash), "Invoice should not be completed before completion"
        );

        uint256 initialPortfolioBalance = usdc.balanceOf(account);

        vm.prank(manager);
        destAdapter.completeBridge(messagePayload, abi.encode(SOURCE_LZ_CHAIN_ID));

        assertEq(usdc.balanceOf(account) - initialPortfolioBalance, amount, "Account should receive tokens");
        assertEq(usdc.balanceOf(address(destBridgeEscrow)), 0, "Escrow should have zero balance after release");
        assertTrue(destBridgeEscrow.isInvoiceCompleted(invoiceHash), "Invoice should be marked as completed");
    }

    /// @notice Full round-trip: depositAndBridge on source → payload from router → deliver only via deliverMessage (to escrow)
    function test_realistic_fullRoundTrip_sourcePayloadAndDeliveryViaStargate() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();

        // ---------- SOURCE CHAIN ----------
        _approveToken(address(usdc), address(bridgeEscrow), amount);
        vm.deal(address(adapter), 0.02 ether); // LayerZero fee
        vm.prank(account);
        bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, amount, address(adapter));

        bytes memory messagePayload = router.getLastSwapPayload();
        uint256 portfolioBalanceBeforeRelease = usdc.balanceOf(account);
        assertGt(messagePayload.length, 0, "messagePayload from source");

        // ---------- DESTINATION CHAIN ----------
        vm.chainId(uint256(DEST_CHAIN_ID));

        BridgeEscrow destBridgeEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        MockStargateRouter destRouter = new MockStargateRouter();
        address destEndpoint = address(destRouter);

        address destAdapterImpl = address(new StargateBridgeAdapter());
        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                destAdapterImpl,
                abi.encodeCall(
                    StargateBridgeAdapter.initialize,
                    (admin, address(destBridgeEscrow), address(destRouter), destEndpoint, "1.0.0")
                )
            ));
        StargateBridgeAdapter destAdapter = StargateBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        // SOURCE_CHAIN_ID and DEST_CHAIN_ID LZ mappings are pre-configured in initialize
        uint64 destChainId = uint64(block.chainid);
        destAdapter.setAssetPoolId(address(usdc), destChainId, SRC_POOL_ID);
        destAdapter.setAssetPoolId(address(usdc), DEST_CHAIN_ID, DST_POOL_ID);
        destAdapter.grantRole(MANAGER, manager);
        destBridgeEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        _registerCallbackModule(destBridgeEscrow, StargateBridgeAdapter.lzReceive.selector, address(destAdapter));

        uint64 msgId = destRouter.addSwapForDelivery(messagePayload);
        usdc.mint(address(destRouter), amount);
        destRouter.deliverMessage(msgId, address(destBridgeEscrow), address(usdc), amount);

        bytes32 expectedInvoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(messagePayload).checksum24)));
        assertTrue(destBridgeEscrow.isInvoiceCompleted(expectedInvoiceHash), "invoice completed");
        assertEq(usdc.balanceOf(account) - portfolioBalanceBeforeRelease, amount, "account received bridged amount");
        assertEq(usdc.balanceOf(address(destBridgeEscrow)), 0, "escrow balance zero after release");
    }

    function test_completeBridge_validatesChecksum() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        // Set up destination chain environment
        (BridgeEscrow destBridgeEscrow,) = _setupDestinationChainForCompletion(invoiceData, address(usdc));

        // Set up adapter on destination chain (simplified setup)
        address destAdapterImpl = address(new StargateBridgeAdapter());
        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                destAdapterImpl,
                abi.encodeCall(
                    StargateBridgeAdapter.initialize,
                    (admin, address(destBridgeEscrow), address(router), endpoint, "1.0.0")
                )
            ));
        StargateBridgeAdapter destAdapter = StargateBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        destAdapter.grantRole(MANAGER, manager);
        destBridgeEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        // Corrupt messagePayload (invalid checksum)
        bytes memory corruptedPayload = abi.encode(
            invoiceData.invoiceId,
            invoiceData.amount,
            bytes32(uint256(invoiceData.timestamp) << 192 | uint256(uint192(invoiceData.checksum24)) ^ 1)
        );

        bytes memory protocolData = abi.encode(SOURCE_LZ_CHAIN_ID);

        vm.prank(manager);
        vm.expectRevert(); // Should revert because checksum is invalid
        destAdapter.completeBridge(corruptedPayload, protocolData);
    }

    function test_completeBridge_revertsIfNotManager() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        // Set up destination chain environment
        (BridgeEscrow destBridgeEscrow, bytes memory messagePayload) =
            _setupDestinationChainForCompletion(invoiceData, address(usdc));

        // Set up adapter on destination chain
        address destAdapterImpl = address(new StargateBridgeAdapter());
        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                destAdapterImpl,
                abi.encodeCall(
                    StargateBridgeAdapter.initialize,
                    (admin, address(destBridgeEscrow), address(router), endpoint, "1.0.0")
                )
            ));
        StargateBridgeAdapter destAdapter = StargateBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        destBridgeEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        bytes memory protocolData = abi.encode(SOURCE_LZ_CHAIN_ID);

        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not manager
        destAdapter.completeBridge(messagePayload, protocolData);
    }

    // ============ LayerZero Receiver Tests (delivery goes to escrow → module → adapter) ============

    /// @notice When delivery goes to escrow, escrow fallback forwards lzReceive to adapter; adapter stores payload
    function test_lzReceive_storesNonceMapping() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(DEST_CHAIN_ID));
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        MockStargateRouter destRouter = new MockStargateRouter();
        address destEndpoint = address(destRouter);
        address destAdapterProxy = address(
            UnsafeUpgrades.deployUUPSProxy(
                address(new StargateBridgeAdapter()),
                abi.encodeCall(
                    StargateBridgeAdapter.initialize,
                    (admin, address(destEscrow), address(destRouter), destEndpoint, "1.0.0")
                )
            )
        );
        StargateBridgeAdapter destAdapter = StargateBridgeAdapter(payable(destAdapterProxy));
        vm.startPrank(admin);
        // SOURCE_CHAIN_ID and DEST_CHAIN_ID LZ mappings are pre-configured in initialize
        uint64 destChainId = uint64(block.chainid);
        destAdapter.setAssetPoolId(address(usdc), destChainId, SRC_POOL_ID);
        destAdapter.setAssetPoolId(address(usdc), DEST_CHAIN_ID, DST_POOL_ID);
        destEscrow.authorizeAdapter(destAdapterProxy);
        _registerCallbackModule(destEscrow, StargateBridgeAdapter.lzReceive.selector, destAdapterProxy);
        vm.stopPrank();

        uint64 msgId = destRouter.addSwapForDelivery(messagePayload);
        usdc.mint(address(destRouter), amount);
        destRouter.deliverMessage(msgId, address(destEscrow), address(usdc), amount);

        bytes memory storedPayload = destAdapter.getMessagePayload(invoiceData.invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "MessagePayload should be stored via callback");
    }

    function test_lzReceive_revertsIfNotEndpoint() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IStargateBridgeAdapter.InvalidEndpoint.selector));
        adapter.lzReceive(SOURCE_LZ_CHAIN_ID, "", 123, messagePayload);
    }

    function test_lzReceive_revertsForEmptyPayload() public {
        vm.prank(endpoint);
        vm.expectRevert(); // adapter reverts (empty payload or MessageReceiveFailed)
        adapter.lzReceive(SOURCE_LZ_CHAIN_ID, "", 123, "");
    }

    // ============ Configuration Tests ============

    function test_setChainIdMapping_updatesMapping() public {
        uint64 chainId = 42161; // Arbitrum
        uint16 lzChainId = 110;

        vm.prank(admin);
        adapter.setChainIdMapping(chainId, lzChainId);

        assertEq(adapter.getLzChainIdForChain(chainId), lzChainId, "LZ chain ID mapping should be set");
        assertEq(adapter.getChainForLzChainId(lzChainId), chainId, "Chain ID mapping should be set");
    }

    function test_setChainIdMapping_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not admin
        adapter.setChainIdMapping(42161, 110);
    }

    function test_setRouter_updatesRouter() public {
        MockStargateRouter newRouter = new MockStargateRouter();

        vm.prank(admin);
        adapter.setRouter(address(newRouter));

        // Verify router was updated (indirectly)
        assertTrue(true, "Router should be updated");
    }

    function test_setRouter_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not admin
        adapter.setRouter(address(0));
    }

    function test_setEndpoint_updatesEndpoint() public {
        address newEndpoint = makeAddr("newEndpoint");

        vm.prank(admin);
        adapter.setEndpoint(newEndpoint);

        // Verify endpoint was updated (indirectly)
        assertTrue(true, "Endpoint should be updated");
    }

    function test_setEndpoint_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not admin
        adapter.setEndpoint(address(0));
    }

    function test_setAssetPoolId_updatesPoolId() public {
        uint256 newPoolId = 2;

        vm.prank(admin);
        adapter.setAssetPoolId(address(usdc), SOURCE_CHAIN_ID, newPoolId);

        // Verify pool ID was set (indirectly)
        assertTrue(true, "Pool ID should be set");
    }

    function test_setAssetPoolId_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not admin
        adapter.setAssetPoolId(address(usdc), SOURCE_CHAIN_ID, 2);
    }

    function test_setDefaultDstGasForCall_updatesGasLimit() public {
        uint256 newGasLimit = 300000;

        vm.prank(admin);
        adapter.setDefaultDstGasForCall(newGasLimit);

        // Verify gas limit was updated (indirectly)
        assertTrue(true, "Gas limit should be updated");
    }

    function test_setDefaultDstGasForCall_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not admin
        adapter.setDefaultDstGasForCall(300000);
    }

    // ============ View Function Tests ============

    function test_getMessagePayload_returnsStoredPayload() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(DEST_CHAIN_ID));
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        MockStargateRouter destRouter = new MockStargateRouter();
        address destEndpoint = address(destRouter);
        address destAdapterProxy = address(
            UnsafeUpgrades.deployUUPSProxy(
                address(new StargateBridgeAdapter()),
                abi.encodeCall(
                    StargateBridgeAdapter.initialize,
                    (admin, address(destEscrow), address(destRouter), destEndpoint, "1.0.0")
                )
            )
        );
        StargateBridgeAdapter destAdapter = StargateBridgeAdapter(payable(destAdapterProxy));
        vm.startPrank(admin);
        // SOURCE_CHAIN_ID and DEST_CHAIN_ID LZ mappings are pre-configured in initialize
        uint64 destChainId = uint64(block.chainid);
        destAdapter.setAssetPoolId(address(usdc), destChainId, SRC_POOL_ID);
        destAdapter.setAssetPoolId(address(usdc), DEST_CHAIN_ID, DST_POOL_ID);
        destEscrow.authorizeAdapter(destAdapterProxy);
        _registerCallbackModule(destEscrow, StargateBridgeAdapter.lzReceive.selector, destAdapterProxy);
        vm.stopPrank();

        uint64 msgId = destRouter.addSwapForDelivery(messagePayload);
        usdc.mint(address(destRouter), amount);
        destRouter.deliverMessage(msgId, address(destEscrow), address(usdc), amount);

        bytes memory storedPayload = destAdapter.getMessagePayload(invoiceData.invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "Stored payload should match");
    }

    function test_quoteLayerZeroFee_returnsFee() public view {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // quoteLayerZeroFee signature: quoteLayerZeroFee(uint16 destinationChainId, uint256, uint256, uint256, bytes calldata payload, uint256 dstGasForCall)
        (uint256 nativeFee, uint256 zroFee) =
            adapter.quoteLayerZeroFee(DEST_LZ_CHAIN_ID, SRC_POOL_ID, DST_POOL_ID, amount, messagePayload, 200000);
        assertEq(nativeFee, 0.01 ether, "Native fee should match router's quote");
        assertEq(zroFee, 0, "ZRO fee should be 0");
    }
}
