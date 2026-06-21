// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title LayerZero V2 and Stargate V2 Interfaces
/// @notice Minimal local copies of the Stargate V2 (OFT-based, LayerZero V2) interfaces used by the
///         StargateBridgeAdapter. The repo does not vendor the LayerZero V2 / Stargate V2 packages, so the
///         structs and signatures here mirror upstream exactly:
///           - SendParam / MessagingFee / MessagingReceipt / OFTReceipt — LayerZero V2 `IOFT.sol`
///           - IStargate.sendToken / Ticket — Stargate V2 `IStargate.sol`
///           - ILayerZeroComposer.lzCompose — LayerZero V2 endpoint compose callback
///           - OFTComposeMsgCodec — LayerZero V2 compose-message codec
/// @author kpk

// ============================================================================
// LayerZero V2 OFT types (mirror @layerzerolabs/.../oft/interfaces/IOFT.sol)
// ============================================================================

/// @notice Parameters for an OFT send (Stargate V2 `sendToken`)
struct SendParam {
    uint32 dstEid; // Destination LayerZero endpoint ID (eid)
    bytes32 to; // Recipient on the destination chain (address widened to bytes32)
    uint256 amountLD; // Amount to send, in local decimals
    uint256 minAmountLD; // Minimum amount to receive, in local decimals (slippage floor)
    bytes extraOptions; // Executor options (e.g. lzCompose gas) built via LayerZero OptionsBuilder
    bytes composeMsg; // Composed message delivered to the destination `to` via lzCompose (non-empty enables compose)
    bytes oftCmd; // OFT command; empty for the default ("Taxi") path
}

/// @notice LayerZero V2 messaging fee
struct MessagingFee {
    uint256 nativeFee; // Fee paid in native gas token
    uint256 lzTokenFee; // Fee paid in the LZ token (0 when paying native)
}

/// @notice LayerZero V2 messaging receipt
struct MessagingReceipt {
    bytes32 guid; // Globally-unique message id
    uint64 nonce; // Per-pathway nonce
    MessagingFee fee; // Fee actually charged
}

/// @notice Stargate/OFT receipt describing the amounts moved
struct OFTReceipt {
    uint256 amountSentLD; // Amount debited on source, in local decimals
    uint256 amountReceivedLD; // Amount credited on destination, in local decimals
}

/// @notice Allowed send-amount bounds returned by `quoteOFT`
struct OFTLimit {
    uint256 minAmountLD;
    uint256 maxAmountLD;
}

/// @notice A single fee/reward component returned by `quoteOFT` (negative = reward)
struct OFTFeeDetail {
    int256 feeAmountLD;
    string description;
}

/// @notice Stargate V2 bus ("Ticket") receipt — returned by sendToken
struct Ticket {
    uint72 ticketId;
    bytes passengerBytes;
}

/// @title IStargate (Stargate V2)
/// @notice Subset of the Stargate V2 OFT pool interface used by the adapter. Each Stargate V2 pool is an OFT
///         for a single underlying token; `sendToken` performs the cross-chain transfer and (when
///         `composeMsg` is non-empty) instructs the destination Stargate to call `lzCompose` on the recipient.
/// @dev Mirrors `IStargate is IOFT` from stargate-v2 `IStargate.sol`.
interface IStargate {
    /// @notice The underlying ERC20 token this Stargate V2 pool bridges (address(0) for the native pool)
    function token() external view returns (address);

    /// @notice Quotes the LayerZero messaging fee for a send
    /// @param _sendParam The send parameters
    /// @param _payInLzToken Whether the fee is paid in the LZ token (false = native)
    /// @return fee The required messaging fee
    function quoteSend(SendParam calldata _sendParam, bool _payInLzToken)
        external
        view
        returns (MessagingFee memory fee);

    /// @notice Quotes the OFT amounts for a send: the destination receives `oftReceipt.amountReceivedLD`
    ///         (= `amountLD` minus the Stargate protocol fee and minus SD-granularity dust).
    /// @param _sendParam The send parameters (amountLD is the gross amount to debit on the source)
    /// @return limit The min/max send-amount bounds
    /// @return oftFeeDetails The fee/reward breakdown (negative entries are rewards)
    /// @return oftReceipt The resulting amounts: `amountSentLD` debited on source, `amountReceivedLD` credited on destination
    function quoteOFT(SendParam calldata _sendParam)
        external
        view
        returns (OFTLimit memory limit, OFTFeeDetail[] memory oftFeeDetails, OFTReceipt memory oftReceipt);

    /// @notice Sends tokens cross-chain via Stargate V2 (OFT), optionally composing a message at the destination
    /// @param _sendParam The send parameters (destination eid, recipient, amounts, options, composeMsg)
    /// @param _fee The messaging fee (native and/or LZ token)
    /// @param _refundAddress Address to refund excess fee
    /// @return msgReceipt LayerZero messaging receipt (guid, nonce, fee)
    /// @return oftReceipt OFT receipt (amount sent / received in local decimals)
    /// @return ticket Stargate bus ticket (unused in Taxi mode)
    function sendToken(SendParam calldata _sendParam, MessagingFee calldata _fee, address _refundAddress)
        external
        payable
        returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt, Ticket memory ticket);
}

