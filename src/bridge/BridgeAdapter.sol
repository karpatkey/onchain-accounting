// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IBridgeAdapter} from "./IBridgeAdapter.sol";
import {IBridgeEscrow} from "./IBridgeEscrow.sol";
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
    function bridge(bytes32 invoiceId, address asset, uint256 amount, bytes calldata bridgeData) external override {
        // Verify caller is BridgeEscrow
        if (msg.sender != bridgeEscrow) revert NotAuthorized();

        _bridge(invoiceId, asset, amount, bridgeData);

        emit BridgeInitiated(invoiceId, asset, amount);
    }

    /// @inheritdoc IBridgeAdapter
    function completeBridge(
        bytes32 invoiceId,
        bytes32 sourceInvoiceId,
        uint64 sourceChainId,
        address portfolioSafe,
        address asset,
        uint256 amount,
        bytes calldata bridgeData
    ) external override {
        // Verify caller is authorized (could be operator or bridge protocol callback)
        if (!hasRole(OPERATOR_ROLE, msg.sender)) {
            revert NotAuthorized();
        }

        _completeBridge(invoiceId, sourceInvoiceId, sourceChainId, portfolioSafe, asset, amount, bridgeData);

        // Call BridgeEscrow.releaseByInvoiceId()
        IBridgeEscrow(bridgeEscrow).releaseByInvoiceId(invoiceId, portfolioSafe, amount);

        emit BridgeCompleted(invoiceId, sourceInvoiceId, sourceChainId);
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
    /// @param asset The token address
    /// @param amount The amount to bridge
    /// @param bridgeData Bridge-specific data
    function _bridge(bytes32 invoiceId, address asset, uint256 amount, bytes calldata bridgeData) internal virtual;

    /// @notice Abstract function - implement bridge-specific completion logic
    /// @param invoiceId The invoice ID for the destination
    /// @param sourceInvoiceId The invoice ID from source chain
    /// @param sourceChainId The source chain ID
    /// @param portfolioSafe The portfolio safe address
    /// @param asset The token address
    /// @param amount The amount received
    /// @param bridgeData Bridge-specific completion data
    function _completeBridge(
        bytes32 invoiceId,
        bytes32 sourceInvoiceId,
        uint64 sourceChainId,
        address portfolioSafe,
        address asset,
        uint256 amount,
        bytes calldata bridgeData
    ) internal virtual;

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

