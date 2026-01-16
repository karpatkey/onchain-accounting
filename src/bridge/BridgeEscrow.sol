// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IBridgeEscrow} from "./IBridgeEscrow.sol";
import {IBridgeAdapter} from "./IBridgeAdapter.sol";
import {InvoiceDataLib} from "./InvoiceDataLib.sol";
import "src/errors.sol";
import "src/constants.sol";

/// @title BridgeEscrow
/// @notice Tracks assets in transit across chains and maintains invoice ledger
/// @author kpk
contract BridgeEscrow is Initializable, AccessControlUpgradeable, IBridgeEscrow {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    //
    // Constants
    //

    /// @notice Role for operators who can cancel invoices
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice ERC-7528 convention for ETH address representation (used in some L2s)
    address public constant NATIVE_ADDRESS_ERC7528 = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    //
    // State Variables
    //

    /// @notice Invoice storage keyed by hashed invoice (checksum)
    mapping(bytes32 => Invoice) public invoices;

    /// @notice Active invoices per portfolio safe
    mapping(address => bytes32[]) private _activeInvoices;
    mapping(address => mapping(bytes32 => bool)) private _activeInvoicesSet;

    /// @notice Authorized portfolio safes
    EnumerableSet.AddressSet private _authorizedPortfolioSafes;

    /// @notice Authorized bridge adapters
    EnumerableSet.AddressSet private _authorizedAdapters;

    /// @notice Current chain ID
    uint64 public chainId;

    /// @notice Tracks completed invoices by hashed invoice for bookkeeping
    mapping(bytes32 => bool) public completedInvoices;

    /// @notice Maps asset symbol to asset address on this chain
    /// @dev Format: assetRegistry[symbol] = assetAddress
    /// @dev address(0) is valid for native tokens (ETH) - must be explicitly registered
    mapping(bytes6 => address) public assetRegistry;

    /// @notice Tracks which asset symbols have been registered (to distinguish unregistered from native ETH)
    /// @dev registeredSymbols[symbol] = true if symbol has been registered
    mapping(bytes6 => bool) public registeredSymbols;

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
    function depositAndBridge(uint64 destinationChainId, bytes6 assetSymbol, uint256 amount, address adapter)
        external
        payable
        returns (bytes32 invoiceHash)
    {
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
        // Verify asset is registered (check registeredSymbols to distinguish unregistered from native ETH)
        if (!registeredSymbols[assetSymbol]) revert InvalidArguments(); // Asset not registered

        // Generate invoice ID (32 bytes, excludes amount)
        bytes32 invoiceId = _generateInvoiceId(chainId, destinationChainId, msg.sender, assetSymbol);

        // Truncate timestamp to uint8 (only need to check if in past)
        uint8 timestampByte = uint8(block.timestamp);

        // Calculate checksum for invoiceId + amount + timestampByte (24 bytes)
        bytes24 checksum24 = _calculateInvoiceIdChecksum(invoiceId, amount, timestampByte);

        // Create invoiceHash from checksum24 (padded to bytes32 for mapping key)
        invoiceHash = bytes32(uint256(uint192(checksum24)));

        // Check if invoice already exists (hash must be unique)
        if (invoices[invoiceHash].invoiceId != bytes32(0)) {
            revert InvoiceAlreadyExists();
        }

        // Create InvoiceData struct with all components
        InvoiceDataLib.InvoiceData memory invoiceData = InvoiceDataLib.InvoiceData({
            invoiceId: invoiceId,
            sourceChainId: uint24(chainId),
            destinationChainId: uint24(destinationChainId),
            portfolioSafe: msg.sender,
            assetSymbol: assetSymbol,
            amount: amount,
            timestampByte: timestampByte,
            checksum24: checksum24
        });

        // Encode to messagePayload for storage and interface compatibility
        bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);

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

        invoices[invoiceHash] = invoice;

        // Add to active invoices (invoiceIds are unique, so no need to check for duplicates)
        _activeInvoices[msg.sender].push(invoiceHash);
        _activeInvoicesSet[msg.sender][invoiceHash] = true;

        // Transfer assets from portfolio safe
        if (_isNativeToken(asset)) {
            // Native token
            if (msg.value != amount) revert InvalidArguments();
            // Contract already holds native tokens via receive()
        } else {
            // ERC20 token
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }

        emit InvoiceCreated(invoiceId, msg.sender, asset, amount, chainId, destinationChainId);

        emit AssetsDeposited(invoiceId, asset, amount);

        // Immediately transfer assets to adapter
        if (_isNativeToken(asset)) {
            // Native token
            (bool success,) = adapter.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            // ERC20 token
            IERC20(asset).safeTransfer(adapter, amount);
        }

        // Call adapter's bridge function with messagePayload
        // BridgeAdapter will decode it once and pass struct to _bridge()
        IBridgeAdapter(adapter).bridge(messagePayload);

        return invoiceHash;
    }

    /// @notice Releases funds based on invoice ID extracted from messagePayload
    /// @param messagePayload The message payload containing invoiceId and checksum
    /// @dev Extracts invoiceId and checksum from messagePayload, validates checksum, and releases funds
    /// @dev This is the ONLY way to release funds - checksum validation is mandatory
    /// @dev Only authorized adapters or operators can call this function to prevent unauthorized releases
    function releaseByInvoiceId(bytes memory messagePayload) external {
        // Require caller to be either an authorized adapter or an operator
        if (!_authorizedAdapters.contains(msg.sender) && !hasRole(OPERATOR_ROLE, msg.sender)) {
            revert NotAuthorized();
        }

        // Extract invoiceId, amount, and meta from messagePayload (exactly 3 slots)
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);
        bytes32 invoiceId = data.invoiceId;
        uint256 amount = data.amount;
        uint8 timestampByte = data.timestampByte;
        bytes24 checksum24 = data.checksum24;

        // MANDATORY: Validate timestamp is in the past (not exact match, just must be <= current)
        if (timestampByte > uint8(block.timestamp)) {
            revert InvalidInvoice(); // Timestamp must be in the past
        }

        // MANDATORY: Validate checksum matches invoiceId + amount + timestampByte - revert if invalid
        if (!this.validateInvoiceIdChecksum(invoiceId, amount, timestampByte, checksum24)) {
            revert InvalidInvoice(); // Checksum mismatch - security check failed
        }

        // Create invoiceHash from checksum24 (padded to bytes32 for mapping key)
        bytes32 invoiceHash = bytes32(uint256(uint192(checksum24)));

        // Check if already completed (prevents double-spending/replay attacks)
        // Note: The invoice itself is not stored on destination chain - it only exists on source chain
        // The checksum validation above ensures the invoice data is valid and authentic
        if (completedInvoices[invoiceHash]) {
            revert InvoiceAlreadyExists();
        }

        // Use already-decoded data from InvoiceDataLib.decode() instead of decoding again
        // Validate destination chain
        if (uint64(data.destinationChainId) != chainId) {
            revert InvalidArguments();
        }

        // Verify portfolio safe is authorized
        if (!_authorizedPortfolioSafes.contains(data.portfolioSafe)) {
            revert NotAuthorized();
        }

        // Look up asset address from symbol
        address asset = assetRegistry[data.assetSymbol];
        // Verify asset is registered (check registeredSymbols to distinguish unregistered from native ETH)
        if (!registeredSymbols[data.assetSymbol]) revert InvalidArguments(); // Asset not registered

        // Mark invoice as completed
        completedInvoices[invoiceHash] = true;

        // Verify sufficient balance (check contract balance)
        if (_isNativeToken(asset)) {
            if (address(this).balance < amount) revert InsufficientBalance();
        } else {
            if (IERC20(asset).balanceOf(address(this)) < amount) revert InsufficientBalance();
        }

        // Transfer assets to portfolio safe
        if (_isNativeToken(asset)) {
            (bool success,) = data.portfolioSafe.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(data.portfolioSafe, amount);
        }

        emit AssetsReleased(invoiceId, data.sourceChainId, asset, amount, data.portfolioSafe);
    }

    //
    // Operator Functions
    //

    /// @inheritdoc IBridgeEscrow
    function cancelInvoice(bytes32 invoiceHash) external override onlyRole(OPERATOR_ROLE) {
        Invoice storage invoice = invoices[invoiceHash];

        if (invoice.invoiceId == bytes32(0)) revert InvoiceNotFound();
        if (invoice.status == InvoiceStatus.COMPLETED) revert InvalidInvoiceStatus();
        if (invoice.status == InvoiceStatus.CANCELLED) revert InvalidInvoiceStatus();

        address asset = invoice.asset;
        uint256 amount = invoice.amount;

        // Verify assets are in the contract before allowing cancellation
        if (_isNativeToken(asset)) {
            // Native token - check contract balance
            if (address(this).balance < amount) revert InsufficientBalance();
        } else {
            // ERC20 token - check contract balance
            if (IERC20(asset).balanceOf(address(this)) < amount) revert InsufficientBalance();
        }

        InvoiceStatus oldStatus = invoice.status;
        invoice.status = InvoiceStatus.CANCELLED;

        // Return assets to portfolio safe
        if (_isNativeToken(asset)) {
            (bool success,) = invoice.portfolioSafe.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(invoice.portfolioSafe, amount);
        }

        // Remove from active invoices
        if (_activeInvoicesSet[invoice.portfolioSafe][invoiceHash]) {
            _removeActiveInvoice(invoice.portfolioSafe, invoiceHash);
        }

        emit InvoiceStatusUpdated(invoice.invoiceId, oldStatus, InvoiceStatus.CANCELLED);
        emit AssetsReleased(invoice.invoiceId, invoice.sourceChainId, asset, amount, invoice.portfolioSafe);
    }

    /// @notice Marks invoices as completed for bookkeeping purposes (source chain only)
    /// @param invoiceHashes Array of invoice hashes to mark as completed
    /// @dev This function should be called by an operator after assets have been released on the destination chain.
    ///      It updates the invoice status on the source chain for bookkeeping purposes only.
    ///      Invalid invoices (not found or wrong status) are skipped and processing continues.
    function markInvoiceCompleted(bytes32[] calldata invoiceHashes) external override onlyRole(OPERATOR_ROLE) {
        uint256 length = invoiceHashes.length;
        bytes32[] memory failedInvoiceIds = new bytes32[](length);
        uint256 failedCount = 0;

        for (uint256 i = 0; i < length; i++) {
            bytes32 invoiceHash = invoiceHashes[i];
            Invoice storage invoice = invoices[invoiceHash];

            // Skip if invoice doesn't exist or is not in BRIDGING status
            if (invoice.invoiceId == bytes32(0)) {
                failedInvoiceIds[failedCount] = bytes32(0);
                failedCount++;
                continue;
            }
            if (invoice.status != InvoiceStatus.BRIDGING) {
                failedInvoiceIds[failedCount] = invoice.invoiceId;
                failedCount++;
                continue;
            }

            InvoiceStatus oldStatus = invoice.status;
            invoice.status = InvoiceStatus.COMPLETED;
            completedInvoices[invoiceHash] = true;

            // Remove from active invoices
            if (_activeInvoicesSet[invoice.portfolioSafe][invoiceHash]) {
                _removeActiveInvoice(invoice.portfolioSafe, invoiceHash);
            }

            emit InvoiceStatusUpdated(invoice.invoiceId, oldStatus, InvoiceStatus.COMPLETED);
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
    /// @param asset The asset address (address(0) for native ETH/tokens)
    function registerAsset(bytes6 symbol, address asset) external onlyRole(OPERATOR_ROLE) {
        // Allow address(0) for native tokens (e.g., ETH) - used by Superchain adapter
        assetRegistry[symbol] = asset;
        registeredSymbols[symbol] = true;
        emit AssetRegistered(symbol, asset);
    }

    /// @notice Unregisters an asset symbol
    /// @param symbol The asset symbol to unregister
    function unregisterAsset(bytes6 symbol) external onlyRole(OPERATOR_ROLE) {
        delete assetRegistry[symbol];
        registeredSymbols[symbol] = false;
        emit AssetUnregistered(symbol);
    }

    //
    // View Functions
    //

    /// @inheritdoc IBridgeEscrow
    function getInvoice(bytes32 invoiceHash) external view override returns (Invoice memory) {
        return invoices[invoiceHash];
    }

    /// @inheritdoc IBridgeEscrow
    function getActiveInvoices(address portfolioSafe) external view override returns (bytes32[] memory) {
        return _activeInvoices[portfolioSafe];
    }

    /// @notice Calculates the total in-transit balance for an asset by summing all active invoice amounts
    /// @param asset The asset address to calculate balance for
    /// @param portfolioSafe Optional portfolio safe address to filter by. If address(0), sums across all safes
    /// @return The total amount in transit for this asset (optionally filtered by portfolio safe)
    /// @dev Iterates through active invoices and sums amounts from invoices with BRIDGING status
    function getInTransitBalanceForAsset(address asset, address portfolioSafe) external view returns (uint256) {
        uint256 total = 0;
        
        if (portfolioSafe == address(0)) {
            // If no specific safe provided, iterate through all authorized portfolio safes
            uint256 length = _authorizedPortfolioSafes.length();
            for (uint256 i = 0; i < length; i++) {
                address safe = _authorizedPortfolioSafes.at(i);
                bytes32[] memory activeInvoiceHashes = _activeInvoices[safe];
                
                for (uint256 j = 0; j < activeInvoiceHashes.length; j++) {
                    bytes32 invoiceHash = activeInvoiceHashes[j];
                    Invoice storage inv = invoices[invoiceHash];
                    
                    // Only count invoices that are still BRIDGING (not cancelled or completed)
                    if (inv.status == InvoiceStatus.BRIDGING && inv.asset == asset) {
                        total += inv.amount;
                    }
                }
            }
        } else {
            // If specific safe provided, only check that safe's active invoices
            bytes32[] memory activeInvoiceHashes = _activeInvoices[portfolioSafe];
            
            for (uint256 j = 0; j < activeInvoiceHashes.length; j++) {
                bytes32 invoiceHash = activeInvoiceHashes[j];
                Invoice storage inv = invoices[invoiceHash];
                
                // Only count invoices that are still BRIDGING (not cancelled or completed)
                if (inv.status == InvoiceStatus.BRIDGING && inv.asset == asset) {
                    total += inv.amount;
                }
            }
        }
        
        return total;
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
    /// @param invoiceHash The hashed invoice ID to check
    /// @return True if the invoice has been completed
    function isInvoiceCompleted(bytes32 invoiceHash) external view override returns (bool) {
        return completedInvoices[invoiceHash];
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

    /// @notice Generates a 32-byte invoice ID (excludes amount)
    /// @param sourceChainId Source chain ID
    /// @param destinationChainId Destination chain ID
    /// @param portfolioSafe Portfolio safe address (full 20 bytes)
    /// @param assetSymbol Asset symbol (bytes6)
    /// @return invoiceId The 32-byte invoice ID
    function _generateInvoiceId(
        uint64 sourceChainId,
        uint64 destinationChainId,
        address portfolioSafe,
        bytes6 assetSymbol
    ) internal pure returns (bytes32) {
        // Pack data: 3 + 3 + 20 + 6 = 32 bytes exactly
        return bytes32(
            (uint256(uint24(sourceChainId)) << 232) // Bits 232-255 (3 bytes)
                | (uint256(uint24(destinationChainId)) << 208) // Bits 208-231 (3 bytes)
                | (uint256(uint160(portfolioSafe)) << 48) // Bits 48-207 (20 bytes)
                | (uint256(uint48(assetSymbol))) // Bits 0-47 (6 bytes)
        );
    }

    /// @notice Calculates checksum for invoiceId + amount + timestampByte (returns 24 bytes)
    /// @param invoiceId The 32-byte invoice ID (excludes amount)
    /// @param amount The amount being bridged
    /// @param timestampByte The timestamp truncated to uint8
    /// @return checksum24 The 24-byte checksum (first 24 bytes of keccak256 hash of invoiceId + amount + timestampByte)
    function _calculateInvoiceIdChecksum(bytes32 invoiceId, uint256 amount, uint8 timestampByte)
        internal
        pure
        returns (bytes24)
    {
        bytes32 fullHash = keccak256(abi.encodePacked(invoiceId, amount, timestampByte));
        return bytes24(fullHash);
    }

    /// @notice Checks if an address represents a native token
    /// @param token The token address to check
    /// @return True if the address is address(0) or NATIVE_ADDRESS_ERC7528
    /// @dev Some L2s use 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE instead of address(0) for native tokens
    function _isNativeToken(address token) internal pure returns (bool) {
        return token == address(0) || token == NATIVE_ADDRESS_ERC7528;
    }

    /// @notice Decodes a 32-byte invoice ID into its components
    /// @param invoiceId The 32-byte invoice ID (excludes amount)
    /// @return sourceChainId Source chain ID
    /// @return destinationChainId Destination chain ID
    /// @return portfolioSafe Portfolio safe address (full 20 bytes)
    /// @return assetSymbol Asset symbol
    function decodeInvoiceId(bytes32 invoiceId)
        external
        pure
        returns (uint24 sourceChainId, uint24 destinationChainId, address portfolioSafe, bytes6 assetSymbol)
    {
        uint256 id = uint256(invoiceId);

        sourceChainId = uint24(id >> 232); // Bits 232-255 (3 bytes)
        destinationChainId = uint24(id >> 208); // Bits 208-231 (3 bytes)
        portfolioSafe = address(uint160(id >> 48)); // Bits 48-207 (20 bytes)
        assetSymbol = bytes6(uint48(id)); // Bits 0-47 (6 bytes)
    }

    /// @notice Validates invoiceId + amount + timestampByte checksum from messagePayload
    /// @param invoiceId The 32-byte invoice ID (excludes amount)
    /// @param amount The amount being bridged
    /// @param timestampByte The timestamp truncated to uint8
    /// @param checksum24 The 24-byte checksum from messagePayload
    /// @return True if checksum is valid
    function validateInvoiceIdChecksum(bytes32 invoiceId, uint256 amount, uint8 timestampByte, bytes24 checksum24)
        external
        pure
        returns (bool)
    {
        bytes24 expectedChecksum = _calculateInvoiceIdChecksum(invoiceId, amount, timestampByte);
        return checksum24 == expectedChecksum;
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

    /// @notice Internal function to remove an active invoice
    /// @param portfolioSafe The portfolio safe address
    /// @param invoiceId The invoice ID to remove
    function _removeActiveInvoice(address portfolioSafe, bytes32 invoiceId) internal {
        bytes32[] storage activeList = _activeInvoices[portfolioSafe];
        uint256 length = activeList.length;

        for (uint256 i = 0; i < length; i++) {
            if (activeList[i] == invoiceId) {
                // Move last element to current position
                activeList[i] = activeList[length - 1];
                // Remove last element
                activeList.pop();
                // Remove from set
                _activeInvoicesSet[portfolioSafe][invoiceId] = false;
                break;
            }
        }
    }
}

