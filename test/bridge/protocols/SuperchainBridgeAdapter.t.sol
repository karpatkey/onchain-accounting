// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {SuperchainBridgeAdapter} from "src/bridge/adapters/SuperchainBridgeAdapter.sol";
import {ISuperchainBridgeAdapter} from "src/bridge/adapters/interfaces/ISuperchainBridgeAdapter.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
import {InvoiceDataLib} from "src/bridge/InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {BridgeScenarioHelper} from "test/bridge/BridgeScenarioHelper.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/bridge/mocks/MockBridgeProtocols.sol";
import {MockCrossDomainMessenger, MockOptimismPortalReal} from "test/bridge/mocks/SuperchainProvenanceMocks.sol";
import {Types} from "@optimism/libraries/Types.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title SuperchainBridgeAdapterTest
/// @notice Protocol tests for the re-architected Superchain (Optimism canonical bridge) adapter (ADR 0012).
/// @dev Provenance model under test:
///      - L1 → L2 deposit completion is authenticated against the L2CrossDomainMessenger
///        (`msg.sender == l2Messenger` AND `xDomainMessageSender() == trustedRemoteAdapter[srcChainId]`),
///        then funds-and-releases.
///      - L2 → L1 withdrawals are proof-gated through the OptimismPortal using the REAL OP withdrawal hash;
///        the portal delivers the ETH to the adapter (the withdrawal target), then the base releases.
contract SuperchainBridgeAdapterTest is BridgeScenarioHelper {
    SuperchainBridgeAdapter public l1Adapter;
    MockL1StandardBridge public l1Bridge;
    MockL2StandardBridge public l2Bridge;
    MockOptimismPortalReal public optimismPortal;

    uint64 public constant L2_CHAIN_ID = 10; // Optimism mainnet

    // A trusted sibling adapter identity on the source (L1) chain, used for deposit-completion provenance.
    address public l1SiblingAdapter = makeAddr("l1SiblingAdapter");

    function setUp() public override {
        super.setUp();
        l1Bridge = new MockL1StandardBridge();
        l2Bridge = new MockL2StandardBridge();
        optimismPortal = new MockOptimismPortalReal();
        vm.deal(address(optimismPortal), 1000 ether);
        _setupL1Adapter();
        vm.label(address(l1Bridge), "MockL1StandardBridge");
        vm.label(address(l2Bridge), "MockL2StandardBridge");
        vm.label(address(optimismPortal), "MockOptimismPortalReal");
        vm.label(address(l1Adapter), "SuperchainBridgeAdapter(L1)");
    }

    function _setupL1Adapter() internal {
        vm.chainId(SOURCE_CHAIN_ID);
        address l1AdapterImpl = address(new SuperchainBridgeAdapter(address(0)));
        address payable l1AdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                l1AdapterImpl,
                abi.encodeCall(
                    SuperchainBridgeAdapter.initialize,
                    (admin, address(bridgeEscrow), address(0), address(1), address(0), "1.0.0")
                )
            ));
        l1Adapter = SuperchainBridgeAdapter(l1AdapterProxy);
        vm.startPrank(admin);
        l1Adapter.grantRole(MANAGER, manager);
        l1Adapter.setL1BridgeForL2(L2_CHAIN_ID, address(l1Bridge));
        l1Adapter.setOptimismPortalForL2(L2_CHAIN_ID, address(optimismPortal));
        l1Adapter.setL2TokenForL2(L2_CHAIN_ID, address(usdc), address(usdc));
        vm.stopPrank();
        _authorizeAdapter(address(l1Adapter));
    }

    /// @notice Deploys an L2 adapter bound to `destEscrow` with `l2Messenger_` as its messenger, and trusts
    ///         the L1 sibling adapter for the source chain (deposit-completion provenance).
    function _setupL2Adapter(BridgeEscrow destEscrow, address l2Messenger_) internal returns (SuperchainBridgeAdapter) {
        address l2AdapterImpl = address(new SuperchainBridgeAdapter(address(0)));
        address payable l2AdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                l2AdapterImpl,
                abi.encodeCall(
                    SuperchainBridgeAdapter.initialize,
                    (admin, address(destEscrow), address(l2Bridge), address(0), l2Messenger_, "1.0.0")
                )
            ));
        SuperchainBridgeAdapter destAdapter = SuperchainBridgeAdapter(l2AdapterProxy);
        vm.startPrank(admin);
        destAdapter.grantRole(MANAGER, manager);
        // Trust the L1 sibling adapter as the source sender for the source chain.
        destAdapter.setTrustedRemoteAdapter(SOURCE_CHAIN_ID, bytes32(uint256(uint160(l1SiblingAdapter))));
        destEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();
        return destAdapter;
    }

    // ============ L1 -> L2 Deposit Initiation Tests ============

    function test_bridge_l1ToL2_initiatesEthDeposit() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;
        vm.prank(admin);
        bridgeEscrow.registerAsset(WETH_SYMBOL, address(0));
        vm.deal(account, amount);

        uint256 nonce = bridgeEscrow.bridgeNonce(account);
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, L2_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount, nonce);

        vm.prank(account);
        bridgeEscrow.depositAndBridge{value: amount}(L2_CHAIN_ID, WETH_SYMBOL, amount, address(l1Adapter));

        assertEq(
            l1Adapter.getMessagePayload(invoiceData.invoiceId).length,
            InvoiceDataLib.encode(invoiceData).length,
            "payload stored"
        );
        assertEq(address(l1Bridge).balance, amount, "L1 bridge received ETH from adapter");
    }

    function test_bridge_l1ToL2_initiatesErc20Deposit() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1000 * 10 ** usdc.decimals();
        _approveToken(address(usdc), address(bridgeEscrow), amount);

        uint256 nonce = bridgeEscrow.bridgeNonce(account);
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, L2_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount, nonce);

        vm.prank(account);
        bridgeEscrow.depositAndBridge(L2_CHAIN_ID, USDC_SYMBOL, amount, address(l1Adapter));

        // Mock L1 bridge pulled tokens from adapter
        assertEq(usdc.balanceOf(address(l1Bridge)), amount, "L1 bridge received tokens");
        assertEq(
            l1Adapter.getMessagePayload(invoiceData.invoiceId).length,
            InvoiceDataLib.encode(invoiceData).length,
            "payload stored"
        );
    }

    /// @notice Option C: one L1 adapter routes a deposit through the L1 bridge of the *destination* L2.
    function test_bridge_l1ToL2_routesToPerL2Bridge() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint64 baseL2 = 8453;
        MockL1StandardBridge baseBridge = new MockL1StandardBridge();
        vm.prank(admin);
        l1Adapter.setL1BridgeForL2(baseL2, address(baseBridge));

        uint256 amount = 1000 * 10 ** usdc.decimals();
        _approveToken(address(usdc), address(bridgeEscrow), amount);
        vm.prank(account);
        bridgeEscrow.depositAndBridge(baseL2, USDC_SYMBOL, amount, address(l1Adapter));

        assertEq(usdc.balanceOf(address(baseBridge)), amount, "deposit routed to the destination L2's bridge");
        assertEq(usdc.balanceOf(address(l1Bridge)), 0, "the other L2's bridge is untouched");
    }

    /// @notice A deposit to an L2 with no configured L1 bridge reverts (no silent misroute).
    function test_bridge_l1ToL2_revertsForUnconfiguredDestChain() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1000 * 10 ** usdc.decimals();
        _approveToken(address(usdc), address(bridgeEscrow), amount);
        vm.prank(account);
        vm.expectRevert(); // InvalidL1Bridge — no bridge configured for chain 999
        bridgeEscrow.depositAndBridge(999, USDC_SYMBOL, amount, address(l1Adapter));
    }

    function test_bridge_revertsIfNotCalledByBridgeEscrow() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, L2_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        l1Adapter.bridge(messagePayload);
    }

    // ============ L1 -> L2 Deposit Completion (authenticated messenger path) ============

    /// @notice Builds an L2 environment with a real-relaying messenger and an invoice payload.
    function _setupL2DepositEnv()
        internal
        returns (
            BridgeEscrow destEscrow,
            SuperchainBridgeAdapter destAdapter,
            MockCrossDomainMessenger l2Messenger,
            bytes memory messagePayload,
            bytes32 invoiceHash
        )
    {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, L2_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        messagePayload = InvoiceDataLib.encode(invoiceData);
        invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));

        vm.chainId(L2_CHAIN_ID);
        destEscrow = _setupDestinationChainEscrow(L2_CHAIN_ID);
        l2Messenger = new MockCrossDomainMessenger();
        destAdapter = _setupL2Adapter(destEscrow, address(l2Messenger));

        // Canonical bridge delivered the bridged tokens to the L2 adapter (the recipient).
        usdc.mint(address(destAdapter), amount);
    }

    function test_completeDeposit_onL2_authenticatedMessenger_releases() public {
        (
            BridgeEscrow destEscrow,
            SuperchainBridgeAdapter destAdapter,
            MockCrossDomainMessenger l2Messenger,
            bytes memory messagePayload,
            bytes32 invoiceHash
        ) = _setupL2DepositEnv();

        uint256 amount = 1000 * 10 ** usdc.decimals();
        assertFalse(destEscrow.isInvoiceCompleted(invoiceHash), "invoice not completed yet");
        uint256 portfolioBefore = usdc.balanceOf(account);

        // The genuine L2 messenger relays the deposit message; source sender is the trusted L1 sibling.
        l2Messenger.relayMessage(
            address(destAdapter),
            l1SiblingAdapter,
            abi.encodeCall(SuperchainBridgeAdapter.completeDeposit, (messagePayload))
        );

        assertTrue(destEscrow.isInvoiceCompleted(invoiceHash), "invoice completed");
        assertEq(usdc.balanceOf(account) - portfolioBefore, amount, "account received tokens");
        assertEq(usdc.balanceOf(address(destAdapter)), 0, "adapter forwarded all tokens");
    }

    function test_completeDeposit_revertsIfCallerNotMessenger() public {
        (, SuperchainBridgeAdapter destAdapter,, bytes memory messagePayload,) = _setupL2DepositEnv();

        // Direct call (msg.sender != l2Messenger) must be rejected — provenance not established.
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        destAdapter.completeDeposit(messagePayload);
    }

    function test_completeDeposit_revertsIfUntrustedXDomainSender() public {
        (, SuperchainBridgeAdapter destAdapter, MockCrossDomainMessenger l2Messenger, bytes memory messagePayload,) =
            _setupL2DepositEnv();

        // Messenger is genuine, but the source sender is NOT the trusted sibling adapter.
        address attacker = makeAddr("attacker");
        vm.expectRevert(); // relayMessage bubbles the adapter's NotAuthorized revert
        l2Messenger.relayMessage(
            address(destAdapter), attacker, abi.encodeCall(SuperchainBridgeAdapter.completeDeposit, (messagePayload))
        );
    }

    function test_completeDeposit_revertsIfNoTrustedRemoteConfigured() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, L2_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(L2_CHAIN_ID);
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(L2_CHAIN_ID);
        MockCrossDomainMessenger l2Messenger = new MockCrossDomainMessenger();

        // Build an L2 adapter WITHOUT setting trustedRemoteAdapter.
        address l2AdapterImpl = address(new SuperchainBridgeAdapter(address(0)));
        address payable l2AdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                l2AdapterImpl,
                abi.encodeCall(
                    SuperchainBridgeAdapter.initialize,
                    (admin, address(destEscrow), address(l2Bridge), address(0), address(l2Messenger), "1.0.0")
                )
            ));
        SuperchainBridgeAdapter destAdapter = SuperchainBridgeAdapter(l2AdapterProxy);
        vm.prank(admin);
        destEscrow.authorizeAdapter(address(destAdapter));
        usdc.mint(address(destAdapter), amount);

        // No trusted remote => xDomainMessageSender can never match => revert.
        vm.expectRevert();
        l2Messenger.relayMessage(
            address(destAdapter),
            l1SiblingAdapter,
            abi.encodeCall(SuperchainBridgeAdapter.completeDeposit, (messagePayload))
        );
    }

    function test_completeDeposit_revertsForEmptyPayload() public {
        (, SuperchainBridgeAdapter destAdapter, MockCrossDomainMessenger l2Messenger,,) = _setupL2DepositEnv();

        vm.expectRevert();
        l2Messenger.relayMessage(
            address(destAdapter), l1SiblingAdapter, abi.encodeCall(SuperchainBridgeAdapter.completeDeposit, (""))
        );
    }

    // ============ L2 -> L1 Withdrawal Initiation Tests ============

    function test_bridge_l2ToL1_initiatesWithdrawal() public {
        vm.chainId(L2_CHAIN_ID);
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(L2_CHAIN_ID);
        MockCrossDomainMessenger l2Messenger = new MockCrossDomainMessenger();
        SuperchainBridgeAdapter destAdapter = _setupL2Adapter(destEscrow, address(l2Messenger));

        uint256 amount = 1000 * 10 ** usdc.decimals();
        _approveToken(address(usdc), address(destEscrow), amount);
        vm.prank(account);
        destEscrow.depositAndBridge(SOURCE_CHAIN_ID, USDC_SYMBOL, amount, address(destAdapter));

        assertEq(usdc.balanceOf(address(l2Bridge)), amount, "L2 bridge received tokens");
    }

    // ============ L2 -> L1 Withdrawal Completion (prove + finalize, real OP hash) ============

    /// @notice Builds an L1 adapter + escrow, and a withdrawal tx whose target is that adapter.
    function _deployL1WithdrawalAdapter(BridgeEscrow l1Escrow) internal returns (SuperchainBridgeAdapter) {
        address l1AdapterImpl = address(new SuperchainBridgeAdapter(address(0)));
        address payable l1AdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                l1AdapterImpl,
                abi.encodeCall(
                    SuperchainBridgeAdapter.initialize,
                    (admin, address(l1Escrow), address(0), address(1), address(0), "1.0.0")
                )
            ));
        SuperchainBridgeAdapter l1Ad = SuperchainBridgeAdapter(l1AdapterProxy);
        vm.startPrank(admin);
        l1Ad.grantRole(MANAGER, manager);
        l1Ad.setOptimismPortalForL2(L2_CHAIN_ID, address(optimismPortal));
        l1Escrow.authorizeAdapter(address(l1Ad));
        vm.stopPrank();
        return l1Ad;
    }

    function test_completeBridge_l2ToL1_finalizesAndReleases() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;

        BridgeEscrow l1Escrow = bridgeEscrow;
        vm.prank(admin);
        l1Escrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(l1Escrow);

        // Invoice destined for L1 (the account is authorized in escrow setUp).
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);
        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));

        // Real OP withdrawal that delivers `amount` ETH to the L1 adapter (the recipient).
        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 1, sender: address(l2Bridge), target: address(l1Ad), value: amount, gasLimit: 200000, data: ""
        });
        bytes32 realHash = l1Ad.hashWithdrawal(wtx);

        // Manager proves the withdrawal and correlates it to the invoice.
        vm.prank(manager);
        l1Ad.proveWithdrawal(
            L2_CHAIN_ID,
            wtx,
            0,
            Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0)),
            new bytes[](0),
            invoiceData.invoiceId
        );

        assertTrue(l1Ad.isWithdrawalProven(L2_CHAIN_ID, realHash), "withdrawal proven under real hash");
        assertEq(l1Ad.getInvoiceIdByWithdrawalHash(realHash), invoiceData.invoiceId, "invoice correlated");

        uint256 portfolioBefore = account.balance;

        // Manager completes: adapter finalizes (portal delivers ETH to adapter), base releases to account.
        vm.prank(manager);
        l1Ad.completeBridge(messagePayload, abi.encode(wtx));

        assertTrue(l1Escrow.isInvoiceCompleted(invoiceHash), "invoice completed");
        assertEq(account.balance - portfolioBefore, amount, "account received withdrawn ETH");
        assertEq(address(l1Ad).balance, 0, "adapter forwarded all ETH");
    }

    function test_completeBridge_l2ToL1_revertsIfNotProven() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;

        BridgeEscrow l1Escrow = bridgeEscrow;
        vm.prank(admin);
        l1Escrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(l1Escrow);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 7, sender: address(l2Bridge), target: address(l1Ad), value: amount, gasLimit: 200000, data: ""
        });

        // Not proven => completion must revert (never weaken: provenance is required).
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISuperchainBridgeAdapter.WithdrawalNotProven.selector));
        l1Ad.completeBridge(messagePayload, abi.encode(wtx));
    }

    function test_completeBridge_l2ToL1_revertsIfTargetNotAdapter() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;

        BridgeEscrow l1Escrow = bridgeEscrow;
        vm.prank(admin);
        l1Escrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(l1Escrow);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Withdrawal target is NOT the adapter — funds would not land on the adapter; must be rejected.
        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 2, sender: address(l2Bridge), target: account, value: amount, gasLimit: 200000, data: ""
        });
        // Prove it so the only failing check is the target binding.
        vm.prank(manager);
        l1Ad.proveWithdrawal(
            L2_CHAIN_ID,
            wtx,
            0,
            Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0)),
            new bytes[](0),
            invoiceData.invoiceId
        );

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISuperchainBridgeAdapter.InvalidWithdrawalFinalization.selector));
        l1Ad.completeBridge(messagePayload, abi.encode(wtx));
    }

    function test_completeBridge_revertsIfNotManager() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;
        BridgeEscrow l1Escrow = bridgeEscrow;
        vm.prank(admin);
        l1Escrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(l1Escrow);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);
        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 1, sender: address(l2Bridge), target: address(l1Ad), value: amount, gasLimit: 200000, data: ""
        });

        vm.prank(unauthorized);
        vm.expectRevert();
        l1Ad.completeBridge(messagePayload, abi.encode(wtx));
    }

    function test_completeBridge_l1_revertsForEmptyProtocolData() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;
        BridgeEscrow l1Escrow = bridgeEscrow;
        vm.prank(admin);
        l1Escrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(l1Escrow);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // On L1 a withdrawal completion requires the WithdrawalTransaction in protocolData.
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISuperchainBridgeAdapter.InvalidWithdrawalFinalization.selector));
        l1Ad.completeBridge(messagePayload, "");
    }

    function test_completeBridge_revertsForEmptyPayload() public {
        vm.chainId(L2_CHAIN_ID);
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(L2_CHAIN_ID);
        MockCrossDomainMessenger l2Messenger = new MockCrossDomainMessenger();
        SuperchainBridgeAdapter destAdapter = _setupL2Adapter(destEscrow, address(l2Messenger));

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(InvalidCompletionData.selector));
        destAdapter.completeBridge("", "");
    }

    // ============ Configuration Tests ============

    function test_setL1BridgeForL2_updatesBridge() public {
        vm.chainId(SOURCE_CHAIN_ID);
        MockL1StandardBridge newBridge = new MockL1StandardBridge();
        vm.prank(admin);
        l1Adapter.setL1BridgeForL2(L2_CHAIN_ID, address(newBridge));
        assertEq(address(l1Adapter.l1BridgeForL2(L2_CHAIN_ID)), address(newBridge));
    }

    function test_setL1BridgeForL2_revertsIfNotAdmin() public {
        vm.chainId(SOURCE_CHAIN_ID);
        vm.prank(unauthorized);
        vm.expectRevert();
        l1Adapter.setL1BridgeForL2(L2_CHAIN_ID, address(1));
    }

    function test_setDefaultL2GasLimit_updatesGasLimit() public {
        vm.prank(admin);
        l1Adapter.setDefaultL2GasLimit(300000);
        assertEq(l1Adapter.defaultL2GasLimit(), 300000);
    }

    function test_setTrustedRemoteAdapter_storesIdentity() public {
        vm.chainId(SOURCE_CHAIN_ID);
        bytes32 remote = bytes32(uint256(uint160(l1SiblingAdapter)));
        vm.prank(admin);
        l1Adapter.setTrustedRemoteAdapter(L2_CHAIN_ID, remote);
        assertEq(l1Adapter.trustedRemoteAdapter(L2_CHAIN_ID), remote);
    }

    function test_setTrustedRemoteAdapter_revertsIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        l1Adapter.setTrustedRemoteAdapter(L2_CHAIN_ID, bytes32(uint256(1)));
    }

    function test_hashWithdrawal_matchesRealOpHash() public view {
        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 42,
            sender: address(0xBEEF),
            target: address(0xCAFE),
            value: 5 ether,
            gasLimit: 100000,
            data: hex"1234"
        });
        bytes32 expected = keccak256(abi.encode(wtx.nonce, wtx.sender, wtx.target, wtx.value, wtx.gasLimit, wtx.data));
        assertEq(l1Adapter.hashWithdrawal(wtx), expected, "real OP withdrawal hash (abi.encode)");
    }

    function test_getMessagePayload_returnsStoredPayload() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1000 * 10 ** usdc.decimals();
        uint256 nonce = bridgeEscrow.bridgeNonce(account);
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, L2_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount, nonce);
        _approveToken(address(usdc), address(bridgeEscrow), amount);
        vm.prank(account);
        bridgeEscrow.depositAndBridge(L2_CHAIN_ID, USDC_SYMBOL, amount, address(l1Adapter));

        bytes memory stored = l1Adapter.getMessagePayload(invoiceData.invoiceId);
        assertEq(stored.length, InvoiceDataLib.encode(invoiceData).length);
        InvoiceDataLib.InvoiceData memory decoded = InvoiceDataLib.decode(stored);
        assertEq(decoded.invoiceId, invoiceData.invoiceId);
    }
}
