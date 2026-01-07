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

    /// @notice Nonce counter per portfolio safe
    mapping(address => uint256) public nonces;

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
        address asset,
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

        // Increment nonce for this portfolio safe
        uint256 nonce = ++nonces[msg.sender];

        // Generate invoice ID
        invoiceId = _generateInvoiceId(chainId, destinationChainId, msg.sender, nonce);

        // Create invoice with BRIDGING status (since we bridge immediately)
        Invoice memory invoice = Invoice({
            invoiceId: invoiceId,
            sourceChainId: chainId,
            destinationChainId: destinationChainId,
            portfolioSafe: msg.sender,
            globalNonce: nonce,
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

        emit InvoiceCreated(invoiceId, msg.sender, asset, amount, chainId, destinationChainId, nonce);

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

    /// @inheritdoc IBridgeEscrow
    function release(
        bytes32 invoiceId,
        bytes32 sourceInvoiceId,
        uint64 sourceChainId,
        address portfolioSafe,
        address asset,
        uint256 amount
    ) external {
        // Only authorized adapters can release (after bridge completion)
        if (!_authorizedAdapters.contains(msg.sender)) {
            revert NotAuthorized();
        }

        // Verify portfolio safe is authorized
        if (!_authorizedPortfolioSafes.contains(portfolioSafe)) {
            revert NotAuthorized();
        }

        // Verify invoice doesn't already exist (prevent double-release)
        if (invoices[invoiceId].invoiceId != bytes32(0)) {
            revert InvoiceAlreadyExists();
        }

        // Create completion invoice
        Invoice memory invoice = Invoice({
            invoiceId: invoiceId,
            sourceChainId: sourceChainId,
            destinationChainId: chainId,
            portfolioSafe: portfolioSafe,
            globalNonce: 0, // Not used for destination invoices
            asset: asset,
            amount: amount,
            timestamp: block.timestamp,
            status: InvoiceStatus.COMPLETED
        });

        invoices[invoiceId] = invoice;

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

        emit InvoiceStatusUpdated(invoiceId, InvoiceStatus.BRIDGING, InvoiceStatus.COMPLETED);
        emit AssetsReleased(invoiceId, asset, amount, portfolioSafe);
    }

    /// @inheritdoc IBridgeEscrow
    function cancelInvoice(bytes32 invoiceId) external onlyRole(OPERATOR_ROLE) {
        Invoice storage invoice = invoices[invoiceId];

        if (invoice.invoiceId == bytes32(0)) revert InvoiceNotFound();
        if (invoice.status == InvoiceStatus.COMPLETED) revert InvalidInvoiceStatus();
        if (invoice.status == InvoiceStatus.CANCELLED) revert InvalidInvoiceStatus();

        InvoiceStatus oldStatus = invoice.status;
        invoice.status = InvoiceStatus.CANCELLED;

        // Decrease in-transit balances (assets are with adapter, but we stop tracking them)
        address asset = invoice.asset;
        uint256 amount = invoice.amount;
        inTransitBalances[asset] -= amount;
        inTransitBalancesBySafe[invoice.portfolioSafe][asset] -= amount;

        // Note: Assets are already with the adapter when status is BRIDGING,
        // so we cannot return them here. The adapter must handle asset recovery
        // if the bridge fails and cancellation is needed.

        // Remove from active invoices
        _activeInvoices[invoice.portfolioSafe].remove(invoiceId);

        emit InvoiceStatusUpdated(invoiceId, oldStatus, InvoiceStatus.CANCELLED);
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

    /// @notice Generates a unique invoice ID
    /// @param sourceChainId Source chain ID
    /// @param destinationChainId Destination chain ID
    /// @param portfolioSafe Portfolio safe address
    /// @param nonce Nonce for this portfolio safe
    /// @return invoiceId The generated invoice ID
    function _generateInvoiceId(uint64 sourceChainId, uint64 destinationChainId, address portfolioSafe, uint256 nonce)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(sourceChainId, destinationChainId, portfolioSafe, nonce));
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
        // A more robust check would use ERC165, but this is simpler for now
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

