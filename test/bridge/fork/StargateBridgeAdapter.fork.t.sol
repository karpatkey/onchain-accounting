// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StargateBridgeAdapter} from "src/bridge/adapters/StargateBridgeAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {IBridgeEscrow} from "src/bridge/IBridgeEscrow.sol";
import {BridgeTestBase} from "test/bridge/fork/BridgeTestBase.fork.sol";

/// @title StargateBridgeAdapterForkTest
/// @notice Fork tests for Stargate Bridge Adapter using real mainnet contracts
contract StargateBridgeAdapterForkTest is BridgeTestBase {
    StargateBridgeAdapter public adapter;
    IERC20 public usdc;

    // Mainnet LayerZero V2 endpoint + Stargate V2 USDC pool - source: LayerZero V2 deployments + Stargate V2 docs
    address public constant LZ_ENDPOINT_MAINNET = 0x1a44076050125825900e736c501f859c50fE728c; // EndpointV2
    address public constant STARGATE_POOL_USDC_MAINNET = 0xc026395860Db2d07ee33e05fE50ed7bD583189C7; // StargatePoolUSDC

    function setUp() public override {
        super.setUp();
        _selectMainnetFork();
        _setupStargateAdapter();
        _fundAccount();
    }

    function _setupStargateAdapter() internal {
        // Deploy Stargate V2 adapter
        address adapterImpl = address(new StargateBridgeAdapter());
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
}

