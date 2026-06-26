// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Client} from "@chainlink/src/v0.8/ccip/libraries/Client.sol";

import {CcipBridgeAdapter} from "src/bridge/adapters/CcipBridgeAdapter.sol";
import {ICcipBridgeAdapter} from "src/bridge/adapters/interfaces/ICcipBridgeAdapter.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {IBridgeEscrow} from "src/bridge/IBridgeEscrow.sol";
import {BridgeTestBase} from "test/bridge/fork/BridgeTestBase.fork.sol";

/// @title CcipBridgeAdapterForkTest
/// @notice Fork tests for CCIP Bridge Adapter using the real mainnet CCIP Router (ADR 0012 provenance model).
/// @dev Source side: `depositAndBridge` dispatches through the genuine CCIP Router (recipient = sibling adapter).
///      Destination side: the genuine Router calls `ccipReceive` on the adapter; the adapter authenticates
///      `msg.sender == router`, the source chain selector, the source sender (`trustedRemoteAdapter`) and the
///      delivered token, then funds the escrow and releases (funded pass-through). We exercise the destination
///      path on the same mainnet fork by impersonating the real Router (vm.prank) — CCIP gives no offline way
///      to deliver a genuine cross-chain message, but authenticating against the real Router address and the
///      real selector mapping is the load-bearing provenance check.
contract CcipBridgeAdapterForkTest is BridgeTestBase {
    CcipBridgeAdapter public adapter;
    IERC20 public usdc;

    // Mainnet CCIP Router (Ethereum) - source: script/config/chains/1.json + Chainlink docs
    address public constant CCIP_ROUTER_MAINNET = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;

    // CCIP chain selectors (pre-configured in the adapter's initialize). Source: Chainlink CCIP directory.
    uint64 public constant ETHEREUM_SELECTOR = 5009297550715157269;
    uint64 public constant OPTIMISM_SELECTOR = 3734403246176062136;

    function setUp() public override {
        super.setUp();
        _selectMainnetFork();
        _setupCcipAdapter();
        _fundAccount();
    }

    function _setupCcipAdapter() internal {
        // Deploy CCIP adapter
        address adapterImpl = address(new CcipBridgeAdapter());
        address adapterProxy = UnsafeUpgrades.deployUUPSProxy(
            adapterImpl,
            abi.encodeCall(
                CcipBridgeAdapter.initialize,
                (
                    admin,
                    address(bridgeEscrow),
                    CCIP_ROUTER_MAINNET,
                    address(0), // feeToken = native ETH
                    "1.0.0"
                )
            )
        );
        adapter = CcipBridgeAdapter(adapterProxy);

        // Configure adapter roles
        vm.startPrank(admin);
        adapter.grantRole(MANAGER, manager);
        vm.stopPrank();

        // Authorize adapter in BridgeEscrow
        _authorizeAdapter(address(adapter));

        // Setup USDC reference
        usdc = IERC20(MAINNET_USDC);

        // Labels
        vm.label(address(adapter), "CcipBridgeAdapter");
    }

    // ============ Bridge Initiation Tests ============

    /// @notice Uses real CCIP router on mainnet to initiate a bridge to Optimism
    function testFork_ccip_bridge_initiatesRealTransfer() public {
        uint256 amount = TEST_AMOUNT_USDC;
        uint64 destChainId = OPTIMISM_CHAIN_ID;

        // Approve BridgeEscrow to spend USDC
        _approveToken(MAINNET_USDC, address(bridgeEscrow), amount);

        // Fund adapter with ETH for CCIP fees (native)
        vm.deal(address(adapter), 0.1 ether);

        // Get initial balances
        uint256 initialPortfolioBalance = usdc.balanceOf(account);

        // Create invoice data
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(MAINNET_CHAIN_ID, destChainId, account, USDC_SYMBOL_BYTES6, amount);

        // Initiate bridge via BridgeEscrow
        vm.prank(account);
        bytes32 invoiceHash = bridgeEscrow.depositAndBridge(destChainId, USDC_SYMBOL, amount, address(adapter));

        // Verify account USDC balance decreased by amount (tokens pulled and bridged via CCIP)
        assertEq(usdc.balanceOf(account), initialPortfolioBalance - amount, "Account balance should decrease");

        // Verify invoice was created and is in BRIDGING status
        IBridgeEscrow.Invoice memory invoice = bridgeEscrow.getInvoice(invoiceHash);
        assertEq(invoice.invoiceId, invoiceData.invoiceId, "Invoice ID should match");
        assertEq(invoice.amount, amount, "Invoice amount should match");
        assertEq(
            uint8(invoice.status), uint8(IBridgeEscrow.InvoiceStatus.BRIDGING), "Invoice should be in BRIDGING status"
        );
    }

    // ============ Destination Completion (provenance via genuine Router) ============

    /// @notice Deploys a destination-side escrow + CCIP adapter on this mainnet fork, wired to the real Router
    ///         and trusting the (CREATE2 same-address) source sibling for the Optimism source chain/selector.
    function _deployDestination() internal returns (BridgeEscrow destEscrow, CcipBridgeAdapter destAdapter) {
        destEscrow = _deployDestinationEscrow(MAINNET_CHAIN_ID);

        address destAdapterProxy = UnsafeUpgrades.deployUUPSProxy(
            address(new CcipBridgeAdapter()),
            abi.encodeCall(
                CcipBridgeAdapter.initialize, (admin, address(destEscrow), CCIP_ROUTER_MAINNET, address(0), "1.0.0")
            )
        );
        destAdapter = CcipBridgeAdapter(destAdapterProxy);

        vm.startPrank(admin);
        destAdapter.grantRole(MANAGER, manager);
        // Source sibling adapter (CREATE2 same-address) trusted for the Optimism source chain/selector.
        destAdapter.setTrustedRemoteAdapter(OPTIMISM_CHAIN_ID, _siblingIdentity(address(destAdapter)));
        destEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();
    }

    /// @notice The genuine CCIP Router delivers `ccipReceive` to the adapter: it authenticates the router, the
    ///         source selector + sender and the delivered token, then funds the escrow and releases to account.
    function testFork_ccip_ccipReceive_authenticatesRouterAndReleases() public {
        uint256 amount = TEST_AMOUNT_USDC;

        (BridgeEscrow destEscrow, CcipBridgeAdapter destAdapter) = _deployDestination();

        // Invoice authored on the source chain (Optimism) bound for this destination chain (Ethereum fork).
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(OPTIMISM_CHAIN_ID, MAINNET_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // CCIP delivered the bridged USDC to the adapter (the recipient) before calling ccipReceive.
        _fundAccountWithToken(MAINNET_USDC, address(destAdapter), amount);

        Client.EVMTokenAmount[] memory delivered = new Client.EVMTokenAmount[](1);
        delivered[0] = Client.EVMTokenAmount({token: MAINNET_USDC, amount: amount});

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("ccip-fork-msg"),
            sourceChainSelector: OPTIMISM_SELECTOR,
            sender: abi.encode(address(destAdapter)), // CREATE2 same-address sibling
            data: messagePayload,
            destTokenAmounts: delivered
        });

        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));
        uint256 portfolioBefore = IERC20(MAINNET_USDC).balanceOf(account);

        // Genuine protocol path: the real CCIP Router is the caller.
        vm.prank(CCIP_ROUTER_MAINNET);
        destAdapter.ccipReceive(message);

        assertEq(IERC20(MAINNET_USDC).balanceOf(account) - portfolioBefore, amount, "account received bridged USDC");
        assertEq(IERC20(MAINNET_USDC).balanceOf(address(destAdapter)), 0, "adapter forwarded all tokens");
        assertEq(IERC20(MAINNET_USDC).balanceOf(address(destEscrow)), 0, "escrow holds no standing balance");
        assertTrue(destEscrow.isInvoiceCompleted(invoiceHash), "invoice marked completed");
    }

    /// @notice ccipReceive reverts when not called by the genuine Router (only the real protocol path authenticates).
    function testFork_ccip_ccipReceive_revertsWhenNotRouter() public {
        uint256 amount = TEST_AMOUNT_USDC;
        (, CcipBridgeAdapter destAdapter) = _deployDestination();

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(OPTIMISM_CHAIN_ID, MAINNET_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("ccip-fork-msg-2"),
            sourceChainSelector: OPTIMISM_SELECTOR,
            sender: abi.encode(address(destAdapter)),
            data: InvoiceDataLib.encode(invoiceData),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(ICcipBridgeAdapter.InvalidRouter.selector));
        destAdapter.ccipReceive(message);
    }

    /// @notice ccipReceive from the genuine Router still reverts when the source sender is not the trusted sibling.
    function testFork_ccip_ccipReceive_revertsForUntrustedSource() public {
        uint256 amount = TEST_AMOUNT_USDC;
        (, CcipBridgeAdapter destAdapter) = _deployDestination();

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(OPTIMISM_CHAIN_ID, MAINNET_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        _fundAccountWithToken(MAINNET_USDC, address(destAdapter), amount);

        Client.EVMTokenAmount[] memory delivered = new Client.EVMTokenAmount[](1);
        delivered[0] = Client.EVMTokenAmount({token: MAINNET_USDC, amount: amount});

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("ccip-fork-msg-3"),
            sourceChainSelector: OPTIMISM_SELECTOR,
            sender: abi.encode(makeAddr("impostor")), // not the trusted sibling
            data: InvoiceDataLib.encode(invoiceData),
            destTokenAmounts: delivered
        });

        vm.prank(CCIP_ROUTER_MAINNET);
        vm.expectRevert(abi.encodeWithSelector(ICcipBridgeAdapter.InvalidBridgeData.selector));
        destAdapter.ccipReceive(message);
    }
}

