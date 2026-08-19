// SPDX-License-Identifier: BUSL-1.1
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
///      funds the escrow, which records the delivery into per-invoice custody (hold-then-claim, ADR 0024). Across exposes no source-sender on the
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
    /// @dev Retained as config metadata only. The invoice tracks the exact bridged amount end to end and the
    ///      escrow pulls exactly that amount into destination custody (hold-then-claim), so the V3 outputAmount
    ///      MUST equal the inputAmount — we cannot shave a relayer margin out of it. A zero-margin deposit is
    ///      not filled by the open relayer network; the fill is instead guaranteed by a designated
    ///      `exclusiveRelayer` (see below). This field does NOT shape outputAmount.
    int64 public defaultRelayerFeePct;

    /// @notice Optional relayer with exclusive rights to fill this adapter's deposits (0 = open to all).
    /// @dev Because outputAmount == inputAmount (zero open-market margin), no rational open-market relayer
    ///      fills these deposits. Designating an exclusive relayer (operated/arranged by the fund) that fills
    ///      at zero margin makes the lane work. When unset, deposits are open but may never be filled — they
    ///      then expire at fillDeadline and Across refunds inputAmount to this adapter (recoverable by MANAGER).
    address public exclusiveRelayer;

    /// @notice Seconds after deposit during which `exclusiveRelayer` has exclusive fill rights (0 = none).
    uint32 public exclusivityPeriod;

    /// @notice Mapping from deposit ID to invoice ID
    /// @dev Used to correlate Across deposits with invoice IDs
    mapping(uint32 => bytes32) public depositIdToInvoiceId;

    /// @notice Mapping from invoice ID to deposit ID
    /// @dev Used to track which deposit ID was used for each invoice
    mapping(bytes32 => uint32) public invoiceToDepositId;

    /// @notice Mapping to store message payloads by invoice ID
    /// @dev Used to retrieve payloads on destination chain
    mapping(bytes32 => bytes) public messagePayloads;

    /// @notice Per-route output token: the destination-chain equivalent of a source asset, keyed by
    ///         (destinationChainId => srcAsset). Across V3's SpokePool rejects `outputToken == address(0)`, so
    ///         `_bridge` must supply the real destination token; this map is populated per lane by the admin.
    mapping(uint256 => mapping(address => address)) public outputTokenFor;

    /// @param expectedInitializer_ Address permitted to call initialize (address(0) allows anyone).
    constructor(address expectedInitializer_) BridgeAdapter(expectedInitializer_) {}

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

    /// @notice Sets the exclusive relayer and its exclusivity window for deposits (admin only).
    /// @param exclusiveRelayer_ The relayer with exclusive fill rights (address(0) = open to all relayers).
    /// @param exclusivityPeriod_ Seconds after deposit during which only `exclusiveRelayer_` may fill.
    function setExclusiveRelayer(address exclusiveRelayer_, uint32 exclusivityPeriod_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        exclusiveRelayer = exclusiveRelayer_;
        exclusivityPeriod = exclusivityPeriod_;
        emit ExclusiveRelayerSet(exclusiveRelayer_, exclusivityPeriod_);
    }

    /// @inheritdoc IAcrossBridgeAdapter
    function setOutputToken(uint256 destChainId, address srcAsset, address outputToken_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        outputTokenFor[destChainId][srcAsset] = outputToken_;
        emit OutputTokenSet(destChainId, srcAsset, outputToken_);
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
        // amount arrives intact for the destination custody record (hold-then-claim, ADR 0024).
        uint256 inputAmount = data.amount;
        uint256 outputAmount = data.amount;

        // Approve SpokePool to spend tokens (if ERC20)
        if (!isNative) {
            IERC20(asset).forceApprove(address(spokePool), inputAmount);
        }

        // Across V3 deposit. originToken on the SpokePool side: address(0) for native, asset otherwise.
        address inputToken = isNative ? address(0) : asset;

        // outputToken is the destination-chain equivalent of `asset`. Across V3's SpokePool rejects a zero output
        // token for ERC20 deposits, so each ERC20 lane must be configured via setOutputToken(destChainId, asset,
        // dstToken) before bridging. Native deposits (not used by the production config, which registers WETH as
        // an ERC20) keep the zero sentinel — Across resolves the native equivalent itself.
        address outputToken;
        if (!isNative) {
            outputToken = outputTokenFor[uint256(data.destinationChainId)][asset];
            if (outputToken == address(0)) revert OutputTokenNotSet(uint256(data.destinationChainId), asset);
        }

        uint32 nowTs = uint32(block.timestamp);

        // Optional exclusive relayer: with outputAmount == inputAmount there is no open-market margin, so a
        // designated relayer is how the deposit gets filled. When unset, deposit is open (and may expire).
        uint32 exclusivityDeadline = exclusiveRelayer == address(0) ? 0 : nowTs + exclusivityPeriod;

        spokePool.depositV3{value: isNative ? inputAmount : 0}(
            address(this), // depositor
            recipient, // recipient (sibling adapter on destination)
            inputToken, // inputToken
            outputToken, // outputToken (destination-chain equivalent; Across V3 rejects address(0))
            inputAmount, // inputAmount
            outputAmount, // outputAmount (== inputAmount; amount tracked intact)
            uint256(data.destinationChainId), // destinationChainId
            exclusiveRelayer, // exclusiveRelayer (address(0) = open to all)
            nowTs, // quoteTimestamp
            nowTs + spokePool.fillDeadlineBuffer(), // fillDeadline: max the SpokePool accepts (reverts beyond it)
            exclusivityDeadline, // exclusivityDeadline (0 = no exclusivity)
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
