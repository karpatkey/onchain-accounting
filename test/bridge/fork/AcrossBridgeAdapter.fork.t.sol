// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AcrossBridgeAdapter} from "src/bridge/adapters/AcrossBridgeAdapter.sol";
import {IAcrossBridgeAdapter} from "src/bridge/adapters/interfaces/IAcrossBridgeAdapter.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {IBridgeEscrow} from "src/bridge/IBridgeEscrow.sol";
import {BridgeTestBase} from "test/bridge/fork/BridgeTestBase.fork.sol";

/// @title AcrossBridgeAdapterForkTest
/// @notice Fork tests for the Across V3 Bridge Adapter against the real mainnet SpokePool (ADR 0012).
/// @dev Source side: `depositAndBridge` calls the genuine SpokePool `depositV3` with the destination recipient
///      set to the sibling adapter (CREATE2 same-address) and the invoice payload carried in the V3 `message`.
///      Destination side: on a filled relay the genuine destination SpokePool transfers the tokens to the
///      adapter and calls `handleV3AcrossMessage` on it directly. The adapter authenticates
///      `msg.sender == spokePool`, cross-checks the delivered token+amount against the invoice, verifies the
///      source against `trustedRemoteAdapter`, then funds the escrow and releases (funded pass-through).
///      We exercise the destination path on the same mainnet fork by impersonating the real SpokePool
///      (vm.prank) after dealing the delivered tokens to the adapter — Across gives no offline way to produce a
///      genuine relayer fill, but authenticating against the real SpokePool address is the provenance check.
contract AcrossBridgeAdapterForkTest is BridgeTestBase {
    AcrossBridgeAdapter public adapter;
    IERC20 public usdc;

    // Across V3 SpokePool addresses. Source: https://docs.across.to/reference/contract-addresses
    address public constant SPOKE_POOL_MAINNET = 0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5;
    address public constant SPOKE_POOL_OPTIMISM = 0x6f26Bf09B1C792e3228e5467807a900A503c0281;

    int64 public constant DEFAULT_RELAYER_FEE_PCT = 0.001e18; // 0.1% (config metadata; invoice tracks exact amount)

    function setUp() public override {
        super.setUp();
        _selectMainnetFork();
        _setupAcrossAdapter();
        _fundAccount();
    }

    function _setupAcrossAdapter() internal {
        address adapterImpl = address(new AcrossBridgeAdapter());
        address payable adapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                adapterImpl,
                abi.encodeCall(
                    AcrossBridgeAdapter.initialize,
                    (admin, address(bridgeEscrow), SPOKE_POOL_MAINNET, DEFAULT_RELAYER_FEE_PCT, "1.0.0")
                )
            ));
        adapter = AcrossBridgeAdapter(adapterProxy);

        vm.startPrank(admin);
        adapter.grantRole(MANAGER, manager);
        vm.stopPrank();

        _authorizeAdapter(address(adapter));

        usdc = IERC20(MAINNET_USDC);
        vm.label(address(adapter), "AcrossBridgeAdapter");
        vm.label(SPOKE_POOL_MAINNET, "Across_SpokePool_Mainnet");
    }

    // ============ Bridge Initiation (real SpokePool depositV3) ============

    /// @notice Uses the real mainnet SpokePool to initiate a V3 deposit to Optimism (recipient = sibling adapter).
    function testFork_across_bridge_initiatesRealDepositV3() public {
        uint256 amount = TEST_AMOUNT_USDC;
        uint64 destChainId = OPTIMISM_CHAIN_ID;

        _approveToken(MAINNET_USDC, address(bridgeEscrow), amount);

        uint256 initialPortfolioBalance = usdc.balanceOf(account);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(MAINNET_CHAIN_ID, destChainId, account, USDC_SYMBOL_BYTES6, amount);

        vm.prank(account);
        bytes32 invoiceHash = bridgeEscrow.depositAndBridge(destChainId, USDC_SYMBOL, amount, address(adapter));

        // USDC left the account and was deposited into the SpokePool via the adapter's depositV3 call.
        assertEq(usdc.balanceOf(account), initialPortfolioBalance - amount, "account balance should decrease");
        assertEq(usdc.balanceOf(address(adapter)), 0, "adapter forwarded tokens to the SpokePool");

        IBridgeEscrow.Invoice memory invoice = bridgeEscrow.getInvoice(invoiceHash);
        assertEq(invoice.invoiceId, invoiceData.invoiceId, "invoice id matches");
        assertEq(invoice.amount, amount, "invoice amount matches");
        assertEq(uint8(invoice.status), uint8(IBridgeEscrow.InvoiceStatus.BRIDGING), "invoice should be BRIDGING");

        // The invoice payload was recorded for the dispatched V3 deposit.
        bytes memory payload = adapter.getMessagePayload(invoiceData.invoiceId);
        assertGt(payload.length, 0, "messagePayload recorded for dispatched V3 deposit");
    }

    function testFork_across_bridge_revertsIfNotEscrow() public {
        uint256 amount = TEST_AMOUNT_USDC;
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(MAINNET_CHAIN_ID, OPTIMISM_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(account);
        vm.expectRevert(); // only the escrow may call bridge()
        adapter.bridge(messagePayload);
    }

    // ============ Destination Completion (genuine SpokePool handleV3AcrossMessage) ============

    /// @notice Deploys a destination escrow + Across adapter on this mainnet fork, wired to the real SpokePool
    ///         and trusting the (CREATE2 same-address) source sibling for the source chain.
    function _deployDestination(uint64 srcChainId)
        internal
        returns (BridgeEscrow destEscrow, AcrossBridgeAdapter destAdapter)
    {
        destEscrow = _deployDestinationEscrow(MAINNET_CHAIN_ID);

        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                address(new AcrossBridgeAdapter()),
                abi.encodeCall(
                    AcrossBridgeAdapter.initialize,
                    (admin, address(destEscrow), SPOKE_POOL_MAINNET, DEFAULT_RELAYER_FEE_PCT, "1.0.0")
                )
            ));
        destAdapter = AcrossBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        destAdapter.grantRole(MANAGER, manager);
        // Across surfaces no source sender on a fill, so the trusted remote for the source chain is this
        // adapter's own identity (CREATE2 same-address sibling).
        destAdapter.setTrustedRemoteAdapter(srcChainId, _siblingIdentity(address(destAdapter)));
        destEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();
    }

    /// @notice The genuine SpokePool delivers tokens + calls handleV3AcrossMessage: the adapter authenticates the
    ///         SpokePool + source, then funds the escrow and releases to the account (funded pass-through).
    function testFork_across_handleV3AcrossMessage_authenticatesSpokePoolAndReleases() public {
        // Source chain is Optimism for this delivery; the destination is this mainnet fork.
        uint64 srcChainId = OPTIMISM_CHAIN_ID;
        uint256 amount = TEST_AMOUNT_USDC;

        (BridgeEscrow destEscrow, AcrossBridgeAdapter destAdapter) = _deployDestination(srcChainId);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(srcChainId, MAINNET_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // The SpokePool transfers the bridged tokens to the adapter (the recipient) before calling back.
        _fundAccountWithToken(MAINNET_USDC, address(destAdapter), amount);

        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));
        uint256 portfolioBefore = usdc.balanceOf(account);

        // Genuine protocol path: the real mainnet SpokePool is the caller.
        vm.prank(SPOKE_POOL_MAINNET);
        destAdapter.handleV3AcrossMessage(MAINNET_USDC, amount, makeAddr("relayer"), messagePayload);

        assertEq(usdc.balanceOf(account) - portfolioBefore, amount, "account received bridged USDC");
        assertEq(usdc.balanceOf(address(destAdapter)), 0, "adapter forwarded all tokens");
        assertEq(usdc.balanceOf(address(destEscrow)), 0, "escrow holds no standing balance");
        assertTrue(destEscrow.isInvoiceCompleted(invoiceHash), "invoice marked completed");

        bytes memory stored = destAdapter.getMessagePayload(invoiceData.invoiceId);
        assertEq(stored.length, messagePayload.length, "payload stored on completion");
    }

    /// @notice handleV3AcrossMessage reverts when not called by the genuine SpokePool.
    function testFork_across_handleV3AcrossMessage_revertsWhenNotSpokePool() public {
        uint64 srcChainId = OPTIMISM_CHAIN_ID;
        uint256 amount = TEST_AMOUNT_USDC;
        (, AcrossBridgeAdapter destAdapter) = _deployDestination(srcChainId);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(srcChainId, MAINNET_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        _fundAccountWithToken(MAINNET_USDC, address(destAdapter), amount);

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IAcrossBridgeAdapter.MessageReceiveFailed.selector));
        destAdapter.handleV3AcrossMessage(MAINNET_USDC, amount, makeAddr("relayer"), messagePayload);
    }

    /// @notice handleV3AcrossMessage from the genuine SpokePool reverts when the delivered token mismatches.
    function testFork_across_handleV3AcrossMessage_revertsForTokenMismatch() public {
        uint64 srcChainId = OPTIMISM_CHAIN_ID;
        uint256 amount = TEST_AMOUNT_USDC;
        (, AcrossBridgeAdapter destAdapter) = _deployDestination(srcChainId);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(srcChainId, MAINNET_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Deliver DAI but the invoice is for USDC.
        _fundAccountWithToken(MAINNET_DAI, address(destAdapter), amount);

        vm.prank(SPOKE_POOL_MAINNET);
        vm.expectRevert(abi.encodeWithSelector(IAcrossBridgeAdapter.InvalidBridgeData.selector));
        destAdapter.handleV3AcrossMessage(MAINNET_DAI, amount, makeAddr("relayer"), messagePayload);
    }
}
