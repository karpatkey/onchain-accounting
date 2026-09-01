// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {CctpBridgeAdapter} from "src/bridge/adapters/CctpBridgeAdapter.sol";
import {ICctpBridgeAdapter} from "src/bridge/adapters/interfaces/ICctpBridgeAdapter.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {BridgeScenarioHelper} from "test/bridge/BridgeScenarioHelper.sol";
import {
    CctpProvenanceMessage,
    MockProvenanceMessageTransmitter,
    MockProvenanceTokenMessenger
} from "test/bridge/mocks/CctpProvenanceMocks.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";

/// @title CctpBridgeAdapterTest
/// @notice Test suite for the re-architected CCTP Bridge Adapter (attestation-provenance model).
/// @dev On the destination chain the adapter mints USDC to ITSELF (mintRecipient ==
///      destinationCaller == adapter), verifies the attested CCTP message body against the invoice,
///      dedups by nonce, forwards the minted USDC to the escrow, and the base BridgeAdapter records the
///      delivery into escrow custody (ADR 0027). A subsequent MANAGER `claim` pays the account.
contract CctpBridgeAdapterTest is BridgeScenarioHelper {
    CctpBridgeAdapter public adapter;
    MockProvenanceTokenMessenger public tokenMessenger;
    MockProvenanceMessageTransmitter public messageTransmitter;

    uint32 public constant SOURCE_DOMAIN = 0; // Ethereum mainnet domain (chainId 1)
    uint32 public constant DEST_DOMAIN = 6; // domain used for DEST_CHAIN_ID in these tests

    function setUp() public override {
        super.setUp();

        // Deploy mock CCTP contracts (source chain)
        messageTransmitter = new MockProvenanceMessageTransmitter(SOURCE_DOMAIN, address(usdc));
        tokenMessenger = new MockProvenanceTokenMessenger();

        // Deploy CCTP adapter
        address adapterImpl = address(new CctpBridgeAdapter(address(0)));
        address adapterProxy = UnsafeUpgrades.deployUUPSProxy(
            adapterImpl,
            abi.encodeCall(
                CctpBridgeAdapter.initialize,
                (admin, address(bridgeEscrow), address(tokenMessenger), address(messageTransmitter), "1.0.0")
            )
        );
        adapter = CctpBridgeAdapter(adapterProxy);

        // Configure adapter (destination mapping + roles). SOURCE_CHAIN_ID -> SOURCE_DOMAIN(0) is
        // pre-configured in initialize; we override DEST_CHAIN_ID -> DEST_DOMAIN here.
        vm.startPrank(admin);
        adapter.setDomainMapping(DEST_CHAIN_ID, DEST_DOMAIN);
        adapter.grantRole(MANAGER, manager);
        vm.stopPrank();

        // Authorize adapter in BridgeEscrow
        _authorizeAdapter(address(adapter));

        // Setup labels
        vm.label(address(adapter), "CctpBridgeAdapter");
        vm.label(address(tokenMessenger), "MockProvenanceTokenMessenger");
        vm.label(address(messageTransmitter), "MockProvenanceMessageTransmitter");
    }

    // ============ Bridge Initiation Tests ============

    function test_bridge_initiatesCctpTransfer() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        _approveToken(address(usdc), address(bridgeEscrow), amount);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Transfer tokens to BridgeEscrow (simulating depositAndBridge flow)
        vm.prank(account);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(bridgeEscrow), amount);

        // BridgeEscrow approves adapter (approval-based pull pattern)
        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);

        // Initiate bridge (adapter pulls tokens + burns via TokenMessenger)
        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);

        assertEq(tokenMessenger.nonce(), 1, "Mock should have incremented nonce");
        // The burned USDC is held by the TokenMessenger; adapter holds none.
        assertEq(usdc.balanceOf(address(tokenMessenger)), amount, "TokenMessenger holds burned USDC");
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter holds no USDC after burn");
    }

    function test_bridge_revertsForNativeToken() public {
        uint256 amount = 1 ether;
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.deal(address(adapter), amount);

        vm.prank(address(bridgeEscrow));
        vm.expectRevert(); // CCTP only supports USDC
        adapter.bridge(messagePayload);
    }

    function test_bridge_revertsForInvalidDomain() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        uint64 invalidChainId = 12345; // Not in adapter's configured domain set
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, invalidChainId, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(account);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(bridgeEscrow), amount);

        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);

        vm.prank(address(bridgeEscrow));
        vm.expectRevert(ICctpBridgeAdapter.InvalidDomain.selector); // domain mapping not configured
        adapter.bridge(messagePayload);
    }

    /// @notice Regression: bridging to Ethereum (chainId 1, canonical CCTP domain 0) must NOT revert.
    ///         Domain 0 is a valid configured domain, no longer a sentinel.
    function test_bridge_toEthereumDomainZeroSucceeds() public {
        // Source from Base (8453, domain 6) so the destination (Ethereum, domain 0) is not same-chain.
        vm.chainId(uint256(8453));
        BridgeEscrow srcEscrow = _setupDestinationChainEscrow(8453);

        MockProvenanceMessageTransmitter srcTransmitter = new MockProvenanceMessageTransmitter(6, address(usdc));
        MockProvenanceTokenMessenger srcTokenMessenger = new MockProvenanceTokenMessenger();

        address srcAdapterProxy = UnsafeUpgrades.deployUUPSProxy(
            address(new CctpBridgeAdapter(address(0))),
            abi.encodeCall(
                CctpBridgeAdapter.initialize,
                (admin, address(srcEscrow), address(srcTokenMessenger), address(srcTransmitter), "1.0.0")
            )
        );
        CctpBridgeAdapter srcAdapter = CctpBridgeAdapter(srcAdapterProxy);
        vm.prank(admin);
        srcEscrow.authorizeAdapter(address(srcAdapter));

        // Ethereum (chainId 1) is configured with domain 0 in initialize.
        assertEq(srcAdapter.getDomainForChain(1), 0, "Ethereum -> domain 0");
        assertTrue(srcAdapter.domainConfigured(1), "Ethereum domain explicitly configured");

        uint256 amount = 1_000e6;
        usdc.mint(account, amount);
        vm.startPrank(account);
        usdc.approve(address(srcEscrow), amount);
        // Bridging USDC to Ethereum must succeed (no InvalidDomain revert).
        srcEscrow.depositAndBridge(1, "USDC", amount, address(srcAdapter));
        vm.stopPrank();

        assertEq(srcTokenMessenger.nonce(), 1, "burn happened for Ethereum-bound transfer");
    }

    function test_bridge_revertsIfNotCalledByBridgeEscrow() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(account);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(bridgeEscrow), amount);

        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);

        vm.prank(unauthorized);
        vm.expectRevert(); // caller is not BridgeEscrow
        adapter.bridge(messagePayload);
    }

    // ============ Bridge Completion Tests ============

    function test_completeBridge_mintsUsdcAndReleases() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        (BridgeEscrow destBridgeEscrow, CctpBridgeAdapter destAdapter) = _setupDestinationChainForCctpTest();
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        bytes32 nonce = bytes32(uint256(123));
        bytes memory protocolData = _prepareCctpProtocolData(nonce, amount, address(destAdapter));

        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));
        assertFalse(destBridgeEscrow.isInvoiceCompleted(invoiceHash), "not completed before");

        uint256 initialPortfolioBalance = usdc.balanceOf(account);
        assertEq(usdc.balanceOf(address(destBridgeEscrow)), 0, "escrow starts empty (CCTP mints)");

        // Step 1 (ADR 0027): completeBridge records the delivery — the escrow HOLDS the funds, no payout yet.
        vm.prank(manager);
        destAdapter.completeBridge(messagePayload, protocolData);

        assertEq(usdc.balanceOf(account), initialPortfolioBalance, "account NOT paid on record");
        assertEq(usdc.balanceOf(address(destBridgeEscrow)), amount, "escrow holds the delivered USDC");
        assertEq(usdc.balanceOf(address(destAdapter)), 0, "adapter empty after forwarding to escrow");
        assertEq(destBridgeEscrow.getHeldBalanceForAsset(address(usdc), account), amount, "held for account");
        assertTrue(destBridgeEscrow.isInvoiceCompleted(invoiceHash), "invoice completed on record");
        (,,,,, bool claimedAfterRecord) = destBridgeEscrow.destinationCustody(invoiceHash);
        assertFalse(claimedAfterRecord, "custody not claimed yet");

        // Nonce recorded for replay protection.
        assertTrue(destAdapter.usedNonces(SOURCE_DOMAIN, nonce), "nonce marked used");

        // Step 2 (ADR 0027): MANAGER claims — funds move to the account, escrow drains.
        vm.prank(manager);
        destBridgeEscrow.claim(invoiceHash);
        assertEq(usdc.balanceOf(account) - initialPortfolioBalance, amount, "account received minted USDC on claim");
        assertEq(usdc.balanceOf(address(destBridgeEscrow)), 0, "escrow empty after claim");
        assertEq(destBridgeEscrow.getHeldBalanceForAsset(address(usdc), account), 0, "held cleared after claim");
        (,,,,, bool claimedAfter) = destBridgeEscrow.destinationCustody(invoiceHash);
        assertTrue(claimedAfter, "custody marked claimed");
    }

    function test_completeBridge_revertsOnReplayedNonce() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        (, CctpBridgeAdapter destAdapter) = _setupDestinationChainForCctpTest();
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        bytes32 nonce = bytes32(uint256(777));
        bytes memory protocolData = _prepareCctpProtocolData(nonce, amount, address(destAdapter));

        vm.prank(manager);
        destAdapter.completeBridge(messagePayload, protocolData);

        // Replaying the same nonce must revert (defense-in-depth replay protection in the adapter).
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICctpBridgeAdapter.NonceAlreadyUsed.selector, SOURCE_DOMAIN, nonce));
        destAdapter.completeBridge(messagePayload, protocolData);
    }

    function test_completeBridge_revertsOnAmountMismatch() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        (, CctpBridgeAdapter destAdapter) = _setupDestinationChainForCctpTest();
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // CCTP message mints a different amount than the invoice — must revert.
        bytes32 nonce = bytes32(uint256(5));
        bytes memory cctpMessage = CctpProvenanceMessage.build(
            SOURCE_DOMAIN,
            DEST_DOMAIN,
            nonce,
            address(usdc),
            address(destAdapter.tokenMessenger()),
            address(destAdapter),
            address(destAdapter),
            amount + 1
        );
        bytes memory protocolData = abi.encode(cctpMessage, "mock_attestation");

        vm.prank(manager);
        vm.expectRevert(ICctpBridgeAdapter.AmountMismatch.selector);
        destAdapter.completeBridge(messagePayload, protocolData);
    }

    function test_completeBridge_revertsOnMintRecipientMismatch() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        (BridgeEscrow destBridgeEscrow, CctpBridgeAdapter destAdapter) = _setupDestinationChainForCctpTest();
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Mint recipient is the escrow (NOT the adapter) — provenance check must reject it.
        bytes32 nonce = bytes32(uint256(9));
        bytes memory cctpMessage = CctpProvenanceMessage.build(
            SOURCE_DOMAIN,
            DEST_DOMAIN,
            nonce,
            address(usdc),
            address(destAdapter.tokenMessenger()),
            address(destBridgeEscrow),
            address(destAdapter),
            amount
        );
        bytes memory protocolData = abi.encode(cctpMessage, "mock_attestation");

        vm.prank(manager);
        vm.expectRevert(ICctpBridgeAdapter.InvalidMintRecipient.selector);
        destAdapter.completeBridge(messagePayload, protocolData);
    }

    function test_completeBridge_revertsOnWrongHeaderRecipient() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        (, CctpBridgeAdapter destAdapter) = _setupDestinationChainForCctpTest();
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Header recipient (bytes 76-108) is the adapter, NOT the TokenMessenger — the value a buggy
        // check would expect. Body mintRecipient is the correct adapter, so this isolates the header
        // check: a real Circle message always carries the TokenMessenger here, so a non-TokenMessenger
        // header must revert InvalidMessage.
        bytes32 nonce = bytes32(uint256(21));
        bytes memory cctpMessage = CctpProvenanceMessage.build(
            SOURCE_DOMAIN,
            DEST_DOMAIN,
            nonce,
            address(usdc),
            address(destAdapter), // wrong header recipient (not the TokenMessenger)
            address(destAdapter),
            address(destAdapter),
            amount
        );
        bytes memory protocolData = abi.encode(cctpMessage, "mock_attestation");

        vm.prank(manager);
        vm.expectRevert(ICctpBridgeAdapter.InvalidMessage.selector);
        destAdapter.completeBridge(messagePayload, protocolData);
    }

    function test_completeBridge_revertsWhenDestinationAssetNotMinted() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        (, CctpBridgeAdapter destAdapter) = _setupDestinationChainForCctpTest();
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // The source burnToken legitimately differs from the destination asset, so it is NOT compared.
        // The guard is that the DESTINATION asset (usdc) must actually be minted in the invoice amount.
        // Force the transmitter to mint DAI instead of USDC: the adapter's usdc balance does not rise, so
        // the balance-delta check reverts BurnTokenMismatch.
        MockProvenanceMessageTransmitter(address(destAdapter.messageTransmitter())).setMintTokenOverride(address(dai));

        bytes32 nonce = bytes32(uint256(11));
        bytes memory cctpMessage = CctpProvenanceMessage.build(
            SOURCE_DOMAIN,
            DEST_DOMAIN,
            nonce,
            address(dai), // source burnToken (not compared)
            address(destAdapter.tokenMessenger()),
            address(destAdapter),
            address(destAdapter),
            amount
        );
        bytes memory protocolData = abi.encode(cctpMessage, "mock_attestation");

        vm.prank(manager);
        vm.expectRevert(ICctpBridgeAdapter.BurnTokenMismatch.selector);
        destAdapter.completeBridge(messagePayload, protocolData);
    }

    function test_completeBridge_revertsOnSourceDomainMismatch() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        (, CctpBridgeAdapter destAdapter) = _setupDestinationChainForCctpTest();
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // sourceDomain in the CCTP message (DEST_DOMAIN=6 -> chainId 10) does NOT map to the invoice's
        // sourceChainId (1). Must revert.
        bytes32 nonce = bytes32(uint256(13));
        bytes memory cctpMessage = CctpProvenanceMessage.build(
            DEST_DOMAIN,
            DEST_DOMAIN,
            nonce,
            address(usdc),
            address(destAdapter.tokenMessenger()),
            address(destAdapter),
            address(destAdapter),
            amount
        );
        bytes memory protocolData = abi.encode(cctpMessage, "mock_attestation");

        vm.prank(manager);
        vm.expectRevert(ICctpBridgeAdapter.SourceDomainMismatch.selector);
        destAdapter.completeBridge(messagePayload, protocolData);
    }

    /// @notice Full round-trip: depositAndBridge on source -> payload from invoice -> deliver via
    ///         attested receiveMessage -> completeBridge records custody -> MANAGER claim pays the account.
    function test_realistic_fullRoundTrip() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();

        // ---------- SOURCE CHAIN ----------
        _approveToken(address(usdc), address(bridgeEscrow), amount);
        vm.prank(account);
        bytes32 invoiceHash = bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, amount, address(adapter));

        bytes memory messagePayload = _getMessagePayloadFromInvoiceHash(bridgeEscrow, invoiceHash);
        uint256 portfolioBalanceBeforeRelease = usdc.balanceOf(account);
        assertGt(messagePayload.length, 0, "messagePayload from invoice");

        // ---------- DESTINATION CHAIN ----------
        (BridgeEscrow destBridgeEscrow, CctpBridgeAdapter destAdapter) = _setupDestinationChainForCctpTest();

        bytes32 nonce = bytes32(uint256(42));
        bytes memory protocolData = _prepareCctpProtocolData(nonce, amount, address(destAdapter));

        vm.prank(manager);
        destAdapter.completeBridge(messagePayload, protocolData);

        bytes32 expectedInvoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(messagePayload).checksum24)));
        assertTrue(destBridgeEscrow.isInvoiceCompleted(expectedInvoiceHash), "invoice completed on record");
        // Record holds the funds; the account is paid only after MANAGER claim (ADR 0027).
        assertEq(usdc.balanceOf(account), portfolioBalanceBeforeRelease, "account not paid on record");
        assertEq(
            destBridgeEscrow.getHeldBalanceForAsset(address(usdc), account), amount, "escrow holds for the account"
        );

        vm.prank(manager);
        destBridgeEscrow.claim(expectedInvoiceHash);
        assertEq(usdc.balanceOf(account) - portfolioBalanceBeforeRelease, amount, "account received bridged amount");
        assertEq(destBridgeEscrow.getHeldBalanceForAsset(address(usdc), account), 0, "held cleared after claim");
    }

    function test_completeBridge_validatesChecksum() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        (, CctpBridgeAdapter destAdapter) = _setupDestinationChainForCctpTest();

        bytes32 nonce = bytes32(uint256(123));
        bytes memory protocolData = _prepareCctpProtocolData(nonce, amount, address(destAdapter));

        // Corrupt messagePayload (invalid checksum) — recordDelivery in the base reverts.
        bytes memory corruptedPayload = abi.encode(
            invoiceData.invoiceId,
            invoiceData.amount,
            bytes32(uint256(invoiceData.timestamp) << 192 | uint256(uint192(invoiceData.checksum24)) ^ 1)
        );

        vm.prank(manager);
        vm.expectRevert(); // invalid checksum
        destAdapter.completeBridge(corruptedPayload, protocolData);
    }

    function test_completeBridge_revertsIfNotManager() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        (, CctpBridgeAdapter destAdapter) = _setupDestinationChainForCctpTest();
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        bytes32 nonce = bytes32(uint256(123));
        bytes memory protocolData = _prepareCctpProtocolData(nonce, amount, address(destAdapter));

        vm.prank(unauthorized);
        vm.expectRevert(); // caller is not manager
        destAdapter.completeBridge(messagePayload, protocolData);
    }

    // ============ Configuration Tests ============

    function test_setDomainMapping_updatesMapping() public {
        uint64 chainId = 42161; // Arbitrum
        uint32 domain = 3;

        vm.prank(admin);
        adapter.setDomainMapping(chainId, domain);

        assertEq(adapter.getDomainForChain(chainId), domain, "domain mapping set");
        assertEq(adapter.getChainForDomain(domain), chainId, "chain mapping set");
        assertTrue(adapter.domainConfigured(chainId), "chain marked configured");
    }

    function test_setDomainMapping_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // caller is not admin
        adapter.setDomainMapping(42161, 3);
    }

    // ============ Helpers ============

    /// @notice Set up a destination-chain escrow + CCTP adapter (Optimism, DEST_CHAIN_ID).
    /// @dev The destination adapter has SOURCE_CHAIN_ID(1) -> SOURCE_DOMAIN(0) pre-configured by
    ///      initialize, so domainToChainId[0] == 1 (used by the sourceDomain provenance check).
    function _setupDestinationChainForCctpTest()
        internal
        returns (BridgeEscrow destBridgeEscrow, CctpBridgeAdapter destAdapter)
    {
        vm.chainId(uint256(DEST_CHAIN_ID));
        destBridgeEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);

        MockProvenanceMessageTransmitter destTransmitter =
            new MockProvenanceMessageTransmitter(DEST_DOMAIN, address(usdc));
        MockProvenanceTokenMessenger destTokenMessenger = new MockProvenanceTokenMessenger();

        address destAdapterProxy = UnsafeUpgrades.deployUUPSProxy(
            address(new CctpBridgeAdapter(address(0))),
            abi.encodeCall(
                CctpBridgeAdapter.initialize,
                (admin, address(destBridgeEscrow), address(destTokenMessenger), address(destTransmitter), "1.0.0")
            )
        );
        destAdapter = CctpBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        destAdapter.setDomainMapping(DEST_CHAIN_ID, DEST_DOMAIN);
        destAdapter.grantRole(MANAGER, manager);
        destBridgeEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();
    }

    /// @notice Build protocolData (CCTP message + attestation) for a completion that mints to the adapter.
    /// @dev The message's `burnToken` is the SOURCE-chain token (here `dai`, standing in for e.g. Base USDC),
    ///      which legitimately DIFFERS from the destination asset (`usdc`, e.g. Arbitrum USDC). The mock
    ///      transmitter still mints the destination `usdc` to the adapter — modelling Circle's TokenMinter.
    ///      Using a distinct source token here is deliberate: a prior adapter compared `burnToken` to the
    ///      destination asset and reverted every real cross-chain transfer.
    function _prepareCctpProtocolData(bytes32 nonce, uint256 amount, address destAdapter)
        internal
        view
        returns (bytes memory)
    {
        bytes memory cctpMessage = CctpProvenanceMessage.build(
            SOURCE_DOMAIN,
            DEST_DOMAIN,
            nonce,
            address(dai), // source burnToken != destination asset (usdc)
            address(CctpBridgeAdapter(destAdapter).tokenMessenger()),
            destAdapter,
            destAdapter,
            amount
        );
        return abi.encode(cctpMessage, "mock_attestation");
    }
}
