// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IBridgeEscrow} from "./IBridgeEscrow.sol";
import {IBridgeAdapter} from "./IBridgeAdapter.sol";
import {InvoiceDataLib} from "./InvoiceDataLib.sol";
import "src/errors.sol";
import "src/constants.sol";

/// @title BridgeEscrow
/// @notice Tracks assets in transit across chains and maintains invoice ledger
/// @author kpk
contract BridgeEscrow is Initializable, AccessControlUpgradeable, ReentrancyGuard, PausableUpgradeable, IBridgeEscrow {
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
    /// @dev Invariant: Should only contain invoice hashes with status BRIDGING
    mapping(address => bytes32[]) private _activeInvoices;
    mapping(address => mapping(bytes32 => bool)) private _activeInvoicesSet;

    /// @notice Authorized portfolio safes
    EnumerableSet.AddressSet private _authorizedPortfolioSafes;

    /// @notice Authorized bridge adapters
    EnumerableSet.AddressSet private _authorizedAdapters;

    /// @notice Current chain ID
    uint64 public chainId;

    /// @notice Tracks completed invoices by hashed invoice for bookkeeping
    /// @dev Invariant: Should only be true for valid invoice hashes that have been released
    mapping(bytes32 => bool) public completedInvoices;

    /// @notice Maps asset symbol to asset address on this chain
    /// @dev Format: assetRegistry[symbol] = assetAddress
    /// @dev address(0) is valid for native tokens (ETH) - must be explicitly registered
    mapping(bytes6 => address) public assetRegistry;

    /// @notice Tracks which asset symbols have been registered (to distinguish unregistered from native ETH)
    /// @dev registeredSymbols[symbol] = true if symbol has been registered
    mapping(bytes6 => bool) public registeredSymbols;

    /// @notice Cached in-transit balances per safe and asset
    /// @dev _inTransitBalances[safe][asset] = total amount in transit for that safe and asset
    /// @dev Invariant: Should equal sum of amounts from all BRIDGING invoices for that safe and asset
    mapping(address => mapping(address => uint256)) private _inTransitBalances;

    /// @notice Cached in-transit balances across all safes per asset
    /// @dev _inTransitBalancesAllSafes[asset] = total amount in transit across all safes for that asset
    /// @dev Invariant: Should equal sum of _inTransitBalances[safe][asset] across all safes
    mapping(address => uint256) private _inTransitBalancesAllSafes;

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
        __Pausable_init();
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
        whenNotPaused
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

        // Use full uint64 timestamp (8 bytes) - no truncation needed
        uint64 timestamp = uint64(block.timestamp);

        // Calculate checksum for invoiceId + amount + timestamp (24 bytes)
        bytes24 checksum24 = _calculateInvoiceIdChecksum(invoiceId, amount, timestamp);

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
            timestamp: timestamp,
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
            status: InvoiceStatus.BRIDGING,
            adapter: adapter
        });

        invoices[invoiceHash] = invoice;

        // Add to active invoices (invoiceIds are unique, so no need to check for duplicates)
        _activeInvoices[msg.sender].push(invoiceHash);
        _activeInvoicesSet[msg.sender][invoiceHash] = true;

        // Update in-transit balance cache (invoice is in BRIDGING status)
        _updateInTransitBalance(msg.sender, asset, amount, true);

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

        // For ERC20: Approve adapter to pull assets
        // For Native: Transfer assets to adapter
        if (_isNativeToken(asset)) {
            // Native token - must transfer
            (bool success,) = adapter.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            // ERC20 token - approve adapter to pull
            // Use forceApprove (replaces deprecated safeApprove)
            IERC20(asset).forceApprove(adapter, amount);
        }

        // Call adapter's bridge function with messagePayload
        // Adapter will pull ERC20 tokens in _bridge() if approved
        // BridgeAdapter will decode it once and pass struct to _bridge()
        IBridgeAdapter(adapter).bridge(messagePayload);

        return invoiceHash;
    }

    /// @inheritdoc IBridgeEscrow
    function releaseByInvoiceId(bytes memory messagePayload) external nonReentrant whenNotPaused {
        if (!_authorizedAdapters.contains(msg.sender) && !hasRole(OPERATOR_ROLE, msg.sender)) {
            revert NotAuthorized();
        }

        // Extract invoiceId, amount, and meta from messagePayload (exactly 3 slots)
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);
        bytes32 invoiceId = data.invoiceId;
        uint256 amount = data.amount;
        uint64 timestamp = data.timestamp;
        bytes24 checksum24 = data.checksum24;

        // MANDATORY: Validate timestamp is in the past (no wrapping issues with uint64)
        uint64 currentTimestamp = uint64(block.timestamp);
        if (timestamp > currentTimestamp) {
            revert InvalidTimestamp(timestamp, currentTimestamp);
        }

        // MANDATORY: Validate checksum matches invoiceId + amount + timestamp - revert if invalid
        bytes24 expectedChecksum = _calculateInvoiceIdChecksum(invoiceId, amount, timestamp);
        if (checksum24 != expectedChecksum) {
            revert InvalidChecksum(invoiceId, checksum24, expectedChecksum);
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
        if (!registeredSymbols[data.assetSymbol]) revert InvalidArguments();

        uint256 balance;
        if (_isNativeToken(asset)) {
            balance = address(this).balance;
            if (balance < amount) revert InsufficientBalance(asset, amount, balance);
        } else {
            balance = IERC20(asset).balanceOf(address(this));
            if (balance < amount) revert InsufficientBalance(asset, amount, balance);
        }

        completedInvoices[invoiceHash] = true;
        emit InvoiceCompleted(invoiceHash, invoiceId);
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
        uint256 balance;
        if (_isNativeToken(asset)) {
            // Native token - check contract balance
            balance = address(this).balance;
            if (balance < amount) revert InsufficientBalance(asset, amount, balance);
        } else {
            // ERC20 token - check contract balance
            balance = IERC20(asset).balanceOf(address(this));
            if (balance < amount) revert InsufficientBalance(asset, amount, balance);
        }

        InvoiceStatus oldStatus = invoice.status;
        invoice.status = InvoiceStatus.CANCELLED;

        // Update in-transit balance cache (invoice is no longer in BRIDGING status)
        _updateInTransitBalance(invoice.portfolioSafe, asset, amount, false);

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

    /// @inheritdoc IBridgeEscrow
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

            // Update in-transit balance cache (invoice is no longer in BRIDGING status)
            _updateInTransitBalance(invoice.portfolioSafe, invoice.asset, invoice.amount, false);

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
    /// @dev Prevents unregistering if there are active invoices for this asset symbol
    function unregisterAsset(bytes6 symbol) external onlyRole(OPERATOR_ROLE) {
        // Check if asset has active invoices
        if (_hasActiveInvoicesForAsset(symbol)) {
            revert AssetHasActiveInvoices(symbol);
        }

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
    function getActiveInvoices(address portfolioSafe) external view override returns (Invoice[] memory) {
        bytes32[] memory activeInvoiceHashes = _activeInvoices[portfolioSafe];
        uint256 length = activeInvoiceHashes.length;
        Invoice[] memory activeInvoices = new Invoice[](length);

        for (uint256 i = 0; i < length; i++) {
            bytes32 invoiceHash = activeInvoiceHashes[i];
            Invoice storage invoice = invoices[invoiceHash];
            activeInvoices[i] = invoice;
        }

        return activeInvoices;
    }

    /// @notice Returns all assets in-transit for a specific portfolio safe with their amounts
    /// @param portfolioSafe The portfolio safe address
    /// @return assets Array of asset addresses
    /// @return amounts Array of amounts corresponding to each asset
    /// @dev Aggregates amounts per asset from all active invoices with BRIDGING status
    function getInTransitBalancesForSafe(address portfolioSafe)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts)
    {
        bytes32[] memory activeInvoiceHashes = _activeInvoices[portfolioSafe];
        uint256 length = activeInvoiceHashes.length;

        // Use a temporary mapping to aggregate amounts per asset
        // Since we can't use mappings in memory, we'll use arrays and iterate
        address[] memory tempAssets = new address[](length);
        uint256[] memory tempAmounts = new uint256[](length);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < length; i++) {
            bytes32 invoiceHash = activeInvoiceHashes[i];
            Invoice storage invoice = invoices[invoiceHash];

            // Invoices in _activeInvoices are guaranteed to be BRIDGING (cancelled/completed invoices are removed)
            address asset = invoice.asset;
            uint256 amount = invoice.amount;

            // Find if asset already exists in temp arrays
            bool found = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (tempAssets[j] == asset) {
                    tempAmounts[j] += amount;
                    found = true;
                    break;
                }
            }

            // If not found, add new asset
            if (!found) {
                tempAssets[uniqueCount] = asset;
                tempAmounts[uniqueCount] = amount;
                uniqueCount++;
            }
        }

        // Resize arrays to actual unique count
        assets = new address[](uniqueCount);
        amounts = new uint256[](uniqueCount);

        for (uint256 i = 0; i < uniqueCount; i++) {
            assets[i] = tempAssets[i];
            amounts[i] = tempAmounts[i];
        }
    }

    /// @notice Calculates the total in-transit balance for an asset using cached balances
    /// @param asset The asset address to calculate balance for
    /// @param portfolioSafe Optional portfolio safe address to filter by. If address(0), sums across all safes
    /// @return The total amount in transit for this asset (optionally filtered by portfolio safe)
    /// @dev Uses cached balances for O(1) lookup instead of iterating through all invoices
    function getInTransitBalanceForAsset(address asset, address portfolioSafe) external view returns (uint256) {
        if (portfolioSafe == address(0)) {
            // Return total across all safes
            return _inTransitBalancesAllSafes[asset];
        } else {
            // Return balance for specific safe
            return _inTransitBalances[portfolioSafe][asset];
        }
    }

    /// @inheritdoc IBridgeEscrow
    function isAuthorizedPortfolioSafe(address safe) external view override returns (bool) {
        return _authorizedPortfolioSafes.contains(safe);
    }

    /// @inheritdoc IBridgeEscrow
    function isAuthorizedAdapter(address adapter) external view override returns (bool) {
        return _authorizedAdapters.contains(adapter);
    }

    /// @inheritdoc IBridgeEscrow
    function isInvoiceCompleted(bytes32 invoiceHash) external view override returns (bool) {
        return completedInvoices[invoiceHash];
    }

    /// @notice Gets the completion status for an array of invoices
    /// @param invoiceHashes Array of invoice hashes to check
    /// @return isCompleted Array of booleans indicating completion status (indexed by input array)
    /// @dev Returns bool array where isCompleted[i] = true if invoiceHashes[i] is completed
    function getInvoicesCompletionStatus(bytes32[] calldata invoiceHashes)
        external
        view
        returns (bool[] memory isCompleted)
    {
        uint256 length = invoiceHashes.length;
        isCompleted = new bool[](length);

        for (uint256 i = 0; i < length; i++) {
            isCompleted[i] = completedInvoices[invoiceHashes[i]];
        }
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

    /// @notice Pauses the contract (prevents deposits and releases)
    /// @dev Only admin can pause
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses the contract
    /// @dev Only admin can unpause
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Emergency withdrawal function for when contract is paused
    /// @param asset The asset address to withdraw (address(0) for native tokens)
    /// @param amount The amount to withdraw
    /// @param to The address to send assets to
    /// @dev Only admin can call this, and only when contract is paused
    /// @dev This is a safety mechanism for critical situations or bugs
    function emergencyWithdraw(address asset, uint256 amount, address to)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenPaused
        nonReentrant
    {
        if (to == address(0)) revert InvalidArguments();
        if (amount == 0) revert InvalidArguments();

        // Transfer assets
        if (_isNativeToken(asset)) {
            uint256 balance = address(this).balance;
            if (balance < amount) revert InsufficientBalance(asset, amount, balance);
            (bool success,) = to.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            uint256 balance = IERC20(asset).balanceOf(address(this));
            if (balance < amount) revert InsufficientBalance(asset, amount, balance);
            IERC20(asset).safeTransfer(to, amount);
        }

        emit EmergencyWithdrawal(asset, amount, to);
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

    /// @notice Calculates checksum for invoiceId + amount + timestamp (returns 24 bytes)
    /// @param invoiceId The 32-byte invoice ID (excludes amount)
    /// @param amount The amount being bridged
    /// @param timestamp The timestamp (uint64)
    /// @return checksum24 The 24-byte checksum (first 24 bytes of keccak256 hash of invoiceId + amount + timestamp)
    function _calculateInvoiceIdChecksum(bytes32 invoiceId, uint256 amount, uint64 timestamp)
        internal
        pure
        returns (bytes24)
    {
        bytes32 fullHash = keccak256(abi.encodePacked(invoiceId, amount, timestamp));
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

    /// @notice Validates invoiceId + amount + timestamp checksum from messagePayload
    /// @param invoiceId The 32-byte invoice ID (excludes amount)
    /// @param amount The amount being bridged
    /// @param timestamp The timestamp (uint64)
    /// @param checksum24 The 24-byte checksum from messagePayload
    /// @return True if checksum is valid
    function validateInvoiceIdChecksum(bytes32 invoiceId, uint256 amount, uint64 timestamp, bytes24 checksum24)
        external
        pure
        returns (bool)
    {
        bytes24 expectedChecksum = _calculateInvoiceIdChecksum(invoiceId, amount, timestamp);
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

    /// @notice Updates in-transit balance caches when invoices are created or completed/cancelled
    /// @param safe The portfolio safe address
    /// @param asset The asset address
    /// @param amount The amount to add or subtract
    /// @param increment True to increment, false to decrement
    /// @dev Updates both per-safe and all-safes balances atomically
    function _updateInTransitBalance(address safe, address asset, uint256 amount, bool increment) internal {
        if (increment) {
            _inTransitBalances[safe][asset] += amount;
            _inTransitBalancesAllSafes[asset] += amount;
        } else {
            // Defensive: prevent underflow (shouldn't happen in normal operation)
            if (_inTransitBalances[safe][asset] >= amount) {
                _inTransitBalances[safe][asset] -= amount;
            }
            if (_inTransitBalancesAllSafes[asset] >= amount) {
                _inTransitBalancesAllSafes[asset] -= amount;
            }
        }
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

    /// @notice Checks if an asset symbol has any active invoices
    /// @param assetSymbol The asset symbol to check
    /// @return True if there are active invoices for this asset symbol
    /// @dev Iterates through all authorized portfolio safes and checks their active invoices
    /// @dev This is gas-intensive but only called during unregisterAsset (admin operation)
    function _hasActiveInvoicesForAsset(bytes6 assetSymbol) internal view returns (bool) {
        // Get all authorized portfolio safes
        uint256 safeCount = _authorizedPortfolioSafes.length();

        // Iterate through each safe
        for (uint256 i = 0; i < safeCount; i++) {
            address safe = _authorizedPortfolioSafes.at(i);
            bytes32[] memory activeInvoiceHashes = _activeInvoices[safe];

            // Check each active invoice for this safe
            for (uint256 j = 0; j < activeInvoiceHashes.length; j++) {
                bytes32 invoiceHash = activeInvoiceHashes[j];
                Invoice storage invoice = invoices[invoiceHash];

                // Decode invoiceId to get assetSymbol
                // invoiceId format: sourceChainId (3 bytes) + destinationChainId (3 bytes) + portfolioSafe (20 bytes) + assetSymbol (6 bytes)
                bytes6 invoiceAssetSymbol = bytes6(uint48(uint256(invoice.invoiceId)));

                // Check if this invoice uses the asset symbol we're checking
                if (invoiceAssetSymbol == assetSymbol) {
                    return true;
                }
            }
        }

        return false;
    }
}

