// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CcipBridgeAdapter} from "src/bridge/adapters/CcipBridgeAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {IBridgeEscrow} from "src/bridge/IBridgeEscrow.sol";
import {BridgeTestBase} from "test/bridge/fork/BridgeTestBase.fork.sol";

/// @title CcipBridgeAdapterForkTest
/// @notice Fork tests for CCIP Bridge Adapter using real mainnet contracts
contract CcipBridgeAdapterForkTest is BridgeTestBase {
    CcipBridgeAdapter public adapter;
    IERC20 public usdc;

    // Mainnet CCIP Router (Ethereum) - source: script/config/chains/1.json + Chainlink docs
    address public constant CCIP_ROUTER_MAINNET = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;

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
}

