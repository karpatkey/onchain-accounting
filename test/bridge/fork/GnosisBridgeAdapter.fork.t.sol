// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GnosisBridgeAdapter} from "src/bridge/adapters/GnosisBridgeAdapter.sol";
import {IGnosisBridgeAdapter} from "src/bridge/adapters/interfaces/IGnosisBridgeAdapter.sol";
import {IAMB} from "src/bridge/adapters/interfaces/IGnosisInterfaces.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {IBridgeEscrow} from "src/bridge/IBridgeEscrow.sol";
import {BridgeTestBase} from "test/bridge/fork/BridgeTestBase.fork.sol";

/// @title GnosisBridgeAdapterForkTest
/// @notice Fork tests for the Gnosis Omnibridge adapter against the real Ethereum mainnet Omnibridge + AMB
///         (ADR 0012). Source side: `depositAndBridge` to Gnosis Chain (100) calls the real Omnibridge
///         `relayTokensAndCall` with the destination recipient set to the sibling adapter (CREATE2
///         same-address) and the invoice payload as the call data. Destination side: the Omnibridge mediator
///         delivers tokens to the adapter and calls `onTokenTransfer`; the adapter authenticates
///         `msg.sender == omnibridge` AND the AMB-reported source (`messageSender == trustedRemoteAdapter`,
///         `messageSourceChainId == source chain`), then funds the escrow and releases.
/// @dev The AMB `messageSender()` / `messageSourceChainId()` are only meaningful while the AMB is executing a
///      relayed message, so the destination-completion test mocks ONLY those two getters (vm.mockCall) while
///      still requiring the callback to come from the real Omnibridge mediator address — authenticating against
///      the genuine protocol contract. There is no offline way to drive a real AMB-relayed delivery.
contract GnosisBridgeAdapterForkTest is BridgeTestBase {
    GnosisBridgeAdapter public adapter;
    IERC20 public usdc;

    // Gnosis chain id (Omnibridge bridges Ethereum (1) <-> Gnosis Chain (100)).
    uint64 public constant GNOSIS_CHAIN_ID = 100;

    // Ethereum mainnet (foreign) Omnibridge mediator + AMB. Source: docs.gnosischain.com (Omnibridge key contracts).
    address public constant OMNIBRIDGE_MAINNET = 0x88ad09518695c6c3712AC10a214bE5109a655671;

    /// @notice Gnosis Chain (home) Omnibridge mediator — the source mediator the AMB reports as
    ///         messageSender() for a Gnosis(100) -> Ethereum inbound transfer.
    address public constant GNOSIS_HOME_MEDIATOR = 0xf6A78083ca3e2a662D6dd1703c939c8aCE2e268d;
    address public constant AMB_MAINNET = 0x4C36d2919e407f0Cc2Ee3c993ccF8ac26d9CE64e;

    function setUp() public override {
        super.setUp();
        _selectMainnetFork();
        _setupGnosisAdapter();
        _fundAccount();
    }

    function _setupGnosisAdapter() internal {
        address adapterImpl = address(new GnosisBridgeAdapter(address(0)));
        address payable adapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                adapterImpl,
                abi.encodeCall(
                    GnosisBridgeAdapter.initialize,
                    (admin, address(bridgeEscrow), OMNIBRIDGE_MAINNET, AMB_MAINNET, "1.0.0")
                )
            ));
        adapter = GnosisBridgeAdapter(payable(adapterProxy));

        vm.startPrank(admin);
        adapter.grantRole(MANAGER, manager);
        vm.stopPrank();

        _authorizeAdapter(address(adapter));

        usdc = IERC20(MAINNET_USDC);
        vm.label(address(adapter), "GnosisBridgeAdapter");
        vm.label(OMNIBRIDGE_MAINNET, "Gnosis_Omnibridge_Mainnet");
        vm.label(AMB_MAINNET, "Gnosis_AMB_Mainnet");
    }

    // ============ Bridge Initiation (real Omnibridge relayTokensAndCall) ============

    /// @notice Uses the real mainnet Omnibridge to relay USDC to Gnosis Chain (recipient = sibling adapter).
    function testFork_gnosis_bridge_initiatesRealRelay() public {
        uint256 amount = TEST_AMOUNT_USDC;

        _approveToken(MAINNET_USDC, address(bridgeEscrow), amount);

        uint256 initialPortfolioBalance = usdc.balanceOf(account);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(MAINNET_CHAIN_ID, GNOSIS_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);

        vm.prank(account);
        bytes32 invoiceHash = bridgeEscrow.depositAndBridge(GNOSIS_CHAIN_ID, USDC_SYMBOL, amount, address(adapter));

        // USDC left the account; the adapter pulled it and relayed it into the real Omnibridge mediator.
        assertEq(usdc.balanceOf(account), initialPortfolioBalance - amount, "account balance should decrease");
        assertEq(usdc.balanceOf(address(adapter)), 0, "adapter relayed tokens to the Omnibridge");

        IBridgeEscrow.Invoice memory invoice = bridgeEscrow.getInvoice(invoiceHash);
        assertEq(invoice.invoiceId, invoiceData.invoiceId, "invoice id matches");
        assertEq(uint8(invoice.status), uint8(IBridgeEscrow.InvoiceStatus.BRIDGING), "invoice should be BRIDGING");

        bytes memory payload = adapter.getMessagePayload(invoiceData.invoiceId);
        assertGt(payload.length, 0, "messagePayload recorded for the relay");
    }

    function testFork_gnosis_bridge_revertsForUnsupportedChain() public {
        uint256 amount = TEST_AMOUNT_USDC;
        _approveToken(MAINNET_USDC, address(bridgeEscrow), amount);

        // Omnibridge only bridges between Ethereum (1) and Gnosis Chain (100).
        vm.prank(account);
        vm.expectRevert();
        bridgeEscrow.depositAndBridge(OPTIMISM_CHAIN_ID, USDC_SYMBOL, amount, address(adapter));
    }

    // ============ Destination Completion (genuine mediator onTokenTransfer) ============

    /// @notice Deploys a destination escrow + Gnosis adapter on this fork, wired to the real Omnibridge + AMB,
    ///         trusting the (CREATE2 same-address) source sibling for the source chain.
    function _deployDestination(uint64 srcChainId, address remoteSibling)
        internal
        returns (BridgeEscrow destEscrow, GnosisBridgeAdapter destAdapter)
    {
        destEscrow = _deployDestinationEscrow(MAINNET_CHAIN_ID);

        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                address(new GnosisBridgeAdapter(address(0))),
                abi.encodeCall(
                    GnosisBridgeAdapter.initialize,
                    (admin, address(destEscrow), OMNIBRIDGE_MAINNET, AMB_MAINNET, "1.0.0")
                )
            ));
        destAdapter = GnosisBridgeAdapter(payable(destAdapterProxy));

        vm.startPrank(admin);
        destAdapter.grantRole(MANAGER, manager);
        // Gnosis authenticates against the SOURCE Omnibridge mediator (what amb.messageSender() reports),
        // not the sibling adapter. remoteSibling is unused (retained for signature compatibility).
        remoteSibling;
        destAdapter.setTrustedMediator(srcChainId, GNOSIS_HOME_MEDIATOR);
        destEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();
    }

    /// @notice Mocks ONLY the AMB provenance getters to report a relay from `sender` on `srcChainId`.
    function _mockAmbProvenance(address sender, uint64 srcChainId) internal {
        vm.mockCall(AMB_MAINNET, abi.encodeWithSelector(IAMB.messageSender.selector), abi.encode(sender));
        vm.mockCall(
            AMB_MAINNET,
            abi.encodeWithSelector(IAMB.messageSourceChainId.selector),
            abi.encode(bytes32(uint256(srcChainId)))
        );
    }

    /// @notice The genuine Omnibridge mediator delivers tokens + calls onTokenTransfer: the adapter authenticates
    ///         the mediator + AMB-reported source, then funds the escrow and releases to the account.
    function testFork_gnosis_onTokenTransfer_authenticatesMediatorAndReleases() public {
        uint64 srcChainId = GNOSIS_CHAIN_ID;
        uint256 amount = TEST_AMOUNT_USDC;

        // The trusted source sibling is the CREATE2 same-address adapter.
        (BridgeEscrow destEscrow, GnosisBridgeAdapter destAdapter) = _deployDestination(srcChainId, address(0));

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(srcChainId, MAINNET_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Omnibridge delivers the tokens to the adapter (the recipient) before the callback.
        _fundAccountWithToken(MAINNET_USDC, address(destAdapter), amount);

        // AMB reports the relay as coming from the trusted SOURCE Omnibridge mediator.
        _mockAmbProvenance(GNOSIS_HOME_MEDIATOR, srcChainId);

        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));
        uint256 portfolioBefore = usdc.balanceOf(account);

        // Genuine protocol path: the real Omnibridge mediator is the caller.
        vm.prank(OMNIBRIDGE_MAINNET);
        bool ok = destAdapter.onTokenTransfer(address(destAdapter), amount, messagePayload);
        assertTrue(ok, "onTokenTransfer returns true");

        vm.clearMockedCalls();

        assertEq(usdc.balanceOf(account) - portfolioBefore, amount, "account received bridged USDC");
        assertEq(usdc.balanceOf(address(destAdapter)), 0, "adapter forwarded all tokens");
        assertEq(usdc.balanceOf(address(destEscrow)), 0, "escrow holds no standing balance");
        assertTrue(destEscrow.isInvoiceCompleted(invoiceHash), "invoice marked completed");
    }

    /// @notice onTokenTransfer reverts when not called by the genuine Omnibridge mediator.
    function testFork_gnosis_onTokenTransfer_revertsWhenNotOmnibridge() public {
        uint64 srcChainId = GNOSIS_CHAIN_ID;
        uint256 amount = TEST_AMOUNT_USDC;
        (, GnosisBridgeAdapter destAdapter) = _deployDestination(srcChainId, address(0));
        vm.prank(admin);
        destAdapter.setTrustedRemoteAdapter(srcChainId, _siblingIdentity(address(destAdapter)));

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(srcChainId, MAINNET_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(account);
        vm.expectRevert(); // NotAuthorized — caller is not the Omnibridge mediator
        destAdapter.onTokenTransfer(address(destAdapter), amount, messagePayload);
    }

    /// @notice onTokenTransfer from the genuine mediator reverts when the AMB source sender is not trusted.
    function testFork_gnosis_onTokenTransfer_revertsForUntrustedSource() public {
        uint64 srcChainId = GNOSIS_CHAIN_ID;
        uint256 amount = TEST_AMOUNT_USDC;
        (, GnosisBridgeAdapter destAdapter) = _deployDestination(srcChainId, address(0));
        vm.prank(admin);
        destAdapter.setTrustedRemoteAdapter(srcChainId, _siblingIdentity(address(destAdapter)));

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(srcChainId, MAINNET_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        _fundAccountWithToken(MAINNET_USDC, address(destAdapter), amount);

        // AMB reports an impostor as the cross-chain sender.
        _mockAmbProvenance(makeAddr("impostor"), srcChainId);

        vm.prank(OMNIBRIDGE_MAINNET);
        vm.expectRevert(abi.encodeWithSelector(IGnosisBridgeAdapter.InvalidBridgeData.selector));
        destAdapter.onTokenTransfer(address(destAdapter), amount, messagePayload);

        vm.clearMockedCalls();
    }
}
