// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IBridgeAdapter} from "./IBridgeAdapter.sol";
import {IBridgeEscrow} from "./IBridgeEscrow.sol";
import {BridgeData} from "./BridgeData.sol";
import "src/errors.sol";
import "src/constants.sol";

/// @title BridgeAdapter
/// @notice Abstract base contract for bridge adapter implementations
/// @author kpk
abstract contract BridgeAdapter is Initializable, AccessControlUpgradeable, IBridgeAdapter {
    using SafeERC20 for IERC20;

    //
    // Constants
    //

    /// @notice Role for operators who can complete bridges
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    //
    // State Variables
    //

    /// @notice The BridgeEscrow contract address
    address public bridgeEscrow;

    /// @notice Bridge provider name (e.g., "CCTP", "Gnosis")
    string public bridgeProviderName;

    /// @notice Adapter version
    string public adapterVersion;

    //
    // Events
    //

    /// @notice Event emitted when a bridge is initiated
    event BridgeInitiated(bytes32 indexed invoiceId, address indexed asset, uint256 amount);

    /// @notice Event emitted when a bridge is completed
    event BridgeCompleted(bytes32 indexed invoiceId, bytes32 indexed sourceInvoiceId, uint64 sourceChainId);

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

    /// @notice Initializes the BridgeAdapter
    /// @param admin_ The admin address
    /// @param bridgeEscrow_ The BridgeEscrow contract address
    /// @param providerName_ The bridge provider name
    /// @param version_ The adapter version
    function initialize(address admin_, address bridgeEscrow_, string memory providerName_, string memory version_)
        external
        initializer
    {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        bridgeEscrow = bridgeEscrow_;
        bridgeProviderName = providerName_;
        adapterVersion = version_;
    }

    //
    // IBridgeAdapter Implementation
    //

    /// @inheritdoc IBridgeAdapter
    function bridge(bytes32 invoiceId, bytes calldata bridgeData) external override {
        // Verify caller is BridgeEscrow
        if (msg.sender != bridgeEscrow) revert NotAuthorized();

        // Decode standardized bridge data
        BridgeData.BridgeParams memory params = BridgeData.decode(bridgeData);

        _bridge(invoiceId, params);

        emit BridgeInitiated(invoiceId, params.asset, params.amount);
    }

    /// @inheritdoc IBridgeAdapter
    function completeBridge(
        bytes32 invoiceId,
        address portfolioSafe,
        uint256 amount,
        bytes calldata bridgeData
    ) external override {
        // Verify caller is authorized (could be operator or bridge protocol callback)
        if (!hasRole(OPERATOR_ROLE, msg.sender)) {
            revert NotAuthorized();
        }

        // Decode standardized completion data
        BridgeData.CompletionParams memory completionParams = BridgeData.decodeCompletion(bridgeData);

        // Extract invoiceId from bridge message if adapter supports it
        // This allows adapters to relay invoiceId in bridge messages and extract it on destination
        bytes32 extractedInvoiceId = _extractInvoiceIdFromBridgeData(completionParams.protocolData);
        
        // Use extracted invoiceId if available, otherwise use the parameter
        bytes32 invoiceIdToUse = extractedInvoiceId != bytes32(0) ? extractedInvoiceId : invoiceId;

        // Decode invoiceId to get sourceChainId (invoiceId already encodes this)
        (uint24 decodedSourceChainId,,,) = IBridgeEscrow(bridgeEscrow).decodeInvoiceId(invoiceIdToUse);

        _completeBridge(invoiceIdToUse, completionParams);

        // Call BridgeEscrow.releaseByInvoiceId() with the invoiceId to use
        IBridgeEscrow(bridgeEscrow).releaseByInvoiceId(invoiceIdToUse, portfolioSafe, amount);

        // sourceInvoiceId is the same as invoiceIdToUse (the invoice from source chain)
        emit BridgeCompleted(invoiceIdToUse, invoiceIdToUse, uint64(decodedSourceChainId));
    }

    /// @inheritdoc IBridgeAdapter
    function bridgeProvider() external view override returns (string memory) {
        return bridgeProviderName;
    }

    /// @inheritdoc IBridgeAdapter
    function version() external view override returns (string memory) {
        return adapterVersion;
    }

    //
    // Abstract Functions
    //

    /// @notice Abstract function - implement bridge-specific logic
    /// @param invoiceId The invoice ID
    /// @param params Standardized bridge parameters (asset, amount, destinationChainId, recipient, messagePayload)
    function _bridge(bytes32 invoiceId, BridgeData.BridgeParams memory params) internal virtual;

    /// @notice Virtual function to extract invoiceId from bridge protocol data
    /// @dev Override this if your adapter relays invoiceId in bridge messages
    /// @param protocolData Bridge-specific protocol data (e.g., CCTP message, CCIP message)
    /// @return extractedInvoiceId The extracted invoiceId, or bytes32(0) if not found/not supported
    /// @dev Default implementation returns bytes32(0), meaning use the parameter passed to completeBridge
    function _extractInvoiceIdFromBridgeData(bytes memory protocolData)
        internal
        view
        virtual
        returns (bytes32 extractedInvoiceId)
    {
        // Default: don't extract, use parameter
        protocolData; // Silence unused parameter warning
        return bytes32(0);
    }

    /// @notice Abstract function - implement bridge-specific completion logic
    /// @param invoiceId The invoice ID (extracted from message or passed as parameter)
    /// @param params Standardized completion parameters (messagePayload, protocolData)
    /// @dev All other information (sourceChainId, portfolioSafe, asset, amount) can be derived
    ///      from invoiceId via decodeInvoiceId() if needed by the adapter
    function _completeBridge(bytes32 invoiceId, BridgeData.CompletionParams memory params) internal virtual;

    //
    // ERC165 Support
    //

    /// @notice Checks if the contract supports an interface
    /// @param interfaceId The interface ID to check
    /// @return True if supported
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IBridgeAdapter).interfaceId || super.supportsInterface(interfaceId);
    }
}

