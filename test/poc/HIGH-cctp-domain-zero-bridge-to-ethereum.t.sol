// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test, console} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {CctpBridgeAdapter} from "src/bridge/adapters/CctpBridgeAdapter.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
import {ICctpBridgeAdapter} from "src/bridge/adapters/interfaces/ICctpBridgeAdapter.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/bridge/mocks/MockBridgeProtocols.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";

/// @notice PoC: CCTP adapter uses `destinationDomain == 0` as a "not configured" sentinel,
///         but the canonical CCTP domain for Ethereum mainnet IS 0. As a result, every attempt
///         to bridge USDC *into* Ethereum reverts with `InvalidDomain`, making the Ethereum
///         leg of CCTP completely unusable from any non-Ethereum source chain.
contract Poc_CctpDomainZero is Test {
    address public admin = makeAddr("admin");
    address public manager = makeAddr("manager");
    address public account = makeAddr("account");

    BridgeEscrow public srcEscrow;
    CctpBridgeAdapter public srcAdapter;
    Mock_ERC20 public usdc;
    MockTokenMessenger public tokenMessenger;
    MockMessageTransmitter public messageTransmitter;

    // Simulate bridging USDC from Base (8453, domain=6) -> Ethereum (1, domain=0)
    uint64 public constant BASE_CHAIN_ID = 8453;
    uint64 public constant ETHEREUM_CHAIN_ID = 1;

    function setUp() public {
        vm.chainId(uint256(BASE_CHAIN_ID));

        usdc = new Mock_ERC20("USDC", 6);
        messageTransmitter = new MockMessageTransmitter(
            6,
            /* localDomain */
            address(usdc)
        );
        tokenMessenger = new MockTokenMessenger(address(messageTransmitter));

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

    /// @notice Verify the bug: chainIdToDomain[1] = 0 (Ethereum's canonical domain), and the adapter
    ///         treats `domain == 0` as "not configured", so any deposit targeting Ethereum reverts.
    function test_exploit_cctpBridgeToEthereumAlwaysReverts() public {
        // 1. Confirm Ethereum is "configured" with domain 0 by the constructor mapping.
        assertEq(srcAdapter.getDomainForChain(ETHEREUM_CHAIN_ID), 0, "ETH mapped to domain 0 (correct CCTP value)");

        // 2. Try to bridge USDC from Base -> Ethereum. Mint, approve, deposit.
        uint256 amount = 1_000e6;
        usdc.mint(account, amount);
        vm.startPrank(account);
        usdc.approve(address(srcEscrow), amount);
        vm.expectRevert(ICctpBridgeAdapter.InvalidDomain.selector);
        srcEscrow.depositAndBridge(ETHEREUM_CHAIN_ID, "USDC", amount, address(srcAdapter));
        vm.stopPrank();

        // 3. Compare: bridging to a non-zero-domain chain (e.g. Arbitrum, domain=3) does NOT revert.
        //    This proves the bug is specifically the domain-0 sentinel collision, not a generic config issue.
        usdc.mint(account, amount);
        vm.startPrank(account);
        usdc.approve(address(srcEscrow), amount);
        srcEscrow.depositAndBridge(
            42161,
            /* Arbitrum */
            "USDC",
            amount,
            address(srcAdapter)
        );
        vm.stopPrank();
        console.log("Arbitrum bridge succeeded; Ethereum bridge reverted because domain==0 is the sentinel.");
    }
}
