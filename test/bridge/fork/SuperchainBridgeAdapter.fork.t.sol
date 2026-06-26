// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {SuperchainBridgeAdapter} from "src/bridge/adapters/SuperchainBridgeAdapter.sol";
import {ISuperchainBridgeAdapter} from "src/bridge/adapters/interfaces/ISuperchainBridgeAdapter.sol";
import {ICrossDomainMessenger} from "src/bridge/adapters/interfaces/ISuperchainInterfaces.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {IBridgeEscrow} from "src/bridge/IBridgeEscrow.sol";
import {BridgeTestBase} from "test/bridge/fork/BridgeTestBase.fork.sol";

/// @title SuperchainBridgeAdapterForkTest
/// @notice Fork tests for the Superchain (Optimism canonical bridge) adapter using real mainnet + Optimism
///         contracts (ADR 0012). Source side: L1->L2 deposits via the real L1StandardBridge / OptimismPortal,
///         L2->L1 withdrawals via the real L2StandardBridge. Destination side: L1->L2 deposit completion
///         (`completeDeposit`) is authenticated against the real L2CrossDomainMessenger
///         (`msg.sender == l2Messenger` AND `xDomainMessageSender() == trustedRemoteAdapter`). The withdrawal
///         hash is set on L1 at PROVE time (not at withdrawal initiation), matching the re-architected adapter.
/// @dev The xDomainMessageSender of the real L2 messenger is only meaningful during a genuine relayed call, so
///      the deposit-completion test mocks ONLY that getter (vm.mockCall) while still requiring the call to come
///      from the real messenger address — authenticating against the real protocol contract. A genuine L2->L1
///      finalize requires a real proven withdrawal (L2 output root + Merkle proof), which has no offline path;
///      the prove+finalize release flow is exercised end-to-end in the unit test with a real-OP-hash portal mock.
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

        // The invoice payload was stored on withdrawal initiation.
        bytes memory storedPayload = l2Adapter.getMessagePayload(invoiceData.invoiceId);
        assertGt(storedPayload.length, 0, "messagePayload should be stored on L2 at withdrawal initiation");

        // ADR 0012: the REAL OP withdrawal hash is only computed on L1 at prove time (it depends on the
        // L2ToL1MessagePasser nonce), so it must NOT be set on L2 at withdrawal initiation.
        bytes32 withdrawalHash = l2Adapter.getWithdrawalHashByInvoiceId(invoiceData.invoiceId);
        assertEq(withdrawalHash, bytes32(0), "withdrawal hash is set on L1 at prove time, not at initiation");
    }

    /// @notice ADR 0012: invoice<->withdrawalHash correlation is established on L1 at PROVE time, not during the
    ///         L2 withdrawal initiation. Confirms initiation does not pre-populate the correlation.
    function testFork_l2ToL1_withdrawalHashUnsetUntilProve() public {
        _selectOptimismFork();

        uint256 amount = TEST_ETH_AMOUNT;
        uint64 destChainId = MAINNET_CHAIN_ID;

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(OPTIMISM_CHAIN_ID, destChainId, account, WETH_SYMBOL_BYTES6, amount);

        vm.prank(account);
        l2BridgeEscrow.depositAndBridge{value: amount}(destChainId, WETH_SYMBOL, amount, address(l2Adapter));

        // No withdrawal hash is correlated yet (prove happens later, on L1, with a real OP withdrawal hash).
        assertEq(
            l2Adapter.getWithdrawalHashByInvoiceId(invoiceData.invoiceId),
            bytes32(0),
            "no withdrawal hash correlated at initiation"
        );
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

    // ============ L1 → L2 Deposit Completion (authenticated messenger) ============

    /// @notice On the OP fork, the real L2CrossDomainMessenger relays the deposit message to the L2 adapter,
    ///         which authenticates the messenger + the L1 source sibling, then funds the escrow and releases the
    ///         delivered ETH to the account (funded pass-through). msg.sender is the REAL messenger; only the
    ///         xDomainMessageSender getter is mocked (it is meaningless outside a genuine relay).
    function testFork_l1ToL2_completeDeposit_authenticatesMessengerAndReleases() public {
        _selectOptimismFork();

        uint256 amount = TEST_ETH_AMOUNT;

        // L1 sibling adapter (CREATE2 same-address) trusted as the source sender for the L1 source chain.
        address l1Sibling = address(l2Adapter);
        vm.prank(admin);
        l2Adapter.setTrustedRemoteAdapter(MAINNET_CHAIN_ID, _siblingIdentity(l1Sibling));

        // Invoice authored on L1 (source) bound for L2 (this fork). The account is an authorized safe.
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(MAINNET_CHAIN_ID, OPTIMISM_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // The canonical bridge delivered the bridged ETH to the L2 adapter (the recipient) before the relay.
        // vm.deal SETS the balance, so deal exactly the delivered amount and assert it is fully forwarded.
        _fundAccountWithEth(address(l2Adapter), amount);

        // The real L2CrossDomainMessenger reports the L1 sibling as the cross-domain sender during the relay.
        vm.mockCall(
            L2_CROSS_DOMAIN_MESSENGER,
            abi.encodeWithSelector(ICrossDomainMessenger.xDomainMessageSender.selector),
            abi.encode(l1Sibling)
        );

        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));
        uint256 portfolioBefore = account.balance;

        // Genuine protocol path: msg.sender is the real L2CrossDomainMessenger.
        vm.prank(L2_CROSS_DOMAIN_MESSENGER);
        l2Adapter.completeDeposit(messagePayload);

        vm.clearMockedCalls();

        assertEq(account.balance - portfolioBefore, amount, "account received bridged ETH");
        assertEq(address(l2Adapter).balance, 0, "adapter forwarded all delivered ETH");
        assertTrue(l2BridgeEscrow.isInvoiceCompleted(invoiceHash), "invoice marked completed");
    }

    /// @notice completeDeposit reverts when not called by the genuine L2CrossDomainMessenger.
    function testFork_l1ToL2_completeDeposit_revertsWhenNotMessenger() public {
        _selectOptimismFork();

        uint256 amount = TEST_ETH_AMOUNT;
        vm.prank(admin);
        l2Adapter.setTrustedRemoteAdapter(MAINNET_CHAIN_ID, _siblingIdentity(address(l2Adapter)));

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(MAINNET_CHAIN_ID, OPTIMISM_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(account);
        vm.expectRevert(); // NotAuthorized — caller is not the L2 messenger
        l2Adapter.completeDeposit(messagePayload);
    }

    /// @notice completeDeposit from the genuine messenger reverts when the L1 source sender is not the trusted sibling.
    function testFork_l1ToL2_completeDeposit_revertsForUntrustedXDomainSender() public {
        _selectOptimismFork();

        uint256 amount = TEST_ETH_AMOUNT;
        vm.prank(admin);
        l2Adapter.setTrustedRemoteAdapter(MAINNET_CHAIN_ID, _siblingIdentity(address(l2Adapter)));

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(MAINNET_CHAIN_ID, OPTIMISM_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        _fundAccountWithEth(address(l2Adapter), amount);

        // Messenger is genuine, but the reported cross-domain sender is an impostor.
        vm.mockCall(
            L2_CROSS_DOMAIN_MESSENGER,
            abi.encodeWithSelector(ICrossDomainMessenger.xDomainMessageSender.selector),
            abi.encode(makeAddr("impostor"))
        );

        vm.prank(L2_CROSS_DOMAIN_MESSENGER);
        vm.expectRevert(); // NotAuthorized — xDomainMessageSender != trustedRemoteAdapter
        l2Adapter.completeDeposit(messagePayload);

        vm.clearMockedCalls();
    }
}