// ============================================================================
// LayerZero V2 compose receiver (mirror ILayerZeroComposer)
// ============================================================================

/// @title ILayerZeroComposer
/// @notice The destination-side compose callback. The genuine LayerZero V2 Endpoint calls `lzCompose` on the
///         recipient (`SendParam.to`) after Stargate has delivered the tokens to it.
interface ILayerZeroComposer {
    /// @notice Receives a composed message from the LayerZero Endpoint after token delivery
    /// @param _from The OApp that sent the compose message on the destination chain (the Stargate pool)
    /// @param _guid The globally-unique message id
    /// @param _message The OFT-composed message (OFTComposeMsgCodec layout: nonce|srcEid|amountLD|composeFrom|composeMsg)
    /// @param _executor The LayerZero executor that delivered the message
    /// @param _extraData Executor-supplied extra data
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;
}

// ============================================================================
// OFTComposeMsgCodec (mirror LayerZero V2 codec)
// ============================================================================

/// @title OFTComposeMsgCodec
/// @notice Decodes the LayerZero V2 OFT compose message delivered to `lzCompose`.
/// @dev Layout: nonce[0:8] | srcEid[8:12] | amountLD[12:44] | composeFrom[44:76] | composeMsg[76:].
library OFTComposeMsgCodec {
    uint256 private constant NONCE_OFFSET = 8;
    uint256 private constant SRC_EID_OFFSET = 12;
    uint256 private constant AMOUNT_LD_OFFSET = 44;
    uint256 private constant COMPOSE_FROM_OFFSET = 76;

    /// @notice Minimum length of a valid OFT-composed message (the fixed header through composeFrom)
    /// @dev Used to bounds-check a message before slicing its fields.
    function composeFromEnd() internal pure returns (uint256) {
        return COMPOSE_FROM_OFFSET;
    }

    /// @notice The origin nonce of the message
    function nonce(bytes calldata _msg) internal pure returns (uint64) {
        return uint64(bytes8(_msg[0:NONCE_OFFSET]));
    }

    /// @notice The source LayerZero endpoint ID (eid)
    function srcEid(bytes calldata _msg) internal pure returns (uint32) {
        return uint32(bytes4(_msg[NONCE_OFFSET:SRC_EID_OFFSET]));
    }

    /// @notice The amount delivered, in local decimals
    function amountLD(bytes calldata _msg) internal pure returns (uint256) {
        return uint256(bytes32(_msg[SRC_EID_OFFSET:AMOUNT_LD_OFFSET]));
    }

    /// @notice The originating sender on the source chain (the source OApp / sibling adapter), as bytes32
    function composeFrom(bytes calldata _msg) internal pure returns (bytes32) {
        return bytes32(_msg[AMOUNT_LD_OFFSET:COMPOSE_FROM_OFFSET]);
    }

    /// @notice The application-specific composed payload (the invoice messagePayload)
    function composeMsg(bytes calldata _msg) internal pure returns (bytes memory) {
        return _msg[COMPOSE_FROM_OFFSET:];
    }
}

// ============================================================================
// Legacy Stargate V1 / LayerZero V1 types (retained for shared test mocks only)
// ============================================================================
// The StargateBridgeAdapter no longer uses these — it is Stargate V2 (OFT / LayerZero V2). They remain
// defined here solely so the shared `test/bridge/mocks/MockBridgeProtocols.sol` (a shared file outside this
// migration's edit scope) continues to compile. New code must use the V2 types above.

/// @title ILayerZeroReceiver (LayerZero V1)
/// @notice Legacy LayerZero V1 receiver interface. Unused by the V2 adapter; kept for shared mocks.
interface ILayerZeroReceiver {
    function lzReceive(uint16 _srcChainId, bytes calldata _srcAddress, uint64 _nonce, bytes calldata _payload) external;
}

/// @title IStargateRouter (Stargate V1)
/// @notice Legacy Stargate V1 Router interface. Unused by the V2 adapter; kept for shared mocks.
interface IStargateRouter {
    struct LzTxObj {
        uint256 dstGasForCall;
        uint256 dstNativeAmount;
        bytes dstNativeAddr;
    }

    function quoteLayerZeroFee(
        uint16 _dstChainId,
        uint8 _functionType,
        bytes calldata _toAddress,
        bytes calldata _transferAndCallPayload,
        IStargateRouter.LzTxObj memory _lzTxParams
    ) external view returns (uint256 nativeFee, uint256 zroFee);

    function swap(
        uint16 _lzChainId,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        address payable _refundAddress,
        uint256 _amountLd,
        uint256 _minAmountLd,
        IStargateRouter.LzTxObj memory _lzTxParams,
        bytes calldata _to,
        bytes calldata _payload
    ) external payable;
}
