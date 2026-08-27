// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {GnosisBridgeAdapter} from "src/bridge/adapters/GnosisBridgeAdapter.sol";
import {IGnosisBridgeAdapter} from "src/bridge/adapters/interfaces/IGnosisBridgeAdapter.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {BridgeScenarioHelper} from "test/bridge/BridgeScenarioHelper.sol";
import {
    MockProvenanceOmnibridge,
    MockProvenanceAMB,
    MockUSDCTransmuter
} from "test/bridge/mocks/GnosisProvenanceMocks.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title GnosisBridgeAdapterTest
/// @notice Test suite for the Gnosis Omnibridge adapter under the ADR 0012 provenance model.
/// @dev Destination recipient is the sibling adapter (address(this)). The Omnibridge mediator delivers tokens
///      to the adapter and calls onTokenTransfer; the adapter authenticates msg.sender == omnibridge plus the
///      AMB-reported source (messageSender == trustedRemoteAdapter, messageSourceChainId == source chain), then
///      records the delivery into escrow custody (ADR 0027). A MANAGER claim later pays the account. The MANAGER
///      completeBridge path verifies the same provenance.
contract GnosisBridgeAdapterTest is BridgeScenarioHelper {
    GnosisBridgeAdapter public adapter;
    MockProvenanceOmnibridge public omnibridge;
    MockProvenanceAMB public amb;

    uint64 public constant GNOSIS_CHAIN_ID = 100; // Gnosis Chain

    // The trusted sibling adapter living on the source chain (Ethereum). On real deployments this matches the
    // destination adapter's own address (CREATE2 same-address); for unit tests any fixed address works.
    address public remoteAdapter = makeAddr("remoteAdapter");
    /// @dev The source Omnibridge mediator address the AMB reports as messageSender() for inbound transfers.
    address public sourceMediator = makeAddr("sourceMediator");

    function setUp() public override {
        super.setUp();

        omnibridge = new MockProvenanceOmnibridge();
        amb = new MockProvenanceAMB();

        adapter = _deployGnosisAdapter(address(bridgeEscrow), address(omnibridge), address(amb));

        vm.startPrank(admin);
        adapter.grantRole(MANAGER, manager);
        // Trust the sibling adapter on the source chain (Ethereum, chain id 1 = SOURCE_CHAIN_ID).
        adapter.setTrustedRemoteAdapter(SOURCE_CHAIN_ID, bytes32(uint256(uint160(remoteAdapter))));
        vm.stopPrank();

        _authorizeAdapter(address(adapter));

        vm.label(address(adapter), "GnosisBridgeAdapter");
        vm.label(address(omnibridge), "MockProvenanceOmnibridge");
        vm.label(address(amb), "MockProvenanceAMB");
    }

    // ============ Helpers ============

    function _deployGnosisAdapter(address escrow_, address omnibridge_, address amb_)
        internal
        returns (GnosisBridgeAdapter)
    {
        address adapterImpl = address(new GnosisBridgeAdapter(address(0)));
        address payable adapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                adapterImpl,
                abi.encodeCall(GnosisBridgeAdapter.initialize, (admin, escrow_, omnibridge_, amb_, "1.0.0"))
            ));
        return GnosisBridgeAdapter(adapterProxy);
    }

    /// @notice Sets up a destination-chain escrow + adapter wired for the provenance model.
    /// @dev Trusts `remoteAdapter` for SOURCE_CHAIN_ID and configures the dest AMB so onTokenTransfer/_completeBridge
    ///      authentication passes.
    function _setupDestination(MockProvenanceOmnibridge destOmnibridge, MockProvenanceAMB destAmb)
        internal
        returns (BridgeEscrow destEscrow, GnosisBridgeAdapter destAdapter)
    {
        destEscrow = _setupDestinationChainEscrow(GNOSIS_CHAIN_ID);
        destAdapter = _deployGnosisAdapter(address(destEscrow), address(destOmnibridge), address(destAmb));

        vm.startPrank(admin);
        destAdapter.grantRole(MANAGER, manager);
        destAdapter.setTrustedMediator(SOURCE_CHAIN_ID, sourceMediator);
        destEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        // Authentic AMB provenance: the AMB reports the SOURCE Omnibridge mediator as messageSender.
        destAmb.setMessageSender(sourceMediator);
        destAmb.setMessageSourceChainId(bytes32(uint256(SOURCE_CHAIN_ID)));
    }

    // ============ Bridge Initiation Tests ============

    function test_bridge_initiatesOmnibridgeTransfer() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        _approveToken(address(usdc), address(bridgeEscrow), amount);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(account);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(bridgeEscrow), amount);

        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);

        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);

        // Recipient must be the sibling adapter (address(this)), not the escrow.
        assertEq(omnibridge.lastRelayReceiver(), address(adapter), "Receiver should be the sibling adapter");
        (bytes memory relayData, uint256 relayValue) = omnibridge.getLastRelayData();
        assertEq(relayValue, amount, "Relay value equals amount");
        assertEq(relayData.length, messagePayload.length, "Relay data carries the invoice payload");

        bytes memory storedPayload = adapter.getMessagePayload(invoiceData.invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "MessagePayload should be stored");
    }

    function test_bridge_revertsForUnsupportedChain() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData = _createInvoiceData(
            SOURCE_CHAIN_ID,
            999, // Unsupported chain ID (not 1 or 100)
            account,
            USDC_SYMBOL_BYTES6,
            amount
        );
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(account);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(bridgeEscrow), amount);

        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);

        vm.prank(address(bridgeEscrow));
        vm.expectRevert(abi.encodeWithSelector(IGnosisBridgeAdapter.UnsupportedChain.selector, uint64(999)));
        adapter.bridge(messagePayload);
    }

    function test_bridge_revertsForNativeToken() public {
        uint256 amount = 1 ether;
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Re-point the WETH symbol to native (address(0)) so the adapter exercises its native-token rejection.
        vm.prank(admin);
        bridgeEscrow.registerAsset(WETH_SYMBOL, address(0));

        vm.prank(address(bridgeEscrow));
        vm.expectRevert(abi.encodeWithSelector(IGnosisBridgeAdapter.NativeTokenNotSupported.selector));
        adapter.bridge(messagePayload);
    }

    function test_bridge_revertsIfNotCalledByBridgeEscrow() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        adapter.bridge(messagePayload);
    }

    // ============ Bridge Completion Tests (MANAGER fallback path) ============

    function test_managerFallback_completesAfterDeferredRelease() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        MockProvenanceOmnibridge destOmnibridge = new MockProvenanceOmnibridge();
        MockProvenanceAMB destAmb = new MockProvenanceAMB();
        (BridgeEscrow destEscrow, GnosisBridgeAdapter destAdapter) = _setupDestination(destOmnibridge, destAmb);

        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));

        // Auto delivery while the escrow is PAUSED: onTokenTransfer authenticates (mediator) and records
        // provenance, but the release reverts (whenNotPaused) and is caught — tokens stay on the adapter,
        // the invoice is NOT completed, but it is now marked authenticated.
        vm.prank(admin);
        destEscrow.pause();
        usdc.mint(address(destOmnibridge), amount);
        destOmnibridge.deliverTokens(address(usdc), address(destAdapter), amount, messagePayload);

        assertTrue(destAdapter.authenticatedInvoice(invoiceHash), "invoice authenticated at delivery");
        assertFalse(destEscrow.isInvoiceCompleted(invoiceHash), "invoice not completed while release deferred");
        assertEq(usdc.balanceOf(address(destAdapter)), amount, "adapter holds the delivered tokens");

        // Unpause and complete via the MANAGER fallback against the recorded provenance.
        vm.prank(admin);
        destEscrow.unpause();
        uint256 initialPortfolioBalance = usdc.balanceOf(account);

        vm.prank(manager);
        destAdapter.completeBridge(messagePayload, "");

        // ADR 0027: completeBridge records the delivery into custody — escrow HOLDS, no payout yet.
        assertEq(usdc.balanceOf(account), initialPortfolioBalance, "account NOT paid on record");
        assertEq(usdc.balanceOf(address(destAdapter)), 0, "adapter zero after funding escrow custody");
        assertEq(usdc.balanceOf(address(destEscrow)), amount, "escrow holds the delivery");
        assertEq(destEscrow.getHeldBalanceForAsset(address(usdc), account), amount, "held for account");
        assertTrue(destEscrow.isInvoiceCompleted(invoiceHash), "invoice completed via fallback record");

        // MANAGER claim pays the account.
        vm.prank(manager);
        destEscrow.claim(invoiceHash);
        assertEq(usdc.balanceOf(account) - initialPortfolioBalance, amount, "account receives tokens on claim");
        assertEq(destEscrow.getHeldBalanceForAsset(address(usdc), account), 0, "held cleared after claim");
    }

    /// @notice `authenticatedInvoice` is keyed by the per-operation invoice HASH, not the reusable lane
    ///         `invoiceId`. Authenticating one transfer must NOT let the MANAGER fallback complete a different
    ///         same-lane transfer (same src/dst/account/asset → same invoiceId, different nonce → different hash).
    function test_managerFallback_perHash_notPerLane() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        // Two transfers on the SAME lane (share invoiceId), different nonce → different invoiceHash.
        InvoiceDataLib.InvoiceData memory invA =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount, 0);
        InvoiceDataLib.InvoiceData memory invB =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount, 1);
        assertEq(invA.invoiceId, invB.invoiceId, "same lane => same invoiceId");
        assertTrue(invA.checksum24 != invB.checksum24, "different nonce => different hash");

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        MockProvenanceOmnibridge destOmnibridge = new MockProvenanceOmnibridge();
        MockProvenanceAMB destAmb = new MockProvenanceAMB();
        (, GnosisBridgeAdapter destAdapter) = _setupDestination(destOmnibridge, destAmb);

        // Deliver + authenticate ONLY transfer A.
        usdc.mint(address(destOmnibridge), amount);
        destOmnibridge.deliverTokens(address(usdc), address(destAdapter), amount, InvoiceDataLib.encode(invA));
        assertTrue(destAdapter.authenticatedInvoice(bytes32(uint256(uint192(invA.checksum24)))), "A authenticated");
        assertFalse(destAdapter.authenticatedInvoice(bytes32(uint256(uint192(invB.checksum24)))), "B NOT authenticated");

        // MANAGER fallback for B (same lane, unauthenticated hash) must revert — even with funds present.
        usdc.mint(address(destAdapter), amount);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IGnosisBridgeAdapter.InvalidBridgeData.selector));
        destAdapter.completeBridge(InvoiceDataLib.encode(invB), "");
    }

    function test_managerFallback_revertsWithoutPriorAuthentication() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        MockProvenanceOmnibridge destOmnibridge = new MockProvenanceOmnibridge();
        MockProvenanceAMB destAmb = new MockProvenanceAMB();
        (, GnosisBridgeAdapter destAdapter) = _setupDestination(destOmnibridge, destAmb);

        // No genuine delivery happened, so no provenance was recorded — the fallback cannot complete even
        // with funds present (the AMB cannot be re-read out of message context).
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);
        usdc.mint(address(destAdapter), amount);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IGnosisBridgeAdapter.InvalidBridgeData.selector));
        destAdapter.completeBridge(messagePayload, "");
    }

    function test_onTokenTransfer_revertsForUntrustedMediator() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        MockProvenanceOmnibridge destOmnibridge = new MockProvenanceOmnibridge();
        MockProvenanceAMB destAmb = new MockProvenanceAMB();
        (, GnosisBridgeAdapter destAdapter) = _setupDestination(destOmnibridge, destAmb);

        // AMB reports an impostor mediator (not the configured source mediator) — auth must fail, and the
        // mediator mock forwards the onTokenTransfer revert.
        destAmb.setMessageSender(makeAddr("impostor"));
        usdc.mint(address(destOmnibridge), amount);

        vm.expectRevert(abi.encodeWithSelector(IGnosisBridgeAdapter.InvalidBridgeData.selector));
        destOmnibridge.deliverTokens(address(usdc), address(destAdapter), amount, messagePayload);
    }

    function test_completeBridge_revertsIfNotManager() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        MockProvenanceOmnibridge destOmnibridge = new MockProvenanceOmnibridge();
        MockProvenanceAMB destAmb = new MockProvenanceAMB();
        (, GnosisBridgeAdapter destAdapter) = _setupDestination(destOmnibridge, destAmb);

        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        destAdapter.completeBridge(messagePayload, "");
    }

    /// @notice Full round-trip: depositAndBridge on source -> read payload from omnibridge -> deliver only via
    ///         the mediator's deliverTokens (auto onTokenTransfer path) on the destination.
    function test_realistic_fullRoundTrip_sourcePayloadAndDeliveryViaGnosis() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();

        // ---------- SOURCE CHAIN ----------
        _approveToken(address(usdc), address(bridgeEscrow), amount);
        vm.prank(account);
        bridgeEscrow.depositAndBridge(GNOSIS_CHAIN_ID, USDC_SYMBOL, amount, address(adapter));

        (bytes memory messagePayload, uint256 relayAmount) = omnibridge.getLastRelayData();
        uint256 portfolioBalanceBeforeRelease = usdc.balanceOf(account);
        assertGt(messagePayload.length, 0, "messagePayload from source");
        assertEq(relayAmount, amount, "relay value equals amount");

        // ---------- DESTINATION CHAIN ----------
        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        MockProvenanceOmnibridge destOmnibridge = new MockProvenanceOmnibridge();
        MockProvenanceAMB destAmb = new MockProvenanceAMB();
        (BridgeEscrow destEscrow, GnosisBridgeAdapter destAdapter) = _setupDestination(destOmnibridge, destAmb);

        // Mediator holds the tokens, delivers to the adapter, then calls onTokenTransfer (auto release).
        usdc.mint(address(destOmnibridge), amount);
        destOmnibridge.deliverTokens(address(usdc), address(destAdapter), amount, messagePayload);

        bytes32 expectedInvoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(messagePayload).checksum24)));
        assertTrue(destEscrow.isInvoiceCompleted(expectedInvoiceHash), "invoice completed on record");
        // ADR 0027: auto delivery records custody and HOLDS; the account is paid only on MANAGER claim.
        assertEq(usdc.balanceOf(account), portfolioBalanceBeforeRelease, "account NOT paid on delivery");
        assertEq(usdc.balanceOf(address(destEscrow)), amount, "escrow holds the delivery");
        assertEq(destEscrow.getHeldBalanceForAsset(address(usdc), account), amount, "held for account");
        assertEq(usdc.balanceOf(address(destAdapter)), 0, "adapter balance zero after funding escrow custody");

        vm.prank(manager);
        destEscrow.claim(expectedInvoiceHash);
        assertEq(usdc.balanceOf(account) - portfolioBalanceBeforeRelease, amount, "account received bridged amount");
        assertEq(usdc.balanceOf(address(destEscrow)), 0, "escrow drained after claim");
        assertEq(destEscrow.getHeldBalanceForAsset(address(usdc), account), 0, "held cleared after claim");
    }

    // ============ onTokenTransfer (auto provenance path) Tests ============

    function test_onTokenTransfer_releasesAndStoresPayload() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        MockProvenanceOmnibridge destOmnibridge = new MockProvenanceOmnibridge();
        MockProvenanceAMB destAmb = new MockProvenanceAMB();
        (, GnosisBridgeAdapter destAdapter) = _setupDestination(destOmnibridge, destAmb);

        usdc.mint(address(destOmnibridge), amount);
        destOmnibridge.deliverTokens(address(usdc), address(destAdapter), amount, messagePayload);

        bytes memory storedPayload = destAdapter.getMessagePayload(invoiceData.invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "MessagePayload should be stored via callback");
    }

    function test_onTokenTransfer_storesTransactionHash() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        MockProvenanceOmnibridge destOmnibridge = new MockProvenanceOmnibridge();
        MockProvenanceAMB destAmb = new MockProvenanceAMB();
        (, GnosisBridgeAdapter destAdapter) = _setupDestination(destOmnibridge, destAmb);

        bytes32 txHash = keccak256("test-transaction-hash");
        destAmb.setTransactionHash(txHash);

        usdc.mint(address(destOmnibridge), amount);
        destOmnibridge.deliverTokens(address(usdc), address(destAdapter), amount, messagePayload);

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

    /// @notice The adapter's onTokenTransfer reverts when not called by the Omnibridge mediator.
    function test_onTokenTransfer_revertsWhenNotOmnibridge() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        adapter.onTokenTransfer(remoteAdapter, amount, messagePayload);
    }

    /// @notice onTokenTransfer from the genuine mediator still reverts if AMB provenance is not the trusted source.
    function test_onTokenTransfer_revertsWhenSourceNotTrusted() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        MockProvenanceOmnibridge destOmnibridge = new MockProvenanceOmnibridge();
        MockProvenanceAMB destAmb = new MockProvenanceAMB();
        (, GnosisBridgeAdapter destAdapter) = _setupDestination(destOmnibridge, destAmb);

        // Wrong source chain reported by AMB.
        destAmb.setMessageSourceChainId(bytes32(uint256(uint64(137))));

        usdc.mint(address(destOmnibridge), amount);
        vm.expectRevert(abi.encodeWithSelector(IGnosisBridgeAdapter.InvalidBridgeData.selector));
        destOmnibridge.deliverTokens(address(usdc), address(destAdapter), amount, messagePayload);
    }

    /// @notice onTokenTransfer reverts if the delivered amount is below the invoiced amount.
    function test_onTokenTransfer_revertsWhenDeliveredAmountTooLow() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        MockProvenanceOmnibridge destOmnibridge = new MockProvenanceOmnibridge();
        MockProvenanceAMB destAmb = new MockProvenanceAMB();
        (, GnosisBridgeAdapter destAdapter) = _setupDestination(destOmnibridge, destAmb);

        // Deliver less than invoiced.
        uint256 short = amount - 1;
        usdc.mint(address(destOmnibridge), short);
        vm.expectRevert(abi.encodeWithSelector(IGnosisBridgeAdapter.InvalidBridgeData.selector));
        destOmnibridge.deliverTokens(address(usdc), address(destAdapter), short, messagePayload);
    }

    /// @notice onTokenBridged reverts if the mediator delivers a DIFFERENT token than the invoice asset, even when
    ///         the adapter already holds a stale balance of the real invoice asset (defense-in-depth: the balance
    ///         check alone would otherwise pass and false-release the invoice asset).
    function test_onTokenBridged_revertsWhenDeliveredTokenMismatch() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        MockProvenanceOmnibridge destOmnibridge = new MockProvenanceOmnibridge();
        MockProvenanceAMB destAmb = new MockProvenanceAMB();
        (, GnosisBridgeAdapter destAdapter) = _setupDestination(destOmnibridge, destAmb);

        // Stale balance of the real invoice asset: the balance check alone would pass.
        usdc.mint(address(destAdapter), amount);

        // The mediator delivers a DIFFERENT token — must revert on the delivered-token guard.
        Mock_ERC20 wrongToken = new Mock_ERC20("WRONG", uint8(usdc.decimals()));
        wrongToken.mint(address(destOmnibridge), amount);

        vm.expectRevert(
            abi.encodeWithSelector(
                IGnosisBridgeAdapter.InvalidDeliveredToken.selector, address(usdc), address(wrongToken)
            )
        );
        destOmnibridge.deliverTokens(address(wrongToken), address(destAdapter), amount, messagePayload);
    }

    // ============ Configuration Tests ============

    function test_setOmnibridge_updatesOmnibridge() public {
        MockProvenanceOmnibridge newOmnibridge = new MockProvenanceOmnibridge();

        vm.prank(admin);
        adapter.setOmnibridge(address(newOmnibridge));

        assertEq(address(adapter.omnibridge()), address(newOmnibridge), "Omnibridge should be updated");
    }

    function test_setOmnibridge_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        adapter.setOmnibridge(address(0));
    }

    function test_setAMB_updatesAMB() public {
        MockProvenanceAMB newAmb = new MockProvenanceAMB();

        vm.prank(admin);
        adapter.setAmb(address(newAmb));

        assertEq(address(adapter.amb()), address(newAmb), "AMB should be updated");
    }

    function test_setAMB_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        adapter.setAmb(address(0));
    }

    function test_setTrustedRemoteAdapter_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        adapter.setTrustedRemoteAdapter(SOURCE_CHAIN_ID, bytes32(uint256(uint160(remoteAdapter))));
    }

    // ============ View Function Tests ============

    function test_getMessagePayload_returnsStoredPayload() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        MockProvenanceOmnibridge destOmnibridge = new MockProvenanceOmnibridge();
        MockProvenanceAMB destAmb = new MockProvenanceAMB();
        (, GnosisBridgeAdapter destAdapter) = _setupDestination(destOmnibridge, destAmb);

        usdc.mint(address(destOmnibridge), amount);
        destOmnibridge.deliverTokens(address(usdc), address(destAdapter), amount, messagePayload);

        bytes memory storedPayload = destAdapter.getMessagePayload(invoiceData.invoiceId);
        assertEq(storedPayload.length, messagePayload.length, "Stored payload should match");
    }

    function test_areTokensAvailable_returnsTrueWhenTokensPresent() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Store payload via bridge (source path).
        vm.prank(account);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(bridgeEscrow), amount);
        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);
        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);

        // Simulate delivery of tokens to the adapter.
        usdc.mint(address(adapter), amount);

        assertTrue(adapter.areTokensAvailable(invoiceData.invoiceId, address(usdc)), "Tokens should be available");
    }

    function test_areTokensAvailable_returnsFalseWhenTokensNotPresent() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(account);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(bridgeEscrow), amount);
        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);
        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);

        // bridge() pulled the tokens out; do not mint more.
        assertFalse(adapter.areTokensAvailable(invoiceData.invoiceId, address(usdc)), "Tokens should not be available");
    }

    // ============ USDC Transmuter Swap (fee-free OmniBridge USDC<->USDC.e) ============

    /// @dev Fresh legacy + USDC.e mocks + a transmuter over them (mirrors the Gnosis USDCTransmuter 1:1 swap).
    function _deployTransmuterTokens() internal returns (Mock_ERC20 legacy, Mock_ERC20 usdce, MockUSDCTransmuter tm) {
        legacy = new Mock_ERC20("USDC", 6); // legacy "USD//C on xDai"
        usdce = new Mock_ERC20("USDC.e", 6); // Circle Bridged USDC.e
        tm = new MockUSDCTransmuter(address(legacy), address(usdce));
    }

    /// @notice Forward (ETH->GC): OmniBridge delivers legacy USDC; the adapter swaps it 1:1 to the registered
    ///         USDC.e via the transmuter and records the USDC.e delivery into custody (ADR 0027); a MANAGER
    ///         claim then pays the account.
    function test_transmuter_forwardSwap_deliversUsdcE() public {
        uint256 amount = 1000e6;
        (Mock_ERC20 legacy, Mock_ERC20 usdce, MockUSDCTransmuter tm) = _deployTransmuterTokens();

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        MockProvenanceOmnibridge destOmnibridge = new MockProvenanceOmnibridge();
        MockProvenanceAMB destAmb = new MockProvenanceAMB();
        (BridgeEscrow destEscrow, GnosisBridgeAdapter destAdapter) = _setupDestination(destOmnibridge, destAmb);

        // GC registers USDC.e under the logical "USDC" symbol; wire the transmuter on the adapter.
        vm.startPrank(admin);
        destEscrow.registerAsset(USDC_SYMBOL, address(usdce));
        destAdapter.setUsdcTransmuter(address(tm));
        vm.stopPrank();

        InvoiceDataLib.InvoiceData memory inv =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory payload = InvoiceDataLib.encode(inv);
        bytes32 invoiceHash = bytes32(uint256(uint192(inv.checksum24)));

        // OmniBridge delivers the LEGACY token to the adapter and fires onTokenBridged.
        legacy.mint(address(destOmnibridge), amount);
        uint256 acctBefore = usdce.balanceOf(account);
        destOmnibridge.deliverTokens(address(legacy), address(destAdapter), amount, payload);

        assertTrue(destEscrow.isInvoiceCompleted(invoiceHash), "invoice completed via legacy->USDC.e swap record");
        // ADR 0027: the swapped USDC.e is recorded into custody and HELD; the account is paid only on claim.
        assertEq(usdce.balanceOf(account), acctBefore, "account NOT paid on delivery");
        assertEq(destEscrow.getHeldBalanceForAsset(address(usdce), account), amount, "held USDC.e for account");
        assertEq(legacy.balanceOf(address(destAdapter)), 0, "no legacy dust on adapter");
        assertEq(usdce.balanceOf(address(destAdapter)), 0, "no USDC.e dust on adapter (forwarded to escrow)");

        vm.prank(manager);
        destEscrow.claim(invoiceHash);
        assertEq(usdce.balanceOf(account) - acctBefore, amount, "account receives USDC.e on claim");
        assertEq(destEscrow.getHeldBalanceForAsset(address(usdce), account), 0, "held cleared after claim");
    }

    /// @notice Reverse (GC->ETH): the adapter swaps the registered USDC.e to legacy 1:1 via the transmuter, then
    ///         bridges the legacy token over the OmniBridge.
    function test_transmuter_reverseSwap_bridgesLegacy() public {
        uint256 amount = 1000e6;
        (Mock_ERC20 legacy, Mock_ERC20 usdce, MockUSDCTransmuter tm) = _deployTransmuterTokens();

        vm.chainId(uint256(GNOSIS_CHAIN_ID)); // source = Gnosis, destination = Ethereum (1)

        // Re-point the source escrow's "USDC" to USDC.e, wire the transmuter, and seed its legacy reserve.
        vm.startPrank(admin);
        bridgeEscrow.registerAsset(USDC_SYMBOL, address(usdce));
        adapter.setUsdcTransmuter(address(tm));
        vm.stopPrank();
        legacy.mint(address(tm), amount); // withdraw pays legacy from the transmuter's reserve

        InvoiceDataLib.InvoiceData memory inv =
            _createInvoiceData(GNOSIS_CHAIN_ID, SOURCE_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory payload = InvoiceDataLib.encode(inv);

        // Escrow holds USDC.e and approves the adapter (as depositAndBridge would).
        usdce.mint(address(bridgeEscrow), amount);
        vm.prank(address(bridgeEscrow));
        usdce.approve(address(adapter), amount);

        vm.prank(address(bridgeEscrow));
        adapter.bridge(payload);

        // The adapter swapped USDC.e->legacy and bridged the LEGACY token to the sibling adapter.
        assertEq(omnibridge.lastRelayToken(), address(legacy), "bridged the legacy USDC token");
        assertEq(omnibridge.lastRelayReceiver(), address(adapter), "receiver is the sibling adapter");
        assertEq(legacy.balanceOf(address(omnibridge)), amount, "omnibridge received the legacy amount");
        assertEq(usdce.balanceOf(address(adapter)), 0, "adapter swapped out all USDC.e");
    }

    /// @notice Fail-safe: if the transmuter is disabled at delivery, the auto swap reverts but the invoice is
    ///         recorded (authenticated) and the legacy delivery stays on the adapter; the MANAGER fallback
    ///         completes it (swapping) once the transmuter is re-enabled.
    function test_transmuter_forwardSwap_failsafe_managerFallbackCompletes() public {
        uint256 amount = 1000e6;
        (Mock_ERC20 legacy, Mock_ERC20 usdce, MockUSDCTransmuter tm) = _deployTransmuterTokens();

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        MockProvenanceOmnibridge destOmnibridge = new MockProvenanceOmnibridge();
        MockProvenanceAMB destAmb = new MockProvenanceAMB();
        (BridgeEscrow destEscrow, GnosisBridgeAdapter destAdapter) = _setupDestination(destOmnibridge, destAmb);

        vm.startPrank(admin);
        destEscrow.registerAsset(USDC_SYMBOL, address(usdce));
        destAdapter.setUsdcTransmuter(address(tm));
        vm.stopPrank();

        InvoiceDataLib.InvoiceData memory inv =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory payload = InvoiceDataLib.encode(inv);
        bytes32 invoiceHash = bytes32(uint256(uint192(inv.checksum24)));

        // Transmuter disabled at delivery: onTokenBridged records provenance; swap+release revert and are caught.
        tm.setEnabled(false);
        legacy.mint(address(destOmnibridge), amount);
        destOmnibridge.deliverTokens(address(legacy), address(destAdapter), amount, payload);

        assertTrue(destAdapter.authenticatedInvoice(invoiceHash), "invoice authenticated despite deferred swap");
        assertFalse(destEscrow.isInvoiceCompleted(invoiceHash), "not completed while transmuter disabled");
        assertEq(legacy.balanceOf(address(destAdapter)), amount, "legacy delivery held on adapter");

        // Re-enable + complete via the MANAGER fallback (which swaps then releases).
        tm.setEnabled(true);
        uint256 acctBefore = usdce.balanceOf(account);
        vm.prank(manager);
        destAdapter.completeBridge(payload, "");

        assertTrue(destEscrow.isInvoiceCompleted(invoiceHash), "completed by MANAGER fallback record after re-enable");
        // ADR 0027: the fallback records custody and HOLDS; the account is paid only on claim.
        assertEq(usdce.balanceOf(account), acctBefore, "account NOT paid on record");
        assertEq(destEscrow.getHeldBalanceForAsset(address(usdce), account), amount, "held USDC.e for account");

        vm.prank(manager);
        destEscrow.claim(invoiceHash);
        assertEq(usdce.balanceOf(account) - acctBefore, amount, "account receives USDC.e via fallback swap on claim");
        assertEq(destEscrow.getHeldBalanceForAsset(address(usdce), account), 0, "held cleared after claim");
    }
}
