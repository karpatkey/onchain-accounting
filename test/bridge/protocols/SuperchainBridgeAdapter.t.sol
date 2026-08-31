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
import {
    MockCrossDomainMessenger,
    MockOptimismPortalReal,
    MockL1WithdrawalRelay
} from "test/bridge/mocks/SuperchainProvenanceMocks.sol";
import {Types} from "src/bridge/adapters/lib/OptimismTypes.sol";
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
    MockCrossDomainMessenger public l1Messenger;

    uint64 public constant L2_CHAIN_ID = 10; // Optimism mainnet

    // A trusted sibling adapter identity on the source (L1) chain, used for deposit-completion provenance.
    address public l1SiblingAdapter = makeAddr("l1SiblingAdapter");

    function setUp() public override {
        super.setUp();
        l1Bridge = new MockL1StandardBridge();
        l2Bridge = new MockL2StandardBridge();
        optimismPortal = new MockOptimismPortalReal();
        l1Messenger = new MockCrossDomainMessenger();
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
                    (
                        admin,
                        address(bridgeEscrow),
                        address(0),
                        address(l1Messenger),
                        address(0),
                        uint256(SOURCE_CHAIN_ID),
                        "1.0.0"
                    )
                )
            ));
        l1Adapter = SuperchainBridgeAdapter(l1AdapterProxy);
        vm.startPrank(admin);
        l1Adapter.grantRole(MANAGER, manager);
        l1Adapter.setL1BridgeForL2(L2_CHAIN_ID, address(l1Bridge));
        l1Adapter.setOptimismPortalForL2(L2_CHAIN_ID, address(optimismPortal));
        l1Adapter.setL1MessengerForL2(L2_CHAIN_ID, address(l1Messenger));
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
                    (
                        admin,
                        address(destEscrow),
                        address(l2Bridge),
                        address(0),
                        l2Messenger_,
                        uint256(SOURCE_CHAIN_ID),
                        "1.0.0"
                    )
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
            l1Adapter.getMessagePayload(bytes32(uint256(uint192(invoiceData.checksum24)))).length,
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
            l1Adapter.getMessagePayload(bytes32(uint256(uint192(invoiceData.checksum24)))).length,
            InvoiceDataLib.encode(invoiceData).length,
            "payload stored"
        );
    }

    /// @notice Option C: one L1 adapter routes a deposit through the L1 bridge of the *destination* L2.
    function test_bridge_l1ToL2_routesToPerL2Bridge() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint64 baseL2 = 8453;
        MockL1StandardBridge baseBridge = new MockL1StandardBridge();
        vm.startPrank(admin);
        l1Adapter.setL1BridgeForL2(baseL2, address(baseBridge));
        l1Adapter.setL2TokenForL2(baseL2, address(usdc), address(usdc));
        l1Adapter.setL1MessengerForL2(baseL2, address(l1Messenger));
        vm.stopPrank();

        uint256 amount = 1000 * 10 ** usdc.decimals();
        _approveToken(address(usdc), address(bridgeEscrow), amount);
        vm.prank(account);
        bridgeEscrow.depositAndBridge(baseL2, USDC_SYMBOL, amount, address(l1Adapter));

        assertEq(usdc.balanceOf(address(baseBridge)), amount, "deposit routed to the destination L2's bridge");
        assertEq(usdc.balanceOf(address(l1Bridge)), 0, "the other L2's bridge is untouched");
    }

    /// @notice Fail-closed: an ERC20 L1→L2 deposit to a destination L2 with no configured L2 token reverts, instead
    ///         of silently defaulting the L2 token to the (wrong) L1 address, which would lock the deposit (e.g. WETH).
    function test_bridge_l1ToL2_erc20_revertsIfL2TokenUnconfigured() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint64 baseL2 = 8453;
        MockL1StandardBridge baseBridge = new MockL1StandardBridge();
        // Bridge is configured for baseL2, but setL2TokenForL2(baseL2, usdc) is deliberately NOT called.
        vm.prank(admin);
        l1Adapter.setL1BridgeForL2(baseL2, address(baseBridge));

        uint256 amount = 1000 * 10 ** usdc.decimals();
        _approveToken(address(usdc), address(bridgeEscrow), amount);

        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISuperchainBridgeAdapter.L2TokenNotConfigured.selector, uint256(baseL2), address(usdc)
            )
        );
        bridgeEscrow.depositAndBridge(baseL2, USDC_SYMBOL, amount, address(l1Adapter));
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

        assertTrue(destEscrow.isInvoiceCompleted(invoiceHash), "invoice completed on record");
        // ADR 0027: the relay records custody and HOLDS; the account is paid only on MANAGER claim.
        assertEq(usdc.balanceOf(account), portfolioBefore, "account NOT paid on delivery");
        assertEq(usdc.balanceOf(address(destEscrow)), amount, "escrow holds the delivery");
        assertEq(destEscrow.getHeldBalanceForAsset(address(usdc), account), amount, "held for account");
        assertEq(usdc.balanceOf(address(destAdapter)), 0, "adapter forwarded all tokens to escrow");

        vm.prank(manager);
        destEscrow.claim(invoiceHash);
        assertEq(usdc.balanceOf(account) - portfolioBefore, amount, "account received tokens on claim");
        assertEq(destEscrow.getHeldBalanceForAsset(address(usdc), account), 0, "held cleared after claim");
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
                    (
                        admin,
                        address(destEscrow),
                        address(l2Bridge),
                        address(0),
                        address(l2Messenger),
                        uint256(SOURCE_CHAIN_ID),
                        "1.0.0"
                    )
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
                    (admin, address(l1Escrow), address(0), address(1), address(0), uint256(SOURCE_CHAIN_ID), "1.0.0")
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

        // Realistic OP withdrawal shape: a `L2StandardBridge.withdrawTo` withdrawal's portal `target` is the L1
        // messenger/bridge relay (NOT this adapter). The relay forwards the finalized ETH to the adapter as the
        // `withdrawTo` receiver. This is exactly the shape the old `target == address(this)` check wrongly rejected.
        MockL1WithdrawalRelay relay = new MockL1WithdrawalRelay();
        relay.setRecipient(payable(address(l1Ad)));
        vm.prank(admin);
        l1Ad.setL1MessengerForL2(L2_CHAIN_ID, address(relay)); // relay stands in for the L1CrossDomainMessenger
        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 1, sender: address(l2Bridge), target: address(relay), value: amount, gasLimit: 200000, data: ""
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
            InvoiceDataLib.encode(invoiceData)
        );

        assertTrue(l1Ad.isWithdrawalProven(L2_CHAIN_ID, realHash), "withdrawal proven under real hash");
        assertEq(l1Ad.getInvoiceIdByWithdrawalHash(realHash), invoiceData.invoiceId, "invoice correlated");

        uint256 portfolioBefore = account.balance;

        // Manager completes: adapter finalizes (portal delivers ETH to adapter), base records the delivery into
        // escrow custody (ADR 0027). The escrow HOLDS the ETH; a subsequent MANAGER claim pays the account.
        vm.prank(manager);
        l1Ad.completeBridge(messagePayload, abi.encode(wtx));

        assertTrue(l1Escrow.isInvoiceCompleted(invoiceHash), "invoice completed on record");
        assertEq(account.balance, portfolioBefore, "account NOT paid on record");
        assertEq(address(l1Escrow).balance, amount, "escrow holds the withdrawn ETH");
        assertEq(l1Escrow.getHeldBalanceForAsset(address(0), account), amount, "held for account");
        assertEq(address(l1Ad).balance, 0, "adapter forwarded all ETH to escrow");

        vm.prank(manager);
        l1Escrow.claim(invoiceHash);
        assertEq(account.balance - portfolioBefore, amount, "account received withdrawn ETH on claim");
        assertEq(l1Escrow.getHeldBalanceForAsset(address(0), account), 0, "held cleared after claim");
    }

    /// @notice `canFinalizeWithdrawal` must gate on the portal's finalization predicate (`checkWithdrawal`), NOT
    ///         merely on proven-ness. A proven-but-immature withdrawal (before the proof-maturity + dispute-game
    ///         air-gap) is NOT finalizable → false; once the portal's gate opens → true; once finalized → false
    ///         again. This is the regression for the "proven ⇏ finalizable" over-report (canFinalizeWithdrawal was
    ///         byte-identical to isWithdrawalProven, so it reported finalizable the instant the proof landed).
    function test_canFinalizeWithdrawal_gatesOnPortalCheckWithdrawal() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;
        vm.prank(admin);
        bridgeEscrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(bridgeEscrow);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        MockL1WithdrawalRelay relay = new MockL1WithdrawalRelay();
        relay.setRecipient(payable(address(l1Ad)));
        vm.prank(admin);
        l1Ad.setL1MessengerForL2(L2_CHAIN_ID, address(relay));
        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 1, sender: address(l2Bridge), target: address(relay), value: amount, gasLimit: 200000, data: ""
        });
        bytes32 realHash = l1Ad.hashWithdrawal(wtx);

        // Not proven yet → not finalizable.
        assertFalse(l1Ad.canFinalizeWithdrawal(L2_CHAIN_ID, realHash), "unproven: not finalizable");

        // Prove it. Proven ✓, but the maturity/air-gap gate has NOT opened → still NOT finalizable (the fix).
        vm.prank(manager);
        l1Ad.proveWithdrawal(
            L2_CHAIN_ID,
            wtx,
            0,
            Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0)),
            new bytes[](0),
            InvoiceDataLib.encode(invoiceData)
        );
        assertTrue(l1Ad.isWithdrawalProven(L2_CHAIN_ID, realHash), "proven");
        assertFalse(l1Ad.canFinalizeWithdrawal(L2_CHAIN_ID, realHash), "proven but immature: NOT finalizable");

        // Portal's gate opens (proof matured, game resolved DEFENDER_WINS, air-gap elapsed) → finalizable.
        optimismPortal.setFinalizable(realHash, true);
        assertTrue(l1Ad.canFinalizeWithdrawal(L2_CHAIN_ID, realHash), "gate open: finalizable");

        // Once finalized, a fresh finalize would revert → report not-finalizable so the caller settles instead.
        vm.prank(manager);
        l1Ad.completeBridge(InvoiceDataLib.encode(invoiceData), abi.encode(wtx));
        assertFalse(l1Ad.canFinalizeWithdrawal(L2_CHAIN_ID, realHash), "already finalized: not finalizable");
    }

    /// @notice RE11-M-01: a permissionless portal front-run may finalize a withdrawal on the portal before the
    ///         adapter settles it. completeBridge's skip branch still settles such a withdrawal, so
    ///         `canFinalizeWithdrawal` MUST report true for it — gating it out on `!finalizedWithdrawals` would
    ///         strand exactly the withdrawal RE3-H-01's skip branch exists to settle (RE3-H-01 at the tooling
    ///         layer). It flips to false only once the adapter has settled it (one-shot `_settledWithdrawals`).
    function test_canFinalizeWithdrawal_trueWhenFrontRunFinalizedButNotYetSettled() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;
        BridgeEscrow l1Escrow = bridgeEscrow;
        vm.prank(admin);
        l1Escrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(l1Escrow);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);
        MockL1WithdrawalRelay relay = new MockL1WithdrawalRelay();
        relay.setRecipient(payable(address(l1Ad)));
        vm.prank(admin);
        l1Ad.setL1MessengerForL2(L2_CHAIN_ID, address(relay));
        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 1, sender: address(l2Bridge), target: address(relay), value: amount, gasLimit: 200000, data: ""
        });
        Types.OutputRootProof memory emptyProof = Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0));
        bytes32 realHash = l1Ad.hashWithdrawal(wtx);

        // Adapter proves (it is the proof submitter that completeBridge's finalize checks).
        vm.prank(manager);
        l1Ad.proveWithdrawal(L2_CHAIN_ID, wtx, 0, emptyProof, new bytes[](0), messagePayload);

        // A third party front-runs the permissionless portal finalize: the portal is marked finalized, but the
        // adapter has NOT settled the invoice yet.
        address griefer = makeAddr("griefer");
        vm.startPrank(griefer);
        optimismPortal.proveWithdrawalTransaction(wtx, 0, emptyProof, new bytes[](0));
        optimismPortal.finalizeWithdrawalTransaction(wtx);
        vm.stopPrank();
        assertTrue(optimismPortal.finalizedWithdrawals(realHash), "portal finalized by front-run");
        vm.deal(address(l1Ad), amount); // the finalized relay delivered the ETH to the adapter
        // forge-lint: disable-next-line(asm-keccak256)
        relay.setSuccessfulMessage(keccak256(wtx.data), true);

        // THE REGRESSION GUARD: canFinalizeWithdrawal must STILL be true — completeBridge's skip branch can settle
        // it. The buggy gate (`if (finalizedWithdrawals) return false`) returns false here → the settler strands it.
        assertTrue(
            l1Ad.canFinalizeWithdrawal(L2_CHAIN_ID, realHash),
            "front-run-finalized but unsettled: still settleable (must NOT strand)"
        );

        // Settle it via completeBridge's skip branch; afterwards it flips to false (one-shot `_settledWithdrawals`).
        vm.prank(manager);
        l1Ad.completeBridge(messagePayload, abi.encode(wtx));
        assertFalse(l1Ad.canFinalizeWithdrawal(L2_CHAIN_ID, realHash), "after settle: not finalizable");
    }

    /// @notice ADR 0028: `proveWithdrawal` stores the full `WithdrawalTransaction`, readable back for finalize
    ///         without an L2 log re-read. Round-trips every field (esp. the dynamic `data` — the reason the getter
    ///         is explicit rather than a `public` auto-getter, which would silently drop it).
    function test_getWithdrawalTransaction_roundTripAfterProve() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;
        vm.prank(admin);
        bridgeEscrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(bridgeEscrow);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));

        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 7,
            sender: address(l2Bridge),
            target: address(l1Ad),
            value: amount,
            gasLimit: 200000,
            data: hex"c0ffee"
        });

        // Before prove: unknown invoice hash → zero-valued struct.
        Types.WithdrawalTransaction memory none = l1Ad.getWithdrawalTransaction(invoiceHash);
        assertEq(none.nonce, 0, "no stored wtx before prove");
        assertEq(none.data.length, 0, "no stored data before prove");

        vm.prank(manager);
        l1Ad.proveWithdrawal(
            L2_CHAIN_ID,
            wtx,
            0,
            Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0)),
            new bytes[](0),
            InvoiceDataLib.encode(invoiceData)
        );

        Types.WithdrawalTransaction memory got = l1Ad.getWithdrawalTransaction(invoiceHash);
        assertEq(got.nonce, wtx.nonce, "nonce round-trips");
        assertEq(got.sender, wtx.sender, "sender round-trips");
        assertEq(got.target, wtx.target, "target round-trips");
        assertEq(got.value, wtx.value, "value round-trips");
        assertEq(got.gasLimit, wtx.gasLimit, "gasLimit round-trips");
        assertEq(got.data, wtx.data, "dynamic data round-trips (why the getter is explicit, not auto)");
    }

    /// @notice ADR 0028 regression: two SAME-LANE withdrawals (same route invoiceId, distinct per-op invoice
    ///         hashes) both proven in the window must each keep their OWN stored WithdrawalTransaction. Keying the
    ///         store by invoiceId (the bug Copilot caught) would let the second prove overwrite the first's tx.
    function test_getWithdrawalTransaction_sameLaneWithdrawalsDoNotCollide() public {
        vm.chainId(SOURCE_CHAIN_ID);
        vm.prank(admin);
        bridgeEscrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(bridgeEscrow);

        // Same lane (src/dst/account/symbol → same invoiceId) but distinct amounts → distinct invoice hashes.
        InvoiceDataLib.InvoiceData memory inv1 =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, 1 ether);
        InvoiceDataLib.InvoiceData memory inv2 =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, 2 ether);
        assertEq(inv1.invoiceId, inv2.invoiceId, "same lane => same route invoiceId");
        bytes32 hash1 = bytes32(uint256(uint192(inv1.checksum24)));
        bytes32 hash2 = bytes32(uint256(uint192(inv2.checksum24)));
        assertTrue(hash1 != hash2, "distinct operations => distinct invoice hashes");

        Types.WithdrawalTransaction memory wtx1 = Types.WithdrawalTransaction({
            nonce: 1, sender: address(l2Bridge), target: address(l1Ad), value: 1 ether, gasLimit: 200000, data: hex"aa"
        });
        Types.WithdrawalTransaction memory wtx2 = Types.WithdrawalTransaction({
            nonce: 2,
            sender: address(l2Bridge),
            target: address(l1Ad),
            value: 2 ether,
            gasLimit: 200000,
            data: hex"bbbb"
        });

        Types.OutputRootProof memory emptyProof = Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0));
        vm.startPrank(manager);
        l1Ad.proveWithdrawal(L2_CHAIN_ID, wtx1, 0, emptyProof, new bytes[](0), InvoiceDataLib.encode(inv1));
        l1Ad.proveWithdrawal(L2_CHAIN_ID, wtx2, 0, emptyProof, new bytes[](0), InvoiceDataLib.encode(inv2));
        vm.stopPrank();

        // Each per-op hash keeps its own tx — the second prove did NOT overwrite the first.
        assertEq(l1Ad.getWithdrawalTransaction(hash1).value, 1 ether, "first withdrawal tx intact");
        assertEq(l1Ad.getWithdrawalTransaction(hash1).data, hex"aa", "first data intact");
        assertEq(l1Ad.getWithdrawalTransaction(hash2).value, 2 ether, "second withdrawal tx stored");
        assertEq(l1Ad.getWithdrawalTransaction(hash2).data, hex"bbbb", "second data stored");
    }

    /// @notice One withdrawal settles exactly one invoice. The SAME proven+finalized withdrawal filed under two invoice
    ///         hashes (a MANAGER mis-derivation) must not settle both — the second completion reverts on the one-shot
    ///         consumption guard even with the messenger's PERMANENT `successfulMessages` flag true and stray adapter
    ///         funds covering the amount. This makes the already-finalized skip-branch as reuse-proof as the normal
    ///         branch (where the portal reverts on a second finalize). (Super-review Medium.)
    function test_completeBridge_l2ToL1_revertsOnWithdrawalReuseAcrossInvoices() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;
        BridgeEscrow l1Escrow = bridgeEscrow;
        vm.prank(admin);
        l1Escrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(l1Escrow);

        // Two DISTINCT invoices (distinct nonces => distinct invoice hashes), ONE physical withdrawal filed under both.
        InvoiceDataLib.InvoiceData memory invA =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount, 1);
        InvoiceDataLib.InvoiceData memory invB =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount, 2);
        bytes32 hashA = bytes32(uint256(uint192(invA.checksum24)));
        bytes32 hashB = bytes32(uint256(uint192(invB.checksum24)));

        MockL1WithdrawalRelay relay = new MockL1WithdrawalRelay();
        relay.setRecipient(payable(address(l1Ad)));
        vm.prank(admin);
        l1Ad.setL1MessengerForL2(L2_CHAIN_ID, address(relay)); // relay stands in for the L1CrossDomainMessenger
        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 1, sender: address(l2Bridge), target: address(relay), value: amount, gasLimit: 200000, data: ""
        });
        Types.OutputRootProof memory emptyProof = Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0));
        vm.startPrank(manager);
        l1Ad.proveWithdrawal(L2_CHAIN_ID, wtx, 0, emptyProof, new bytes[](0), InvoiceDataLib.encode(invA));
        l1Ad.proveWithdrawal(L2_CHAIN_ID, wtx, 0, emptyProof, new bytes[](0), InvoiceDataLib.encode(invB));
        vm.stopPrank();

        // Complete A: normal branch finalizes + delivers `amount`, settling A and consuming the withdrawal.
        vm.prank(manager);
        l1Ad.completeBridge(InvoiceDataLib.encode(invA), "");
        assertTrue(l1Escrow.isInvoiceCompleted(hashA), "A settled");

        // B: the withdrawal is now finalized (skip-branch), successfulMessages is permanently true, and stray funds
        // cover `amount` — only the consumption guard stops a second settlement.
        // forge-lint: disable-next-line(asm-keccak256)
        relay.setSuccessfulMessage(keccak256(wtx.data), true);
        vm.deal(address(l1Ad), amount);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISuperchainBridgeAdapter.InvalidWithdrawalFinalization.selector));
        l1Ad.completeBridge(InvoiceDataLib.encode(invB), "");
    }

    /// @notice proveWithdrawal rejects zero invoice keys atomically (Copilot): a zero invoiceHash would prove on the
    ///         portal but store no WithdrawalTransaction, defeating the ADR 0028 queryable flow and only surfacing as
    ///         WithdrawalNotProven at completion. Fail fast at prove instead.
    /// @notice proveWithdrawal now DERIVES both invoice keys on-chain from the payload (Copilot), so an operator can't
    ///         supply a mismatched/typo'd key that overwrites another op's stored tx. An empty payload reverts
    ///         InvalidWithdrawalProof (the only zero-key case left reachable via the API).
    function test_proveWithdrawal_revertsOnEmptyPayload() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;
        vm.prank(admin);
        bridgeEscrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(bridgeEscrow);
        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 1, sender: address(l2Bridge), target: address(l1Ad), value: amount, gasLimit: 200000, data: ""
        });
        Types.OutputRootProof memory emptyProof = Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISuperchainBridgeAdapter.InvalidWithdrawalProof.selector));
        l1Ad.proveWithdrawal(L2_CHAIN_ID, wtx, 0, emptyProof, new bytes[](0), "");
    }

    /// @notice Deriving the storage key on-chain from the payload's `checksum24` is not enough on its own: the checksum
    ///         must also be validated against the payload's OWN (invoiceId, amount, timestamp, nonce), or an operator
    ///         could borrow another live operation's checksum (hence its `invoiceHash` key) under a different payload
    ///         and overwrite that operation's stored WithdrawalTransaction. proveWithdrawal now recomputes + checks the
    ///         checksum (mirroring recordDelivery), so a forged/inconsistent payload reverts InvalidWithdrawalProof.
    ///         (Copilot review.)
    function test_proveWithdrawal_revertsOnForgedChecksum() public {
        vm.chainId(SOURCE_CHAIN_ID);
        vm.prank(admin);
        bridgeEscrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(bridgeEscrow);
        Types.OutputRootProof memory emptyProof = Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0));

        // Prove a GENUINE victim operation first (self-consistent checksum) so its WithdrawalTransaction is stored.
        InvoiceDataLib.InvoiceData memory victim =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, 1 ether, 1);
        bytes32 victimHash = bytes32(uint256(uint192(victim.checksum24)));
        Types.WithdrawalTransaction memory victimTx = Types.WithdrawalTransaction({
            nonce: 1, sender: address(l2Bridge), target: address(l1Ad), value: 1 ether, gasLimit: 200000, data: hex"aa"
        });
        vm.prank(manager);
        l1Ad.proveWithdrawal(L2_CHAIN_ID, victimTx, 0, emptyProof, new bytes[](0), InvoiceDataLib.encode(victim));

        // Forge: a payload with a DIFFERENT invoiceId (different account => distinct route id, but the SAME source
        // chain so it still passes the >>232 source-chain check) that BORROWS the victim's checksum — so it derives the
        // victim's storage key. Every guard except the checksum passes; only the checksum guard prevents the overwrite.
        InvoiceDataLib.InvoiceData memory forged =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, address(0xBEEF), WETH_SYMBOL_BYTES6, 2 ether, 2);
        assertTrue(forged.invoiceId != victim.invoiceId, "forged carries a distinct route invoiceId");
        forged.checksum24 = victim.checksum24; // borrow the victim's checksum/key
        assertEq(bytes32(uint256(uint192(forged.checksum24))), victimHash, "forged derives the victim's storage key");

        Types.WithdrawalTransaction memory forgedTx = Types.WithdrawalTransaction({
            nonce: 9, sender: address(l2Bridge), target: address(l1Ad), value: 2 ether, gasLimit: 200000, data: hex"cc"
        });
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISuperchainBridgeAdapter.InvalidWithdrawalProof.selector));
        l1Ad.proveWithdrawal(L2_CHAIN_ID, forgedTx, 0, emptyProof, new bytes[](0), InvoiceDataLib.encode(forged));

        // The guard held: the victim's stored tx is intact — the forged payload did NOT overwrite it.
        assertEq(l1Ad.getWithdrawalTransaction(victimHash).value, 1 ether, "victim tx value intact");
        assertEq(l1Ad.getWithdrawalTransaction(victimHash).data, hex"aa", "victim tx data intact");
    }

    /// @notice prove-time mirrors recordDelivery's amount!=0 guard: a self-consistent zero-amount payload can never
    ///         complete (recordDelivery rejects amount==0), so storing a WithdrawalTransaction under its key is pure
    ///         un-completable dust — proveWithdrawal rejects it up front. (claude-review.)
    function test_proveWithdrawal_revertsOnZeroAmount() public {
        vm.chainId(SOURCE_CHAIN_ID);
        vm.prank(admin);
        bridgeEscrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(bridgeEscrow);
        Types.OutputRootProof memory emptyProof = Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0));

        // A payload with amount == 0 but an otherwise self-consistent checksum (so it clears the checksum guard).
        InvoiceDataLib.InvoiceData memory zero =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, 0, 1);
        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 1, sender: address(l2Bridge), target: address(l1Ad), value: 0, gasLimit: 200000, data: hex"aa"
        });
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISuperchainBridgeAdapter.InvalidWithdrawalProof.selector));
        l1Ad.proveWithdrawal(L2_CHAIN_ID, wtx, 0, emptyProof, new bytes[](0), InvoiceDataLib.encode(zero));
    }

    /// @notice The stored WithdrawalTransaction is keyed by the ON-CHAIN-derived invoice hash, so two same-lane ops
    ///         proven with their own payloads keep separate stored txs — no operator can overwrite one with the other
    ///         (the mismatched-key overwrite class is gone since keys are derived, not supplied).
    function test_proveWithdrawal_derivedKeys_noCrossOpOverwrite() public {
        vm.chainId(SOURCE_CHAIN_ID);
        vm.prank(admin);
        bridgeEscrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(bridgeEscrow);
        // Same lane (same invoiceId), distinct amounts → distinct derived invoice hashes.
        InvoiceDataLib.InvoiceData memory invA =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, 1 ether);
        InvoiceDataLib.InvoiceData memory invB =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, 2 ether);
        bytes32 hashA = bytes32(uint256(uint192(invA.checksum24)));
        bytes32 hashB = bytes32(uint256(uint192(invB.checksum24)));
        Types.WithdrawalTransaction memory wtxA = Types.WithdrawalTransaction({
            nonce: 1, sender: address(l2Bridge), target: address(l1Ad), value: 1 ether, gasLimit: 200000, data: hex"aa"
        });
        Types.WithdrawalTransaction memory wtxB = Types.WithdrawalTransaction({
            nonce: 2,
            sender: address(l2Bridge),
            target: address(l1Ad),
            value: 2 ether,
            gasLimit: 200000,
            data: hex"bbbb"
        });
        Types.OutputRootProof memory emptyProof = Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0));
        vm.startPrank(manager);
        l1Ad.proveWithdrawal(L2_CHAIN_ID, wtxA, 0, emptyProof, new bytes[](0), InvoiceDataLib.encode(invA));
        l1Ad.proveWithdrawal(L2_CHAIN_ID, wtxB, 0, emptyProof, new bytes[](0), InvoiceDataLib.encode(invB));
        vm.stopPrank();
        // Each op's payload derived its own key; neither overwrote the other.
        assertEq(l1Ad.getWithdrawalTransaction(hashA).data, hex"aa", "op A's tx intact");
        assertEq(l1Ad.getWithdrawalTransaction(hashB).data, hex"bbbb", "op B's tx intact");
    }

    /// @notice Config-coupling (super-review Low): the skip-branch binds the withdrawal target to `l1MessengerForL2` for
    ///         the SOURCE L2, so a portal-only config (messenger left unwired) makes a front-run-finalized withdrawal
    ///         revert `MessengerNotConfigured` at completion — a clear error, no fund loss (funds recoverable via MANAGER).
    function test_completeBridge_l2ToL1_revertsIfSourceMessengerUnconfigured() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;
        BridgeEscrow l1Escrow = bridgeEscrow;
        vm.prank(admin);
        l1Escrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(l1Escrow); // portal wired, messenger deliberately NOT

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        MockL1WithdrawalRelay relay = new MockL1WithdrawalRelay();
        relay.setRecipient(payable(address(l1Ad)));
        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 1, sender: address(l2Bridge), target: address(relay), value: amount, gasLimit: 200000, data: ""
        });
        Types.OutputRootProof memory emptyProof = Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0));
        vm.prank(manager);
        l1Ad.proveWithdrawal(L2_CHAIN_ID, wtx, 0, emptyProof, new bytes[](0), InvoiceDataLib.encode(invoiceData));

        // Front-run finalize delivers the funds; the source messenger is unwired, so completion fails loudly.
        address griefer = makeAddr("griefer");
        vm.startPrank(griefer);
        optimismPortal.proveWithdrawalTransaction(wtx, 0, emptyProof, new bytes[](0));
        optimismPortal.finalizeWithdrawalTransaction(wtx);
        vm.stopPrank();

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(ISuperchainBridgeAdapter.MessengerNotConfigured.selector, uint256(L2_CHAIN_ID))
        );
        l1Ad.completeBridge(InvoiceDataLib.encode(invoiceData), "");
    }

    /// @notice Skip-branch delivered-amount binding (super-review Low): a front-run-finalized withdrawal that delivered
    ///         LESS than the invoice amount must not settle from stray/sibling funds. For ETH the delivered amount is
    ///         `withdrawalTx.value`, so `value < amount` reverts even though the adapter's absolute balance covers `amount`.
    function test_completeBridge_l2ToL1_skipBranch_revertsOnUnderDeliveredValue() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 invoiceAmount = 1 ether;
        uint256 delivered = 0.5 ether;
        BridgeEscrow l1Escrow = bridgeEscrow;
        vm.prank(admin);
        l1Escrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(l1Escrow);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, invoiceAmount);
        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));

        MockL1WithdrawalRelay relay = new MockL1WithdrawalRelay();
        relay.setRecipient(payable(address(l1Ad)));
        vm.prank(admin);
        l1Ad.setL1MessengerForL2(L2_CHAIN_ID, address(relay));
        // A withdrawal delivering only `delivered` (< invoiceAmount) mis-filed under the 1-ETH invoice's hash.
        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 1, sender: address(l2Bridge), target: address(relay), value: delivered, gasLimit: 200000, data: ""
        });
        Types.OutputRootProof memory emptyProof = Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0));
        vm.prank(manager);
        l1Ad.proveWithdrawal(L2_CHAIN_ID, wtx, 0, emptyProof, new bytes[](0), InvoiceDataLib.encode(invoiceData));

        // Front-run finalize delivers `delivered`; top up stray funds so the ABSOLUTE balance covers the full amount.
        address griefer = makeAddr("griefer");
        vm.startPrank(griefer);
        optimismPortal.proveWithdrawalTransaction(wtx, 0, emptyProof, new bytes[](0));
        optimismPortal.finalizeWithdrawalTransaction(wtx);
        vm.stopPrank();
        vm.deal(address(l1Ad), invoiceAmount); // delivered + stray == invoiceAmount (absolute check would pass)
        // forge-lint: disable-next-line(asm-keccak256)
        relay.setSuccessfulMessage(keccak256(wtx.data), true);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISuperchainBridgeAdapter.InvalidWithdrawalFinalization.selector));
        l1Ad.completeBridge(InvoiceDataLib.encode(invoiceData), "");
    }

    /// @notice RE5-L-01: a deploy-config role flip — an L2 deployment mis-setting `l1ChainId_ == block.chainid` — must
    ///         fail at init rather than silently run in L1 mode. Supplying L2-shaped args (l2Bridge) in L1 mode reverts.
    function test_initialize_revertsL1ModeWithL2Contracts() public {
        vm.chainId(L2_CHAIN_ID);
        address impl = address(new SuperchainBridgeAdapter(address(0)));
        vm.expectRevert(abi.encodeWithSelector(ISuperchainBridgeAdapter.InvalidChainId.selector));
        UnsafeUpgrades.deployUUPSProxy(
            impl,
            abi.encodeCall(
                SuperchainBridgeAdapter.initialize,
                (
                    admin,
                    address(bridgeEscrow),
                    address(l2Bridge),
                    address(l1Messenger),
                    address(0),
                    uint256(L2_CHAIN_ID),
                    "1.0.0"
                )
            )
        );
    }

    /// @notice proveWithdrawal reverts when the supplied l2ChainId disagrees with the invoice's encoded source
    ///         chain id — the operator guard that stops proving on the wrong L2 portal (which would strand finalize).
    function test_proveWithdrawal_revertsOnChainIdMismatch() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;

        BridgeEscrow l1Escrow = bridgeEscrow;
        vm.prank(admin);
        l1Escrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(l1Escrow);

        // Invoice encodes sourceChainId = L2_CHAIN_ID.
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);

        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 1, sender: address(l2Bridge), target: address(l1Ad), value: amount, gasLimit: 200000, data: ""
        });

        // Prove against a DIFFERENT L2 chain id than the invoice encodes → revert before touching the portal.
        uint256 wrongL2 = uint256(L2_CHAIN_ID) + 1;
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISuperchainBridgeAdapter.WithdrawalChainIdMismatch.selector, wrongL2, uint256(L2_CHAIN_ID)
            )
        );
        l1Ad.proveWithdrawal(
            wrongL2,
            wtx,
            0,
            Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0)),
            new bytes[](0),
            InvoiceDataLib.encode(invoiceData)
        );
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

    /// @notice A withdrawal whose finalize does not actually credit this adapter `amount` ETH must be rejected by the
    ///         balance-delta guard — here the ETH is delivered elsewhere (`target == account`), so the adapter's
    ///         native balance does not rise and finalize reverts (funds roll back with the tx).
    function test_completeBridge_l2ToL1_revertsIfAdapterNotFunded() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;

        BridgeEscrow l1Escrow = bridgeEscrow;
        vm.prank(admin);
        l1Escrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(l1Escrow);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Finalize delivers the ETH to `account`, not to the adapter → the adapter's balance delta is 0 < amount.
        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 2, sender: address(l2Bridge), target: account, value: amount, gasLimit: 200000, data: ""
        });
        // Prove it so the only failing check is the balance-delta guard.
        vm.prank(manager);
        l1Ad.proveWithdrawal(
            L2_CHAIN_ID,
            wtx,
            0,
            Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0)),
            new bytes[](0),
            InvoiceDataLib.encode(invoiceData)
        );

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISuperchainBridgeAdapter.InvalidWithdrawalFinalization.selector));
        l1Ad.completeBridge(messagePayload, abi.encode(wtx));
    }

    /// @notice RE3-H-01: the OptimismPortal finalize is PERMISSIONLESS, so a third party can front-run it. The
    ///         adapter's completeBridge must stay idempotent — skip the re-finalize (which would revert "already
    ///         finalized") and still record the delivery from the funds the front-run finalize delivered.
    function test_completeBridge_l2ToL1_idempotentIfAlreadyFinalized() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;
        BridgeEscrow l1Escrow = bridgeEscrow;
        vm.prank(admin);
        l1Escrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(l1Escrow);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);
        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));

        MockL1WithdrawalRelay relay = new MockL1WithdrawalRelay();
        relay.setRecipient(payable(address(l1Ad)));
        vm.prank(admin);
        l1Ad.setL1MessengerForL2(L2_CHAIN_ID, address(relay)); // relay stands in for the L1CrossDomainMessenger
        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 1, sender: address(l2Bridge), target: address(relay), value: amount, gasLimit: 200000, data: ""
        });
        vm.prank(manager);
        l1Ad.proveWithdrawal(
            L2_CHAIN_ID,
            wtx,
            0,
            Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0)),
            new bytes[](0),
            InvoiceDataLib.encode(invoiceData)
        );

        // Front-run: a third party proves (as itself — fault-proof portals key proofs by submitter) then finalizes
        // on the permissionless portal → funds land on the adapter via the relay. The adapter also proved it above,
        // so the adapter's own proven-check still passes.
        address griefer = makeAddr("griefer");
        vm.startPrank(griefer);
        optimismPortal.proveWithdrawalTransaction(
            wtx, 0, Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0)), new bytes[](0)
        );
        optimismPortal.finalizeWithdrawalTransaction(wtx);
        vm.stopPrank();
        assertEq(address(l1Ad).balance, amount, "front-run finalize delivered ETH to the adapter");

        // RE4-M-01: the finalize skip-branch confirms the withdrawal's inner relay was delivered before settling.
        // The relay (the withdrawal `target`) stands in for the L1CrossDomainMessenger's successfulMessages.
        // forge-lint: disable-next-line(asm-keccak256)
        relay.setSuccessfulMessage(keccak256(wtx.data), true);

        // completeBridge must still succeed (skip the re-finalize) and record the delivery.
        uint256 portfolioBefore = account.balance;
        vm.prank(manager);
        l1Ad.completeBridge(messagePayload, "");

        assertTrue(l1Escrow.isInvoiceCompleted(invoiceHash), "invoice completed despite the front-run finalize");
        assertEq(address(l1Escrow).balance, amount, "escrow holds the withdrawn ETH");
        assertEq(address(l1Ad).balance, 0, "adapter forwarded all ETH to escrow");
        assertEq(account.balance, portfolioBefore, "account NOT paid until claim");
    }

    /// @notice RE4-M-01: a front-run finalize whose inner relay FAILED (funds not delivered) must NOT let completeBridge
    ///         settle the invoice from stray/donated funds on the shared adapter. The skip-branch requires the
    ///         messenger to report the inner message delivered; here it did not, so completion reverts even though the
    ///         adapter's absolute balance covers `amount`.
    function test_completeBridge_l2ToL1_revertsIfFrontRunFinalizeDidNotDeliver() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;
        BridgeEscrow l1Escrow = bridgeEscrow;
        vm.prank(admin);
        l1Escrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(l1Escrow);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);
        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));

        // Relay does NOT forward to the adapter (simulates a failed inner relay); the portal still marks finalized.
        MockL1WithdrawalRelay relay = new MockL1WithdrawalRelay();
        relay.setRecipient(payable(address(0)));
        vm.prank(admin);
        l1Ad.setL1MessengerForL2(L2_CHAIN_ID, address(relay)); // relay stands in for the L1CrossDomainMessenger
        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 1, sender: address(l2Bridge), target: address(relay), value: amount, gasLimit: 200000, data: ""
        });
        vm.prank(manager);
        l1Ad.proveWithdrawal(
            L2_CHAIN_ID,
            wtx,
            0,
            Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0)),
            new bytes[](0),
            InvoiceDataLib.encode(invoiceData)
        );

        // Front-run finalize (griefer proves + finalizes). Funds land on the relay, NOT the adapter.
        address griefer = makeAddr("griefer");
        vm.startPrank(griefer);
        optimismPortal.proveWithdrawalTransaction(
            wtx, 0, Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0)), new bytes[](0)
        );
        optimismPortal.finalizeWithdrawalTransaction(wtx);
        vm.stopPrank();

        // Donate stray ETH to the adapter so a bare absolute-balance check WOULD pass — the guard must still block it.
        vm.deal(address(l1Ad), amount);
        // The messenger reports the inner message NOT delivered (successfulMessages defaults to false).

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISuperchainBridgeAdapter.InvalidWithdrawalFinalization.selector));
        l1Ad.completeBridge(messagePayload, "");
    }

    /// @notice RE3-M-02: the ERC20 finalize binds the amount by a balance DELTA (like ETH), not the adapter's
    ///         absolute balance — stray/donated tokens must not let a finalize that delivered nothing record a delivery.
    function test_completeBridge_l2ToL1_erc20_deltaGuard() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1000 * 10 ** usdc.decimals();
        BridgeEscrow l1Escrow = bridgeEscrow;
        vm.prank(admin);
        l1Escrow.registerAsset(USDC_SYMBOL, address(usdc));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(l1Escrow);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);
        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));

        // ERC20 withdrawal shape: value 0 (no ETH). The portal mock delivers no tokens to the adapter on finalize.
        // Non-zero target keeps the "stored" sentinel valid.
        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 1, sender: address(l2Bridge), target: address(l1Bridge), value: 0, gasLimit: 200000, data: hex"aa"
        });
        vm.prank(manager);
        l1Ad.proveWithdrawal(
            L2_CHAIN_ID,
            wtx,
            0,
            Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0)),
            new bytes[](0),
            InvoiceDataLib.encode(invoiceData)
        );

        // Adapter already holds `amount` USDC from an unrelated source. Absolute balance would pass; the delta guard
        // must reject because THIS finalize delivered nothing.
        usdc.mint(address(l1Ad), amount);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISuperchainBridgeAdapter.InvalidWithdrawalFinalization.selector));
        l1Ad.completeBridge(messagePayload, "");
    }

    /// @notice RE3-M-03: an L1→L2 deposit now sends an AUTHENTICATED `completeDeposit` message to the L2 sibling via
    ///         the L1CrossDomainMessenger (the previously-dead trust-minimized path). Relaying that captured message
    ///         through the genuine L2 messenger (trusted sibling sender) records the delivery on the L2 escrow.
    function test_bridge_l1ToL2_sendsAuthenticatedCompletionMessage() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1000 * 10 ** usdc.decimals();

        // L1 deposit → the adapter enqueues the authenticated completion message on the messenger.
        _approveToken(address(usdc), address(bridgeEscrow), amount);
        vm.prank(account);
        bridgeEscrow.depositAndBridge(L2_CHAIN_ID, USDC_SYMBOL, amount, address(l1Adapter));

        assertEq(l1Messenger.lastMessageTarget(), address(l1Adapter), "completion message targets the sibling adapter");
        bytes memory sentMsg = l1Messenger.lastMessage();
        assertEq(bytes4(sentMsg), SuperchainBridgeAdapter.completeDeposit.selector, "message is a completeDeposit call");

        // L2 side: escrow + sibling adapter (trusts the L1 sibling), funded by the canonical bridge.
        bytes memory payload = _decodeCompleteDepositPayload(sentMsg);
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(payload);
        bytes32 invoiceHash = bytes32(uint256(uint192(data.checksum24)));

        vm.chainId(L2_CHAIN_ID);
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(L2_CHAIN_ID);
        MockCrossDomainMessenger l2Messenger = new MockCrossDomainMessenger();
        SuperchainBridgeAdapter destAdapter = _setupL2Adapter(destEscrow, address(l2Messenger));
        usdc.mint(address(destAdapter), amount);

        assertFalse(destEscrow.isInvoiceCompleted(invoiceHash), "not completed yet");

        // Relay the captured authenticated message; source sender is the trusted L1 sibling.
        l2Messenger.relayMessage(address(destAdapter), l1SiblingAdapter, sentMsg);

        assertTrue(destEscrow.isInvoiceCompleted(invoiceHash), "authenticated completeDeposit recorded the delivery");
        assertEq(destEscrow.getHeldBalanceForAsset(address(usdc), account), amount, "held for account");
        assertEq(usdc.balanceOf(address(destAdapter)), 0, "adapter forwarded tokens to escrow");
    }

    /// @dev Strips the 4-byte selector and abi.decodes the single `bytes` argument (the completeDeposit payload).
    function _decodeCompleteDepositPayload(bytes memory encodedCall) internal pure returns (bytes memory payload) {
        bytes memory tail = new bytes(encodedCall.length - 4);
        for (uint256 i = 0; i < tail.length; i++) {
            tail[i] = encodedCall[i + 4];
        }
        payload = abi.decode(tail, (bytes));
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

    /// @notice RE3-M-01: completion binds to the withdrawal STORED for the exact invoice (per-operation hash), not to
    ///         operator-supplied protocolData. An invoice that was never proven has no stored tx → reverts, even with
    ///         empty protocolData (which is now valid — the tx is read from storage, not the caller).
    function test_completeBridge_l2ToL1_revertsIfWithdrawalNotProvenForInvoice() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;
        BridgeEscrow l1Escrow = bridgeEscrow;
        vm.prank(admin);
        l1Escrow.registerAsset(WETH_SYMBOL, address(0));
        SuperchainBridgeAdapter l1Ad = _deployL1WithdrawalAdapter(l1Escrow);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(L2_CHAIN_ID, SOURCE_CHAIN_ID, account, WETH_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // No proveWithdrawal for this invoice → no stored WithdrawalTransaction → cannot complete.
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISuperchainBridgeAdapter.WithdrawalNotProven.selector));
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

        bytes memory stored = l1Adapter.getMessagePayload(bytes32(uint256(uint192(invoiceData.checksum24))));
        assertEq(stored.length, InvoiceDataLib.encode(invoiceData).length);
        InvoiceDataLib.InvoiceData memory decoded = InvoiceDataLib.decode(stored);
        assertEq(decoded.invoiceId, invoiceData.invoiceId);
    }
}
