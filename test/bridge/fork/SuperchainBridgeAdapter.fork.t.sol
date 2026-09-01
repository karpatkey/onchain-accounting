// SPDX-License-Identifier: BUSL-1.1
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

    // Base L1 contracts (all deployed on Ethereum mainnet) — used for the fault-proof portal ABI check.
    address public constant BASE_L1_STANDARD_BRIDGE = 0x3154Cf16ccdb4C6d922629664174b904d80F2C35;
    address public constant BASE_OPTIMISM_PORTAL = 0x49048044D57e1C92A77f79988d21Fa8fAF74E97e;
    address public constant BASE_L1_CROSS_DOMAIN_MESSENGER = 0x866E82a600A1414e583f7F13623F1aC5d58b0Afa;

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
        address l1AdapterImpl = address(new SuperchainBridgeAdapter(address(0)));
        address payable l1AdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                l1AdapterImpl,
                abi.encodeCall(
                    SuperchainBridgeAdapter.initialize,
                    (
                        admin,
                        address(l1BridgeEscrow),
                        address(0),
                        L1_CROSS_DOMAIN_MESSENGER,
                        address(0),
                        uint256(MAINNET_CHAIN_ID),
                        "1.0.0"
                    )
                )
            ));
        l1Adapter = SuperchainBridgeAdapter(l1AdapterProxy);

        vm.startPrank(admin);
        l1Adapter.grantRole(MANAGER, manager);
        // Seed the per-L2 bridge + portal + L1 messenger for Optimism (the L2 this fork's deposit tests exercise).
        l1Adapter.setL1BridgeForL2(OPTIMISM_CHAIN_ID, L1_STANDARD_BRIDGE);
        l1Adapter.setOptimismPortalForL2(OPTIMISM_CHAIN_ID, OPTIMISM_PORTAL);
        l1Adapter.setL1MessengerForL2(OPTIMISM_CHAIN_ID, L1_CROSS_DOMAIN_MESSENGER);
        // Also seed the Base per-L2 portal + messenger (both are L1 contracts) for the fault-proof ABI fork check.
        l1Adapter.setL1BridgeForL2(BASE_CHAIN_ID, BASE_L1_STANDARD_BRIDGE);
        l1Adapter.setOptimismPortalForL2(BASE_CHAIN_ID, BASE_OPTIMISM_PORTAL);
        l1Adapter.setL1MessengerForL2(BASE_CHAIN_ID, BASE_L1_CROSS_DOMAIN_MESSENGER);
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
        address l2AdapterImpl = address(new SuperchainBridgeAdapter(address(0)));
        address payable l2AdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                l2AdapterImpl,
                abi.encodeCall(
                    SuperchainBridgeAdapter.initialize,
                    (
                        admin,
                        address(l2BridgeEscrow),
                        L2_STANDARD_BRIDGE,
                        address(0),
                        L2_CROSS_DOMAIN_MESSENGER,
                        uint256(MAINNET_CHAIN_ID),
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
        bytes memory storedPayload = l1Adapter.getMessagePayload(bytes32(uint256(uint192(invoiceData.checksum24))));
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
        bytes memory storedPayload = l2Adapter.getMessagePayload(bytes32(uint256(uint192(invoiceData.checksum24))));
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
        bytes memory storedL1Payload = l1Adapter.getMessagePayload(bytes32(uint256(uint192(l1ToL2Data.checksum24))));
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
        bytes memory storedL2Payload = l2Adapter.getMessagePayload(bytes32(uint256(uint192(l2ToL1Data.checksum24))));
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

        // ADR 0027: delivery records custody and HOLDS the native ETH; the account is paid only on MANAGER claim.
        assertEq(account.balance, portfolioBefore, "account NOT paid on delivery");
        assertEq(address(l2Adapter).balance, 0, "adapter forwarded all delivered ETH to escrow");
        assertEq(address(l2BridgeEscrow).balance, amount, "escrow holds the delivered ETH");
        assertEq(l2BridgeEscrow.getHeldBalanceForAsset(address(0), account), amount, "held for account");
        assertTrue(l2BridgeEscrow.isInvoiceCompleted(invoiceHash), "invoice marked completed on record");

        vm.prank(manager);
        l2BridgeEscrow.claim(invoiceHash);
        assertEq(account.balance - portfolioBefore, amount, "account received bridged ETH on claim");
        assertEq(address(l2BridgeEscrow).balance, 0, "escrow drained after claim");
        assertEq(l2BridgeEscrow.getHeldBalanceForAsset(address(0), account), 0, "held cleared after claim");
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

    // ============ Fault-proof (OP2) portal ABI check ============

    /// @notice The adapter's proven-check must match the LIVE fault-proof portals (OP v5.6.1, Base v5.2.0), which
    ///         expose `provenWithdrawals(bytes32,address) -> (address disputeGameProxy, uint64)` — NOT the legacy
    ///         single-key `provenWithdrawals(bytes32) -> bool`. Calling the adapter's `isWithdrawalProven` /
    ///         `canFinalizeWithdrawal` against the REAL portals MUST decode cleanly (returning false for an
    ///         arbitrary unproven hash) rather than revert — which is exactly what the legacy interface would do.
    ///         This is the regression that catches HIGH#2 (the adapter was written against the pre-fault-proof ABI).
    /// @dev A block where BOTH the OP and Base portals are on the fault-proof system. They migrated at different
    ///      times (OP mid-2024, Base later), so the shared `MAINNET_FORK_BLOCK` (21M) predates Base's migration —
    ///      hence this test pins its own fork here rather than reuse setUp's fork.
    uint256 internal constant FAULT_PROOF_MAINNET_BLOCK = 22_000_000;

    function testFork_faultProofPortal_provenWithdrawalsAbiMatchesLivePortals() public {
        // Own fork at a fault-proof-era block (rolling the shared fork would wipe setUp's deployed contracts).
        uint256 fpFork = createForkWithCadence(getAlchemyUrl("eth-mainnet"), FAULT_PROOF_MAINNET_BLOCK);
        vm.selectFork(fpFork);

        // Fresh L1 adapter with the real OP + Base portals seeded (both L1 fault-proof portals at this block).
        address impl = address(new SuperchainBridgeAdapter(address(0)));
        address payable proxy = payable(UnsafeUpgrades.deployUUPSProxy(
                impl,
                abi.encodeCall(
                    SuperchainBridgeAdapter.initialize,
                    (
                        admin,
                        address(this),
                        address(0),
                        L1_CROSS_DOMAIN_MESSENGER,
                        address(0),
                        uint256(MAINNET_CHAIN_ID),
                        "1.0.0"
                    )
                )
            ));
        SuperchainBridgeAdapter ad = SuperchainBridgeAdapter(proxy);
        vm.startPrank(admin);
        ad.setOptimismPortalForL2(OPTIMISM_CHAIN_ID, OPTIMISM_PORTAL);
        ad.setOptimismPortalForL2(BASE_CHAIN_ID, BASE_OPTIMISM_PORTAL);
        vm.stopPrank();

        bytes32 arbitraryHash = keccak256("some-unproven-withdrawal");

        // These MUST decode cleanly (return false) rather than revert — which is exactly what the legacy single-key
        // `provenWithdrawals(bytes32)` interface would do against the fault-proof portals. This is the HIGH#2 regression.
        assertFalse(ad.isWithdrawalProven(OPTIMISM_CHAIN_ID, arbitraryHash), "OP: decodes not-proven (no revert)");
        assertFalse(
            ad.canFinalizeWithdrawal(OPTIMISM_CHAIN_ID, arbitraryHash), "OP: decodes not-finalizable (no revert)"
        );
        assertFalse(ad.isWithdrawalProven(BASE_CHAIN_ID, arbitraryHash), "Base: decodes not-proven (no revert)");
        assertFalse(ad.canFinalizeWithdrawal(BASE_CHAIN_ID, arbitraryHash), "Base: decodes not-finalizable (no revert)");

        // Ground `canFinalizeWithdrawal`'s finalization-gate delegation against the LIVE portal ABI: the
        // per-submitter fault-proof portals expose `checkWithdrawal(bytes32,address)` and REVERT (non-empty) for an
        // unproven hash — proving the gate function exists and is two-arg. A missing/mismatched selector would revert
        // with EMPTY returndata, which the adapter's try/catch swallows as "not finalizable" — so assert the revert
        // SHAPE here (returndata length > 0), otherwise an ABI drift would pass silently as a false negative.
        _assertCheckWithdrawalIsTwoArg(OPTIMISM_PORTAL, arbitraryHash, address(ad), "OP");
        _assertCheckWithdrawalIsTwoArg(BASE_OPTIMISM_PORTAL, arbitraryHash, address(ad), "Base");
    }

    function _assertCheckWithdrawalIsTwoArg(address portal, bytes32 hash, address submitter, string memory tag)
        internal
        view
    {
        (bool ok, bytes memory ret) =
            portal.staticcall(abi.encodeWithSignature("checkWithdrawal(bytes32,address)", hash, submitter));
        assertFalse(ok, string.concat(tag, ": checkWithdrawal(bytes32,address) reverts for an unproven hash"));
        // A NON-EMPTY revert proves the two-arg selector exists and its body ran the proven-check: a
        // missing/renamed selector would revert with EMPTY returndata (no matching function, no fallback), which
        // the adapter's try/catch swallows as a silent "not finalizable" false-negative — so the length check is
        // the real ABI-drift tripwire. We deliberately do NOT pin the exact error selector: the proven-check reason
        // varies across portal versions/blocks (a custom `OptimismPortal_Unproven()` on the current portals, an
        // `Error(string)` on older ones), so a specific-selector assertion would be brittle, not stronger.
        assertGt(ret.length, 0, string.concat(tag, ": checkWithdrawal(bytes32,address) exists (non-empty revert)"));
    }

    /// @notice The L1→L2 deposit path must send the authenticated `completeDeposit` message through the REAL
    ///         per-L2 L1CrossDomainMessenger with the configured gas limit, for BOTH OP and Base (distinct
    ///         messengers). A single-messenger bug (HIGH#1) or an undersized gas limit would revert here.
    function testFork_l1ToL2_depositSendsMessageViaRealPerL2Messenger() public {
        _selectMainnetFork();
        uint256 amount = TEST_ETH_AMOUNT;

        // OP lane: deposit → real L1StandardBridge.depositETHTo + real OP L1CrossDomainMessenger.sendMessage.
        _fundAccountWithEth(account, amount * 2);
        vm.prank(account);
        l1BridgeEscrow.depositAndBridge{value: amount}(OPTIMISM_CHAIN_ID, WETH_SYMBOL, amount, address(l1Adapter));

        // Base lane: deposit → real Base L1StandardBridge + real Base L1CrossDomainMessenger (distinct addresses).
        _fundAccountWithEth(account, amount * 2);
        vm.prank(account);
        l1BridgeEscrow.depositAndBridge{value: amount}(BASE_CHAIN_ID, WETH_SYMBOL, amount, address(l1Adapter));
    }
}
