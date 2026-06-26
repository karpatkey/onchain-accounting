// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgeAdapter} from "../BridgeAdapter.sol";
import {IBridgeEscrow} from "../IBridgeEscrow.sol";
import {InvoiceDataLib} from "../InvoiceDataLib.sol";
import {IAcrossV3Receiver, ISpokePool} from "./interfaces/IAcrossInterfaces.sol";
import {IAcrossBridgeAdapter} from "./interfaces/IAcrossBridgeAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title AcrossBridgeAdapter
/// @notice Bridge adapter for Across Protocol V3 cross-chain bridge
/// @dev The destination recipient is the sibling adapter (this contract, same address across chains via
///      CREATE2). On a filled V3 relay the destination SpokePool transfers the tokens to this adapter and then
///      calls `handleV3AcrossMessage` directly on it. The adapter authenticates the SpokePool, cross-checks the
///      delivered token+amount against the invoice, verifies the source against `trustedRemoteAdapter`, then
///      funds the escrow and releases (funded pass-through, ADR 0012). Across exposes no source-sender on the
///      fill, so source authentication binds the payload's `sourceChainId` to the configured trusted remote.
/// @author KPK
contract AcrossBridgeAdapter is BridgeAdapter, IAcrossBridgeAdapter {
    using SafeERC20 for IERC20;

    //
    // State Variables
    //

    /// @notice SpokePool contract address
    ISpokePool public spokePool;

    /// @notice Default relayer/LP fee percentage (in 1e18, e.g., 0.01e18 = 1%)
    /// @dev Retained as config metadata. The invoice tracks the exact bridged amount end to end, so the V3
    ///      outputAmount is set equal to the inputAmount (the bridged amount must arrive intact for the funded
    ///      pass-through release). Relayer compensation is handled by the SpokePool fee model, not by shaving
    ///      the invoice amount.
    int64 public defaultRelayerFeePct;

    /// @notice Mapping from deposit ID to invoice ID
    /// @dev Used to correlate Across deposits with invoice IDs
    mapping(uint32 => bytes32) public depositIdToInvoiceId;

    /// @notice Mapping from invoice ID to deposit ID
    /// @dev Used to track which deposit ID was used for each invoice
    mapping(bytes32 => uint32) public invoiceToDepositId;

    /// @notice Mapping to store message payloads by invoice ID
    /// @dev Used to retrieve payloads on destination chain
    mapping(bytes32 => bytes) public messagePayloads;

    /// @inheritdoc IAcrossBridgeAdapter
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address spokePool_,
        int64 defaultRelayerFeePct_,
        string memory version_
    ) external {
        // Initialize parent BridgeAdapter (single source of truth for admin, bridgeEscrow, provider name, version)
        super._initializeBridgeAdapter(admin_, bridgeEscrow_, "Across", version_);

        if (spokePool_ == address(0)) revert InvalidSpokePool();
        if (defaultRelayerFeePct_ < 0 || defaultRelayerFeePct_ > 1e18) {
            revert InvalidRelayerFee();
        }
        spokePool = ISpokePool(spokePool_);
        defaultRelayerFeePct = defaultRelayerFeePct_;
    }

    //
    // Configuration
    //

    /// @inheritdoc IAcrossBridgeAdapter
    function setSpokePool(address spokePool_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (spokePool_ == address(0)) revert InvalidSpokePool();
        spokePool = ISpokePool(spokePool_);
    }

    /// @inheritdoc IAcrossBridgeAdapter
    function setDefaultRelayerFeePct(int64 relayerFeePct_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (relayerFeePct_ < 0 || relayerFeePct_ > 1e18) {
            revert InvalidRelayerFee();
        }
        defaultRelayerFeePct = relayerFeePct_;
    }

    //
    // BridgeAdapter Implementation
    //

    /// @inheritdoc BridgeAdapter
    /// @dev Receives decoded invoice data and initiates an Across V3 deposit. The destination recipient is the
    ///      sibling adapter (`address(this)`, same address via CREATE2) so the destination SpokePool delivers
    ///      tokens to it and calls `handleV3AcrossMessage` on it directly.
    function _bridge(InvoiceDataLib.InvoiceData memory data) internal override {
        // Encode messagePayload carried in the V3 `message` field
        bytes memory messagePayload = InvoiceDataLib.encode(data);

        // Get asset address from escrow
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));

        // Check if asset is native token (address(0) or NATIVE_ADDRESS_ERC7528)
        bool isNative = _isNativeToken(asset);

        // Pull ERC20 tokens from escrow if not native (escrow approved us in depositAndBridge)
        if (!isNative) {
            IERC20(asset).safeTransferFrom(bridgeEscrow, address(this), data.amount);
        }

        // Recipient is the sibling adapter on the destination chain (same address via CREATE2).
        // The destination SpokePool transfers tokens to it and calls handleV3AcrossMessage on it.
        address recipient = address(this);

        // The invoice tracks the exact bridged amount end to end: outputAmount == inputAmount so the full
        // amount arrives intact for the funded pass-through release.
        uint256 inputAmount = data.amount;
        uint256 outputAmount = data.amount;

        // Approve SpokePool to spend tokens (if ERC20)
        if (!isNative) {
            IERC20(asset).forceApprove(address(spokePool), inputAmount);
        }

        // Across V3 deposit. originToken on the SpokePool side: address(0) for native, asset otherwise.
        // outputToken address(0) lets Across deliver the canonical equivalent token on the destination chain.
        address inputToken = isNative ? address(0) : asset;
        uint32 nowTs = uint32(block.timestamp);

        spokePool.depositV3{value: isNative ? inputAmount : 0}(
            address(this), // depositor
            recipient, // recipient (sibling adapter on destination)
            inputToken, // inputToken
            address(0), // outputToken (canonical equivalent on destination)
            inputAmount, // inputAmount
            outputAmount, // outputAmount (== inputAmount; amount tracked intact)
            uint256(data.destinationChainId), // destinationChainId
            address(0), // exclusiveRelayer (none)
            nowTs, // quoteTimestamp
            nowTs + spokePool.fillDeadlineBuffer(), // fillDeadline: max the SpokePool accepts (reverts beyond it)
            0, // exclusivityDeadline (none)
            messagePayload // message (carries the invoice payload)
        );

        // Store the messagePayload for later correlation. V3 assigns the deposit id in the SpokePool event
        // (not returned inline), so the placeholder deposit id 0 is emitted.
        messagePayloads[data.invoiceId] = messagePayload;
        emit AcrossBridgeInitiated(data.invoiceId, uint256(data.destinationChainId), 0, data.amount);
    }

    /// @inheritdoc BridgeAdapter
    /// @dev MANAGER fallback completion: the SpokePool normally calls `handleV3AcrossMessage` directly (auto
    ///      path). This manager path is used only if that did not run. The adapter must already hold the
    ///      delivered tokens (Across delivered them to this adapter as the recipient); `protocolData` carries
    ///      the source chain id so the source can be authenticated the same way. The base then funds+releases.
    function _completeBridge(bytes calldata messagePayload, bytes calldata protocolData) internal override {
        if (messagePayload.length == 0) revert InvalidCompletionData();
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

        // Authenticate the source: protocolData encodes (uint32 depositId, uint256 sourceChainId).
        uint32 depositId = 0;
        uint256 sourceChainId = 0;
        if (protocolData.length >= 64) {
            (depositId, sourceChainId) = abi.decode(protocolData, (uint32, uint256));
        }
        _authenticateSource(uint64(sourceChainId), data.sourceChainId);

        // Verify the adapter actually holds the invoiced asset+amount (delivered by the protocol).
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));
        _verifyDelivered(asset, data.amount);

        messagePayloads[data.invoiceId] = messagePayload;
        if (depositId != 0) {
            depositIdToInvoiceId[depositId] = data.invoiceId;
            invoiceToDepositId[data.invoiceId] = depositId;
        }
        emit AcrossBridgeCompleted(data.invoiceId, sourceChainId, depositId);
    }

    /// @inheritdoc IAcrossV3Receiver
    /// @dev Auto completion path. Called by the genuine destination SpokePool after it transfers the tokens to
    ///      this adapter. Authenticates the SpokePool, cross-checks the delivered token+amount against the
    ///      invoice, verifies the source against `trustedRemoteAdapter`, then funds the escrow and releases.
    ///      Across does NOT provide a source sender on the fill, so source authentication binds the payload's
    ///      `sourceChainId` to the configured trusted remote (CREATE2 same-address sibling).
    function handleV3AcrossMessage(
        address tokenSent,
        uint256 amount,
        address,
        /* relayer */
        bytes memory message
    )
        external
        override
        nonReentrant
    {
        if (msg.sender != address(spokePool)) revert MessageReceiveFailed();
        if (message.length == 0) revert InvalidCompletionData();

        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(message);
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));

        // Across enforces tokenSent/amount, but we still bind them to the invoice the message claims.
        // For native deliveries the SpokePool sends value (tokenSent == address(0)); for ERC20 it must
        // match the registered asset. The delivered amount must cover the invoice amount.
        if (_isNativeToken(asset)) {
            if (!_isNativeToken(tokenSent)) revert InvalidBridgeData();
        } else if (tokenSent != asset) {
            revert InvalidBridgeData();
        }
        if (amount < data.amount) revert InvalidBridgeData();

        // Source authentication: Across gives no source sender, so bind the payload's source chain to the
        // configured trusted remote sibling adapter (same address via CREATE2).
        _authenticateSource(uint64(data.sourceChainId), data.sourceChainId);

        // Defense-in-depth: confirm the adapter actually holds the invoiced asset+amount.
        _verifyDelivered(asset, data.amount);

        messagePayloads[data.invoiceId] = message;
        _fundAndRelease(message, asset, data.amount);

        emit AcrossBridgeCompleted(data.invoiceId, data.sourceChainId, 0);
    }

    /// @notice Legacy Across V2 message handler — permanently disabled (ADR 0012, V3 migration).
    /// @dev The adapter migrated to the V3 `handleV3AcrossMessage` flow; the V2 `handleAcrossMessage`
    ///      entrypoint is retired and always reverts. It is retained only so the V2 callback selector
    ///      (`0x0ea1f938`) still resolves on this contract and any inbound V2-style call is rejected rather
    ///      than silently accepted. Never routes funds.
    function handleAcrossMessage(
        address, /* tokenSent */
        uint256, /* amount */
        bool, /* fillCompleted */
        address, /* relayer */
        bytes memory /* message */
    )
        external
        pure
    {
        revert MessageReceiveFailed();
    }

    //
    // Internal Helpers
    //

    /// @dev Authenticates that an inbound Across message corresponds to a known sibling adapter on a known
    ///      source chain. Across does not surface a source sender on the fill, so we require the source chain
    ///      to have a configured `trustedRemoteAdapter` and require it to equal this adapter's own identity
    ///      (the CREATE2 same-address sibling). `claimedSourceChainId` is the chain id encoded in the invoice
    ///      payload; `sourceKey` is the value to look up (same as the claimed source chain for Across).
    function _authenticateSource(uint64 sourceKey, uint24 claimedSourceChainId) internal view {
        if (sourceKey == 0 || uint256(sourceKey) != uint256(claimedSourceChainId)) revert InvalidBridgeData();
        bytes32 trusted = trustedRemoteAdapter[sourceKey];
        if (trusted == bytes32(0) || trusted != _toBytes32(address(this))) revert InvalidBridgeData();
    }

    /// @dev Reverts unless this adapter holds at least `amount` of `asset` (delivered by the protocol).
    function _verifyDelivered(address asset, uint256 amount) internal view {
        uint256 bal = _isNativeToken(asset) ? address(this).balance : IERC20(asset).balanceOf(address(this));
        if (bal < amount) revert InsufficientBalance(asset, amount, bal);
    }

    //
    // View Functions
    //

    /// @inheritdoc IAcrossBridgeAdapter
    function getMessagePayload(bytes32 invoiceId) external view override returns (bytes memory) {
        return messagePayloads[invoiceId];
    }

    //
    // ERC165 Support
    //

    /// @notice Checks if the contract supports an interface
    /// @param interfaceId The interface ID to check
    /// @return True if supported
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAcrossV3Receiver).interfaceId || super.supportsInterface(interfaceId);
    }

    //
    // Receive Function
    //

    /// @notice Allows contract to receive native tokens (for ETH deposits/deliveries)
    receive() external payable {}
}
