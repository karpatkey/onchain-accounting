// SPDX-License-Identifier: MIT
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
import {MockProvenanceOmnibridge, MockProvenanceAMB} from "test/bridge/mocks/GnosisProvenanceMocks.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title GnosisBridgeAdapterTest
/// @notice Test suite for the Gnosis Omnibridge adapter under the ADR 0012 provenance model.
/// @dev Destination recipient is the sibling adapter (address(this)). The Omnibridge mediator delivers tokens
///      to the adapter and calls onTokenTransfer; the adapter authenticates msg.sender == omnibridge plus the
///      AMB-reported source (messageSender == trustedRemoteAdapter, messageSourceChainId == source chain), then
///      funds the escrow and releases. The MANAGER completeBridge path verifies the same provenance.
contract GnosisBridgeAdapterTest is BridgeScenarioHelper {
    GnosisBridgeAdapter public adapter;
    MockProvenanceOmnibridge public omnibridge;
    MockProvenanceAMB public amb;

    uint64 public constant GNOSIS_CHAIN_ID = 100; // Gnosis Chain

    // The trusted sibling adapter living on the source chain (Ethereum). On real deployments this matches the
    // destination adapter's own address (CREATE2 same-address); for unit tests any fixed address works.
    address public remoteAdapter = makeAddr("remoteAdapter");

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
        address adapterImpl = address(new GnosisBridgeAdapter());
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
        destAdapter.setTrustedRemoteAdapter(SOURCE_CHAIN_ID, bytes32(uint256(uint160(remoteAdapter))));
        destEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        // Authentic AMB provenance: message came from the trusted sibling on the source chain.
        destAmb.setMessageSender(remoteAdapter);
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

    function test_completeBridge_releasesTokensOnDestinationChain() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        MockProvenanceOmnibridge destOmnibridge = new MockProvenanceOmnibridge();
        MockProvenanceAMB destAmb = new MockProvenanceAMB();
        (BridgeEscrow destEscrow, GnosisBridgeAdapter destAdapter) = _setupDestination(destOmnibridge, destAmb);

        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Funded pass-through: the adapter holds the delivered tokens; the base pulls exactly `amount` to the escrow.
        usdc.mint(address(destAdapter), amount);

        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));
        assertFalse(destEscrow.isInvoiceCompleted(invoiceHash), "Invoice should not be completed before completion");

        uint256 initialPortfolioBalance = usdc.balanceOf(account);

        vm.prank(manager);
        destAdapter.completeBridge(messagePayload, "");

        assertEq(usdc.balanceOf(account) - initialPortfolioBalance, amount, "Account should receive tokens");
        assertEq(usdc.balanceOf(address(destEscrow)), 0, "Escrow should have zero balance after release");
        assertEq(usdc.balanceOf(address(destAdapter)), 0, "Adapter should have zero balance after funding release");
        assertTrue(destEscrow.isInvoiceCompleted(invoiceHash), "Invoice should be marked as completed");
    }

    function test_completeBridge_revertsWhenSourceNotTrusted() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        MockProvenanceOmnibridge destOmnibridge = new MockProvenanceOmnibridge();
        MockProvenanceAMB destAmb = new MockProvenanceAMB();
        (, GnosisBridgeAdapter destAdapter) = _setupDestination(destOmnibridge, destAmb);

        // AMB reports an impostor sender — provenance must fail even with funds present.
        destAmb.setMessageSender(makeAddr("impostor"));

        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);
        usdc.mint(address(destAdapter), amount);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IGnosisBridgeAdapter.InvalidBridgeData.selector));
        destAdapter.completeBridge(messagePayload, "");
    }

    function test_completeBridge_validatesChecksum() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        vm.chainId(uint256(GNOSIS_CHAIN_ID));
        MockProvenanceOmnibridge destOmnibridge = new MockProvenanceOmnibridge();
        MockProvenanceAMB destAmb = new MockProvenanceAMB();
        (, GnosisBridgeAdapter destAdapter) = _setupDestination(destOmnibridge, destAmb);

        // Provenance authentic + funds present, but the payload checksum is corrupted: escrow must reject.
        usdc.mint(address(destAdapter), amount);

        bytes memory corruptedPayload = abi.encode(
            invoiceData.invoiceId,
            invoiceData.amount,
            invoiceData.nonce,
            bytes32(uint256(invoiceData.timestamp) << 192 | uint256(uint192(invoiceData.checksum24)) ^ 1)
        );

        vm.prank(manager);
        vm.expectRevert(); // InvalidChecksum from BridgeEscrow.releaseByInvoiceId
        destAdapter.completeBridge(corruptedPayload, "");
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
        assertTrue(destEscrow.isInvoiceCompleted(expectedInvoiceHash), "invoice completed");
        assertEq(usdc.balanceOf(account) - portfolioBalanceBeforeRelease, amount, "account received bridged amount");
        assertEq(usdc.balanceOf(address(destEscrow)), 0, "escrow balance zero after release");
        assertEq(usdc.balanceOf(address(destAdapter)), 0, "adapter balance zero after funding release");
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
}
