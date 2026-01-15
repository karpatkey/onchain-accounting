// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "src/bridge/BridgeEscrow.sol";
import "src/bridge/InvoiceDataLib.sol";
import "test/mocks/tokens.sol";

/// @title BridgeTestBase
/// @notice Base test contract for bridge adapter tests
/// @dev Provides common setup for BridgeEscrow and test utilities
abstract contract BridgeTestBase is Test {
    // Test accounts
    address public admin = makeAddr("admin");
    address public operator = makeAddr("operator");
    address public portfolioSafe = makeAddr("portfolioSafe");
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

    // Asset symbols (bytes6, right-padded with spaces)
    bytes6 public constant USDC_SYMBOL = "USDC  ";
    bytes6 public constant WETH_SYMBOL = "WETH  ";
    bytes6 public constant DAI_SYMBOL = "DAI   ";

    function setUp() public virtual {
        _setupTokens();
        _setupBridgeEscrow();
        _setupLabels();
    }

    function _setupTokens() internal {
        usdc = new Mock_ERC20("USDC", 6);
        weth = new Mock_ERC20("WETH", 18);
        dai = new Mock_ERC20("DAI", 18);

        // Mint tokens to portfolio safe
        usdc.mint(portfolioSafe, INITIAL_BALANCE);
        weth.mint(portfolioSafe, INITIAL_BALANCE);
        dai.mint(portfolioSafe, INITIAL_BALANCE);
    }

    function _setupBridgeEscrow() internal {
        // Deploy BridgeEscrow implementation
        address bridgeEscrowImpl = address(new BridgeEscrow());

        // Deploy proxy
        address[] memory initialSafes = new address[](1);
        initialSafes[0] = portfolioSafe;

        address[] memory initialAdapters = new address[](0); // Will be added per test

        address payable bridgeEscrowProxy = payable(UnsafeUpgrades.deployUUPSProxy(
                bridgeEscrowImpl,
                abi.encodeCall(BridgeEscrow.initialize, (admin, SOURCE_CHAIN_ID, initialSafes, initialAdapters))
            ));

        bridgeEscrow = BridgeEscrow(bridgeEscrowProxy);

        // Grant operator role to admin and operator
        vm.startPrank(admin);
        bridgeEscrow.grantRole(keccak256("OPERATOR_ROLE"), admin);
        bridgeEscrow.grantRole(keccak256("OPERATOR_ROLE"), operator);
        vm.stopPrank();

        // Register assets (requires OPERATOR_ROLE)
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
        vm.label(operator, "operator");
        vm.label(portfolioSafe, "portfolioSafe");
    }

    /// @notice Helper to authorize an adapter
    function _authorizeAdapter(address adapter) internal {
        vm.startPrank(admin);
        bridgeEscrow.authorizeAdapter(adapter);
        vm.stopPrank();
    }

    /// @notice Helper to create a valid invoice data
    function _createInvoiceData(
        uint64 sourceChainId,
        uint64 destChainId,
        address safe,
        bytes6 assetSymbol,
        uint256 amount
    ) internal view returns (InvoiceDataLib.InvoiceData memory) {
        bytes32 invoiceId = _generateInvoiceId(sourceChainId, destChainId, safe, assetSymbol);
        uint8 timestampByte = uint8(block.timestamp);
        bytes24 checksum24 = _calculateChecksum(invoiceId, amount, timestampByte);

        return InvoiceDataLib.InvoiceData({
            invoiceId: invoiceId,
            sourceChainId: uint24(sourceChainId),
            destinationChainId: uint24(destChainId),
            portfolioSafe: safe,
            assetSymbol: assetSymbol,
            amount: amount,
            timestampByte: timestampByte,
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
            (uint256(uint24(sourceChainId)) << 232) | (uint256(uint24(destChainId)) << 208)
                | (uint256(uint160(safe)) << 48) | uint256(uint48(assetSymbol))
        );
    }

    /// @notice Helper to calculate checksum (matches BridgeEscrow logic)
    function _calculateChecksum(bytes32 invoiceId, uint256 amount, uint8 timestampByte)
        internal
        pure
        returns (bytes24)
    {
        bytes32 hash = keccak256(abi.encodePacked(invoiceId, amount, timestampByte));
        return bytes24(hash); // First 24 bytes
    }

    /// @notice Helper to approve token spending
    function _approveToken(address token, address spender, uint256 amount) internal {
        vm.startPrank(portfolioSafe);
        IERC20(token).approve(spender, amount);
        vm.stopPrank();
    }

    /// @notice Helper to get asset address from symbol
    function _getAssetAddress(bytes6 symbol) internal view returns (address) {
        if (symbol == USDC_SYMBOL) return address(usdc);
        if (symbol == WETH_SYMBOL) return address(weth);
        if (symbol == DAI_SYMBOL) return address(dai);
        revert("Unknown asset symbol");
    }
}
