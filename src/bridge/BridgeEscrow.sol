// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IBridgeEscrow} from "./IBridgeEscrow.sol";
import {IBridgeAdapter} from "./IBridgeAdapter.sol";
import "src/errors.sol";
import "src/constants.sol";

/// @title BridgeEscrow
/// @notice Tracks assets in transit across chains and maintains invoice ledger
/// @author kpk
contract BridgeEscrow is Initializable, AccessControlUpgradeable, IBridgeEscrow {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    //
    // Constants
    //

    /// @notice Role for operators who can cancel invoices
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    //
    // State Variables
    //

    /// @notice Invoice storage
    mapping(bytes32 => Invoice) public invoices;

    /// @notice Active invoices per portfolio safe
    mapping(address => EnumerableSet.Bytes32Set) private _activeInvoices;

    /// @notice Total in-transit balance per asset
    mapping(address => uint256) public inTransitBalances;

    /// @notice In-transit balance per portfolio safe and asset
    mapping(address => mapping(address => uint256)) public inTransitBalancesBySafe;

    /// @notice Authorized portfolio safes
    EnumerableSet.AddressSet private _authorizedPortfolioSafes;

    /// @notice Authorized bridge adapters
    EnumerableSet.AddressSet private _authorizedAdapters;

    /// @notice Current chain ID
    uint64 public chainId;

    /// @notice Tracks completed invoices by invoiceId for bookkeeping
    mapping(bytes32 => bool) public completedInvoices;

    /// @notice Maps asset symbol to asset address on this chain
    /// @dev Format: assetRegistry[symbol] = assetAddress
    mapping(bytes6 => address) public assetRegistry;

    //
    // Constructor
    //

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    //
    // Initialization
    //

    /// @notice Initializes the BridgeEscrow contract
    /// @param admin_ The admin address
    /// @param chainId_ The chain ID where this contract is deployed
    /// @param initialPortfolioSafes Array of initial authorized portfolio safes
    /// @param initialAdapters Array of initial authorized adapters
    function initialize(
        address admin_,
        uint64 chainId_,
        address[] memory initialPortfolioSafes,
        address[] memory initialAdapters
    ) external initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        chainId = chainId_;

        // Authorize initial portfolio safes
        for (uint256 i = 0; i < initialPortfolioSafes.length; i++) {
            _authorizePortfolioSafe(initialPortfolioSafes[i]);
        }

        // Authorize initial adapters
        for (uint256 i = 0; i < initialAdapters.length; i++) {
            _authorizeAdapter(initialAdapters[i]);
        }
    }

    //
    // Receive Function
    //

    /// @notice Allows contract to receive native tokens
    receive() external payable {}

    //
    // Core Functions
    //

    /// @inheritdoc IBridgeEscrow
    function depositAndBridge(
        uint64 destinationChainId,
        bytes6 assetSymbol,
        uint256 amount,
        address adapter,
        bytes calldata bridgeData
    ) external payable returns (bytes32 invoiceId) {
        // Only authorized portfolio safes can deposit
        if (!_authorizedPortfolioSafes.contains(msg.sender)) {
            revert NotAuthorized();
        }

        // Verify adapter is authorized
        if (!_authorizedAdapters.contains(adapter)) {
            revert NotAuthorized();
        }

        if (amount == 0) revert InvalidArguments();
        if (destinationChainId == chainId) revert InvalidArguments(); // Can't bridge to same chain

        // Look up asset address from symbol
        address asset = assetRegistry[assetSymbol];
        if (asset == address(0)) revert InvalidArguments(); // Asset not registered

        // Generate invoice ID with checksum (no nonce needed)
        invoiceId = _generateInvoiceId(chainId, destinationChainId, msg.sender, assetSymbol);

        // Create invoice with BRIDGING status (since we bridge immediately)
        Invoice memory invoice = Invoice({
            invoiceId: invoiceId,
            sourceChainId: chainId,
            destinationChainId: destinationChainId,
            portfolioSafe: msg.sender,
            asset: asset,
            amount: amount,
            timestamp: block.timestamp,
            status: InvoiceStatus.BRIDGING
        });

        invoices[invoiceId] = invoice;
        _activeInvoices[msg.sender].add(invoiceId);

        // Transfer assets from portfolio safe
        if (asset == address(0)) {
            // Native token
            if (msg.value != amount) revert InvalidArguments();
            // Contract already holds native tokens via receive()
        } else {
            // ERC20 token
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }

        // Update in-transit balances
        inTransitBalances[asset] += amount;
        inTransitBalancesBySafe[msg.sender][asset] += amount;

        emit InvoiceCreated(invoiceId, msg.sender, asset, amount, chainId, destinationChainId);

        emit AssetsDeposited(invoiceId, asset, amount);

        // Immediately transfer assets to adapter
        if (asset == address(0)) {
            // Native token
            (bool success,) = adapter.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            // ERC20 token
            IERC20(asset).safeTransfer(adapter, amount);
        }

        // Call adapter's bridge function
        IBridgeAdapter(adapter).bridge(invoiceId, asset, amount, bridgeData);
    }

    /// @notice Releases funds based on invoice ID validation
    /// @param invoiceId The invoice ID to decode and validate
    /// @param portfolioSafe The portfolio safe address (must match decoded invoiceId)
    /// @param amount The amount to release
    /// @dev This function decodes the invoiceId, looks up asset from symbol, validates all parameters match,
    ///      and releases the funds if all validations pass. Note: Invoice status updates should only occur on the source chain.
    function releaseByInvoiceId(
        bytes32 invoiceId,
        address portfolioSafe,
        uint256 amount
    ) external {
        // Check if this invoiceId has already been completed (bookkeeping check)
        if (completedInvoices[invoiceId]) {
            revert InvoiceAlreadyExists(); // Invoice already completed
        }

        // Decode invoice ID (validates checksum internally)
        (uint24 sourceChainId, uint24 destinationChainId, address decodedPortfolioSafe, bytes6 assetSymbol) =
            this.decodeInvoiceId(invoiceId);

        // Validate destination chain matches current chain
        if (uint64(destinationChainId) != chainId) {
            revert InvalidArguments(); // Wrong destination chain
        }

        // Verify portfolio safe is authorized (check full address first)
        if (!_authorizedPortfolioSafes.contains(portfolioSafe)) {
            revert NotAuthorized();
        }

        // Validate portfolio safe matches decoded invoiceId (compare only lower 10 bytes since it's truncated)
        // The decoded address is padded with zeros, so we compare only the lower 80 bits
        if (uint80(uint160(portfolioSafe)) != uint80(uint160(decodedPortfolioSafe))) {
            revert InvalidArguments(); // Portfolio safe mismatch
        }

        // Look up asset address from symbol
        address asset = assetRegistry[assetSymbol];
        if (asset == address(0)) revert InvalidArguments(); // Asset not registered

        // Mark invoice as completed for bookkeeping (invoice state only exists on source chain)
        completedInvoices[invoiceId] = true;

        // Decrease in-transit balances
        if (inTransitBalances[asset] < amount) revert InsufficientBalance();
        inTransitBalances[asset] -= amount;
        inTransitBalancesBySafe[portfolioSafe][asset] -= amount;

        // Transfer assets to portfolio safe
        if (asset == address(0)) {
            (bool success,) = portfolioSafe.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(portfolioSafe, amount);
        }

        // Only emit AssetsReleased - InvoiceStatusUpdated should be emitted on source chain
        emit AssetsReleased(invoiceId, sourceChainId, asset, amount, portfolioSafe);
    }

    //
    // Operator Functions
    //

    /// @inheritdoc IBridgeEscrow
    function cancelInvoice(bytes32 invoiceId) external onlyRole(OPERATOR_ROLE) {
        Invoice storage invoice = invoices[invoiceId];

        if (invoice.invoiceId == bytes32(0)) revert InvoiceNotFound();
        if (invoice.status == InvoiceStatus.COMPLETED) revert InvalidInvoiceStatus();
        if (invoice.status == InvoiceStatus.CANCELLED) revert InvalidInvoiceStatus();

        address asset = invoice.asset;
        uint256 amount = invoice.amount;

        // Verify assets are in the contract before allowing cancellation
        if (asset == address(0)) {
            // Native token - check contract balance
            if (address(this).balance < amount) revert InsufficientBalance();
        } else {
            // ERC20 token - check contract balance
            if (IERC20(asset).balanceOf(address(this)) < amount) revert InsufficientBalance();
        }

        InvoiceStatus oldStatus = invoice.status;
        invoice.status = InvoiceStatus.CANCELLED;

        // Decrease in-transit balances
        inTransitBalances[asset] -= amount;
        inTransitBalancesBySafe[invoice.portfolioSafe][asset] -= amount;

        // Return assets to portfolio safe
        if (asset == address(0)) {
            (bool success,) = invoice.portfolioSafe.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(invoice.portfolioSafe, amount);
        }

        // Remove from active invoices
        _activeInvoices[invoice.portfolioSafe].remove(invoiceId);

        emit InvoiceStatusUpdated(invoiceId, oldStatus, InvoiceStatus.CANCELLED);
        emit AssetsReleased(invoiceId, invoice.sourceChainId, asset, amount, invoice.portfolioSafe);
    }

    /// @notice Marks invoices as completed for bookkeeping purposes (source chain only)
    /// @param invoiceIds Array of invoice IDs to mark as completed
    /// @dev This function should be called by an operator after assets have been released on the destination chain.
    ///      It updates the invoice status on the source chain for bookkeeping purposes only.
    ///      Invalid invoices (not found or wrong status) are skipped and processing continues.
    function markInvoiceCompleted(bytes32[] calldata invoiceIds) external onlyRole(OPERATOR_ROLE) {
        uint256 length = invoiceIds.length;
        bytes32[] memory failedInvoiceIds = new bytes32[](length);
        uint256 failedCount = 0;

        for (uint256 i = 0; i < length; i++) {
            bytes32 invoiceId = invoiceIds[i];
            Invoice storage invoice = invoices[invoiceId];

            // Skip if invoice doesn't exist or is not in BRIDGING status
            if (invoice.invoiceId == bytes32(0)) {
                failedInvoiceIds[failedCount] = invoiceId;
                failedCount++;
                continue;
            }
            if (invoice.status != InvoiceStatus.BRIDGING) {
                failedInvoiceIds[failedCount] = invoiceId;
                failedCount++;
                continue;
            }

            InvoiceStatus oldStatus = invoice.status;
            invoice.status = InvoiceStatus.COMPLETED;

            // Remove from active invoices
            _activeInvoices[invoice.portfolioSafe].remove(invoiceId);

            emit InvoiceStatusUpdated(invoiceId, oldStatus, InvoiceStatus.COMPLETED);
        }

        // Emit event for failed invoice completions if any
        if (failedCount > 0) {
            // Resize array to actual failed count
            bytes32[] memory failed = new bytes32[](failedCount);
            for (uint256 i = 0; i < failedCount; i++) {
                failed[i] = failedInvoiceIds[i];
            }
            emit InvoiceCompletionFailed(failed);
        }
    }

    /// @notice Registers an asset with its symbol on this chain
    /// @param symbol The asset symbol (bytes6, e.g., "USDC  " or "WETH  ")
    /// @param asset The asset address
    function registerAsset(bytes6 symbol, address asset) external onlyRole(OPERATOR_ROLE) {
        if (asset == address(0)) revert InvalidArguments();
        assetRegistry[symbol] = asset;
        emit AssetRegistered(symbol, asset);
    }

    /// @notice Unregisters an asset symbol
    /// @param symbol The asset symbol to unregister
    function unregisterAsset(bytes6 symbol) external onlyRole(OPERATOR_ROLE) {
        delete assetRegistry[symbol];
        emit AssetUnregistered(symbol);
    }

    //
    // View Functions
    //

    /// @inheritdoc IBridgeEscrow
    function getInvoice(bytes32 invoiceId) external view override returns (Invoice memory) {
        return invoices[invoiceId];
    }

    /// @inheritdoc IBridgeEscrow
    function getActiveInvoices(address portfolioSafe) external view override returns (bytes32[] memory) {
        return _activeInvoices[portfolioSafe].values();
    }

    /// @inheritdoc IBridgeEscrow
    function getInTransitBalance(address asset) external view override returns (uint256) {
        return inTransitBalances[asset];
    }

    /// @inheritdoc IBridgeEscrow
    function getInTransitBalanceFor(address portfolioSafe, address asset) external view override returns (uint256) {
        return inTransitBalancesBySafe[portfolioSafe][asset];
    }

    /// @inheritdoc IBridgeEscrow
    function isAuthorizedPortfolioSafe(address safe) external view override returns (bool) {
        return _authorizedPortfolioSafes.contains(safe);
    }

    /// @inheritdoc IBridgeEscrow
    function isAuthorizedAdapter(address adapter) external view override returns (bool) {
        return _authorizedAdapters.contains(adapter);
    }

    /// @notice Checks if an invoice has been completed
    /// @param invoiceId The invoice ID to check
    /// @return True if the invoice has been completed
    function isInvoiceCompleted(bytes32 invoiceId) external view returns (bool) {
        return completedInvoices[invoiceId];
    }

    //
    // Admin Functions
    //

    /// @notice Authorizes a portfolio safe
    /// @param safe The portfolio safe address to authorize
    function authorizePortfolioSafe(address safe) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _authorizePortfolioSafe(safe);
        emit PortfolioSafeAuthorized(safe);
    }

    /// @notice Revokes authorization for a portfolio safe
    /// @param safe The portfolio safe address to revoke
    function revokePortfolioSafe(address safe) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _authorizedPortfolioSafes.remove(safe);
        emit PortfolioSafeRevoked(safe);
    }

    /// @notice Authorizes a bridge adapter
    /// @param adapter The adapter address to authorize
    function authorizeAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _authorizeAdapter(adapter);
        emit AdapterAuthorized(adapter);
    }

    /// @notice Revokes authorization for a bridge adapter
    /// @param adapter The adapter address to revoke
    function revokeAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _authorizedAdapters.remove(adapter);
        emit AdapterRevoked(adapter);
    }

    //
    // Internal Functions
    //

    /// @notice Generates a unique invoice ID (decodable with checksum)
    /// @param sourceChainId Source chain ID
    /// @param destinationChainId Destination chain ID
    /// @param portfolioSafe Portfolio safe address
    /// @param assetSymbol Asset symbol (bytes6, e.g., "USDC  " or "WETH  ")
    /// @return invoiceId The generated invoice ID
    /// @dev Encoding: [sourceChainId (3 bytes) | destinationChainId (3 bytes) | portfolioSafe truncated (10 bytes) | assetSymbol (6 bytes) | checksum (10 bytes)]
    /// @dev Checksum is calculated as keccak256 of the other fields, truncated to 10 bytes
    function _generateInvoiceId(
        uint64 sourceChainId,
        uint64 destinationChainId,
        address portfolioSafe,
        bytes6 assetSymbol
    ) internal pure returns (bytes32) {
        // Pack data without checksum: sourceChainId (3) + destinationChainId (3) + portfolioSafe (10) + assetSymbol (6) = 22 bytes
        bytes memory data = abi.encodePacked(
            uint24(sourceChainId),
            uint24(destinationChainId),
            uint80(uint160(portfolioSafe)), // Truncate to 10 bytes
            assetSymbol
        );

        // Calculate checksum (first 10 bytes of keccak256 hash)
        bytes32 hash = keccak256(data);
        uint80 checksum = uint80(uint256(hash) >> 176);

        // Pack with checksum: data (22 bytes) + checksum (10 bytes) = 32 bytes
        return bytes32(
            (uint256(uint24(sourceChainId)) << 232) |
            (uint256(uint24(destinationChainId)) << 208) |
            (uint256(uint80(uint160(portfolioSafe))) << 128) |
            (uint256(uint48(assetSymbol)) << 80) |
            uint256(checksum)
        );
    }

    /// @notice Decodes an invoice ID into its components and validates the checksum
    /// @param invoiceId The invoice ID to decode
    /// @return sourceChainId Source chain ID (truncated to uint24)
    /// @return destinationChainId Destination chain ID (truncated to uint24)
    /// @return portfolioSafe Portfolio safe address (truncated to 10 bytes, padded with zeros)
    /// @return assetSymbol Asset symbol (bytes6)
    /// @dev Reverts if the checksum is invalid
    function decodeInvoiceId(bytes32 invoiceId)
        external
        pure
        returns (
            uint24 sourceChainId,
            uint24 destinationChainId,
            address portfolioSafe,
            bytes6 assetSymbol
        )
    {
        uint256 id = uint256(invoiceId);
        sourceChainId = uint24(id >> 232);
        destinationChainId = uint24(id >> 208);
        uint80 portfolioSafeTruncated = uint80(id >> 128);
        portfolioSafe = address(uint160(portfolioSafeTruncated));
        assetSymbol = bytes6(uint48(id >> 80));
        uint80 storedChecksum = uint80(id);

        // Reconstruct data without checksum (using truncated portfolioSafe)
        bytes memory data = abi.encodePacked(
            sourceChainId,
            destinationChainId,
            portfolioSafeTruncated,
            assetSymbol
        );

        // Calculate expected checksum (first 10 bytes of hash)
        bytes32 hash = keccak256(data);
        uint80 expectedChecksum = uint80(uint256(hash) >> 176);

        // Validate checksum - revert if invalid
        if (storedChecksum != expectedChecksum) {
            revert InvalidInvoice(); // Invalid checksum
        }
    }

    /// @notice Internal function to authorize a portfolio safe
    /// @param safe The portfolio safe address
    function _authorizePortfolioSafe(address safe) internal {
        if (safe == address(0)) revert InvalidArguments();
        _authorizedPortfolioSafes.add(safe);
    }

    /// @notice Internal function to authorize an adapter
    /// @param adapter The adapter address
    function _authorizeAdapter(address adapter) internal {
        if (adapter == address(0)) revert InvalidArguments();
        // Verify adapter implements IBridgeAdapter interface
        // Note: We check this by attempting to call a view function
        try IBridgeAdapter(adapter).bridgeProvider() returns (
            string memory
        ) {
        // Interface check passed
        }
        catch {
            revert InvalidArguments();
        }
        _authorizedAdapters.add(adapter);
    }
}

