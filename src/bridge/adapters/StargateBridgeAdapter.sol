// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgeAdapter} from "../BridgeAdapter.sol";
import {IBridgeEscrow} from "../IBridgeEscrow.sol";
import {InvoiceDataLib} from "../InvoiceDataLib.sol";
import {
    IStargate,
    ILayerZeroComposer,
    OFTComposeMsgCodec,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt,
    Ticket
} from "./interfaces/IStargateInterfaces.sol";
import {IStargateBridgeAdapter} from "./interfaces/IStargateBridgeAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title StargateBridgeAdapter
/// @notice Bridge adapter for Stargate V2 (OFT-based, LayerZero V2)
/// @dev ADR 0012. Outbound: each asset maps to a Stargate V2 pool (an OFT for that token); `_bridge` calls
///      `IStargate.sendToken` with the destination recipient (`SendParam.to`) set to the sibling adapter
///      (`address(this)`, same address across chains via CREATE2) and the invoice messagePayload carried in
///      `SendParam.composeMsg`, so Stargate delivers the tokens to the adapter and then has the LayerZero V2
///      Endpoint call `lzCompose` on it. Inbound: `lzCompose` authenticates `msg.sender == endpoint`, the
///      composing OApp (`_from == stargatePool`), the source eid and the source sibling adapter (`composeFrom
///      == trustedRemoteAdapter[srcChainId]`), verifies the delivered token+amount against the invoice, then
///      funds the escrow and releases (funded pass-through). There is no V1 `swap`/bare `lzReceive` path.
/// @author KPK
contract StargateBridgeAdapter is BridgeAdapter, IStargateBridgeAdapter {
    using SafeERC20 for IERC20;
    using OFTComposeMsgCodec for bytes;

    //
    // State Variables
    //

    /// @notice LayerZero V2 Endpoint contract address (the only authorized caller of lzCompose)
    address public endpoint;

    /// @notice Stargate V2 pool (OFT) per asset; `pool.token()` must equal the asset
    mapping(address => address) public stargatePool;

    /// @notice Mapping from standard chain ID to LayerZero endpoint ID (eid)
    mapping(uint64 => uint32) public chainIdToEid;

    /// @notice Mapping from LayerZero endpoint ID (eid) to standard chain ID
    mapping(uint32 => uint64) public eidToChainId;

    /// @notice Executor options (extraOptions) per destination eid (lzCompose gas budget); empty allowed
    mapping(uint32 => bytes) public composeOptions;

    /// @notice Mapping to store message payloads by invoice ID
    mapping(bytes32 => bytes) public messagePayloads;

    /// @notice Max bridge fee tolerated on a send, in basis points. A quote worse than this (destination would
    ///         receive less than `(10000 - MAX_BRIDGE_FEE_BPS)/10000` of the gross) reverts the send, so a
    ///         misconfigured/abusive pool cannot silently burn most of the deposit. 5% matches the prior implicit
    ///         floor; a reward (received >= sent) has zero fee and always passes.
    uint256 public constant MAX_BRIDGE_FEE_BPS = 500;

    /// @dev Internal helper to set both chainId <-> eid mappings
    function _setEid(uint64 chainId, uint32 eid) internal {
        chainIdToEid[chainId] = eid;
        eidToChainId[eid] = chainId;
    }

    /// @inheritdoc IStargateBridgeAdapter
    function initialize(address admin_, address bridgeEscrow_, address endpoint_, string memory version_) external {
        // Initialize parent BridgeAdapter (single source of truth for admin, bridgeEscrow, provider name, version)
        super._initializeBridgeAdapter(admin_, bridgeEscrow_, "Stargate", version_);

        if (endpoint_ == address(0)) revert InvalidEndpoint();
        endpoint = endpoint_;

        // Pre-configure known LayerZero V2 endpoint IDs (eids). Source:
        // https://docs.layerzero.network/v2/deployments/deployed-contracts
        _setEid(1, 30101); // Ethereum
        _setEid(56, 30102); // BNB Chain
        _setEid(43114, 30106); // Avalanche
        _setEid(137, 30109); // Polygon PoS
        _setEid(42161, 30110); // Arbitrum
        _setEid(10, 30111); // Optimism
        _setEid(59144, 30183); // Linea
        _setEid(8453, 30184); // Base
        _setEid(100, 30145); // Gnosis
    }

    //
    // Configuration
    //

    /// @inheritdoc IStargateBridgeAdapter
    function setEidMapping(uint64 chainId, uint32 eid) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setEid(chainId, eid);
    }

    /// @inheritdoc IStargateBridgeAdapter
    function setEndpoint(address endpoint_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (endpoint_ == address(0)) revert InvalidEndpoint();
        endpoint = endpoint_;
    }

    /// @inheritdoc IStargateBridgeAdapter
    function setStargatePool(address asset, address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pool == address(0)) revert InvalidPool();
        // Bind the pool to the asset: the Stargate V2 pool's underlying token must match the asset.
        if (IStargate(pool).token() != asset) revert InvalidPool();
        stargatePool[asset] = pool;
    }

    /// @inheritdoc IStargateBridgeAdapter
    function setComposeOptions(uint32 dstEid, bytes calldata options) external onlyRole(DEFAULT_ADMIN_ROLE) {
        composeOptions[dstEid] = options;
    }

    //
    // BridgeAdapter Implementation (outbound)
    //

    /// @inheritdoc BridgeAdapter
    /// @dev Sends the asset cross-chain via Stargate V2 `sendToken`, with the invoice payload composed so the
    ///      destination sibling adapter receives it via lzCompose after the tokens are delivered to it.
    function _bridge(InvoiceDataLib.InvoiceData memory data) internal override {
        uint32 dstEid = chainIdToEid[uint64(data.destinationChainId)];
        if (dstEid == 0) revert UnsupportedChain(0);

        // Resolve the asset and its Stargate V2 pool.
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));
        // Stargate bridges ERC20 OFT pools; native must be wrapped first.
        if (_isNativeToken(asset)) revert InvalidBridgeData();

        address pool = stargatePool[asset];
        if (pool == address(0)) revert InvalidPool();

        // Pull the gross ERC20 amount from escrow (escrow approved us in depositAndBridge), approve the pool.
        IERC20(asset).safeTransferFrom(bridgeEscrow, address(this), data.amount);
        IERC20(asset).forceApprove(pool, data.amount);

        // Recipient is the sibling adapter on the destination chain (same address via CREATE2). The invoice
        // payload travels in composeMsg so Stargate delivers tokens then triggers lzCompose on the recipient.
        SendParam memory sendParam = SendParam({
            dstEid: dstEid,
            to: _toBytes32(address(this)),
            amountLD: data.amount,
            minAmountLD: 0, // set below from the quote
            extraOptions: composeOptions[dstEid],
            composeMsg: bytes(""), // set below once we know the post-fee amount
            oftCmd: bytes("") // Taxi mode (immediate)
        });

        // POST-FEE OUTPUT MODEL (resolves the PR#86 fee issue): Stargate V2 applies a protocol fee and SD-dust
        // rounding (so the destination adapter usually receives `amountReceivedLD <= amountLD`), but can also quote
        // a reward (`OFTFeeDetail` negative fee) making it slightly larger. The destination funded pass-through
        // must release EXACTLY the amount the payload carries, so we quote the receive amount in this same tx and
        // re-encode the invoice payload to carry it. The recipient then receives and releases exactly
        // `amountReceivedLD` (the bridge fee/reward is borne by the transfer, standard bridge UX). The source-chain
        // invoice still records the gross deposit; source↔destination pairing is by `invoiceId` (fee-independent),
        // so the differing post-fee checksum on the destination is immaterial.
        // quoteOFT is the AUTHORITATIVE in-tx pre-image of sendToken's credit: both read the same pool/feeLib
        // state within this single transaction (nothing interleaves), so `amountReceivedLD` equals the amount
        // sendToken will credit on the destination. Pinning minAmountLD to it (below) therefore carries zero
        // slippage *by construction* — it is exact, not optimistic.
        (,, OFTReceipt memory receipt) = IStargate(pool).quoteOFT(sendParam);
        uint256 receivedAmount = receipt.amountReceivedLD;
        if (receivedAmount == 0) revert InvalidBridgeData();
        // Sanity floor: reject an abnormally large fee. A misconfigured/abusive pool quoting a near-total fee
        // would otherwise pass silently (source locks the gross deposit, destination pays ~dust, no revert).
        // A reward (receivedAmount >= data.amount) has zero fee and always passes; only excessive *loss* reverts.
        if (receivedAmount < data.amount && (data.amount - receivedAmount) * 10000 > data.amount * MAX_BRIDGE_FEE_BPS) {
            revert InvalidBridgeData();
        }

        // Build a SEPARATE post-fee copy for the COMPOSED payload (the destination release amount) — do NOT mutate
        // `data`, which is shared by reference with the base `bridge()` (it emits `BridgeInitiated` with the gross
        // deposit amount after this returns). KEEP THESE FIELDS IN SYNC with InvoiceDataLib.InvoiceData: a new
        // field added there must be copied here, or the destination payload silently carries a zero/stale value.
        InvoiceDataLib.InvoiceData memory postFeeData = InvoiceDataLib.InvoiceData({
            invoiceId: data.invoiceId,
            sourceChainId: data.sourceChainId,
            destinationChainId: data.destinationChainId,
            account: data.account,
            assetSymbol: data.assetSymbol,
            amount: receivedAmount,
            nonce: data.nonce,
            timestamp: data.timestamp,
            checksum24: InvoiceDataLib.calculateChecksum(data.invoiceId, receivedAmount, data.timestamp, data.nonce)
        });
        sendParam.minAmountLD = receivedAmount;
        sendParam.composeMsg = InvoiceDataLib.encode(postFeeData);
        // Reward safety: any reward is delivered to THIS adapter in the same lzCompose, which the destination
        // verifies via `_message.amountLD() >= payload.amount` AND `balanceOf(this) >= payload.amount`. An
        // under-delivered reward therefore safely reverts there; it can never release one invoice from another's
        // funds (adapters forward everything and hold no standing balance).

        // Quote the LayerZero messaging fee (paid in native) and send.
        MessagingFee memory fee = IStargate(pool).quoteSend(sendParam, false);
        (MessagingReceipt memory msgReceipt,,) =
            IStargate(pool).sendToken{value: fee.nativeFee}(sendParam, fee, address(this));

        // Reset approval (defensive; sendToken should have consumed exactly amountLD).
        IERC20(asset).forceApprove(pool, 0);

        // Store the GROSS payload so getMessagePayload on the SOURCE matches the gross invoice the escrow recorded
        // (the escrow keys its BRIDGING invoice by the gross checksum). The post-fee payload lives only in the
        // destination composeMsg above; the destination adapter stores its own post-fee payload on receipt.
        messagePayloads[data.invoiceId] = InvoiceDataLib.encode(data);

        // Emit the GROSS source amount (consistent with the base BridgeInitiated event and other adapters'
        // *BridgeInitiated events). The post-fee amount lives in the composed payload / OFT receipt.
        emit StargateBridgeInitiated(data.invoiceId, dstEid, msgReceipt.guid, data.amount);
    }

    //
    // BridgeAdapter Implementation (completion)
    //

    /// @inheritdoc BridgeAdapter
    /// @dev MANAGER fallback completion: the LayerZero Endpoint normally calls `lzCompose` directly (auto
    ///      path). This manager path is used only if that did not run. `protocolData` carries the full
    ///      OFT-composed `_message` (OFTComposeMsgCodec layout) so we authenticate the source the same way.
    ///      The adapter must already hold the delivered tokens (Stargate delivered them to this adapter as the
    ///      recipient); the base then funds+releases.
    function _completeBridge(bytes calldata messagePayload, bytes calldata protocolData) internal override {
        if (protocolData.length < OFTComposeMsgCodec.composeFromEnd()) revert InvalidCompletionData();

        uint32 srcEid_ = protocolData.srcEid();
        bytes32 composeFrom_ = protocolData.composeFrom();
        _authenticateSource(srcEid_, composeFrom_);

        bytes memory authedPayload = protocolData.composeMsg();
        if (authedPayload.length == 0) revert InvalidCompletionData();
        // The base completeBridge funds + releases against `messagePayload`, so it MUST be the same payload
        // we authenticated from the LayerZero compose message — otherwise a manager could release a different
        // invoice than the one provenance vouches for.
        if (keccak256(messagePayload) != keccak256(authedPayload)) revert InvalidCompletionData();

        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(authedPayload);
        messagePayloads[data.invoiceId] = authedPayload;

        emit StargateBridgeCompleted(data.invoiceId, srcEid_);
    }

    /// @inheritdoc ILayerZeroComposer
    /// @dev Auto completion path. Called by the genuine LayerZero V2 Endpoint on the destination chain after
    ///      Stargate delivered the tokens to this adapter. Authenticates the endpoint, the composing Stargate
    ///      pool, the source eid and the source sibling adapter, verifies the delivered token+amount matches
    ///      the invoice, then funds the escrow and releases (funded pass-through).
    function lzCompose(address _from, bytes32, bytes calldata _message, address, bytes calldata)
        external
        payable
        override
        nonReentrant
    {
        // 1) Authenticate the genuine protocol contracts: the LayerZero Endpoint must be the caller, and the
        //    composing OApp must be a Stargate pool we configured.
        if (msg.sender != endpoint) revert InvalidEndpoint();

        // 2) Authenticate the source chain + sibling adapter.
        uint32 srcEid_ = _message.srcEid();
        bytes32 composeFrom_ = _message.composeFrom();
        _authenticateSource(srcEid_, composeFrom_);

        // 3) Decode the invoice and resolve the destination asset + its configured Stargate pool.
        bytes memory messagePayload = _message.composeMsg();
        if (messagePayload.length == 0) revert InvalidCompletionData();
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));
        address pool = stargatePool[asset];
        if (pool == address(0)) revert InvalidPool();
        // The composing OApp must be exactly the Stargate pool that bridges this asset.
        if (_from != pool) revert InvalidBridgeData();

        // 4) Verify Stargate actually delivered the invoiced amount of the asset to this adapter.
        if (_message.amountLD() < data.amount) revert InvalidBridgeData();
        if (IERC20(asset).balanceOf(address(this)) < data.amount) revert InvalidBridgeData();

        messagePayloads[data.invoiceId] = messagePayload;
        _fundAndRelease(messagePayload, asset, data.amount);

        emit StargateBridgeCompleted(data.invoiceId, srcEid_);
    }

    /// @dev Authenticates that an inbound message came from a known sibling adapter on a known source chain.
    function _authenticateSource(uint32 srcEid_, bytes32 composeFrom_) internal view {
        uint64 srcChainId = eidToChainId[srcEid_];
        if (srcChainId == 0) revert UnsupportedChain(srcEid_);
        if (composeFrom_ != trustedRemoteAdapter[srcChainId]) revert InvalidBridgeData();
    }

    //
    // View Functions
    //

    /// @inheritdoc IStargateBridgeAdapter
    function getMessagePayload(bytes32 invoiceId) external view override returns (bytes memory) {
        return messagePayloads[invoiceId];
    }

    /// @inheritdoc IStargateBridgeAdapter
    function getEidForChain(uint64 chainId) external view override returns (uint32) {
        return chainIdToEid[chainId];
    }

    /// @inheritdoc IStargateBridgeAdapter
    function getChainForEid(uint32 eid) external view override returns (uint64) {
        return eidToChainId[eid];
    }

    //
    // ERC165 Support
    //

    /// @notice Checks if the contract supports an interface
    /// @param interfaceId The interface ID to check
    /// @return True if supported
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ILayerZeroComposer).interfaceId || super.supportsInterface(interfaceId);
    }

    //
    // Receive Function
    //

    /// @notice Allows contract to receive native tokens (for LayerZero fees / refunds)
    receive() external payable {}
}
