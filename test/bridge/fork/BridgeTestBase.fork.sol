// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";

/// @title BridgeTestBase (Fork)
/// @notice Base test contract for fork-based bridge adapter tests
/// @dev Provides fork setup, real contract addresses, and helper functions for testing with real bridge protocols
abstract contract BridgeTestBase is TestEnvConfigurator {
    // Test accounts
    address public admin = makeAddr("admin");
    address public manager = makeAddr("manager");
    address public account = makeAddr("account");

    // Contracts
    BridgeEscrow public bridgeEscrow;

    // Fork IDs
    uint256 public mainnetFork;
    uint256 public optimismFork;

    // Chain IDs
    uint64 public constant MAINNET_CHAIN_ID = 1;
    uint64 public constant OPTIMISM_CHAIN_ID = 10;
    uint64 public constant BASE_CHAIN_ID = 8453;

    // Asset symbols (string for escrow API; bytes6 for invoice data)
    string public constant USDC_SYMBOL = "USDC";
    string public constant WETH_SYMBOL = "WETH";
    string public constant DAI_SYMBOL = "DAI";
    bytes6 public constant USDC_SYMBOL_BYTES6 = "USDC  ";
    bytes6 public constant WETH_SYMBOL_BYTES6 = "WETH  ";
    bytes6 public constant DAI_SYMBOL_BYTES6 = "DAI   ";

    // Real contract addresses (Mainnet)
    address public constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant MAINNET_DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // CCTP addresses (Mainnet)
    address public constant CCTP_TOKEN_MESSENGER = 0xBd3fa81B58Ba92a82136038B25aDec7066af3155;
    address public constant CCTP_MESSAGE_TRANSMITTER = 0x0a992d191DEeC32aFe36203Ad87D7d289a738F81;

    // Superchain addresses (Mainnet) - Optimism OP Mainnet.
    // Source: ethereum-optimism/superchain-registry (superchain/configs/mainnet/op.toml + addresses.json).
    address public constant L1_STANDARD_BRIDGE = 0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1;
    address public constant OPTIMISM_PORTAL = 0xbEb5Fc579115071764c7423A4f12eDde41f106Ed;
    // L1CrossDomainMessengerProxy for OP Mainnet (chain id 10) on Ethereum L1.
    address public constant L1_CROSS_DOMAIN_MESSENGER = 0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1;

    // Superchain addresses (Optimism)
    address public constant L2_STANDARD_BRIDGE = 0x4200000000000000000000000000000000000010;
    address public constant L2_CROSS_DOMAIN_MESSENGER = 0x4200000000000000000000000000000000000007;

    // Optimism token addresses
    address public constant OPTIMISM_USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address public constant OPTIMISM_WETH = 0x4200000000000000000000000000000000000006;

    // Test amounts
    uint256 public constant TEST_AMOUNT_USDC = 1000 * 1e6; // 1000 USDC (6 decimals)
    uint256 public constant TEST_AMOUNT_ETH = 1 ether;
    uint256 public constant TEST_AMOUNT_DAI = 1000 * 1e18;

    // Fork block numbers (recent stable blocks)
    uint256 public constant MAINNET_FORK_BLOCK = 21_000_000; // Adjust to recent block
    uint256 public constant OPTIMISM_FORK_BLOCK = 130_000_000; // Adjust to recent block

    function setUp() public virtual {
        _setupForks();
        _setupBridgeEscrow();
        _setupLabels();
    }

    /// @notice Sets up mainnet fork
    function _setupForks() internal {
        mainnetFork = createForkWithCadence(getAlchemyUrl("eth-mainnet"), MAINNET_FORK_BLOCK);
        optimismFork = createForkWithCadence(getAlchemyUrl("opt-mainnet"), OPTIMISM_FORK_BLOCK);

        // Select mainnet fork by default and set chainId (fork state may not set chainid for non-mainnet)
        vm.selectFork(mainnetFork);
        vm.chainId(MAINNET_CHAIN_ID);
    }

    /// @notice Switches to mainnet fork
    function _selectMainnetFork() internal {
        vm.selectFork(mainnetFork);
        vm.chainId(MAINNET_CHAIN_ID);
        // Note: Don't roll fork here as it resets state and loses deployed contracts
        // If you need a specific block, roll before deploying contracts in setUp()
        // vm.rollFork(MAINNET_FORK_BLOCK);
    }

    /// @notice Switches to Optimism fork
    function _selectOptimismFork() internal {
        vm.selectFork(optimismFork);
        vm.chainId(OPTIMISM_CHAIN_ID);
        // Note: Don't roll fork here as it resets state and loses deployed contracts
        // If you need a specific block, roll before deploying contracts in setUp()
        // vm.rollFork(OPTIMISM_FORK_BLOCK);
    }

    /// @notice Sets up BridgeEscrow on the current fork
    function _setupBridgeEscrow() internal {
        // Deploy BridgeEscrow implementation
        address bridgeEscrowImpl = address(new BridgeEscrow());

        // Deploy proxy
        address[] memory initialSafes = new address[](1);
        initialSafes[0] = account;

        address[] memory initialAdapters = new address[](0); // Will be added per test

        uint64 chainId = _getCurrentChainId();
        address payable bridgeEscrowProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                bridgeEscrowImpl,
                abi.encodeCall(BridgeEscrow.initialize, (admin, chainId, initialSafes, initialAdapters))
            ));

        bridgeEscrow = BridgeEscrow(bridgeEscrowProxy);

        // Grant manager role to admin and manager
        vm.startPrank(admin);
        bridgeEscrow.grantRole(MANAGER, admin);
        bridgeEscrow.grantRole(MANAGER, manager);
        vm.stopPrank();

        // Register assets based on current chain (requires MANAGER role)
        _registerAssets();
    }

    /// @notice Registers assets based on current chain
    function _registerAssets() internal {
        vm.startPrank(admin);

        if (block.chainid == MAINNET_CHAIN_ID) {
            bridgeEscrow.registerAsset(USDC_SYMBOL, MAINNET_USDC);
            bridgeEscrow.registerAsset(WETH_SYMBOL, MAINNET_WETH);
            bridgeEscrow.registerAsset(DAI_SYMBOL, MAINNET_DAI);
        } else if (block.chainid == OPTIMISM_CHAIN_ID) {
            bridgeEscrow.registerAsset(USDC_SYMBOL, OPTIMISM_USDC);
            bridgeEscrow.registerAsset(WETH_SYMBOL, OPTIMISM_WETH);
            // DAI may not be available on Optimism, skip if needed
        }

        vm.stopPrank();
    }

    /// @notice Gets current chain ID from block.chainid
    function _getCurrentChainId() internal view returns (uint64) {
        return uint64(block.chainid);
    }

    /// @notice Sets up labels for debugging
    function _setupLabels() internal {
        vm.label(address(bridgeEscrow), "BridgeEscrow");
        vm.label(admin, "admin");
        vm.label(manager, "manager");
        vm.label(account, "account");

        // Label real contracts
        if (block.chainid == MAINNET_CHAIN_ID) {
            vm.label(MAINNET_USDC, "USDC");
            vm.label(MAINNET_WETH, "WETH");
            vm.label(MAINNET_DAI, "DAI");
            vm.label(CCTP_TOKEN_MESSENGER, "CCTP_TokenMessenger");
            vm.label(CCTP_MESSAGE_TRANSMITTER, "CCTP_MessageTransmitter");
            vm.label(L1_STANDARD_BRIDGE, "L1StandardBridge");
        } else if (block.chainid == OPTIMISM_CHAIN_ID) {
            vm.label(OPTIMISM_USDC, "USDC_OP");
            vm.label(OPTIMISM_WETH, "WETH_OP");
            vm.label(L2_STANDARD_BRIDGE, "L2StandardBridge");
        }
    }

    /// @notice Helper to authorize an adapter
    function _authorizeAdapter(address adapter) internal {
        vm.startPrank(admin);
        bridgeEscrow.authorizeAdapter(adapter);
        vm.stopPrank();
    }

    /// @notice Authorizes an adapter on a specific escrow instance (used for destination-side fork tests).
    function _authorizeAdapterForEscrow(address adapter, BridgeEscrow escrow) internal {
        vm.startPrank(admin);
        escrow.authorizeAdapter(adapter);
        vm.stopPrank();
    }

    /// @notice Deploys a fresh BridgeEscrow proxy on the current fork pinned to `chainIdForEscrow`, grants
    ///         MANAGER to admin+manager, authorizes `account` as a safe, and registers the standard assets so
    ///         destination-side completion tests can release to the account. Mirrors the production escrow
    ///         (UUPS proxy), so `releaseByInvoiceId` validates checksum/replay/account exactly as on-chain.
    /// @dev `account` is registered as an initial safe via `initialize`. Use `vm.chainId(chainIdForEscrow)`
    ///      before completion so the escrow's `block.chainid` checks line up with the destination.
    function _deployDestinationEscrow(uint64 chainIdForEscrow) internal returns (BridgeEscrow destEscrow) {
        address impl = address(new BridgeEscrow());
        address[] memory initialSafes = new address[](1);
        initialSafes[0] = account;
        address[] memory initialAdapters = new address[](0);

        address payable proxy = payable(UnsafeUpgrades.deployUUPSProxy(
                impl, abi.encodeCall(BridgeEscrow.initialize, (admin, chainIdForEscrow, initialSafes, initialAdapters))
            ));
        destEscrow = BridgeEscrow(proxy);

        vm.startPrank(admin);
        destEscrow.grantRole(MANAGER, admin);
        destEscrow.grantRole(MANAGER, manager);
        // Register assets for the chain we are simulating on this fork.
        if (chainIdForEscrow == MAINNET_CHAIN_ID) {
            destEscrow.registerAsset(USDC_SYMBOL, MAINNET_USDC);
            destEscrow.registerAsset(WETH_SYMBOL, MAINNET_WETH);
            destEscrow.registerAsset(DAI_SYMBOL, MAINNET_DAI);
        } else if (chainIdForEscrow == OPTIMISM_CHAIN_ID) {
            destEscrow.registerAsset(USDC_SYMBOL, OPTIMISM_USDC);
            destEscrow.registerAsset(WETH_SYMBOL, OPTIMISM_WETH);
        }
        vm.stopPrank();
    }

    /// @notice Trusted-remote identity for the (CREATE2 same-address) sibling adapter.
    /// @dev ADR 0012 deploys escrow+adapters at the same address on every chain via CREATE2, so the trusted
    ///      remote sibling for a source chain is simply the destination adapter's own address widened to bytes32.
    function _siblingIdentity(address destAdapter) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(destAdapter)));
    }

    /// @notice Funds an account with ETH
    function _fundAccountWithEth(address recipient, uint256 amount) internal {
        vm.deal(recipient, amount);
    }

    /// @notice Funds an account with ERC20 tokens by dealing
    function _fundAccountWithToken(address token, address recipient, uint256 amount) internal {
        // Use deal cheatcode to give tokens
        deal(token, recipient, amount);
    }

    /// @notice Funds account with test amounts
    function _fundAccount() internal {
        if (block.chainid == MAINNET_CHAIN_ID) {
            _fundAccountWithToken(MAINNET_USDC, account, TEST_AMOUNT_USDC);
            _fundAccountWithToken(MAINNET_WETH, account, TEST_AMOUNT_ETH);
            _fundAccountWithEth(account, TEST_AMOUNT_ETH);
        } else if (block.chainid == OPTIMISM_CHAIN_ID) {
            _fundAccountWithToken(OPTIMISM_USDC, account, TEST_AMOUNT_USDC);
            _fundAccountWithToken(OPTIMISM_WETH, account, TEST_AMOUNT_ETH);
            _fundAccountWithEth(account, TEST_AMOUNT_ETH);
        }
    }

    /// @notice Helper to create a valid invoice data with the default nonce (0).
    function _createInvoiceData(
        uint64 sourceChainId,
        uint64 destChainId,
        address safe,
        bytes6 assetSymbol,
        uint256 amount
    ) internal view returns (InvoiceDataLib.InvoiceData memory) {
        return _createInvoiceData(sourceChainId, destChainId, safe, assetSymbol, amount, 0);
    }

    /// @notice Helper to create a valid invoice data with an explicit nonce (ADR 0012).
    function _createInvoiceData(
        uint64 sourceChainId,
        uint64 destChainId,
        address safe,
        bytes6 assetSymbol,
        uint256 amount,
        uint256 nonce
    ) internal view returns (InvoiceDataLib.InvoiceData memory) {
        bytes32 invoiceId = _generateInvoiceId(sourceChainId, destChainId, safe, assetSymbol);
        uint64 timestamp = uint64(block.timestamp);
        bytes24 checksum24 = _calculateChecksum(invoiceId, amount, timestamp, nonce);

        return InvoiceDataLib.InvoiceData({
            invoiceId: invoiceId,
            sourceChainId: SafeCast.toUint24(sourceChainId),
            destinationChainId: SafeCast.toUint24(destChainId),
            account: safe,
            assetSymbol: assetSymbol,
            amount: amount,
            nonce: nonce,
            timestamp: timestamp,
            checksum24: checksum24
        });
    }

    /// @notice Helper to generate invoice ID (matches BridgeEscrow logic)
    function _generateInvoiceId(uint64 sourceChainId, uint64 destChainId, address safe, bytes6 assetSymbol)
        internal
        pure
        returns (bytes32)
    {
        // Pack: sourceChainId (3 bytes) + destChainId (3 bytes) + safe (20 bytes) + assetSymbol (6 bytes) = 32 bytes
        return bytes32(
            (uint256(SafeCast.toUint24(sourceChainId)) << 232) | (uint256(SafeCast.toUint24(destChainId)) << 208)
                | (uint256(uint160(safe)) << 48) | uint256(uint48(assetSymbol))
        );
    }

    /// @notice Helper to calculate checksum (matches BridgeEscrow logic; ADR 0012 nonce in preimage)
    function _calculateChecksum(bytes32 invoiceId, uint256 amount, uint64 timestamp, uint256 nonce)
        internal
        pure
        returns (bytes24)
    {
        return InvoiceDataLib.calculateChecksum(invoiceId, amount, timestamp, nonce);
    }

    /// @notice Helper to approve token spending
    function _approveToken(address token, address spender, uint256 amount) internal {
        vm.startPrank(account);
        IERC20(token).approve(spender, amount);
        vm.stopPrank();
    }

    /// @notice Gets real token address for a symbol on current chain
    function _getRealTokenAddress(bytes6 symbol) internal view returns (address) {
        if (symbol == USDC_SYMBOL_BYTES6) {
            return block.chainid == MAINNET_CHAIN_ID ? MAINNET_USDC : OPTIMISM_USDC;
        } else if (symbol == WETH_SYMBOL_BYTES6) {
            return block.chainid == MAINNET_CHAIN_ID ? MAINNET_WETH : OPTIMISM_WETH;
        } else if (symbol == DAI_SYMBOL_BYTES6) {
            return MAINNET_DAI; // DAI may not be on Optimism
        }
        revert("Unknown asset symbol");
    }
}
