// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBridgeAdapter} from "./IBridgeAdapter.sol";
import {IBridgeEscrow} from "./IBridgeEscrow.sol";
import {InvoiceDataLib} from "./InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title BridgeAdapter
/// @notice Abstract base for bridge adapters (non-upgradeable, single-initialize).
/// @dev See ADR 0012. There is no escrow fallback dispatcher. A bridge is completed via the
///      MANAGER-gated `completeBridge`, which runs the adapter's protocol-specific `_completeBridge` and then
///      funds the escrow per-invoice and calls `BridgeEscrow.releaseByInvoiceId` (re-validated by the escrow).
///      Each adapter is the direct on-chain recipient; its authenticated completion path verifies the real
///      protocol message + source sender (against `trustedRemoteAdapter`) before releasing.
/// @author KPK
abstract contract BridgeAdapter is AccessControl, ReentrancyGuard, IBridgeAdapter {
    using SafeERC20 for IERC20;

    //
    // Constants
    //

    /// @notice Role for managers who can complete bridges and recover assets
    bytes32 public constant MANAGER_ROLE = MANAGER;

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

    /// @notice Allowlist of trusted sibling adapters on remote chains, keyed by a protocol-specific source key
    ///         (chainId / CCIP selector / CCTP domain / LZ eid — the adapter defines the key).
    /// @dev The inbound value is the remote adapter identity as bytes32 (address widened, or raw bytes32).
    ///      Concrete adapters consult this in their authenticated callback to verify message provenance.
    mapping(uint64 => bytes32) public trustedRemoteAdapter;

    bool private _initialized;

    /// @notice The only address permitted to call initialize, or address(0) to allow anyone.
    /// @dev Set at CREATE2 time (baked into the adapter's creationCode identically on every chain, so the
    ///      deterministic address is preserved). The adapter address is precomputable and initialize grants
    ///      DEFAULT_ADMIN_ROLE, so an unrestricted initializer can be front-run: a bot deploys the identical
    ///      bytecode at the deterministic address and initializes it first. Pinning the initializer closes
    ///      that window — a bot cannot initialize even after pre-deploying. A zero value disables the guard
    ///      (used in tests); production bakes the deployer EOA.
    address public immutable expectedInitializer;

    /// @notice Emitted when a trusted remote adapter is set/updated for a source key
    event TrustedRemoteAdapterSet(uint64 indexed sourceKey, bytes32 remoteAdapter);

    /// @param expectedInitializer_ The address permitted to call initialize (address(0) allows anyone).
    constructor(address expectedInitializer_) {
        expectedInitializer = expectedInitializer_;
    }

    /// @notice One-time initializer for the BridgeAdapter (internal; only for use by derived adapters)
    /// @dev Derived adapters expose their own initialize() and call this via super._initializeBridgeAdapter().
    function _initializeBridgeAdapter(
        address admin_,
        address bridgeEscrow_,
        string memory providerName_,
        string memory version_
    ) internal {
        if (expectedInitializer != address(0) && msg.sender != expectedInitializer) {
            revert NotAuthorized();
        }
        if (_initialized) revert AlreadyInitialized();
        if (admin_ == address(0) || bridgeEscrow_ == address(0)) revert InvalidArguments();
        _initialized = true;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        bridgeEscrow = bridgeEscrow_;
        bridgeProviderName = providerName_;
        adapterVersion = version_;
    }

    //
    // Config
    //

    /// @notice Sets the trusted remote adapter for a source key (admin only)
    /// @param sourceKey Protocol-specific source identifier (chainId / selector / domain / eid)
    /// @param remoteAdapter The remote sibling adapter identity (bytes32). bytes32(0) clears it.
    function setTrustedRemoteAdapter(uint64 sourceKey, bytes32 remoteAdapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        trustedRemoteAdapter[sourceKey] = remoteAdapter;
        emit TrustedRemoteAdapterSet(sourceKey, remoteAdapter);
    }

    //
    // Helper Functions
    //

    /// @notice Checks if an address represents a native token
    function _isNativeToken(address token) internal pure returns (bool) {
        return token == address(0) || token == NATIVE_ADDRESS_ERC7528;
    }

    /// @notice Widens an address to a bytes32 identity (for trustedRemoteAdapter comparisons)
    function _toBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    //
    // IBridgeAdapter Implementation
    //

    /// @inheritdoc IBridgeAdapter
    function bridge(bytes calldata messagePayload) external override {
        if (msg.sender != bridgeEscrow) revert NotAuthorized();
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);
        _bridge(data);
        emit BridgeInitiated(data.invoiceId, data.amount);
    }

    /// @inheritdoc IBridgeAdapter
    /// @dev MANAGER-operated completion path. The adapter's `_completeBridge` performs protocol-specific
    ///      verification (e.g. CCTP attestation, OP withdrawal finalization) and ensures the adapter holds
    ///      the delivered `amount` of the asset; the base then funds the escrow and releases atomically
    ///      (funded pass-through, ADR 0012).
    function completeBridge(bytes calldata messagePayload, bytes calldata protocolData) external override nonReentrant {
        if (!hasRole(MANAGER_ROLE, msg.sender)) revert NotAuthorized();
        if (messagePayload.length == 0) revert InvalidCompletionData();
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);
        _completeBridge(messagePayload, protocolData);
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));
        _fundAndRelease(messagePayload, asset, data.amount);
        emit BridgeCompleted(data.invoiceId);
    }

    /// @notice Hands the escrow exactly `amount` of `asset` and triggers the funded pass-through release.
    /// @dev The adapter must already hold `amount` of `asset` (delivered by the protocol). For ERC20 the
    ///      escrow pulls via transferFrom (exact approval, reset to 0 after); for native the value is
    ///      forwarded with the call. The escrow validates checksum/replay/account and forwards to the account.
    function _fundAndRelease(bytes memory messagePayload, address asset, uint256 amount) internal {
        if (_isNativeToken(asset)) {
            uint256 bal = address(this).balance;
            if (bal < amount) revert InsufficientBalance(asset, amount, bal);
            IBridgeEscrow(bridgeEscrow).releaseByInvoiceId{value: amount}(messagePayload);
        } else {
            uint256 bal = IERC20(asset).balanceOf(address(this));
            if (bal < amount) revert InsufficientBalance(asset, amount, bal);
            IERC20(asset).forceApprove(bridgeEscrow, amount);
            IBridgeEscrow(bridgeEscrow).releaseByInvoiceId(messagePayload);
            IERC20(asset).forceApprove(bridgeEscrow, 0);
        }
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

    /// @notice Implement bridge-specific outbound logic
    function _bridge(InvoiceDataLib.InvoiceData memory data) internal virtual;

    /// @notice Pushes `amount` of `asset` held by the adapter straight to the escrow and emits TokensTransferredToEscrow.
    /// @dev Legacy push-to-escrow helper, NOT on the shipped completion path. `completeBridge` instead calls
    ///      `_fundAndRelease` (funded pass-through, ADR 0012), which leaves the funds on the adapter for the escrow
    ///      to pull on `releaseByInvoiceId`. No shipped adapter (CCTP included) calls this; it is retained for
    ///      derived adapters that would rather hand the escrow the tokens before release. Reverts InsufficientBalance
    ///      if the adapter holds less than `amount`, or TransferFailed on a failed native send.
    function _transferTokensToEscrow(bytes32 invoiceId, address asset, uint256 amount) internal {
        if (_isNativeToken(asset)) {
            uint256 adapterBalance = address(this).balance;
            if (adapterBalance < amount) revert InsufficientBalance(asset, amount, adapterBalance);
            (bool success,) = bridgeEscrow.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            uint256 adapterBalance = IERC20(asset).balanceOf(address(this));
            if (adapterBalance < amount) revert InsufficientBalance(asset, amount, adapterBalance);
            IERC20(asset).safeTransfer(bridgeEscrow, amount);
        }
        emit TokensTransferredToEscrow(invoiceId, asset, amount);
    }

    /// @notice Implement bridge-specific completion logic (protocol verification); the base then releases
    function _completeBridge(bytes calldata messagePayload, bytes calldata protocolData) internal virtual;

    /// @inheritdoc IBridgeAdapter
    /// @dev Recipient-restricted (ADR 0012, H11): recovered funds may only go to the escrow or an
    ///      escrow-authorized account, never an arbitrary address.
    function recoverStuckAssets(address asset, uint256 amount, address to)
        external
        virtual
        override
        onlyRole(MANAGER_ROLE)
        nonReentrant
    {
        if (amount == 0) revert InvalidArguments();
        if (to != bridgeEscrow && !IBridgeEscrow(bridgeEscrow).isAuthorizedAccount(to)) revert NotAuthorized();

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

        emit AssetsRecovered(asset, amount, to);
    }

    //
    // ERC165 Support
    //

    /// @notice Checks if the contract supports an interface
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IBridgeAdapter).interfaceId || super.supportsInterface(interfaceId);
    }
}
