// SPDX-License-Identifier: MIT
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
/// @author kpk
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
        bytes memory messagePayload = InvoiceDataLib.encode(data);

        uint32 dstEid = chainIdToEid[uint64(data.destinationChainId)];
        if (dstEid == 0) revert UnsupportedChain(0);

        // Resolve the asset and its Stargate V2 pool.
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));
        // Stargate bridges ERC20 OFT pools; native must be wrapped first.
        if (_isNativeToken(asset)) revert InvalidBridgeData();

        address pool = stargatePool[asset];
        if (pool == address(0)) revert InvalidPool();

        // Pull ERC20 tokens from escrow (escrow approved us in depositAndBridge), approve the Stargate pool.
        IERC20(asset).safeTransferFrom(bridgeEscrow, address(this), data.amount);
        IERC20(asset).forceApprove(pool, data.amount);

        // Recipient is the sibling adapter on the destination chain (same address via CREATE2). The invoice
        // payload travels in composeMsg so Stargate delivers tokens then triggers lzCompose on the recipient.
        SendParam memory sendParam = SendParam({
            dstEid: dstEid,
            to: _toBytes32(address(this)),
            amountLD: data.amount,
            // KNOWN ISSUE (Copilot PR#86): Stargate V2 applies a protocol fee, so the destination adapter
            // receives `amount - fee` < `amount`; the exact-amount funded pass-through then can't release and
            // would strand the shortfall. `minAmountLD = amount` is rejected by the real pool (fee), and a
            // loose floor masks the shortfall. The correct fix is fee-aware: quote the receive amount
            // (IStargate.quoteOFT) and either gross up the input so the destination receives >= `amount`, or
            // record the invoice as the post-fee output amount. Tracked as a follow-up — see thread on PR #86.
            minAmountLD: (data.amount * 95) / 100,
            extraOptions: composeOptions[dstEid],
            composeMsg: messagePayload,
            oftCmd: bytes("") // Taxi mode (immediate)
        });

        // Quote the LayerZero messaging fee (paid in native) and send.
        MessagingFee memory fee = IStargate(pool).quoteSend(sendParam, false);
        (MessagingReceipt memory msgReceipt,,) =
            IStargate(pool).sendToken{value: fee.nativeFee}(sendParam, fee, address(this));

        // Reset approval (defensive; sendToken should have consumed exactly amountLD).
        IERC20(asset).forceApprove(pool, 0);

        messagePayloads[data.invoiceId] = messagePayload;

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
