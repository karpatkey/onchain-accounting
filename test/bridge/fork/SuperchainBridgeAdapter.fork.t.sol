// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {SuperchainBridgeAdapter} from "src/bridge/adapters/SuperchainBridgeAdapter.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {IBridgeEscrow} from "src/bridge/IBridgeEscrow.sol";
import {BridgeTestBase} from "test/bridge/fork/BridgeTestBase.fork.sol";

/// @title SuperchainBridgeAdapterForkTest
/// @notice Fork tests for Superchain Bridge Adapter using real mainnet and Optimism contracts
contract SuperchainBridgeAdapterForkTest is BridgeTestBase {
    SuperchainBridgeAdapter public l1Adapter;
    SuperchainBridgeAdapter public l2Adapter;
    BridgeEscrow public l1BridgeEscrow;
    BridgeEscrow public l2BridgeEscrow;

    // Test amounts
    uint256 public constant TEST_ETH_AMOUNT = 0.1 ether;

    function setUp() public override {
        super.setUp();
        _setupL1Adapter();
        _setupL2Adapter();
    }

    function _setupL1Adapter() internal {
        _selectMainnetFork();

        // Setup L1 BridgeEscrow
        address l1EscrowImpl = address(new BridgeEscrow());
        address[] memory initialSafes = new address[](1);
        initialSafes[0] = account;
        address[] memory initialAdapters = new address[](0);

        // Use explicit MAINNET_CHAIN_ID for clarity when forking
        address payable l1EscrowProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                l1EscrowImpl,
                abi.encodeCall(BridgeEscrow.initialize, (admin, MAINNET_CHAIN_ID, initialSafes, initialAdapters))
            ));
        l1BridgeEscrow = BridgeEscrow(l1EscrowProxy);

        vm.startPrank(admin);
        l1BridgeEscrow.grantRole(MANAGER, admin);
        l1BridgeEscrow.grantRole(MANAGER, manager);
        // Register native ETH (address(0)) for WETH_SYMBOL
        // BridgeEscrow now allows address(0) for native tokens
        l1BridgeEscrow.registerAsset(WETH_SYMBOL, address(0));
        vm.stopPrank();

        // Deploy L1 adapter
        address l1AdapterImpl = address(new SuperchainBridgeAdapter());
        address payable l1AdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                l1AdapterImpl,
                abi.encodeCall(
                    SuperchainBridgeAdapter.initialize,
                    (
                        admin,
                        address(l1BridgeEscrow),
                        L1_STANDARD_BRIDGE,
                        address(0), // L2 bridge not needed on L1
                        L1_CROSS_DOMAIN_MESSENGER,
                        address(0), // L2 messenger not needed on L1
                        OPTIMISM_PORTAL,
                        "1.0.0"
                    )
                )
            ));
        l1Adapter = SuperchainBridgeAdapter(l1AdapterProxy);

        vm.startPrank(admin);
        l1Adapter.grantRole(MANAGER, manager);
        vm.stopPrank();

        _authorizeAdapterForEscrow(address(l1Adapter), l1BridgeEscrow);

        // Fund account on L1
        _fundAccountWithEth(account, TEST_ETH_AMOUNT * 2);

        // Fund adapter with ETH for gas (needed for deposits)
        _fundAccountWithEth(address(l1Adapter), 1 ether);
    }

    function _setupL2Adapter() internal {
        _selectOptimismFork();

        // Setup L2 BridgeEscrow
        address l2EscrowImpl = address(new BridgeEscrow());
        address[] memory initialSafes = new address[](1);
        initialSafes[0] = account;
        address[] memory initialAdapters = new address[](0);

        // Use explicit OPTIMISM_CHAIN_ID: fork state may leave block.chainid as 1
        address payable l2EscrowProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                l2EscrowImpl,
                abi.encodeCall(BridgeEscrow.initialize, (admin, OPTIMISM_CHAIN_ID, initialSafes, initialAdapters))
            ));
        l2BridgeEscrow = BridgeEscrow(l2EscrowProxy);

        vm.startPrank(admin);
        l2BridgeEscrow.grantRole(MANAGER, admin);
        l2BridgeEscrow.grantRole(MANAGER, manager);
        // Register native ETH (address(0)) for WETH_SYMBOL
        // BridgeEscrow now allows address(0) for native tokens
        l2BridgeEscrow.registerAsset(WETH_SYMBOL, address(0));
        vm.stopPrank();

        // Deploy L2 adapter
        address l2AdapterImpl = address(new SuperchainBridgeAdapter());
        address payable l2AdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                l2AdapterImpl,
                abi.encodeCall(
                    SuperchainBridgeAdapter.initialize,
                    (
                        admin,
                        address(l2BridgeEscrow),
                        address(0), // L1 bridge not needed on L2
                        L2_STANDARD_BRIDGE,
                        address(0), // L1 messenger not needed on L2
                        L2_CROSS_DOMAIN_MESSENGER,
                        address(0), // Portal not needed on L2
                        "1.0.0"
                    )
                )
            ));
        l2Adapter = SuperchainBridgeAdapter(l2AdapterProxy);

        vm.startPrank(admin);
        l2Adapter.grantRole(MANAGER, manager);
        vm.stopPrank();

        _authorizeAdapterForEscrow(address(l2Adapter), l2BridgeEscrow);

        // Fund account on L2
        _fundAccountWithEth(account, TEST_ETH_AMOUNT * 2);

        // Fund adapter with ETH for gas (needed for withdrawals)
        _fundAccountWithEth(address(l2Adapter), 1 ether);
    }

    function _authorizeAdapterForEscrow(address adapter, BridgeEscrow escrow) internal {
        vm.startPrank(admin);
        escrow.authorizeAdapter(adapter);
        vm.stopPrank();
    }

    // ============ L1 → L2 Deposit Tests ============

    function testFork_l1ToL2_depositEth() public {
        _selectMainnetFork();

        uint256 amount = TEST_ETH_AMOUNT;
        uint64 destChainId = OPTIMISM_CHAIN_ID;

        // Get initial balances
        uint256 initialL1Balance = account.balance;

        // Create invoice data
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(MAINNET_CHAIN_ID, destChainId, account, WETH_SYMBOL_BYTES6, amount);

        // Initiate bridge via BridgeEscrow
        vm.prank(account);
        bytes32 invoiceHash =
            l1BridgeEscrow.depositAndBridge{value: amount}(destChainId, WETH_SYMBOL, amount, address(l1Adapter));

        // Verify ETH flow:
        // 1. Account balance decreased
        assertEq(account.balance, initialL1Balance - amount, "Account balance should decrease");

        // 2. For Optimism, ETH deposits go through OptimismPortal, not directly to L1StandardBridge
        // The bridge balance won't increase - instead, the deposit is recorded in the portal
        // We verify the deposit was initiated by checking:
        // - Invoice was created
        // - messagePayload was stored
        // - Adapter processed the bridge call

        // Verify invoice was created
        IBridgeEscrow.Invoice memory invoice = l1BridgeEscrow.getInvoice(invoiceHash);
        assertEq(invoice.invoiceId, invoiceData.invoiceId, "Invoice ID should match");
        assertEq(invoice.amount, amount, "Invoice amount should match");
        assertEq(
            uint8(invoice.status), uint8(IBridgeEscrow.InvoiceStatus.BRIDGING), "Invoice should be in BRIDGING status"
        );

        // Verify messagePayload was stored on L1 (before switching forks)
        bytes memory storedPayload = l1Adapter.getMessagePayload(invoiceData.invoiceId);
        assertGt(storedPayload.length, 0, "Message payload should be stored on L1");

        // Note: To verify L2 receipt, we would need to:
        // 1. Switch to Optimism fork
        // 2. Deploy L2 adapter on Optimism fork (separate deployment)
        // 3. Wait for cross-domain message to be processed
        // For now, we verify the deposit was initiated correctly on L1
    }

    function testFork_l1ToL2_messagePayloadPreserved() public {
        _selectMainnetFork();

        uint256 amount = TEST_ETH_AMOUNT;
        uint64 destChainId = OPTIMISM_CHAIN_ID;

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(MAINNET_CHAIN_ID, destChainId, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(account);
        bytes32 invoiceHash =
            l1BridgeEscrow.depositAndBridge{value: amount}(destChainId, WETH_SYMBOL, amount, address(l1Adapter));

        // Verify invoice data matches
        IBridgeEscrow.Invoice memory invoice = l1BridgeEscrow.getInvoice(invoiceHash);
        assertEq(invoice.invoiceId, invoiceData.invoiceId, "Invoice ID should match");
        assertEq(invoice.amount, invoiceData.amount, "Amount should match");

        // Verify checksum validation works
        bool isValid = l1BridgeEscrow.validateInvoiceIdChecksum(
            invoiceData.invoiceId, invoiceData.amount, invoiceData.timestamp, invoiceData.nonce, invoiceData.checksum24
        );
        assertTrue(isValid, "Checksum should be valid");

        // Verify messagePayload can be decoded
        InvoiceDataLib.InvoiceData memory decoded = InvoiceDataLib.decode(messagePayload);
        assertEq(decoded.invoiceId, invoiceData.invoiceId, "Decoded invoice ID should match");
        assertEq(decoded.amount, invoiceData.amount, "Decoded amount should match");
    }

    // ============ L2 → L1 Withdrawal Tests ============

    function testFork_l2ToL1_withdrawalInitiated() public {
        // Note: l2Adapter and l2BridgeEscrow are already deployed in setUp() on Optimism fork
        _selectOptimismFork();

        uint256 amount = TEST_ETH_AMOUNT;
        uint64 destChainId = MAINNET_CHAIN_ID;

        // Get initial balances
        uint256 initialL2Balance = account.balance;

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(OPTIMISM_CHAIN_ID, destChainId, account, WETH_SYMBOL_BYTES6, amount);

        // Initiate withdrawal via BridgeEscrow
        vm.prank(account);
        bytes32 invoiceHash =
            l2BridgeEscrow.depositAndBridge{value: amount}(destChainId, WETH_SYMBOL, amount, address(l2Adapter));

        // Verify ETH flow:
        // 1. Account balance decreased
        assertEq(account.balance, initialL2Balance - amount, "Account balance should decrease");

        // 2. For Optimism L2 → L1 withdrawals, ETH goes through the withdrawal system
        // The bridge balance might not increase immediately - withdrawals are queued
        // We verify the withdrawal was initiated by checking invoice and withdrawal hash

        // Verify invoice was created
        IBridgeEscrow.Invoice memory invoice = l2BridgeEscrow.getInvoice(invoiceHash);
        assertEq(invoice.invoiceId, invoiceData.invoiceId, "Invoice ID should match");
        assertEq(
            uint8(invoice.status), uint8(IBridgeEscrow.InvoiceStatus.BRIDGING), "Invoice should be in BRIDGING status"
        );

        // Verify withdrawal hash was stored
        bytes32 withdrawalHash = l2Adapter.getWithdrawalHashByInvoiceId(invoiceData.invoiceId);
        assertTrue(withdrawalHash != bytes32(0), "Withdrawal hash should be stored");
    }

    function testFork_l2ToL1_withdrawalChallengePeriod() public {
        // Note: l2Adapter and l2BridgeEscrow are already deployed in setUp() on Optimism fork
        _selectOptimismFork();

        uint256 amount = TEST_ETH_AMOUNT;
        uint64 destChainId = MAINNET_CHAIN_ID;

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(OPTIMISM_CHAIN_ID, destChainId, account, WETH_SYMBOL_BYTES6, amount);

        vm.prank(account);
        l2BridgeEscrow.depositAndBridge{value: amount}(destChainId, WETH_SYMBOL, amount, address(l2Adapter));

        // Get withdrawal hash
        bytes32 withdrawalHash = l2Adapter.getWithdrawalHashByInvoiceId(invoiceData.invoiceId);

        // Note: In a real scenario, we would:
        // 1. Prove the withdrawal (requires L2 output root and proofs)
        // 2. Wait for challenge period (7 days)
        // 3. Finalize the withdrawal

        // For fork tests, we can simulate the challenge period with vm.warp()
        // However, proving and finalizing require complex setup with L2 output roots
        // This test verifies the withdrawal was initiated correctly

        // Verify withdrawal hash is tracked
        bytes32 trackedInvoiceId = l2Adapter.getInvoiceIdByWithdrawalHash(withdrawalHash);
        assertEq(trackedInvoiceId, invoiceData.invoiceId, "Invoice ID should be tracked by withdrawal hash");
    }

    function testFork_messagePayload_crossDomainMessenger() public {
        // Test L1 → L2
        _selectMainnetFork();

        uint256 amount = TEST_ETH_AMOUNT;
        InvoiceDataLib.InvoiceData memory l1ToL2Data =
            _createInvoiceData(MAINNET_CHAIN_ID, OPTIMISM_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory l1ToL2Payload = InvoiceDataLib.encode(l1ToL2Data);

        vm.prank(account);
        l1BridgeEscrow.depositAndBridge{value: amount}(OPTIMISM_CHAIN_ID, WETH_SYMBOL, amount, address(l1Adapter));

        // Verify payload stored on L1
        bytes memory storedL1Payload = l1Adapter.getMessagePayload(l1ToL2Data.invoiceId);
        assertEq(storedL1Payload.length, l1ToL2Payload.length, "L1 payload should be stored");

        // Test L2 → L1
        // Note: l2Adapter and l2BridgeEscrow are already deployed in setUp() on Optimism fork
        _selectOptimismFork();

        InvoiceDataLib.InvoiceData memory l2ToL1Data =
            _createInvoiceData(OPTIMISM_CHAIN_ID, MAINNET_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory l2ToL1Payload = InvoiceDataLib.encode(l2ToL1Data);

        vm.prank(account);
        l2BridgeEscrow.depositAndBridge{value: amount}(MAINNET_CHAIN_ID, WETH_SYMBOL, amount, address(l2Adapter));

        // Verify payload stored on L2
        bytes memory storedL2Payload = l2Adapter.getMessagePayload(l2ToL1Data.invoiceId);
        assertEq(storedL2Payload.length, l2ToL1Payload.length, "L2 payload should be stored");
    }
}
