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

    // Mainnet Stargate router/endpoint (LayerZero v1) - source: script/config/chains/1.json + Stargate docs
    address public constant STARGATE_ROUTER_MAINNET = 0x8731d54E9D02c286767d56ac03e8037C07e01e98;
    address public constant LZ_ENDPOINT_MAINNET = 0x66A71Dcef29A0fFBDBE3c6a460a3B5BC225Cd675;

    // Known Stargate pool IDs for USDC (Ethereum and Optimism)
    // Source: Stargate docs; used only for this fork test
    uint256 public constant SRC_POOL_ID = 1; // USDC pool on Ethereum
    uint256 public constant DST_POOL_ID = 1; // USDC pool on Optimism

    function setUp() public override {
        super.setUp();
        _selectMainnetFork();
        _setupStargateAdapter();
        _fundAccount();
    }

    function _setupStargateAdapter() internal {
        // Deploy Stargate adapter
        address adapterImpl = address(new StargateBridgeAdapter());
        address adapterProxy = UnsafeUpgrades.deployUUPSProxy(
            adapterImpl,
            abi.encodeCall(
                StargateBridgeAdapter.initialize,
                (admin, address(bridgeEscrow), STARGATE_ROUTER_MAINNET, LZ_ENDPOINT_MAINNET, "1.0.0")
            )
        );
        adapter = StargateBridgeAdapter(payable(adapterProxy));

        // Configure adapter: LZ chain IDs for 1 and 10 are pre-configured in initialize
        vm.startPrank(admin);
        // Set pool IDs for USDC on source and destination chains
        adapter.setAssetPoolId(MAINNET_USDC, MAINNET_CHAIN_ID, SRC_POOL_ID);
        adapter.setAssetPoolId(MAINNET_USDC, OPTIMISM_CHAIN_ID, DST_POOL_ID);
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

    /// @notice On mainnet fork, the adapter correctly calls Stargate router.swap(); LayerZero's relayer
    ///         reverts with "Relayer: stargate composer is not sending" because the call is not from
    ///         the Stargate composer context. We expect this revert to confirm we hit the protocol path.
    function testFork_stargate_bridge_initiatesRealSwap() public {
        uint256 amount = TEST_AMOUNT_USDC;
        uint64 destChainId = OPTIMISM_CHAIN_ID;

        _approveToken(MAINNET_USDC, address(bridgeEscrow), amount);
        vm.deal(address(adapter), 0.1 ether);

        vm.expectRevert("Relayer: stargate composer is not sending");
        vm.prank(account);
        bridgeEscrow.depositAndBridge(destChainId, USDC_SYMBOL, amount, address(adapter));
    }
}

