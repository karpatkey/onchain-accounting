// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {CctpBridgeAdapter} from "src/bridge/adapters/CctpBridgeAdapter.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
import {BridgeScenarioHelper} from "test/bridge/BridgeScenarioHelper.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/bridge/mocks/MockBridgeProtocols.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";

/// @title CctpBridgeAdapterTest
/// @notice Test suite for CCTP Bridge Adapter
contract CctpBridgeAdapterTest is BridgeScenarioHelper {
    CctpBridgeAdapter public adapter;
    MockTokenMessenger public tokenMessenger;
    MockMessageTransmitter public messageTransmitter;

    uint32 public constant SOURCE_DOMAIN = 0; // Ethereum mainnet domain
    uint32 public constant DEST_DOMAIN = 6; // Optimism domain

    function setUp() public override {
        super.setUp();

        // Deploy mock CCTP contracts
        messageTransmitter = new MockMessageTransmitter(SOURCE_DOMAIN, address(usdc));
        tokenMessenger = new MockTokenMessenger(address(messageTransmitter));

        // Deploy CCTP adapter
        address adapterImpl = address(new CctpBridgeAdapter());
        address adapterProxy = UnsafeUpgrades.deployUUPSProxy(
            adapterImpl,
            abi.encodeCall(
                CctpBridgeAdapter.initialize,
                (admin, address(bridgeEscrow), address(tokenMessenger), address(messageTransmitter), "1.0.0")
            )
        );
        adapter = CctpBridgeAdapter(adapterProxy);

        // Configure adapter
        vm.startPrank(admin);
        adapter.setDomainMapping(SOURCE_CHAIN_ID, SOURCE_DOMAIN);
        adapter.setDomainMapping(DEST_CHAIN_ID, DEST_DOMAIN);
        adapter.grantRole(keccak256("OPERATOR_ROLE"), operator);
        vm.stopPrank();

        // Authorize adapter in BridgeEscrow
        _authorizeAdapter(address(adapter));

        // Setup labels
        vm.label(address(adapter), "CctpBridgeAdapter");
        vm.label(address(tokenMessenger), "MockTokenMessenger");
        vm.label(address(messageTransmitter), "MockMessageTransmitter");
    }

    // ============ Bridge Initiation Tests ============

    function test_bridge_initiatesCctpTransfer() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        _approveToken(address(usdc), address(bridgeEscrow), amount);

        // Create invoice data
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Transfer tokens to BridgeEscrow (simulating depositAndBridge flow)
        vm.prank(portfolioSafe);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(bridgeEscrow), amount);

        // BridgeEscrow approves adapter (new pattern: approval instead of transfer)
        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);

        // Initiate bridge (adapter will pull tokens in _bridge())
        vm.prank(address(bridgeEscrow));
        adapter.bridge(messagePayload);

        // Verify invoiceId mapping was stored
        bytes32 invoiceId = invoiceData.invoiceId;
        bytes32 storedInvoiceId = adapter.messageToInvoiceId(SOURCE_DOMAIN, tokenMessenger.nonce());
        assertEq(storedInvoiceId, invoiceId, "InvoiceId mapping should be stored");
    }

    function test_bridge_revertsForNativeToken() public {
        uint256 amount = 1 ether;
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, WETH_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.deal(address(adapter), amount);

        vm.prank(address(bridgeEscrow));
        vm.expectRevert(); // Should revert because CCTP only supports USDC
        adapter.bridge(messagePayload);
    }

    function test_bridge_revertsForInvalidDomain() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData = _createInvoiceData(
            SOURCE_CHAIN_ID,
            999,
            portfolioSafe,
            USDC_SYMBOL,
            amount // Invalid chain ID
        );
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Simulate bridge initiation (transfer tokens to BridgeEscrow, then approve adapter)
        vm.prank(portfolioSafe);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(bridgeEscrow), amount);

        // BridgeEscrow approves adapter (new pattern: approval instead of transfer)
        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);

        vm.prank(address(bridgeEscrow));
        vm.expectRevert(); // Should revert because domain mapping doesn't exist
        adapter.bridge(messagePayload);
    }

    function test_bridge_revertsIfNotCalledByBridgeEscrow() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Simulate bridge initiation (transfer tokens to BridgeEscrow, then approve adapter)
        vm.prank(portfolioSafe);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(bridgeEscrow), amount);

        // BridgeEscrow approves adapter (new pattern: approval instead of transfer)
        vm.prank(address(bridgeEscrow));
        usdc.approve(address(adapter), amount);

        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not BridgeEscrow
        adapter.bridge(messagePayload);
    }

    // ============ Bridge Completion Tests ============

    function test_completeBridge_mintsUsdcOnDestination() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);

        // Set up destination chain environment
        (BridgeEscrow destBridgeEscrow, CctpBridgeAdapter destAdapter) = _setupDestinationChainForCctpTest(invoiceData);

        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Execute completion and verify results
        _executeAndVerifyCctpCompletion(destBridgeEscrow, destAdapter, invoiceData, messagePayload, amount);
    }

    /// @notice Helper to set up destination chain for CCTP test
    function _setupDestinationChainForCctpTest(InvoiceDataLib.InvoiceData memory invoiceData)
        internal
        returns (BridgeEscrow destBridgeEscrow, CctpBridgeAdapter destAdapter)
    {
        // Set up destination chain environment (without transferring tokens - CCTP will mint them)
        vm.chainId(uint256(invoiceData.destinationChainId));
        destBridgeEscrow = _setupDestinationChainEscrow(uint64(invoiceData.destinationChainId));

        // Set up CCTP contracts on destination chain
        MockMessageTransmitter destMessageTransmitter = new MockMessageTransmitter(DEST_DOMAIN, address(usdc));
        MockTokenMessenger destTokenMessenger = new MockTokenMessenger(address(destMessageTransmitter));

        // Set up adapter on destination chain
        address destAdapterProxy = UnsafeUpgrades.deployUUPSProxy(
            address(new CctpBridgeAdapter()),
            abi.encodeCall(
                CctpBridgeAdapter.initialize,
                (
                    admin,
                    address(destBridgeEscrow),
                    address(destTokenMessenger),
                    address(destMessageTransmitter),
                    "1.0.0"
                )
            )
        );
        destAdapter = CctpBridgeAdapter(destAdapterProxy);

        // Configure adapter on destination chain
        vm.startPrank(admin);
        destAdapter.setDomainMapping(SOURCE_CHAIN_ID, SOURCE_DOMAIN);
        destAdapter.setDomainMapping(DEST_CHAIN_ID, DEST_DOMAIN);
        destAdapter.grantRole(keccak256("OPERATOR_ROLE"), operator);
        destBridgeEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();
    }

    /// @notice Helper to execute and verify CCTP completion
    function _executeAndVerifyCctpCompletion(
        BridgeEscrow destBridgeEscrow,
        CctpBridgeAdapter destAdapter,
        InvoiceDataLib.InvoiceData memory invoiceData,
        bytes memory messagePayload,
        uint256 amount
    ) internal {
        // Set up invoiceId mapping
        uint64 nonce = 123;
        destAdapter.messageToInvoiceId(SOURCE_DOMAIN, nonce);

        // Create mock CCTP message and protocol data
        bytes memory cctpMessage = _createMockCctpMessage(
            SOURCE_DOMAIN, DEST_DOMAIN, nonce, amount, address(destBridgeEscrow), address(destAdapter)
        );
        bytes memory protocolData = abi.encode(cctpMessage, "mock_attestation");

        // Verify invoice is not completed before completion
        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));
        assertFalse(
            destBridgeEscrow.isInvoiceCompleted(invoiceHash), "Invoice should not be completed before completion"
        );

        // Get initial balance and verify escrow starts at zero
        uint256 initialPortfolioBalance = usdc.balanceOf(portfolioSafe);
        assertEq(usdc.balanceOf(address(destBridgeEscrow)), 0, "Escrow should start with zero balance (CCTP will mint)");

        // Complete bridge
        vm.prank(operator);
        destAdapter.completeBridge(messagePayload, protocolData);

        // Verify balances after completion
        _verifyCompletionBalances(destBridgeEscrow, initialPortfolioBalance, amount);

        // Verify invoice is marked as completed
        assertTrue(destBridgeEscrow.isInvoiceCompleted(invoiceHash), "Invoice should be marked as completed");
    }

    /// @notice Helper to verify balances after completion
    function _verifyCompletionBalances(
        BridgeEscrow destBridgeEscrow,
        uint256 initialPortfolioBalance,
        uint256 expectedAmount
    ) internal view {
        uint256 finalBalance = usdc.balanceOf(portfolioSafe);
        assertEq(finalBalance - initialPortfolioBalance, expectedAmount, "Portfolio safe should receive minted USDC");
        assertEq(usdc.balanceOf(address(destBridgeEscrow)), 0, "Escrow balance should be zero after release");
    }

    /// @notice Full round-trip: depositAndBridge on source → payload from invoice → deliver via receiveMessage → completeBridge
    function test_realistic_fullRoundTrip_sourcePayloadAndDeliveryViaCctp() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();

        // Execute source chain bridge
        (bytes memory messagePayload, uint64 nonce, uint256 portfolioBalanceBeforeRelease) =
            _executeCctpSourceChainBridge(amount);

        // Execute destination chain completion and verify
        _executeCctpDestinationCompletion(messagePayload, nonce, amount, portfolioBalanceBeforeRelease);
    }

    /// @notice Helper to execute source chain bridge for CCTP
    function _executeCctpSourceChainBridge(uint256 amount)
        internal
        returns (bytes memory messagePayload, uint64 nonce, uint256 portfolioBalanceBeforeRelease)
    {
        // ---------- SOURCE CHAIN ----------
        _approveToken(address(usdc), address(bridgeEscrow), amount);
        vm.prank(portfolioSafe);
        bytes32 invoiceHash = bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, amount, address(adapter));

        messagePayload = _getMessagePayloadFromInvoiceHash(bridgeEscrow, invoiceHash);
        nonce = tokenMessenger.nonce();
        portfolioBalanceBeforeRelease = usdc.balanceOf(portfolioSafe);
        assertGt(messagePayload.length, 0, "messagePayload from invoice");
    }

    /// @notice Helper to execute destination chain completion for CCTP
    function _executeCctpDestinationCompletion(
        bytes memory messagePayload,
        uint64 nonce,
        uint256 amount,
        uint256 portfolioBalanceBeforeRelease
    ) internal {
        // ---------- DESTINATION CHAIN ----------
        vm.chainId(uint256(DEST_CHAIN_ID));

        BridgeEscrow destBridgeEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        MockMessageTransmitter destMessageTransmitter = new MockMessageTransmitter(DEST_DOMAIN, address(usdc));
        MockTokenMessenger destTokenMessenger = new MockTokenMessenger(address(destMessageTransmitter));

        CctpBridgeAdapter destAdapter = _deployAndConfigureCctpAdapter(
            destBridgeEscrow, address(destTokenMessenger), address(destMessageTransmitter)
        );

        bytes memory protocolData =
            _prepareCctpProtocolData(nonce, amount, address(destBridgeEscrow), address(destAdapter));

        vm.prank(operator);
        destAdapter.completeBridge(messagePayload, protocolData);

        // Verify completion and balances
        _verifyCctpCompletion(destBridgeEscrow, messagePayload, portfolioBalanceBeforeRelease, amount);
    }

    /// @notice Helper to deploy and configure CCTP adapter
    function _deployAndConfigureCctpAdapter(
        BridgeEscrow destBridgeEscrow,
        address destTokenMessenger,
        address destMessageTransmitter
    ) internal returns (CctpBridgeAdapter destAdapter) {
        address destAdapterProxy = UnsafeUpgrades.deployUUPSProxy(
            address(new CctpBridgeAdapter()),
            abi.encodeCall(
                CctpBridgeAdapter.initialize,
                (admin, address(destBridgeEscrow), destTokenMessenger, destMessageTransmitter, "1.0.0")
            )
        );
        destAdapter = CctpBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        destAdapter.setDomainMapping(SOURCE_CHAIN_ID, SOURCE_DOMAIN);
        destAdapter.setDomainMapping(DEST_CHAIN_ID, DEST_DOMAIN);
        destAdapter.grantRole(keccak256("OPERATOR_ROLE"), operator);
        destBridgeEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();
    }

    /// @notice Helper to prepare CCTP protocol data
    function _prepareCctpProtocolData(uint64 nonce, uint256 amount, address destBridgeEscrow, address destAdapter)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory cctpMessage =
            _createMockCctpMessage(SOURCE_DOMAIN, DEST_DOMAIN, nonce, amount, destBridgeEscrow, destAdapter);
        return abi.encode(cctpMessage, "mock_attestation");
    }

    /// @notice Helper to verify CCTP completion
    function _verifyCctpCompletion(
        BridgeEscrow destBridgeEscrow,
        bytes memory messagePayload,
        uint256 portfolioBalanceBeforeRelease,
        uint256 expectedAmount
    ) internal view {
        bytes32 expectedInvoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(messagePayload).checksum24)));
        assertTrue(destBridgeEscrow.isInvoiceCompleted(expectedInvoiceHash), "invoice completed");

        uint256 portfolioBalanceAfterRelease = usdc.balanceOf(portfolioSafe);
        assertEq(
            portfolioBalanceAfterRelease - portfolioBalanceBeforeRelease,
            expectedAmount,
            "portfolio safe received bridged amount"
        );
    }

    function test_completeBridge_validatesChecksum() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);

        // Set up destination chain environment
        (BridgeEscrow destBridgeEscrow,) = _setupDestinationChainForCompletion(invoiceData, address(usdc));

        // Set up adapter on destination chain
        MockMessageTransmitter destMessageTransmitter = new MockMessageTransmitter(DEST_DOMAIN, address(usdc));
        MockTokenMessenger destTokenMessenger = new MockTokenMessenger(address(destMessageTransmitter));
        address destAdapterImpl = address(new CctpBridgeAdapter());
        address destAdapterProxy = UnsafeUpgrades.deployUUPSProxy(
            destAdapterImpl,
            abi.encodeCall(
                CctpBridgeAdapter.initialize,
                (
                    admin,
                    address(destBridgeEscrow),
                    address(destTokenMessenger),
                    address(destMessageTransmitter),
                    "1.0.0"
                )
            )
        );
        CctpBridgeAdapter destAdapter = CctpBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        destAdapter.grantRole(keccak256("OPERATOR_ROLE"), operator);
        destBridgeEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        uint64 nonce = 123;
        bytes memory cctpMessage =
            _createMockCctpMessage(SOURCE_DOMAIN, DEST_DOMAIN, nonce, amount, portfolioSafe, address(destAdapter));
        bytes memory attestation = "mock_attestation";

        // Corrupt messagePayload (invalid checksum)
        bytes memory corruptedPayload = abi.encode(
            invoiceData.invoiceId,
            invoiceData.amount,
            bytes32(uint256(invoiceData.timestamp) << 192 | uint256(uint192(invoiceData.checksum24)) ^ 1)
        );

        bytes memory protocolData = abi.encode(cctpMessage, attestation);

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
        MockMessageTransmitter destMessageTransmitter = new MockMessageTransmitter(DEST_DOMAIN, address(usdc));
        MockTokenMessenger destTokenMessenger = new MockTokenMessenger(address(destMessageTransmitter));
        address destAdapterImpl = address(new CctpBridgeAdapter());
        address destAdapterProxy = UnsafeUpgrades.deployUUPSProxy(
            destAdapterImpl,
            abi.encodeCall(
                CctpBridgeAdapter.initialize,
                (
                    admin,
                    address(destBridgeEscrow),
                    address(destTokenMessenger),
                    address(destMessageTransmitter),
                    "1.0.0"
                )
            )
        );
        CctpBridgeAdapter destAdapter = CctpBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        destBridgeEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();

        uint64 nonce = 123;
        bytes memory cctpMessage =
            _createMockCctpMessage(SOURCE_DOMAIN, DEST_DOMAIN, nonce, amount, portfolioSafe, address(destAdapter));
        bytes memory attestation = "mock_attestation";
        bytes memory protocolData = abi.encode(cctpMessage, attestation);

        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not operator
        destAdapter.completeBridge(messagePayload, protocolData);
    }

    // ============ Configuration Tests ============

    function test_setDomainMapping_updatesMapping() public {
        uint64 chainId = 42161; // Arbitrum
        uint32 domain = 3;

        vm.prank(admin);
        adapter.setDomainMapping(chainId, domain);

        assertEq(adapter.getDomainForChain(chainId), domain, "Domain mapping should be set");
        assertEq(adapter.getChainForDomain(domain), chainId, "Chain mapping should be set");
    }

    function test_setDomainMapping_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // Should revert because caller is not admin
        adapter.setDomainMapping(42161, 3);
    }

    // ============ Helper Functions ============

    /// @notice Creates a simplified mock CCTP message for testing
    function _createMockCctpMessage(
        uint32 sourceDomain,
        uint32 destDomain,
        uint64 nonce,
        uint256 amount,
        address recipientAddr,
        address destinationCallerAddr
    ) internal pure returns (bytes memory) {
        // Simplified CCTP message format:
        // version (4 bytes) + sourceDomain (4 bytes) + destDomain (4 bytes) + nonce (8 bytes)
        // + sender (32 bytes) + recipient (32 bytes) + destinationCaller (32 bytes) + messageBody (32 bytes for amount)
        bytes memory message = new bytes(148);

        // version = 0 (4 bytes)
        assembly {
            mstore(add(message, 32), shl(224, 0))
        }

        // sourceDomain (4 bytes at offset 4)
        assembly {
            mstore(add(message, 36), shl(224, sourceDomain))
        }

        // destDomain (4 bytes at offset 8)
        assembly {
            mstore(add(message, 40), shl(224, destDomain))
        }

        // nonce (8 bytes at offset 12)
        assembly {
            mstore(add(message, 44), shl(192, nonce))
        }

        // sender (32 bytes at offset 20) - zero for simplicity
        // recipient (32 bytes at offset 52) - portfolio safe address as bytes32
        bytes32 recipient = bytes32(uint256(uint160(recipientAddr)));
        assembly {
            mstore(add(message, 84), recipient)
        }

        // destinationCaller (32 bytes at offset 84) - adapter address as bytes32
        bytes32 destinationCaller = bytes32(uint256(uint160(destinationCallerAddr)));
        assembly {
            mstore(add(message, 116), destinationCaller)
        }

        // messageBody - amount (32 bytes at offset 116)
        assembly {
            mstore(add(message, 148), amount)
        }

        return message;
    }
}
