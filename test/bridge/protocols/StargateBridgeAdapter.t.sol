// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {StargateBridgeAdapter} from "src/bridge/adapters/StargateBridgeAdapter.sol";
import {IStargateBridgeAdapter} from "src/bridge/adapters/interfaces/IStargateBridgeAdapter.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {BridgeScenarioHelper} from "test/bridge/BridgeScenarioHelper.sol";
import {MockStargatePoolV2, MockLZEndpointV2} from "test/bridge/mocks/StargateProvenanceMocks.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";

/// @title StargateBridgeAdapterTest
/// @notice Unit tests for the Stargate V2 (OFT / LayerZero V2) Bridge Adapter under the provenance model
///         (ADR 0012). The genuine LayerZero V2 Endpoint calls `lzCompose` on the destination sibling adapter;
///         the adapter authenticates the endpoint, the composing Stargate pool, the source eid and the source
///         sibling adapter, then funds the escrow and releases.
contract StargateBridgeAdapterTest is BridgeScenarioHelper {
    StargateBridgeAdapter public adapter;
    MockStargatePoolV2 public usdcPool;
    MockLZEndpointV2 public endpoint;

    // LayerZero eids: 30101 (Ethereum) and 30111 (Optimism) are pre-configured in initialize.
    uint32 public constant SOURCE_EID = 30101; // Ethereum
    uint32 public constant DEST_EID = 30111; // Optimism

    function setUp() public override {
        super.setUp();

        // Deploy the LayerZero V2 endpoint mock and a Stargate V2 USDC pool
        endpoint = new MockLZEndpointV2();
        usdcPool = new MockStargatePoolV2(address(usdc));

        // Deploy Stargate adapter
        address adapterImpl = address(new StargateBridgeAdapter());
        address payable adapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                adapterImpl,
                abi.encodeCall(
                    StargateBridgeAdapter.initialize, (admin, address(bridgeEscrow), address(endpoint), "1.0.0")
                )
            ));
        adapter = StargateBridgeAdapter(adapterProxy);

        vm.startPrank(admin);
        adapter.setStargatePool(address(usdc), address(usdcPool));
        adapter.grantRole(MANAGER, manager);
        vm.stopPrank();

        // Authorize adapter in BridgeEscrow
        _authorizeAdapter(address(adapter));

        // Setup labels
        vm.label(address(adapter), "StargateBridgeAdapter");
        vm.label(address(usdcPool), "MockStargatePoolV2");
        vm.label(address(endpoint), "MockLZEndpointV2");
    }

    // ============ Bridge Initiation Tests ============

    function test_bridge_initiatesStargateSend() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        _approveToken(address(usdc), address(bridgeEscrow), amount);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Simulate depositAndBridge: tokens at escrow, escrow approves adapter.
        vm.prank(account);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(bridgeEscrow), amount);
        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);

        // Fund adapter with native gas for the LayerZero fee
        vm.deal(address(adapter), 0.1 ether);

        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);

        // The Stargate pool received the tokens and recorded the compose payload (invoice payload).
        assertEq(usdc.balanceOf(address(usdcPool)), amount, "pool received bridged tokens");
        assertEq(usdcPool.getLastComposeMsg(), messagePayload, "composeMsg == invoice messagePayload");

        // The destination recipient (SendParam.to) is the sibling adapter (this address via CREATE2).
        (, bytes32 to,,,,,) = usdcPool.lastSendParam();
        assertEq(to, bytes32(uint256(uint160(address(adapter)))), "recipient is sibling adapter");

        bytes memory stored = adapter.getMessagePayload(invoiceData.invoiceId);
        assertEq(stored.length, messagePayload.length, "messagePayload stored");
    }

    function test_bridge_revertsForUnsupportedDestChain() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        // destinationChainId 999 has no eid mapping
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, 999, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(account);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(bridgeEscrow), amount);
        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);
        vm.deal(address(adapter), 0.1 ether);

        vm.prank(address(bridgeEscrow));
        vm.expectRevert(abi.encodeWithSelector(IStargateBridgeAdapter.UnsupportedChain.selector, uint32(0)));
        adapter.bridge(messagePayload);
    }

    function test_bridge_revertsForUnconfiguredPool() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();

        // Register a new asset with no Stargate pool configured
        Mock_ERC20 newToken = new Mock_ERC20("NEW", 18);
        newToken.mint(account, amount);
        vm.prank(admin);
        bridgeEscrow.registerAsset("NEW", address(newToken));

        vm.prank(account);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        newToken.transfer(address(bridgeEscrow), amount);
        vm.prank(address(bridgeEscrow));
        newToken.approve(address(adapter), amount);
        vm.deal(address(adapter), 0.1 ether);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, "NEW   ", amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(address(bridgeEscrow));
        vm.expectRevert(abi.encodeWithSelector(IStargateBridgeAdapter.InvalidPool.selector));
        adapter.bridge(messagePayload);
    }

    function test_bridge_revertsIfNotCalledByBridgeEscrow() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(unauthorized);
        vm.expectRevert(); // not BridgeEscrow
        adapter.bridge(messagePayload);
    }

    // ============ Destination: lzCompose auto path (provenance-checked) ============

    /// @notice Full round-trip: deposit on source -> read composed payload from pool -> genuine endpoint
    ///         delivers tokens + lzCompose on the destination adapter -> escrow funded -> account paid.
    function test_realistic_fullRoundTrip_lzComposeRelease() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();

        // ---------- SOURCE CHAIN ----------
        _approveToken(address(usdc), address(bridgeEscrow), amount);
        vm.deal(address(adapter), 0.1 ether);
        vm.prank(account);
        bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, amount, address(adapter));

        bytes memory messagePayload = usdcPool.getLastComposeMsg();
        assertGt(messagePayload.length, 0, "composed payload from source");
        uint256 portfolioBefore = usdc.balanceOf(account);

        // ---------- DESTINATION CHAIN ----------
        vm.chainId(uint256(DEST_CHAIN_ID));
        (
            BridgeEscrow destEscrow,
            StargateBridgeAdapter destAdapter,
            MockStargatePoolV2 destPool,
            MockLZEndpointV2 destEndpoint
        ) = _setupDestination();

        // Genuine delivery: fund the endpoint, then it delivers tokens + lzCompose (from the dest pool).
        usdc.mint(address(destEndpoint), amount);
        bytes memory composeMessage = destEndpoint.encodeComposeMessage(
            1, SOURCE_EID, amount, bytes32(uint256(uint160(address(adapter)))), messagePayload
        );
        destEndpoint.deliverCompose(address(destAdapter), address(destPool), address(usdc), amount, composeMessage);

        bytes32 invoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(messagePayload).checksum24)));
        assertTrue(destEscrow.isInvoiceCompleted(invoiceHash), "invoice completed");
        assertEq(usdc.balanceOf(account) - portfolioBefore, amount, "account received bridged amount");
        assertEq(usdc.balanceOf(address(destEscrow)), 0, "escrow holds nothing (funded pass-through)");
        assertEq(usdc.balanceOf(address(destAdapter)), 0, "adapter forwarded everything");
    }

    /// @notice Post-fee output model (resolves the PR#86 Stargate fee issue): when the pool charges a protocol
    ///         fee, `_bridge` quotes the post-fee receive amount, re-encodes the invoice payload to carry it, and
    ///         pins `minAmountLD` to it. The destination receives and releases exactly the post-fee amount; the
    ///         depositor bears the fee (standard bridge UX). Source records the gross deposit; pairing is by
    ///         invoiceId.
    function test_realistic_postFeeOutput_releasesNetOfFee() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        uint256 fee = 7 * 10 ** usdc.decimals();
        uint256 net = amount - fee;

        usdcPool.setProtocolFeeLD(fee); // source pool charges a protocol fee

        // ---------- SOURCE CHAIN ----------
        _approveToken(address(usdc), address(bridgeEscrow), amount);
        vm.deal(address(adapter), 0.1 ether);
        vm.prank(account);
        bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, amount, address(adapter));

        bytes memory messagePayload = usdcPool.getLastComposeMsg();
        assertEq(InvoiceDataLib.decode(messagePayload).amount, net, "payload carries the post-fee amount");
        (,, uint256 amountLD, uint256 minAmountLD,,,) = usdcPool.lastSendParam();
        assertEq(amountLD, amount, "gross amount debited on source");
        assertEq(minAmountLD, net, "tight slippage floor pinned at the post-fee amount");
        uint256 portfolioBefore = usdc.balanceOf(account);

        // ---------- DESTINATION CHAIN ----------
        vm.chainId(uint256(DEST_CHAIN_ID));
        (
            BridgeEscrow destEscrow,
            StargateBridgeAdapter destAdapter,
            MockStargatePoolV2 destPool,
            MockLZEndpointV2 destEndpoint
        ) = _setupDestination();

        // Stargate delivers the NET (post-fee) amount to the destination adapter.
        usdc.mint(address(destEndpoint), net);
        bytes memory composeMessage = destEndpoint.encodeComposeMessage(
            1, SOURCE_EID, net, bytes32(uint256(uint160(address(adapter)))), messagePayload
        );
        destEndpoint.deliverCompose(address(destAdapter), address(destPool), address(usdc), net, composeMessage);

        bytes32 invoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(messagePayload).checksum24)));
        assertTrue(destEscrow.isInvoiceCompleted(invoiceHash), "invoice completed");
        assertEq(usdc.balanceOf(account) - portfolioBefore, net, "account received the post-fee amount");
        assertEq(usdc.balanceOf(address(destAdapter)), 0, "adapter forwarded everything");
    }

    /// @notice Sets up a destination adapter + escrow trusting the source sibling adapter, ready for lzCompose.
    function _setupDestination()
        internal
        returns (
            BridgeEscrow destEscrow,
            StargateBridgeAdapter destAdapter,
            MockStargatePoolV2 destPool,
            MockLZEndpointV2 destEndpoint
        )
    {
        destEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        destEndpoint = new MockLZEndpointV2();
        destPool = new MockStargatePoolV2(address(usdc));

        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                address(new StargateBridgeAdapter()),
                abi.encodeCall(
                    StargateBridgeAdapter.initialize, (admin, address(destEscrow), address(destEndpoint), "1.0.0")
                )
            ));
        destAdapter = StargateBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        destAdapter.setStargatePool(address(usdc), address(destPool));
        destAdapter.grantRole(MANAGER, manager);
        destAdapter.setTrustedRemoteAdapter(SOURCE_CHAIN_ID, bytes32(uint256(uint160(address(adapter)))));
        destEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();
    }

    function test_lzCompose_revertsIfNotEndpoint() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        vm.chainId(uint256(DEST_CHAIN_ID));
        (, StargateBridgeAdapter destAdapter, MockStargatePoolV2 destPool, MockLZEndpointV2 destEndpoint) =
            _setupDestination();

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);
        bytes memory composeMessage = destEndpoint.encodeComposeMessage(
            1, SOURCE_EID, amount, bytes32(uint256(uint160(address(adapter)))), messagePayload
        );

        // Caller is not the endpoint -> revert.
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IStargateBridgeAdapter.InvalidEndpoint.selector));
        destAdapter.lzCompose(address(destPool), bytes32(0), composeMessage, address(0), bytes(""));
    }

    function test_lzCompose_revertsForUntrustedSourceAdapter() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        vm.chainId(uint256(DEST_CHAIN_ID));
        (, StargateBridgeAdapter destAdapter, MockStargatePoolV2 destPool, MockLZEndpointV2 destEndpoint) =
            _setupDestination();

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        usdc.mint(address(destEndpoint), amount);
        // composeFrom is a WRONG (untrusted) source adapter address.
        bytes memory composeMessage = destEndpoint.encodeComposeMessage(
            1, SOURCE_EID, amount, bytes32(uint256(uint160(unauthorized))), messagePayload
        );

        vm.expectRevert(abi.encodeWithSelector(IStargateBridgeAdapter.InvalidBridgeData.selector));
        destEndpoint.deliverCompose(address(destAdapter), address(destPool), address(usdc), amount, composeMessage);
    }

    function test_lzCompose_revertsForUnsupportedSourceEid() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        vm.chainId(uint256(DEST_CHAIN_ID));
        (, StargateBridgeAdapter destAdapter, MockStargatePoolV2 destPool, MockLZEndpointV2 destEndpoint) =
            _setupDestination();

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        usdc.mint(address(destEndpoint), amount);
        uint32 unknownEid = 40404; // no eidToChainId mapping
        bytes memory composeMessage = destEndpoint.encodeComposeMessage(
            1, unknownEid, amount, bytes32(uint256(uint160(address(adapter)))), messagePayload
        );

        vm.expectRevert(abi.encodeWithSelector(IStargateBridgeAdapter.UnsupportedChain.selector, unknownEid));
        destEndpoint.deliverCompose(address(destAdapter), address(destPool), address(usdc), amount, composeMessage);
    }

    function test_lzCompose_revertsForWrongComposingPool() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        vm.chainId(uint256(DEST_CHAIN_ID));
        (, StargateBridgeAdapter destAdapter,, MockLZEndpointV2 destEndpoint) = _setupDestination();

        // A pool that is NOT the one configured for USDC on the dest adapter.
        MockStargatePoolV2 roguePool = new MockStargatePoolV2(address(usdc));

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        usdc.mint(address(destEndpoint), amount);
        bytes memory composeMessage = destEndpoint.encodeComposeMessage(
            1, SOURCE_EID, amount, bytes32(uint256(uint160(address(adapter)))), messagePayload
        );

        // _from == roguePool != stargatePool[usdc] -> revert.
        vm.expectRevert(abi.encodeWithSelector(IStargateBridgeAdapter.InvalidBridgeData.selector));
        destEndpoint.deliverCompose(address(destAdapter), address(roguePool), address(usdc), amount, composeMessage);
    }

    function test_lzCompose_revertsIfDeliveredLessThanInvoice() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        vm.chainId(uint256(DEST_CHAIN_ID));
        (, StargateBridgeAdapter destAdapter, MockStargatePoolV2 destPool, MockLZEndpointV2 destEndpoint) =
            _setupDestination();

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // amountLD in the composed message claims less than the invoice amount -> reverts.
        usdc.mint(address(destEndpoint), amount);
        bytes memory composeMessage = destEndpoint.encodeComposeMessage(
            1, SOURCE_EID, amount - 1, bytes32(uint256(uint160(address(adapter)))), messagePayload
        );

        vm.expectRevert(abi.encodeWithSelector(IStargateBridgeAdapter.InvalidBridgeData.selector));
        destEndpoint.deliverCompose(address(destAdapter), address(destPool), address(usdc), amount, composeMessage);
    }

    function test_lzCompose_revertsOnReplay() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        vm.chainId(uint256(DEST_CHAIN_ID));
        (
            BridgeEscrow destEscrow,
            StargateBridgeAdapter destAdapter,
            MockStargatePoolV2 destPool,
            MockLZEndpointV2 destEndpoint
        ) = _setupDestination();

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);
        bytes memory composeMessage = destEndpoint.encodeComposeMessage(
            1, SOURCE_EID, amount, bytes32(uint256(uint160(address(adapter)))), messagePayload
        );

        // First delivery succeeds.
        usdc.mint(address(destEndpoint), amount);
        destEndpoint.deliverCompose(address(destAdapter), address(destPool), address(usdc), amount, composeMessage);
        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));
        assertTrue(destEscrow.isInvoiceCompleted(invoiceHash), "completed after first delivery");

        // Second delivery (replay) reverts at the escrow's completedInvoices guard.
        usdc.mint(address(destEndpoint), amount);
        vm.expectRevert();
        destEndpoint.deliverCompose(address(destAdapter), address(destPool), address(usdc), amount, composeMessage);
    }

    // ============ Destination: MANAGER completeBridge fallback path ============

    function test_completeBridge_releasesTokensOnDestinationChain() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        vm.chainId(uint256(DEST_CHAIN_ID));
        (BridgeEscrow destEscrow, StargateBridgeAdapter destAdapter,, MockLZEndpointV2 destEndpoint) =
            _setupDestination();

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Manager path: the adapter already holds the delivered tokens (Stargate delivered to recipient).
        usdc.mint(address(destAdapter), amount);

        // protocolData = the OFT-composed message (authenticated the same way as the auto path).
        bytes memory protocolData = destEndpoint.encodeComposeMessage(
            1, SOURCE_EID, amount, bytes32(uint256(uint160(address(adapter)))), messagePayload
        );

        uint256 portfolioBefore = usdc.balanceOf(account);
        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));

        vm.prank(manager);
        destAdapter.completeBridge(messagePayload, protocolData);

        assertEq(usdc.balanceOf(account) - portfolioBefore, amount, "account received tokens");
        assertEq(usdc.balanceOf(address(destEscrow)), 0, "escrow zero after release");
        assertTrue(destEscrow.isInvoiceCompleted(invoiceHash), "invoice completed");
    }

    function test_completeBridge_revertsIfNotManager() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        vm.chainId(uint256(DEST_CHAIN_ID));
        (, StargateBridgeAdapter destAdapter,, MockLZEndpointV2 destEndpoint) = _setupDestination();

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);
        bytes memory protocolData = destEndpoint.encodeComposeMessage(
            1, SOURCE_EID, amount, bytes32(uint256(uint160(address(adapter)))), messagePayload
        );

        vm.prank(unauthorized);
        vm.expectRevert(); // not MANAGER
        destAdapter.completeBridge(messagePayload, protocolData);
    }

    function test_completeBridge_revertsForUntrustedSource() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        vm.chainId(uint256(DEST_CHAIN_ID));
        (, StargateBridgeAdapter destAdapter,, MockLZEndpointV2 destEndpoint) = _setupDestination();

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);
        usdc.mint(address(destAdapter), amount);

        // Untrusted composeFrom in protocolData -> manager path must still authenticate source.
        bytes memory protocolData = destEndpoint.encodeComposeMessage(
            1, SOURCE_EID, amount, bytes32(uint256(uint160(unauthorized))), messagePayload
        );

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IStargateBridgeAdapter.InvalidBridgeData.selector));
        destAdapter.completeBridge(messagePayload, protocolData);
    }

    function test_completeBridge_validatesChecksum() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        vm.chainId(uint256(DEST_CHAIN_ID));
        (, StargateBridgeAdapter destAdapter,, MockLZEndpointV2 destEndpoint) = _setupDestination();

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        // Corrupt the checksum (flip a bit) while keeping the same wire layout.
        bytes24 badChecksum = bytes24(uint192(invoiceData.checksum24) ^ uint192(1));
        invoiceData.checksum24 = badChecksum;
        bytes memory corruptedPayload = InvoiceDataLib.encode(invoiceData);

        usdc.mint(address(destAdapter), amount);
        bytes memory protocolData = destEndpoint.encodeComposeMessage(
            1, SOURCE_EID, amount, bytes32(uint256(uint160(address(adapter)))), corruptedPayload
        );

        // Source authentication passes; the escrow rejects the bad checksum in releaseByInvoiceId.
        vm.prank(manager);
        vm.expectRevert();
        destAdapter.completeBridge(corruptedPayload, protocolData);
    }

    // ============ Configuration Tests ============

    function test_setEidMapping_updatesMapping() public {
        uint64 chainId = 42161; // Arbitrum
        uint32 eid = 30110;

        vm.prank(admin);
        adapter.setEidMapping(chainId, eid);

        assertEq(adapter.getEidForChain(chainId), eid, "eid mapping set");
        assertEq(adapter.getChainForEid(eid), chainId, "chain mapping set");
    }

    function test_setEidMapping_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        adapter.setEidMapping(42161, 30110);
    }

    function test_setEndpoint_updatesEndpoint() public {
        address newEndpoint = makeAddr("newEndpoint");
        vm.prank(admin);
        adapter.setEndpoint(newEndpoint);
        assertEq(adapter.endpoint(), newEndpoint, "endpoint updated");
    }

    function test_setEndpoint_revertsForZero() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IStargateBridgeAdapter.InvalidEndpoint.selector));
        adapter.setEndpoint(address(0));
    }

    function test_setEndpoint_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        adapter.setEndpoint(makeAddr("x"));
    }

    function test_setStargatePool_updatesPool() public {
        MockStargatePoolV2 newPool = new MockStargatePoolV2(address(weth));
        vm.prank(admin);
        adapter.setStargatePool(address(weth), address(newPool));
        assertEq(adapter.stargatePool(address(weth)), address(newPool), "pool set");
    }

    function test_setStargatePool_revertsForMismatchedToken() public {
        // Pool's underlying is WETH, but we try to bind it to USDC.
        MockStargatePoolV2 wethPool = new MockStargatePoolV2(address(weth));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IStargateBridgeAdapter.InvalidPool.selector));
        adapter.setStargatePool(address(usdc), address(wethPool));
    }

    function test_setStargatePool_revertsForZero() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IStargateBridgeAdapter.InvalidPool.selector));
        adapter.setStargatePool(address(usdc), address(0));
    }

    function test_setStargatePool_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        adapter.setStargatePool(address(usdc), address(usdcPool));
    }

    function test_setComposeOptions_updatesOptions() public {
        bytes memory opts = hex"0003";
        vm.prank(admin);
        adapter.setComposeOptions(DEST_EID, opts);
        assertEq(adapter.composeOptions(DEST_EID), opts, "options set");
    }

    function test_setComposeOptions_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        adapter.setComposeOptions(DEST_EID, hex"0003");
    }

    function test_setTrustedRemoteAdapter_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        adapter.setTrustedRemoteAdapter(SOURCE_CHAIN_ID, bytes32(uint256(1)));
    }

    // ============ View / Pre-config ============

    function test_eids_preconfigured() public view {
        assertEq(adapter.getEidForChain(1), SOURCE_EID, "Ethereum eid");
        assertEq(adapter.getEidForChain(10), DEST_EID, "Optimism eid");
        assertEq(adapter.getChainForEid(SOURCE_EID), 1, "eid -> Ethereum");
    }
}
