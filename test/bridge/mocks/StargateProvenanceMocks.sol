// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IStargate,
    ILayerZeroComposer,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTLimit,
    OFTFeeDetail,
    OFTReceipt,
    Ticket
} from "src/bridge/adapters/interfaces/IStargateInterfaces.sol";

/// @notice Minimal mintable ERC20 view used by the mocks
interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
}

/// @title StargateProvenanceMocks
/// @notice Stargate V2 (OFT / LayerZero V2) mocks for the provenance-model StargateBridgeAdapter tests.
/// @dev These mocks live in a dedicated file (ADR 0012 migration scope) and do NOT touch the shared
///      `MockBridgeProtocols.sol`. They model the two genuine protocol contracts the adapter authenticates:
///      the Stargate V2 pool (an OFT for one token) and the LayerZero V2 Endpoint (the only caller of
///      `lzCompose`). The delivery helper reproduces the real flow: tokens are transferred to the recipient
///      adapter first, then the Endpoint invokes `lzCompose` with an OFTComposeMsgCodec-encoded message.

/// @title MockStargatePoolV2
/// @notice Mock Stargate V2 pool implementing IStargate for a single underlying token.
contract MockStargatePoolV2 is IStargate {
    using SafeERC20 for IERC20;

    address public immutable underlying;
    uint256 public constant NATIVE_FEE = 0.01 ether;

    /// @notice Flat protocol fee (in local decimals) deducted from the send amount; the destination receives
    ///         `amountLD - protocolFeeLD + rewardLD`. Defaults 0 (no fee, no reward) so existing tests are
    ///         unaffected; set them to exercise the post-fee output model (fee) or the reward path.
    uint256 public protocolFeeLD;
    /// @notice Flat reward (in local decimals) added to the credited amount (Stargate `OFTFeeDetail` negative fee).
    uint256 public rewardLD;

    // Records of the last send (for source-side assertions)
    SendParam public lastSendParam;
    bool public sent;

    constructor(address _underlying) {
        underlying = _underlying;
    }

    /// @notice Test hook: configure the flat protocol fee deducted on a send.
    function setProtocolFeeLD(uint256 feeLD) external {
        protocolFeeLD = feeLD;
    }

    /// @notice Test hook: configure a flat reward added on a send (destination receives MORE than sent).
    function setRewardLD(uint256 reward) external {
        rewardLD = reward;
    }

    /// @dev The amount credited on the destination for a given gross send amount (post fee, plus any reward).
    function _received(uint256 amountLD) internal view returns (uint256) {
        uint256 net = amountLD > protocolFeeLD ? amountLD - protocolFeeLD : 0;
        return net + rewardLD;
    }

    /// @inheritdoc IStargate
    function token() external view override returns (address) {
        return underlying;
    }

    /// @inheritdoc IStargate
    function quoteSend(SendParam calldata, bool) external pure override returns (MessagingFee memory fee) {
        fee = MessagingFee({nativeFee: NATIVE_FEE, lzTokenFee: 0});
    }

    /// @inheritdoc IStargate
    function quoteOFT(SendParam calldata _sendParam)
        external
        view
        override
        returns (OFTLimit memory limit, OFTFeeDetail[] memory oftFeeDetails, OFTReceipt memory oftReceipt)
    {
        limit = OFTLimit({minAmountLD: 0, maxAmountLD: type(uint256).max});
        oftFeeDetails = new OFTFeeDetail[](0);
        oftReceipt = OFTReceipt({amountSentLD: _sendParam.amountLD, amountReceivedLD: _received(_sendParam.amountLD)});
    }

    /// @inheritdoc IStargate
    function sendToken(SendParam calldata _sendParam, MessagingFee calldata _fee, address)
        external
        payable
        override
        returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt, Ticket memory ticket)
    {
        require(msg.value >= _fee.nativeFee, "fee");
        uint256 received = _received(_sendParam.amountLD);
        // Enforce the caller's slippage floor, like the real pool.
        require(received >= _sendParam.minAmountLD, "minAmountLD");
        // Pull the tokens from the sender (the adapter), mirroring a real OFT debit.
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), _sendParam.amountLD);

        lastSendParam = _sendParam;
        sent = true;

        msgReceipt = MessagingReceipt({
            guid: keccak256(abi.encode(_sendParam.dstEid, _sendParam.to, _sendParam.amountLD)), nonce: 1, fee: _fee
        });
        oftReceipt = OFTReceipt({amountSentLD: _sendParam.amountLD, amountReceivedLD: received});
        ticket = Ticket({ticketId: 0, passengerBytes: bytes("")});
    }

    /// @notice Returns the composeMsg of the last send (the invoice messagePayload)
    function getLastComposeMsg() external view returns (bytes memory) {
        return lastSendParam.composeMsg;
    }
}

/// @title MockLZEndpointV2
/// @notice Mock LayerZero V2 Endpoint: the only authorized caller of `lzCompose` on a recipient.
/// @dev `deliverCompose` reproduces the genuine destination flow: it first transfers the bridged tokens to
///      the recipient adapter (as Stargate would on token distribution), then calls `lzCompose` on it with an
///      OFTComposeMsgCodec-encoded `_message` built from (nonce, srcEid, amountLD, composeFrom, composeMsg).
contract MockLZEndpointV2 {
    using SafeERC20 for IERC20;

    /// @notice Builds an OFT-composed message in the OFTComposeMsgCodec layout
    /// @dev Layout: nonce[0:8] | srcEid[8:12] | amountLD[12:44] | composeFrom[44:76] | composeMsg[76:]
    function encodeComposeMessage(
        uint64 nonce,
        uint32 srcEid,
        uint256 amountLD,
        bytes32 composeFrom,
        bytes memory composeMsg
    ) public pure returns (bytes memory) {
        return abi.encodePacked(nonce, srcEid, amountLD, composeFrom, composeMsg);
    }

    /// @notice Genuine delivery: fund the recipient with `tokenAmount` of `token`, then call lzCompose as the endpoint.
    /// @param recipient The destination sibling adapter (implements ILayerZeroComposer)
    /// @param stargatePool The composing OApp (`_from`) — the destination Stargate pool
    /// @param token The delivered ERC20 (minted/transferred to the recipient before lzCompose)
    /// @param tokenAmount The amount delivered to the recipient adapter
    /// @param message The OFTComposeMsgCodec-encoded message (use encodeComposeMessage)
    function deliverCompose(
        address recipient,
        address stargatePool,
        address token,
        uint256 tokenAmount,
        bytes calldata message
    ) external {
        if (token != address(0) && tokenAmount > 0) {
            // Tokens arrive at the recipient adapter before the compose callback (real Stargate behaviour).
            IERC20(token).safeTransfer(recipient, tokenAmount);
        }
        bytes32 guid = keccak256(message);
        ILayerZeroComposer(recipient).lzCompose(stargatePool, guid, message, address(this), bytes(""));
    }
}
