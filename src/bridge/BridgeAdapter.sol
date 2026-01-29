// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBridgeAdapter} from "./IBridgeAdapter.sol";
import {IBridgeEscrow} from "./IBridgeEscrow.sol";
import {InvoiceDataLib} from "./InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title BridgeAdapter
/// @notice Abstract base contract for bridge adapter implementations
/// @author kpk
abstract contract BridgeAdapter is Initializable, AccessControlUpgradeable, ReentrancyGuard, IBridgeAdapter {
    using SafeERC20 for IERC20;

    //
    // Constants
    //

    /// @notice Role for operators who can complete bridges
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice ERC-7528 convention for ETH address representation (used in some L2s)
    address public constant NATIVE_ADDRESS_ERC7528 = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

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
    /// @dev Public (not external) so concrete adapters can call super.initialize() from their initialize()
    function initialize(address admin_, address bridgeEscrow_, string memory providerName_, string memory version_)
        public
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

    //
    // Helper Functions
    //

    /// @notice Checks if an address represents a native token
    /// @param token The token address to check
    /// @return True if the address is address(0) or NATIVE_ADDRESS_ERC7528
    /// @dev Some L2s use 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE instead of address(0) for native tokens
    function _isNativeToken(address token) internal pure returns (bool) {
        return token == address(0) || token == NATIVE_ADDRESS_ERC7528;
    }

    //
    // IBridgeAdapter Implementation
    //

    /// @inheritdoc IBridgeAdapter
    function bridge(bytes calldata messagePayload) external override {
        // Verify caller is BridgeEscrow
        if (msg.sender != bridgeEscrow) revert NotAuthorized();

        // Decode messagePayload into struct once
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

        // Pass decoded struct to adapter implementation
        _bridge(data);

        emit BridgeInitiated(data.invoiceId, data.amount);
    }

    /// @inheritdoc IBridgeAdapter
    function completeBridge(bytes calldata messagePayload, bytes calldata protocolData) external override {
        // Verify caller is authorized
        if (!hasRole(OPERATOR_ROLE, msg.sender)) {
            revert NotAuthorized();
        }

        // Validate messagePayload is not empty
        if (messagePayload.length == 0) {
            revert InvalidCompletionData();
        }

        // Decode messagePayload into struct once using InvoiceDataLib
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

        // Note: Checksum validation is done in BridgeEscrow.releaseByInvoiceId()
        // No need to validate here to avoid redundant gas costs

        // Call bridge-specific completion logic
        _completeBridge(messagePayload, protocolData);

        // Call BridgeEscrow.releaseByInvoiceId() with messagePayload (mandatory checksum validation)
        IBridgeEscrow(bridgeEscrow).releaseByInvoiceId(messagePayload);

        emit BridgeCompleted(data.invoiceId);
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
    /// @param data The decoded invoice data struct
    /// @dev Adapter receives decoded struct with all invoice components
    ///      Adapter should encode data back to messagePayload if needed for the bridge protocol
    function _bridge(InvoiceDataLib.InvoiceData memory data) internal virtual;

    /// @notice Transfers tokens from adapter to BridgeEscrow
    /// @param invoiceId The invoice ID
    /// @param asset The asset address (address(0) for native tokens)
    /// @param amount The amount to transfer
    /// @dev Handles both native and ERC20 tokens
    /// @dev Requires exact amount - reverts if insufficient balance
    /// @dev Emits TokensTransferredToEscrow event
    function _transferTokensToEscrow(bytes32 invoiceId, address asset, uint256 amount) internal {
        bool isNative = _isNativeToken(asset);

        if (isNative) {
            // Native token - check balance and transfer
            uint256 adapterBalance = address(this).balance;
            if (adapterBalance < amount) {
                revert InsufficientBalance(asset, amount, adapterBalance);
            }
            (bool success,) = bridgeEscrow.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            // ERC20 token - check balance and transfer
            uint256 adapterBalance = IERC20(asset).balanceOf(address(this));
            if (adapterBalance < amount) {
                revert InsufficientBalance(asset, amount, adapterBalance);
            }
            IERC20(asset).safeTransfer(bridgeEscrow, amount);
        }

        // Emit event directly from adapter
        emit TokensTransferredToEscrow(invoiceId, asset, amount);
    }

    /// @notice Abstract function - implement bridge-specific completion logic
    /// @param messagePayload The message payload (exactly 3 slots: invoiceId, amount, meta)
    /// @param protocolData Bridge-specific protocol data (e.g., CCTP message+attestation, CCIP Any2EVMMessage)
    /// @dev All information (invoiceId, sourceChainId, portfolioSafe, asset, amount) can be derived
    ///      from messagePayload via decodeInvoiceId() if needed by the adapter
    function _completeBridge(bytes calldata messagePayload, bytes calldata protocolData) internal virtual;

    /// @inheritdoc IBridgeAdapter
    function recoverStuckAssets(address asset, uint256 amount, address to)
        external
        override
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert InvalidArguments();
        if (amount == 0) revert InvalidArguments();

        // Default implementation: transfer assets directly
        if (_isNativeToken(asset)) {
            uint256 balance = address(this).balance;
            if (balance < amount) {
                revert InsufficientBalance(asset, amount, balance);
            }
            (bool success,) = to.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            uint256 balance = IERC20(asset).balanceOf(address(this));
            if (balance < amount) {
                revert InsufficientBalance(asset, amount, balance);
            }
            IERC20(asset).safeTransfer(to, amount);
        }

        emit AssetsRecovered(asset, amount, to);
    }

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

