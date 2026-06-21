// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test, console} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {CctpBridgeAdapter} from "src/bridge/adapters/CctpBridgeAdapter.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
import {ICctpBridgeAdapter} from "src/bridge/adapters/interfaces/ICctpBridgeAdapter.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {
    MockProvenanceMessageTransmitter,
    MockProvenanceTokenMessenger
} from "test/bridge/mocks/CctpProvenanceMocks.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";

/// @notice Regression for the (now fixed) HIGH "domain-0 sentinel" bug.
///
/// The CCTP adapter previously used `destinationDomain == 0` as a "not configured" sentinel, but the
/// canonical CCTP domain for Ethereum mainnet IS 0. As a result, every attempt to bridge USDC *into*
/// Ethereum reverted with `InvalidDomain`, making the Ethereum leg of CCTP unusable from any
/// non-Ethereum source chain.
///
/// The fix replaces the sentinel with an explicit `domainConfigured` mapping, so domain 0 is a fully
/// valid, configured destination. This test asserts the bridge to Ethereum now SUCCEEDS.
contract Regression_CctpDomainZero is Test {
    address public admin = makeAddr("admin");
    address public manager = makeAddr("manager");
    address public account = makeAddr("account");

    BridgeEscrow public srcEscrow;
    CctpBridgeAdapter public srcAdapter;
    Mock_ERC20 public usdc;
    MockProvenanceTokenMessenger public tokenMessenger;
    MockProvenanceMessageTransmitter public messageTransmitter;

    // Bridge USDC from Base (8453, domain=6) -> Ethereum (1, domain=0)
    uint64 public constant BASE_CHAIN_ID = 8453;
    uint64 public constant ETHEREUM_CHAIN_ID = 1;

    function setUp() public {
        vm.chainId(uint256(BASE_CHAIN_ID));

        usdc = new Mock_ERC20("USDC", 6);
        messageTransmitter = new MockProvenanceMessageTransmitter(
            6,
            /* localDomain */
            address(usdc)
        );
        tokenMessenger = new MockProvenanceTokenMessenger();

        // Deploy escrow
        address impl = address(new BridgeEscrow());
        address[] memory initialAccounts = new address[](1);
        initialAccounts[0] = account;
        address[] memory initialAdapters = new address[](0);
        address payable escrowProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                impl, abi.encodeCall(BridgeEscrow.initialize, (admin, BASE_CHAIN_ID, initialAccounts, initialAdapters))
            ));
        srcEscrow = BridgeEscrow(escrowProxy);
        vm.startPrank(admin);
        srcEscrow.grantRole(MANAGER, admin);
        srcEscrow.registerAsset("USDC", address(usdc));
        vm.stopPrank();

        // Deploy CCTP adapter — initialize pre-configures chainIdToDomain[1] = 0 (Ethereum)
        address adapterImpl = address(new CctpBridgeAdapter());
        address adapterProxy = UnsafeUpgrades.deployUUPSProxy(
            adapterImpl,
            abi.encodeCall(
                CctpBridgeAdapter.initialize,
                (admin, address(srcEscrow), address(tokenMessenger), address(messageTransmitter), "1.0.0")
            )
        );
        srcAdapter = CctpBridgeAdapter(adapterProxy);

        vm.prank(admin);
        srcEscrow.authorizeAdapter(adapterProxy);
    }

    /// @notice Regression: chainIdToDomain[1] = 0 (Ethereum's canonical domain) is an explicitly
    ///         configured domain (domainConfigured[1] == true), so bridging to Ethereum SUCCEEDS.
    function test_regression_cctpBridgeToEthereumSucceeds() public {
        // 1. Ethereum is configured with domain 0 AND explicitly flagged as configured.
        assertEq(srcAdapter.getDomainForChain(ETHEREUM_CHAIN_ID), 0, "ETH mapped to domain 0 (correct CCTP value)");
        assertTrue(srcAdapter.domainConfigured(ETHEREUM_CHAIN_ID), "ETH domain explicitly configured (not a sentinel)");

        // 2. Bridge USDC from Base -> Ethereum. This must NOT revert (the domain-0 bug is fixed).
        uint256 amount = 1_000e6;
        usdc.mint(account, amount);
        vm.startPrank(account);
        usdc.approve(address(srcEscrow), amount);
        srcEscrow.depositAndBridge(ETHEREUM_CHAIN_ID, "USDC", amount, address(srcAdapter));
        vm.stopPrank();

        assertEq(tokenMessenger.nonce(), 1, "burn happened: Ethereum-bound bridge succeeded");
        console.log("Bridge to Ethereum (domain 0) succeeded; domain-0 sentinel bug is fixed.");

        // 3. An unconfigured chain still reverts with InvalidDomain (sanity: the guard still works).
        uint256 amount2 = 1_000e6;
        usdc.mint(account, amount2);
        vm.startPrank(account);
        usdc.approve(address(srcEscrow), amount2);
        vm.expectRevert(ICctpBridgeAdapter.InvalidDomain.selector);
        srcEscrow.depositAndBridge(
            123456,
            /* unconfigured chain */
            "USDC",
            amount2,
            address(srcAdapter)
        );
        vm.stopPrank();
    }
}
