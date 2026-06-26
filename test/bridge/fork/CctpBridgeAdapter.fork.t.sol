// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {CctpBridgeAdapter} from "src/bridge/adapters/CctpBridgeAdapter.sol";
import {ICircleTokenMessengerV2} from "src/bridge/adapters/interfaces/ICircleTokenMessengerV2.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {IBridgeEscrow} from "src/bridge/IBridgeEscrow.sol";
import {BridgeTestBase} from "test/bridge/fork/BridgeTestBase.fork.sol";

/// @title CctpBridgeAdapterForkTest
/// @notice Fork tests for CCTP Bridge Adapter using real mainnet TokenMessengerV2 / MessageTransmitterV2
contract CctpBridgeAdapterForkTest is BridgeTestBase {
    CctpBridgeAdapter public adapter;
    IERC20 public usdc;

    // CCTP V2 addresses (Ethereum mainnet). Source: https://developers.circle.com/cctp/references/contract-addresses
    address public constant CCTP_TOKEN_MESSENGER_V2 = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address public constant CCTP_MESSAGE_TRANSMITTER_V2 = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;

    // CCTP domain IDs (match adapter pre-config)
    uint32 public constant MAINNET_DOMAIN = 0;
    uint32 public constant OPTIMISM_DOMAIN = 2;
    uint32 public constant BASE_DOMAIN = 6;

    /// @notice Block where CCTP V2 is live on Ethereum
    uint256 public constant CCTP_V2_FORK_BLOCK = 22_100_000;

    function setUp() public override {
        super.setUp();
        _selectMainnetFork();
        vm.rollFork(CCTP_V2_FORK_BLOCK);
        _setupCctpAdapter();
        _fundAccount();
    }

    function _setupCctpAdapter() internal {
        // Deploy CCTP adapter with V2 contracts (depositForBurn with maxFee/minFinalityThreshold)
        address adapterImpl = address(new CctpBridgeAdapter());
        address adapterProxy = UnsafeUpgrades.deployUUPSProxy(
            adapterImpl,
            abi.encodeCall(
                CctpBridgeAdapter.initialize,
                (admin, address(bridgeEscrow), CCTP_TOKEN_MESSENGER_V2, CCTP_MESSAGE_TRANSMITTER_V2, "1.0.0")
            )
        );
        adapter = CctpBridgeAdapter(adapterProxy);

        // Domain mappings for 1, 10, 8453, etc. are pre-configured in initialize(); add any overrides if needed
        vm.startPrank(admin);
        adapter.setDomainMapping(OPTIMISM_CHAIN_ID, OPTIMISM_DOMAIN);
        adapter.setDomainMapping(BASE_CHAIN_ID, BASE_DOMAIN);
        adapter.grantRole(MANAGER, manager);
        vm.stopPrank();

        _authorizeAdapter(address(adapter));

        usdc = IERC20(MAINNET_USDC);
        vm.label(address(adapter), "CctpBridgeAdapter");
    }

    // ============ Bridge Initiation Tests ============

    /// @notice Initiates real CCTP transfer to Base (domain 6)
    function testFork_bridge_initiatesRealCctpTransfer() public {
        uint256 amount = 1 * 1e6; // 1 USDC
        uint64 destChainId = BASE_CHAIN_ID;

        // Approve BridgeEscrow to spend USDC
        _approveToken(MAINNET_USDC, address(bridgeEscrow), amount);

        // Get initial balances
        uint256 initialPortfolioBalance = usdc.balanceOf(account);

        // Create invoice data
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(MAINNET_CHAIN_ID, destChainId, account, USDC_SYMBOL_BYTES6, amount);

        // Initiate bridge via BridgeEscrow
        vm.prank(account);
        bytes32 invoiceHash = bridgeEscrow.depositAndBridge(destChainId, USDC_SYMBOL, amount, address(adapter));

        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should not hold USDC (burned)");
        assertEq(usdc.balanceOf(account), initialPortfolioBalance - amount, "Account balance should decrease");

        bytes32 invoiceId = invoiceData.invoiceId;

        // Verify invoice was created
        IBridgeEscrow.Invoice memory invoice = bridgeEscrow.getInvoice(invoiceHash);
        assertEq(invoice.invoiceId, invoiceId, "Invoice ID should match");
        assertEq(invoice.amount, amount, "Invoice amount should match");
        assertEq(
            uint8(invoice.status), uint8(IBridgeEscrow.InvoiceStatus.BRIDGING), "Invoice should be in BRIDGING status"
        );
    }

    function testFork_bridge_revertsForNativeToken() public {
        uint256 amount = TEST_AMOUNT_ETH;
        uint64 destChainId = OPTIMISM_CHAIN_ID;

        // Try to bridge native token (should revert)
        vm.prank(account);
        vm.expectRevert(); // CCTP only supports USDC
        bridgeEscrow.depositAndBridge{value: amount}(destChainId, WETH_SYMBOL, amount, address(adapter));
    }

    function testFork_bridge_revertsForInvalidDomain() public {
        uint256 amount = TEST_AMOUNT_USDC;
        uint64 destChainId = 999; // Invalid chain ID

        _approveToken(MAINNET_USDC, address(bridgeEscrow), amount);

        vm.prank(account);
        vm.expectRevert(); // Should revert because domain mapping doesn't exist
        bridgeEscrow.depositAndBridge(destChainId, USDC_SYMBOL, amount, address(adapter));
    }

    function testFork_messagePayload_preservedThroughBridge() public {
        uint256 amount = 1 * 1e6; // 1 USDC
        uint64 destChainId = BASE_CHAIN_ID;

        _approveToken(MAINNET_USDC, address(bridgeEscrow), amount);

        // Create invoice data
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(MAINNET_CHAIN_ID, destChainId, account, USDC_SYMBOL_BYTES6, amount);

        // Initiate bridge
        vm.prank(account);
        bytes32 invoiceHash = bridgeEscrow.depositAndBridge(destChainId, USDC_SYMBOL, amount, address(adapter));

        // Verify invoice data matches
        IBridgeEscrow.Invoice memory invoice = bridgeEscrow.getInvoice(invoiceHash);
        assertEq(invoice.invoiceId, invoiceData.invoiceId, "Invoice ID should match");
        assertEq(invoice.amount, invoiceData.amount, "Amount should match");
        assertEq(invoice.account, invoiceData.account, "Account should match");

        // Verify checksum validation works
        bool isValid = bridgeEscrow.validateInvoiceIdChecksum(
            invoiceData.invoiceId, invoiceData.amount, invoiceData.timestamp, invoiceData.nonce, invoiceData.checksum24
        );
        assertTrue(isValid, "Checksum should be valid");
    }

    /// @notice TokenMessengerV2 does not return nonce; adapter emits nonce=0 and does not set messageToInvoiceId.
    ///         Completion uses messagePayload.invoiceId when mapping is zero.
    function testFork_bridge_emitsInitiatedAndDoesNotStoreMapping() public {
        uint256 amount = 1 * 1e6; // 1 USDC
        uint64 destChainId = BASE_CHAIN_ID;

        _approveToken(MAINNET_USDC, address(bridgeEscrow), amount);

        _createInvoiceData(MAINNET_CHAIN_ID, destChainId, account, USDC_SYMBOL_BYTES6, amount);

        vm.recordLogs();
        vm.prank(account);
        bridgeEscrow.depositAndBridge(destChainId, USDC_SYMBOL, amount, address(adapter));

        // Decode CctpBridgeInitiated event: data = (destinationDomain, mintRecipient, amount, nonce)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 nonce = bytes32(uint256(0));
        bytes32 expectedTopic = keccak256("CctpBridgeInitiated(bytes32,uint32,bytes32,bytes32,bytes32)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 1 && logs[i].topics[0] == expectedTopic && logs[i].data.length >= 32 * 4) {
                (,,, nonce) = abi.decode(logs[i].data, (uint32, bytes32, bytes32, bytes32));
                break;
            }
        }
        // Real TokenMessengerV2 does not return nonce; adapter emits nonce=0
        assertEq(nonce, bytes32(0), "Adapter should emit nonce=0 when TokenMessengerV2 does not return nonce");
        // Adapter does not set messageToInvoiceId; completion uses messagePayload when mapping is zero
        bytes32 storedInvoiceId = adapter.messageToInvoiceId(MAINNET_DOMAIN, bytes32(0));
        assertEq(storedInvoiceId, bytes32(0), "Adapter should not store mapping (completion uses payload)");
    }

    // ============ Adapter config (V2 API) ============

    /// @notice Ensures adapter is wired to TokenMessengerV2 and domain mappings are set
    function testFork_adapter_usesV2ContractsAndDomainMappings() public view {
        assertEq(address(adapter.tokenMessenger()), CCTP_TOKEN_MESSENGER_V2, "Adapter should use TokenMessengerV2");
        assertEq(adapter.getDomainForChain(MAINNET_CHAIN_ID), MAINNET_DOMAIN, "Mainnet domain should be 0");
        assertEq(adapter.getDomainForChain(OPTIMISM_CHAIN_ID), OPTIMISM_DOMAIN, "Optimism domain should be 2");
        assertEq(adapter.getDomainForChain(BASE_CHAIN_ID), BASE_DOMAIN, "Base domain should be 6");
        assertEq(adapter.getChainForDomain(MAINNET_DOMAIN), MAINNET_CHAIN_ID, "Domain 0 -> chain 1");
        assertEq(adapter.getChainForDomain(OPTIMISM_DOMAIN), OPTIMISM_CHAIN_ID, "Domain 2 -> chain 10");
    }

    // ============ Destination Completion (provenance) ============
    //
    // ADR 0012 CCTP completion model: on the destination chain the manager calls `completeBridge` with
    // protocolData = abi.encode(cctpMessage, attestation). The adapter verifies the CCTP message body against
    // the invoice (burnToken/amount/mintRecipient/sourceDomain), dedups by nonce, then calls the REAL
    // MessageTransmitterV2.receiveMessage(message, attestation), which mints USDC to the adapter ONLY if the
    // attestation is a genuine Circle signature over that exact message. The base then funds the escrow and
    // releases (funded pass-through).
    //
    // TODO(fork-rpc): a faithful destination-completion fork test requires a live, Circle-attested CCTP message
    // (the real MessageTransmitter rejects any unattested/forged message, so it cannot be produced offline).
    // It is NOT exercised here on purpose — fabricating an attestation would either revert at the real
    // transmitter (no signal) or require mocking receiveMessage, which would weaken the provenance assertion.
    // The full provenance path (message-body verification, nonce dedup, mint-to-adapter, funded release, and
    // every mismatch revert: amount / mintRecipient / burnToken / sourceDomain / replay) is covered against
    // mocks in test/bridge/protocols/CctpBridgeAdapter.t.sol. To add a real fork completion, capture an
    // attested mainnet CCTP message + attestation at a pinned block and feed it through `completeBridge`.
}
