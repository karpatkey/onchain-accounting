// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {SuperchainBridgeAdapter} from "src/bridge/adapters/SuperchainBridgeAdapter.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
import {InvoiceDataLib} from "src/bridge/InvoiceDataLib.sol";
import {BridgeScenarioHelper} from "test/bridge/BridgeScenarioHelper.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/bridge/mocks/MockBridgeProtocols.sol";
import {Types} from "@optimism/libraries/Types.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title SuperchainBridgeAdapterTest
/// @notice Protocol tests for Superchain (Optimism canonical bridge) adapter using mocks
contract SuperchainBridgeAdapterTest is BridgeScenarioHelper {
    SuperchainBridgeAdapter public l1Adapter;
    SuperchainBridgeAdapter public l2Adapter;
    MockL1StandardBridge public l1Bridge;
    MockL2StandardBridge public l2Bridge;
    MockOptimismPortal public optimismPortal;

    uint64 public constant L2_CHAIN_ID = 10; // Optimism mainnet

    function setUp() public override {
        super.setUp();
        l1Bridge = new MockL1StandardBridge();
        l2Bridge = new MockL2StandardBridge();
        optimismPortal = new MockOptimismPortal();
        vm.deal(address(optimismPortal), 1000 ether);
        _setupL1Adapter();
        vm.label(address(l1Bridge), "MockL1StandardBridge");
        vm.label(address(l2Bridge), "MockL2StandardBridge");
        vm.label(address(optimismPortal), "MockOptimismPortal");
        vm.label(address(l1Adapter), "SuperchainBridgeAdapter(L1)");
    }

    function _setupL1Adapter() internal {
        vm.chainId(SOURCE_CHAIN_ID);
        address l1AdapterImpl = address(new SuperchainBridgeAdapter());
        address payable l1AdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                l1AdapterImpl,
                abi.encodeCall(
                    SuperchainBridgeAdapter.initialize,
                    (
                        admin,
                        address(bridgeEscrow),
                        address(l1Bridge),
                        address(0),
                        address(1),
                        address(0),
                        address(optimismPortal),
                        "1.0.0"
                    )
                )
            ));
        l1Adapter = SuperchainBridgeAdapter(l1AdapterProxy);
        vm.startPrank(admin);
        l1Adapter.grantRole(keccak256("OPERATOR_ROLE"), operator);
        l1Adapter.setL1ToL2Token(address(usdc), address(usdc));
        vm.stopPrank();
        _authorizeAdapter(address(l1Adapter));
    }

    function _setupL2Adapter(BridgeEscrow destEscrow) internal returns (SuperchainBridgeAdapter) {
        address l2AdapterImpl = address(new SuperchainBridgeAdapter());
        address payable l2AdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                l2AdapterImpl,
                abi.encodeCall(
                    SuperchainBridgeAdapter.initialize,
                    (
                        admin,
                        address(destEscrow),
                        address(0),
                        address(l2Bridge),
                        address(0),
                        address(1),
                        address(0),
                        "1.0.0"
                    )
                )
            ));
        SuperchainBridgeAdapter destAdapter = SuperchainBridgeAdapter(l2AdapterProxy);
        vm.startPrank(admin);
        destAdapter.grantRole(keccak256("OPERATOR_ROLE"), operator);
        destEscrow.authorizeAdapter(address(destAdapter));
        vm.stopPrank();
        return destAdapter;
    }

    // ============ L1 -> L2 Deposit Tests ============

    function test_bridge_l1ToL2_initiatesEthDeposit() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;
        vm.prank(admin);
        bridgeEscrow.registerAsset(WETH_SYMBOL, address(0));
        vm.deal(portfolioSafe, amount);

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, L2_CHAIN_ID, portfolioSafe, WETH_SYMBOL, amount);

        vm.prank(portfolioSafe);
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

        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, L2_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);

        vm.prank(portfolioSafe);
        bridgeEscrow.depositAndBridge(L2_CHAIN_ID, USDC_SYMBOL, amount, address(l1Adapter));

        // Mock L1 bridge pulled tokens from adapter
        assertEq(usdc.balanceOf(address(l1Bridge)), amount, "L1 bridge received tokens");
        assertEq(
            l1Adapter.getMessagePayload(invoiceData.invoiceId).length,
            InvoiceDataLib.encode(invoiceData).length,
            "payload stored"
        );
    }

    function test_bridge_revertsIfNotCalledByBridgeEscrow() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, L2_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.prank(portfolioSafe);
        require(usdc.transfer(address(bridgeEscrow), amount), "transfer failed");
        vm.prank(address(bridgeEscrow));
        usdc.approve(address(l1Adapter), amount);

        vm.prank(unauthorized);
        vm.expectRevert();
        l1Adapter.bridge(messagePayload);
    }

    // ============ L2 Completion (L1->L2 deposit) Tests ============

    /// @notice On L2, completeBridge(messagePayload, "") runs _completeDeposit and transfers tokens from adapter to escrow, then releaseByInvoiceId
    function test_completeBridge_onL2_completesDeposit() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, L2_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(L2_CHAIN_ID);
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(L2_CHAIN_ID);
        SuperchainBridgeAdapter destAdapter = _setupL2Adapter(destEscrow);

        // Simulate bridge delivered tokens to adapter on L2 (canonical bridge could send to escrow; adapter still supports "arrived at adapter" path)
        usdc.mint(address(destAdapter), amount);

        bytes32 invoiceHash = bytes32(uint256(uint192(invoiceData.checksum24)));
        assertFalse(destEscrow.isInvoiceCompleted(invoiceHash), "invoice not completed yet");

        uint256 portfolioBalanceBefore = usdc.balanceOf(portfolioSafe);
        vm.prank(operator);
        destAdapter.completeBridge(messagePayload, "");

        assertTrue(destEscrow.isInvoiceCompleted(invoiceHash), "invoice completed");
        assertEq(usdc.balanceOf(portfolioSafe) - portfolioBalanceBefore, amount, "portfolio received tokens");
    }

    function test_completeBridge_revertsForEmptyPayload() public {
        vm.chainId(L2_CHAIN_ID);
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(L2_CHAIN_ID);
        SuperchainBridgeAdapter destAdapter = _setupL2Adapter(destEscrow);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(InvalidCompletionData.selector));
        destAdapter.completeBridge("", "");
    }

    function test_completeBridge_revertsIfNotOperator() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, L2_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

        vm.chainId(L2_CHAIN_ID);
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(L2_CHAIN_ID);
        SuperchainBridgeAdapter destAdapter = _setupL2Adapter(destEscrow);
        usdc.mint(address(destAdapter), amount);

        vm.prank(unauthorized);
        vm.expectRevert();
        destAdapter.completeBridge(messagePayload, "");
    }

    // ============ L2 -> L1 Withdrawal Tests ============

    function test_bridge_l2ToL1_initiatesWithdrawal() public {
        vm.chainId(L2_CHAIN_ID);
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(L2_CHAIN_ID);
        SuperchainBridgeAdapter destAdapter = _setupL2Adapter(destEscrow);

        uint256 amount = 1000 * 10 ** usdc.decimals();
        _approveToken(address(usdc), address(destEscrow), amount);
        vm.prank(portfolioSafe);
        destEscrow.depositAndBridge(SOURCE_CHAIN_ID, USDC_SYMBOL, amount, address(destAdapter));

        assertEq(usdc.balanceOf(address(l2Bridge)), amount, "L2 bridge received tokens");
    }

    // ============ Prove & Finalize Withdrawal (L2->L1) Tests ============

    function test_finalizeWithdrawal_releasesToTarget() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1 ether;

        // Simulate we are on L1 after a withdrawal was initiated on L2 and proven
        BridgeEscrow l1Escrow = bridgeEscrow;
        vm.prank(admin);
        l1Escrow.registerAsset(WETH_SYMBOL, address(0));

        address l1AdapterImpl = address(new SuperchainBridgeAdapter());
        address payable l1AdapterProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                l1AdapterImpl,
                abi.encodeCall(
                    SuperchainBridgeAdapter.initialize,
                    (
                        admin,
                        address(l1Escrow),
                        address(l1Bridge),
                        address(0),
                        address(1),
                        address(0),
                        address(optimismPortal),
                        "1.0.0"
                    )
                )
            ));
        SuperchainBridgeAdapter l1Ad = SuperchainBridgeAdapter(l1AdapterProxy);
        vm.prank(admin);
        l1Ad.grantRole(keccak256("OPERATOR_ROLE"), operator);
        vm.prank(admin);
        l1Escrow.authorizeAdapter(address(l1Ad));

        // Build withdrawal tx that would send ETH to escrow
        Types.WithdrawalTransaction memory wtx = Types.WithdrawalTransaction({
            nonce: 1, sender: address(l2Bridge), target: address(l1Escrow), value: amount, gasLimit: 200000, data: ""
        });
        bytes32 withdrawalHash =
            keccak256(abi.encodePacked(wtx.nonce, wtx.sender, wtx.target, wtx.value, wtx.gasLimit, wtx.data));
        // Map withdrawal hash to invoice so adapter can emit / track (in real flow adapter sets this on L2)
        // We can't set storage on the adapter from here without a setter; the test validates portal finalize
        vm.prank(admin);
        optimismPortal.proveWithdrawalTransaction(
            wtx, 0, Types.OutputRootProof(bytes32(0), bytes32(0), bytes32(0), bytes32(0)), new bytes[](0)
        );

        assertTrue(optimismPortal.provenWithdrawals(withdrawalHash), "withdrawal proven");
        uint256 escrowBalanceBefore = address(l1Escrow).balance;
        vm.prank(operator);
        optimismPortal.finalizeWithdrawalTransaction(wtx);
        assertEq(address(l1Escrow).balance - escrowBalanceBefore, amount, "escrow received ETH");
    }

    // ============ Configuration Tests ============

    function test_setL1Bridge_updatesBridge() public {
        vm.chainId(SOURCE_CHAIN_ID);
        MockL1StandardBridge newBridge = new MockL1StandardBridge();
        vm.prank(admin);
        l1Adapter.setL1Bridge(address(newBridge));
        assertEq(address(l1Adapter.l1Bridge()), address(newBridge));
    }

    function test_setL1Bridge_revertsIfNotAdmin() public {
        vm.chainId(SOURCE_CHAIN_ID);
        vm.prank(unauthorized);
        vm.expectRevert();
        l1Adapter.setL1Bridge(address(1));
    }

    function test_setDefaultL2GasLimit_updatesGasLimit() public {
        vm.prank(admin);
        l1Adapter.setDefaultL2GasLimit(300000);
        assertEq(l1Adapter.defaultL2GasLimit(), 300000);
    }

    function test_getMessagePayload_returnsStoredPayload() public {
        vm.chainId(SOURCE_CHAIN_ID);
        uint256 amount = 1000 * 10 ** usdc.decimals();
        InvoiceDataLib.InvoiceData memory invoiceData =
            _createInvoiceData(SOURCE_CHAIN_ID, L2_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        _approveToken(address(usdc), address(bridgeEscrow), amount);
        vm.prank(portfolioSafe);
        bridgeEscrow.depositAndBridge(L2_CHAIN_ID, USDC_SYMBOL, amount, address(l1Adapter));

        bytes memory stored = l1Adapter.getMessagePayload(invoiceData.invoiceId);
        assertEq(stored.length, InvoiceDataLib.encode(invoiceData).length);
        InvoiceDataLib.InvoiceData memory decoded = InvoiceDataLib.decode(stored);
        assertEq(decoded.invoiceId, invoiceData.invoiceId);
    }
}
