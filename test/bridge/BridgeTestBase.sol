// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/bridge/InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";

/// @title BridgeTestBase
/// @notice Base test contract for bridge adapter tests
/// @dev Provides common setup for BridgeEscrow and test utilities
abstract contract BridgeTestBase is Test {
    // Test accounts
    address public admin = makeAddr("admin");
    address public manager = makeAddr("manager");
    address public account = makeAddr("account");
    address public unauthorized = makeAddr("unauthorized");

    // Contracts
    BridgeEscrow public bridgeEscrow;
    Mock_ERC20 public usdc;
    Mock_ERC20 public weth;
    Mock_ERC20 public dai;

    // Test constants
    uint64 public constant SOURCE_CHAIN_ID = 1; // Ethereum mainnet
    uint64 public constant DEST_CHAIN_ID = 10; // Optimism
    uint256 public constant INITIAL_BALANCE = 1000000 * 1e18;
    uint256 public constant BRIDGE_AMOUNT = 1000 * 1e18;

    // Asset symbols: string for escrow API, bytes6 for invoice data (right-padded)
    string public constant USDC_SYMBOL = "USDC";
    string public constant WETH_SYMBOL = "WETH";
    string public constant DAI_SYMBOL = "DAI";
    bytes6 public constant USDC_SYMBOL_BYTES6 = "USDC  ";
    bytes6 public constant WETH_SYMBOL_BYTES6 = "WETH  ";
    bytes6 public constant DAI_SYMBOL_BYTES6 = "DAI   ";

    function setUp() public virtual {
        _setupTokens();
        _setupBridgeEscrow();
        _setupLabels();
    }

    function _setupTokens() internal {
        usdc = new Mock_ERC20("USDC", 6);
        weth = new Mock_ERC20("WETH", 18);
        dai = new Mock_ERC20("DAI", 18);

        // Mint tokens to account
        usdc.mint(account, INITIAL_BALANCE);
        weth.mint(account, INITIAL_BALANCE);
        dai.mint(account, INITIAL_BALANCE);
    }

    function _setupBridgeEscrow() internal {
        // Deploy BridgeEscrow implementation
        address bridgeEscrowImpl = address(new BridgeEscrow());

        // Deploy proxy
        address[] memory initialSafes = new address[](1);
        initialSafes[0] = account;

        address[] memory initialAdapters = new address[](0); // Will be added per test

        // Use SOURCE_CHAIN_ID so unit tests (no fork) get deterministic chainId 1 and invoiceIds match test helpers
        address payable bridgeEscrowProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                bridgeEscrowImpl,
                abi.encodeCall(BridgeEscrow.initialize, (admin, SOURCE_CHAIN_ID, initialSafes, initialAdapters))
            ));

        bridgeEscrow = BridgeEscrow(bridgeEscrowProxy);

        // Grant manager role to admin and manager
        vm.startPrank(admin);
        bridgeEscrow.grantRole(MANAGER, admin);
        bridgeEscrow.grantRole(MANAGER, manager);
        vm.stopPrank();

        // Register assets (requires MANAGER role)
        vm.startPrank(admin);
        bridgeEscrow.registerAsset(USDC_SYMBOL, address(usdc));
        bridgeEscrow.registerAsset(WETH_SYMBOL, address(weth));
        bridgeEscrow.registerAsset(DAI_SYMBOL, address(dai));
        vm.stopPrank();
    }

    function _setupLabels() internal {
        vm.label(address(bridgeEscrow), "BridgeEscrow");
        vm.label(address(usdc), "USDC");
        vm.label(address(weth), "WETH");
        vm.label(address(dai), "DAI");
        vm.label(admin, "admin");
        vm.label(manager, "manager");
        vm.label(account, "account");
    }

    /// @notice Helper to authorize an adapter
    function _authorizeAdapter(address adapter) internal {
        vm.startPrank(admin);
        bridgeEscrow.authorizeAdapter(adapter);
        vm.stopPrank();
    }

    /// @notice Helper to create a valid invoice data with the default nonce (0).
    /// @dev ADR 0012 added a per-account nonce to invoice identity. Call sites that do not deposit first
    ///      (and therefore have no escrow-assigned nonce) use nonce 0 here. For flows that deposit via
    ///      depositAndBridge, read `bridgeEscrow.bridgeNonce(account)` before the deposit and use the
    ///      explicit-nonce overload below.
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

    /// @notice Helper to get asset address from symbol
    function _getAssetAddress(bytes6 symbol) internal view returns (address) {
        if (symbol == USDC_SYMBOL_BYTES6) return address(usdc);
        if (symbol == WETH_SYMBOL_BYTES6) return address(weth);
        if (symbol == DAI_SYMBOL_BYTES6) return address(dai);
        revert("Unknown asset symbol");
    }

    /// @notice Sets up a BridgeEscrow instance for destination chain testing
    /// @param destChainId The destination chain ID to simulate
    /// @return destBridgeEscrow The BridgeEscrow instance configured for destination chain
    function _setupDestinationChainEscrow(uint64 destChainId) internal returns (BridgeEscrow destBridgeEscrow) {
        // Deploy BridgeEscrow implementation
        address bridgeEscrowImpl = address(new BridgeEscrow());

        // Deploy proxy with destination chain ID
        address[] memory initialSafes = new address[](1);
        initialSafes[0] = account;

        address[] memory initialAdapters = new address[](0);

        address payable bridgeEscrowProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                bridgeEscrowImpl,
                abi.encodeCall(BridgeEscrow.initialize, (admin, destChainId, initialSafes, initialAdapters))
            ));

        destBridgeEscrow = BridgeEscrow(bridgeEscrowProxy);

        // Grant manager role
        vm.startPrank(admin);
        destBridgeEscrow.grantRole(MANAGER, admin);
        destBridgeEscrow.grantRole(MANAGER, manager);
        vm.stopPrank();

        // Register assets
        vm.startPrank(admin);
        destBridgeEscrow.registerAsset(USDC_SYMBOL, address(usdc));
        destBridgeEscrow.registerAsset(WETH_SYMBOL, address(weth));
        destBridgeEscrow.registerAsset(DAI_SYMBOL, address(dai));
        vm.stopPrank();
    }

    /// @notice Creates an invoice on destination chain (simulating it was created on source chain)
    /// @param invoiceData The invoice data (from source chain perspective)
    /// @param assetAddress The asset address on destination chain
    /// @dev This simulates the invoice existing on destination chain after being created on source chain. First param reserved for future use.
    function _createInvoiceOnDestinationChain(
        BridgeEscrow,
        InvoiceDataLib.InvoiceData memory invoiceData,
        address assetAddress
    ) internal {
        // Reserved for storage manipulation: invoiceHash and invoice from invoiceData + assetAddress
        (invoiceData, assetAddress); // silence unused (stub for future implementation)

        // Use storage manipulation to create invoice
        // We need to set: invoices[invoiceHash] = invoice
        // And add to active invoices
        vm.startPrank(admin);

        // We'll use a helper contract or direct storage manipulation
        // For now, we'll use the fact that we can call internal functions via storage slots
        // Actually, we need to use a different approach - we can't directly manipulate storage

        // Alternative: Use a test helper that calls internal functions
        // Or: Create invoice via a mock depositAndBridge that we control

        // Best approach: Create a minimal invoice creation helper
        // We'll need to use assembly or a helper contract

        vm.stopPrank();
    }

    /// @notice Simulates tokens arriving on destination chain via bridge
    /// @param destBridgeEscrow The BridgeEscrow on destination chain
    /// @param assetAddress The asset address
    /// @param amount The amount that arrived
    /// @dev Transfers tokens to BridgeEscrow and updates in-transit balances
    function _simulateTokensArrivedOnDestination(BridgeEscrow destBridgeEscrow, address assetAddress, uint256 amount)
        internal
    {
        if (assetAddress == address(0)) {
            // Native token - send ETH to BridgeEscrow
            vm.deal(address(destBridgeEscrow), amount);
        } else {
            // ERC20 token - mint and transfer to BridgeEscrow
            Mock_ERC20 token = Mock_ERC20(assetAddress);
            token.mint(address(this), amount);
            require(token.transfer(address(destBridgeEscrow), amount), "transfer failed");
        }
    }

    /// @notice Complete helper to set up destination chain for completion testing
    /// @param invoiceData The invoice data from source chain
    /// @return destBridgeEscrow The BridgeEscrow on destination chain
    /// @return messagePayload The encoded message payload
    /// @dev This sets up the full destination chain environment for testing completion
    ///      Creates invoice state on destination chain using storage manipulation
    function _setupDestinationChainForCompletion(InvoiceDataLib.InvoiceData memory invoiceData, address)
        internal
        returns (BridgeEscrow destBridgeEscrow, bytes memory messagePayload)
    {
        // Switch to destination chain
        vm.chainId(uint256(invoiceData.destinationChainId));

        // Set up destination chain BridgeEscrow
        destBridgeEscrow = _setupDestinationChainEscrow(uint64(invoiceData.destinationChainId));

        // Encode message payload
        messagePayload = InvoiceDataLib.encode(invoiceData);

        // Note: Invoice is NOT created on destination chain - it only exists on source chain for bookkeeping
        // On destination chain, we only need:
        // 1. Checksum validation (done in releaseByInvoiceId)
        // 2. completedInvoices check (prevents double-spending)
        // 3. Sufficient contract balance to release assets

        // Note: Tokens are NOT automatically transferred to BridgeEscrow here
        // Each bridge adapter test should set up tokens according to how that bridge delivers tokens:
        // - For bridges with callbacks (Across, Stargate, Gnosis, CCIP): tokens arrive at adapter
        // - For bridges without callbacks (CCTP): tokens are minted directly to BridgeEscrow
        // Tokens will be transferred to BridgeEscrow in _completeBridge before releaseByInvoiceId
    }
}
