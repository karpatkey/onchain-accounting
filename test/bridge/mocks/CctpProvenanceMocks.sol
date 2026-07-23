// SPDX-License-Identifier: BUSL-1.1
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

/// @notice Builds CCTP V2 messages in the exact layout the new adapter verifies.
/// @dev Full CCTP V2 message layout (Circle MessageV2 + BurnMessageV2). Byte offsets in brackets:
///        version[0..4] sourceDomain[4..8] destinationDomain[8..12] nonce[12..44]
///        sender[44..76] recipient[76..108] destinationCaller[108..140]
///        minFinalityThreshold[140..144] finalityThresholdExecuted[144..148] messageBody[148..]
///      BurnMessageV2 body (offsets relative to message start, body begins at byte 148):
///        body.version[148..152] burnToken[152..184] mintRecipient[184..216] amount[216..248]
///      Offsets the adapter reads: sourceDomain[4], nonce[12] (bytes32), recipient[76],
///        burnToken[152], mintRecipient[184], amount[216].
library CctpProvenanceMessage {
    /// @notice Build a parseable CCTP V2 message for the provenance model.
    /// @param sourceDomain Source CCTP domain
    /// @param destDomain Destination CCTP domain
    /// @param nonce CCTP V2 message nonce (bytes32, Circle-assigned)
    /// @param burnToken The token burned on source / minted on destination (USDC)
    /// @param headerRecipient The V2 header recipient (bytes 76-108) — in a real token burn message this
    ///        is the destination TokenMessenger (the on-chain handler MessageTransmitter dispatches to),
    ///        NOT the mint recipient
    /// @param mintRecipient The V2 body mintRecipient (bytes 184-216) — the destination adapter
    /// @param destinationCaller The authorized destination caller (the destination adapter)
    /// @param amount The amount minted
    /// @return message The encoded CCTP V2 message (248 bytes: 148 header + 100 body through amount)
    function build(
        uint32 sourceDomain,
        uint32 destDomain,
        bytes32 nonce,
        address burnToken,
        address headerRecipient,
        address mintRecipient,
        address destinationCaller,
        uint256 amount
    ) internal pure returns (bytes memory message) {
        // 148 (V2 header) + 4 (body version) + 32 (burnToken) + 32 (mintRecipient) + 32 (amount) = 248 bytes.
        message = new bytes(248);

        bytes32 headerRecipientWord = bytes32(uint256(uint160(headerRecipient)));
        bytes32 recipientWord = bytes32(uint256(uint160(mintRecipient)));
        bytes32 callerWord = bytes32(uint256(uint160(destinationCaller)));
        bytes32 burnTokenWord = bytes32(uint256(uint160(burnToken)));

        // Fields written in increasing offset order; each writes a full 32-byte word whose meaningful
        // bytes sit at the start, so the next write (starting at/after that field's end) preserves it.
        assembly ("memory-safe") {
            let base := add(message, 32) // first data byte

            // version @0 = 0 (left as zero)
            // sourceDomain @4 (uint32)
            mstore(add(base, 4), shl(224, sourceDomain))
            // destinationDomain @8 (uint32)
            mstore(add(base, 8), shl(224, destDomain))
            // nonce @12 (bytes32, Circle-assigned)
            mstore(add(base, 12), nonce)
            // sender @44 (bytes32) — left as zero
            // recipient @76 (bytes32) — the destination TokenMessenger (the on-chain handler that
            // MessageTransmitter dispatches to), NOT the mint recipient
            mstore(add(base, 76), headerRecipientWord)
            // destinationCaller @108 (bytes32)
            mstore(add(base, 108), callerWord)
            // minFinalityThreshold @140 / finalityThresholdExecuted @144 / body version @148 — left zero
            // body burnToken @152 (bytes32, left-padded address)
            mstore(add(base, 152), burnTokenWord)
            // body mintRecipient @184 (bytes32)
            mstore(add(base, 184), recipientWord)
            // body amount @216 (uint256)
            mstore(add(base, 216), amount)
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
    /// @dev Test hook: when set, receiveMessage mints THIS token instead of `usdc`, modelling Circle's
    ///      TokenMinter minting a token that is NOT the invoice's destination asset (so the adapter's
    ///      destination-asset balance-delta guard must revert). Zero = mint the real destination `usdc`.
    address public mintTokenOverride;
    mapping(bytes32 => bool) public receivedMessages;

    event MessageReceived(bytes32 messageHash, uint32 sourceDomain, bytes32 nonce);

    constructor(uint32 domain, address usdc_) {
        _LOCAL_DOMAIN = domain;
        usdc = IERC20(usdc_);
    }

    /// @notice Test hook: force receiveMessage to mint `token` instead of the destination `usdc`.
    function setMintTokenOverride(address token) external {
        mintTokenOverride = token;
    }

    /// @inheritdoc IMessageTransmitter
    /// @dev Parses the V2 *body* mintRecipient (bytes 184-216) and mints `amount` (body bytes 216-248) to
    ///      it — matching real CCTP, where the transmitter dispatches to the header recipient (the
    ///      TokenMessenger) which mints via the TokenMinter to the body mintRecipient (the adapter).
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
        require(message.length >= 248, "Message too short");

        bytes32 messageHash = keccak256(message);
        require(!receivedMessages[messageHash], "Message already received");
        receivedMessages[messageHash] = true;

        uint32 sourceDomain = uint32(bytes4(message[4:8]));
        bytes32 nonce = bytes32(message[12:44]);
        address recipient = address(uint160(uint256(bytes32(message[184:216]))));
        uint256 amount = uint256(bytes32(message[216:248]));

        // Mint to the body mintRecipient (the adapter, in the provenance model). Real CCTP mints the
        // canonical local token for the (sourceDomain, burnToken) pair; the override models a token that
        // is NOT the invoice's destination asset, which the adapter's balance-delta guard must reject.
        address tokenToMint = mintTokenOverride == address(0) ? address(usdc) : mintTokenOverride;
        IMintableERC20(tokenToMint).mint(recipient, amount);

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
