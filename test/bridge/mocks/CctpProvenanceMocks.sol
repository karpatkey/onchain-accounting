// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICircleTokenMessengerV2} from "src/bridge/adapters/interfaces/ICircleTokenMessengerV2.sol";
import {IMessageTransmitter} from "@chainlink/src/v0.8/ccip/pools/USDC/IMessageTransmitter.sol";

/// @title CctpProvenanceMocks
/// @notice Mocks for the re-architected CCTP provenance model.
/// @dev The new adapter mints USDC to ITSELF on the destination chain (mintRecipient ==
///      destinationCaller == adapter) and verifies the attested CCTP message body before
///      forwarding the minted USDC to the escrow. These mocks model that flow:
///        - MockProvenanceMessageTransmitter.receiveMessage parses the recipient field and mints
///          to it (the adapter), and rejects replayed messages.
///        - buildCctpProvenanceMessage builds a message whose layout exactly matches what the
///          adapter's _verifyCctpMessage parses.

interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
}

/// @notice Builds CCTP messages in the exact layout the new adapter verifies.
/// @dev Full CCTP message layout (matches Circle / IMessageTransmitter). Byte offsets in brackets:
///        version[0..4] sourceDomain[4..8] destinationDomain[8..12] nonce[12..20]
///        sender[20..52] recipient[52..84] destinationCaller[84..116] messageBody[116..]
///      BurnMessage body (offsets relative to message start, body begins at byte 116):
///        body.version[116..120] burnToken[120..152] mintRecipient[152..184] amount[184..216]
///      Offsets the adapter reads: sourceDomain[4], nonce[12], recipient[52],
///        burnToken[120], mintRecipient[152], amount[184].
library CctpProvenanceMessage {
    /// @notice Build a parseable CCTP message for the provenance model.
    /// @param sourceDomain Source CCTP domain
    /// @param destDomain Destination CCTP domain
    /// @param nonce CCTP message nonce
    /// @param burnToken The token burned on source / minted on destination (USDC)
    /// @param mintRecipient The mint recipient (the destination adapter)
    /// @param destinationCaller The authorized destination caller (the destination adapter)
    /// @param amount The amount minted
    /// @return message The encoded CCTP message (248 bytes: 116 header + 132 body)
    function build(
        uint32 sourceDomain,
        uint32 destDomain,
        uint64 nonce,
        address burnToken,
        address mintRecipient,
        address destinationCaller,
        uint256 amount
    ) internal pure returns (bytes memory message) {
        // 116 (header) + 4 (body version) + 32 (burnToken) + 32 (mintRecipient) + 32 (amount)
        // + 32 (messageSender) = 248 bytes.
        message = new bytes(248);

        bytes32 recipientWord = bytes32(uint256(uint160(mintRecipient)));
        bytes32 callerWord = bytes32(uint256(uint160(destinationCaller)));
        bytes32 burnTokenWord = bytes32(uint256(uint160(burnToken)));

        assembly ("memory-safe") {
            let base := add(message, 32) // first data byte

            // version @0 = 0 (left as zero)
            // sourceDomain @4 (uint32)
            mstore(add(base, 4), shl(224, sourceDomain))
            // destinationDomain @8 (uint32)
            mstore(add(base, 8), shl(224, destDomain))
            // nonce @12 (uint64)
            mstore(add(base, 12), shl(192, nonce))
            // sender @20 (bytes32) — left as zero
            // recipient @52 (bytes32) — transmitter-level mint recipient (the adapter)
            mstore(add(base, 52), recipientWord)
            // destinationCaller @84 (bytes32)
            mstore(add(base, 84), callerWord)
            // body version @116 (uint32) — left as zero
            // body burnToken @120 (bytes32, left-padded address)
            mstore(add(base, 120), burnTokenWord)
            // body mintRecipient @152 (bytes32)
            mstore(add(base, 152), recipientWord)
            // body amount @184 (uint256)
            mstore(add(base, 184), amount)
            // body messageSender @216 (bytes32) — left as zero
        }
    }
}

/// @notice Mock MessageTransmitter for the provenance model: mints to the message recipient (the
///         adapter) and rejects replayed messages, simulating Circle's attested receiveMessage.
contract MockProvenanceMessageTransmitter is IMessageTransmitter {
    using SafeERC20 for IERC20;

    uint32 private immutable _LOCAL_DOMAIN;
    uint32 public constant VERSION = 0;
    IERC20 public usdc;
    mapping(bytes32 => bool) public receivedMessages;

    event MessageReceived(bytes32 messageHash, uint32 sourceDomain, uint64 nonce);

    constructor(uint32 domain, address usdc_) {
        _LOCAL_DOMAIN = domain;
        usdc = IERC20(usdc_);
    }

    /// @inheritdoc IMessageTransmitter
    /// @dev Parses the recipient field (bytes 52-84) and mints `amount` (body @184) to it.
    ///      Reverts on replay — modelling Circle's nonce-tracking transmitter. A real transmitter
    ///      additionally verifies `attestation`; here a non-empty attestation is required by the
    ///      adapter before this is ever called.
    function receiveMessage(
        bytes calldata message,
        bytes calldata /* attestation */
    )
        external
        override
        returns (bool)
    {
        require(message.length >= 216, "Message too short");

        bytes32 messageHash = keccak256(message);
        require(!receivedMessages[messageHash], "Message already received");
        receivedMessages[messageHash] = true;

        uint32 sourceDomain = uint32(bytes4(message[4:8]));
        uint64 nonce = uint64(uint256(bytes32(message[12:20])));
        address recipient = address(uint160(uint256(bytes32(message[52:84]))));
        uint256 amount = uint256(bytes32(message[184:216]));

        // Mint USDC to the recipient (the adapter, in the new provenance model).
        IMintableERC20(address(usdc)).mint(recipient, amount);

        emit MessageReceived(messageHash, sourceDomain, nonce);
        return true;
    }

    function localDomain() external view override returns (uint32) {
        return _LOCAL_DOMAIN;
    }

    function version() external pure override returns (uint32) {
        return VERSION;
    }
}

/// @notice Mock TokenMessengerV2 for the provenance model: pulls and holds the burned USDC on the
///         source chain (no return value, matching the real V2 ABI).
contract MockProvenanceTokenMessenger is ICircleTokenMessengerV2 {
    using SafeERC20 for IERC20;

    uint64 public nonce;

    event DepositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    );

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external override {
        IERC20(burnToken).safeTransferFrom(msg.sender, address(this), amount);
        nonce++;
        emit DepositForBurn(
            amount, destinationDomain, mintRecipient, burnToken, destinationCaller, maxFee, minFinalityThreshold
        );
    }
}
