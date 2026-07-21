// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StargateBridgeAdapter} from "src/bridge/adapters/StargateBridgeAdapter.sol";
import {IStargateBridgeAdapter} from "src/bridge/adapters/interfaces/IStargateBridgeAdapter.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {IBridgeEscrow} from "src/bridge/IBridgeEscrow.sol";
import {BridgeTestBase} from "test/bridge/fork/BridgeTestBase.fork.sol";

/// @title StargateBridgeAdapterForkTest
/// @notice Fork tests for the Stargate V2 Bridge Adapter against real mainnet contracts (ADR 0012).
/// @dev Source side: `depositAndBridge` calls the genuine Stargate V2 USDC pool `sendToken` with the destination
///      recipient set to the sibling adapter (CREATE2 same-address) and the invoice payload in `composeMsg`.
///      Destination side: the genuine LayerZero V2 Endpoint calls `lzCompose` on the adapter after Stargate
///      delivers the tokens to it; the adapter authenticates `msg.sender == endpoint`, the composing pool
///      (`_from == stargatePool[asset]`), the source eid + sibling adapter (`composeFrom`), and the delivered
///      amount, then funds the escrow and releases. We exercise the destination path on the same mainnet fork
///      by impersonating the real Endpoint (vm.prank) with `_from` set to the real Stargate pool — there is no
///      offline way to produce a genuine LayerZero delivery, but authenticating against the real Endpoint and
///      pool addresses is the load-bearing provenance check.
contract StargateBridgeAdapterForkTest is BridgeTestBase {
    StargateBridgeAdapter public adapter;
    IERC20 public usdc;

    // Mainnet LayerZero V2 endpoint + Stargate V2 USDC pool - source: LayerZero V2 deployments + Stargate V2 docs
    address public constant LZ_ENDPOINT_MAINNET = 0x1a44076050125825900e736c501f859c50fE728c; // EndpointV2
    address public constant STARGATE_POOL_USDC_MAINNET = 0xc026395860Db2d07ee33e05fE50ed7bD583189C7; // StargatePoolUSDC

    // LayerZero V2 endpoint IDs (eids), pre-configured in the adapter's initialize.
    uint32 public constant ETHEREUM_EID = 30101;
    uint32 public constant OPTIMISM_EID = 30111;

    function setUp() public override {
        super.setUp();
        _selectMainnetFork();
        _setupStargateAdapter();
        _fundAccount();
    }

    function _setupStargateAdapter() internal {
        // Deploy Stargate V2 adapter
        address adapterImpl = address(new StargateBridgeAdapter(address(0)));
        address adapterProxy = UnsafeUpgrades.deployUUPSProxy(
            adapterImpl,
            abi.encodeCall(
                StargateBridgeAdapter.initialize, (admin, address(bridgeEscrow), LZ_ENDPOINT_MAINNET, "1.0.0")
            )
        );
        adapter = StargateBridgeAdapter(payable(adapterProxy));

        // Configure adapter: LayerZero eids for 1 and 10 are pre-configured in initialize
        vm.startPrank(admin);
        // Bind the Stargate V2 USDC pool to the USDC asset
        adapter.setStargatePool(MAINNET_USDC, STARGATE_POOL_USDC_MAINNET);
        adapter.grantRole(MANAGER, manager);
        vm.stopPrank();

        // Authorize adapter in BridgeEscrow
        _authorizeAdapter(address(adapter));

        // Setup USDC reference
        usdc = IERC20(MAINNET_USDC);

        // Labels
        vm.label(address(adapter), "StargateBridgeAdapter");
    }

    // ============ Bridge Initiation Tests ============

    /// @notice On mainnet fork, the adapter calls the real Stargate V2 pool `sendToken` and successfully
    ///         dispatches a composed cross-chain transfer to Optimism (recipient = sibling adapter).
    function testFork_stargate_bridge_initiatesRealSend() public {
        uint256 amount = TEST_AMOUNT_USDC;
        uint64 destChainId = OPTIMISM_CHAIN_ID;

        _approveToken(MAINNET_USDC, address(bridgeEscrow), amount);
        // Fund the adapter with native gas for the LayerZero messaging fee
        vm.deal(address(adapter), 1 ether);

        vm.prank(account);
        bridgeEscrow.depositAndBridge(destChainId, USDC_SYMBOL, amount, address(adapter));

        // The invoice payload was recorded for the dispatched send.
        IBridgeEscrow.Invoice[] memory active = bridgeEscrow.getActiveInvoices(account);
        assertEq(active.length, 1, "one active invoice after dispatch");
        bytes memory payload = adapter.getMessagePayload(active[0].invoiceId);
        assertGt(payload.length, 0, "messagePayload recorded for dispatched send");
    }

    // ============ Destination Completion (genuine Endpoint lzCompose) ============

    /// @notice Builds an OFT-composed message in the LayerZero V2 codec layout the adapter decodes:
    ///         nonce[0:8] | srcEid[8:12] | amountLD[12:44] | composeFrom[44:76] | composeMsg[76:].
    function _encodeComposeMessage(
        uint64 nonce,
        uint32 srcEid,
        uint256 amountLD,
        bytes32 composeFrom,
        bytes memory composeMsg
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(nonce, srcEid, amountLD, composeFrom, composeMsg);
    }

    /// @notice Deploys a destination escrow + Stargate adapter on this mainnet fork, wired to the real Endpoint
    ///         and real USDC pool, trusting the (CREATE2 same-address) source sibling for the source chain.
    function _deployDestination(uint64 srcChainId)
        internal
        returns (BridgeEscrow destEscrow, StargateBridgeAdapter destAdapter)
    {
        destEscrow = _deployDestinationEscrow(MAINNET_CHAIN_ID);

        address payable destAdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                address(new StargateBridgeAdapter(address(0))),
                abi.encodeCall(
                    StargateBridgeAdapter.initialize, (admin, address(destEscrow), LZ_ENDPOINT_MAINNET, "1.0.0")
                )
            ));
        destAdapter = StargateBridgeAdapter(payable(destAdapterProxy));

        vm.startPrank(admin);
        destAdapter.setStargatePool(MAINNET_USDC, STARGATE_POOL_USDC_MAINNET);
        destAdapter.grantRole(MANAGER, manager);
        destAdapter.setTrustedRemoteAdapter(srcChainId, _siblingIdentity(address(destAdapter)));
        destEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();
    }

    /// @notice The genuine LayerZero V2 Endpoint calls lzCompose on the adapter (with the real Stargate pool as
    ///         the composing OApp): the adapter authenticates endpoint + pool + source, then funds + releases.
    function testFork_stargate_lzCompose_authenticatesEndpointAndReleases() public {
        uint64 srcChainId = OPTIMISM_CHAIN_ID;
        uint256 amount = TEST_AMOUNT_USDC;

        (BridgeEscrow destEscrow, StargateBridgeAdapter destAdapter) = _deployDestination(srcChainId);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(srcChainId, MAINNET_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        // Stargate delivered the bridged USDC to the adapter (the recipient) before lzCompose.
        _fundAccountWithToken(MAINNET_USDC, address(destAdapter), amount);

        bytes memory composeMessage =
            _encodeComposeMessage(1, OPTIMISM_EID, amount, _siblingIdentity(address(destAdapter)), messagePayload);

        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));
        uint256 portfolioBefore = usdc.balanceOf(account);

        // Genuine protocol path: the real LayerZero V2 Endpoint is the caller; _from is the real Stargate pool.
        vm.prank(LZ_ENDPOINT_MAINNET);
        destAdapter.lzCompose(STARGATE_POOL_USDC_MAINNET, bytes32(0), composeMessage, address(0), bytes(""));

        assertEq(usdc.balanceOf(account) - portfolioBefore, amount, "account received bridged USDC");
        assertEq(usdc.balanceOf(address(destAdapter)), 0, "adapter forwarded all tokens");
        assertEq(usdc.balanceOf(address(destEscrow)), 0, "escrow holds no standing balance");
        assertTrue(destEscrow.isInvoiceCompleted(invoiceHash), "invoice marked completed");
    }

    /// @notice lzCompose reverts when not called by the genuine Endpoint.
    function testFork_stargate_lzCompose_revertsWhenNotEndpoint() public {
        uint64 srcChainId = OPTIMISM_CHAIN_ID;
        uint256 amount = TEST_AMOUNT_USDC;
        (, StargateBridgeAdapter destAdapter) = _deployDestination(srcChainId);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(srcChainId, MAINNET_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        bytes memory composeMessage = _encodeComposeMessage(
            1, OPTIMISM_EID, amount, _siblingIdentity(address(destAdapter)), InvoiceDataLib.encode(invoiceData)
        );

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IStargateBridgeAdapter.InvalidEndpoint.selector));
        destAdapter.lzCompose(STARGATE_POOL_USDC_MAINNET, bytes32(0), composeMessage, address(0), bytes(""));
    }

    /// @notice lzCompose from the genuine Endpoint reverts when the source sibling adapter is not trusted.
    function testFork_stargate_lzCompose_revertsForUntrustedSource() public {
        uint64 srcChainId = OPTIMISM_CHAIN_ID;
        uint256 amount = TEST_AMOUNT_USDC;
        (, StargateBridgeAdapter destAdapter) = _deployDestination(srcChainId);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(srcChainId, MAINNET_CHAIN_ID, account, USDC_SYMBOL_BYTES6, amount);
        _fundAccountWithToken(MAINNET_USDC, address(destAdapter), amount);

        // composeFrom is an untrusted source adapter identity.
        bytes memory composeMessage = _encodeComposeMessage(
            1, OPTIMISM_EID, amount, _siblingIdentity(makeAddr("impostor")), InvoiceDataLib.encode(invoiceData)
        );

        vm.prank(LZ_ENDPOINT_MAINNET);
        vm.expectRevert(abi.encodeWithSelector(IStargateBridgeAdapter.InvalidBridgeData.selector));
        destAdapter.lzCompose(STARGATE_POOL_USDC_MAINNET, bytes32(0), composeMessage, address(0), bytes(""));
    }
}

