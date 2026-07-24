// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgeAdapter} from "../BridgeAdapter.sol";
import {IBridgeEscrow} from "../IBridgeEscrow.sol";
import {InvoiceDataLib} from "../InvoiceDataLib.sol";
import {ICircleTokenMessengerV2} from "./interfaces/ICircleTokenMessengerV2.sol";
import {IMessageTransmitter} from "@chainlink/src/v0.8/ccip/pools/USDC/IMessageTransmitter.sol";
import {ICctpBridgeAdapter} from "./interfaces/ICctpBridgeAdapter.sol";
import {InvalidArguments} from "src/errors.sol";

/// @title CctpBridgeAdapter
/// @notice Bridge adapter for Circle's Cross-Chain Transfer Protocol (CCTP)
/// @dev MANAGER-driven completion path: provenance is the Circle attestation verified by the
///      MessageTransmitter, NOT a msg.sender/protocol-callback check. On the destination chain
///      USDC mints directly to this adapter (mintRecipient == destinationCaller == address(this));
///      _completeBridge then leaves the minted USDC on this adapter, and the base BridgeAdapter
///      pulls it into the escrow and releases it to the account via _fundAndRelease ->
///      releaseByInvoiceId AFTER _completeBridge returns (funded pass-through, ADR 0012).
/// @author KPK
contract CctpBridgeAdapter is BridgeAdapter, ICctpBridgeAdapter {
    using SafeERC20 for IERC20;

    //
    // State Variables
    //

    /// @notice TokenMessengerV2 contract address (source chain)
    ICircleTokenMessengerV2 private _tokenMessenger;

    /// @notice MessageTransmitter contract address (source chain for sending, destination for receiving)
    IMessageTransmitter public messageTransmitter;

    /// @notice Mapping to store message payloads by invoice ID
    /// @dev Used to retrieve payloads on destination chain
    mapping(bytes32 => bytes) public messagePayloads;

    /// @notice Mapping from CCTP message identifier to invoice ID
    /// @dev Format: messageToInvoiceId[sourceDomain][nonce] = invoiceId. CCTP V2 nonces are `bytes32`
    ///      (Circle-assigned), not the V1 `uint64`.
    mapping(uint32 => mapping(bytes32 => bytes32)) public messageToInvoiceId;

    /// @notice Mapping from chain ID to CCTP domain ID
    mapping(uint64 => uint32) public chainIdToDomain;

    /// @notice Mapping from domain ID to chain ID
    mapping(uint32 => uint64) public domainToChainId;

    /// @notice Whether a chain ID has an explicitly configured CCTP domain mapping
    /// @dev Required because Ethereum's canonical CCTP domain IS 0; domain==0 cannot double as
    ///      an "unconfigured" sentinel (that was the HIGH domain-0 bug). This flag is the source of truth.
    mapping(uint64 => bool) public domainConfigured;

    /// @notice Replay protection: whether a (sourceDomain, nonce) CCTP message was already consumed
    /// @dev Defense in depth — the MessageTransmitter also rejects replayed messages, but the adapter
    ///      records used nonces and reverts on replay before re-invoking receiveMessage. CCTP V2 nonces
    ///      are `bytes32`.
    mapping(uint32 => mapping(bytes32 => bool)) public usedNonces;

    /// @inheritdoc ICctpBridgeAdapter
    function tokenMessenger() public view returns (ICircleTokenMessengerV2) {
        return _tokenMessenger;
    }

    /// @dev Internal helper to set both chainId -> domain and domain -> chainId mappings,
    ///      and mark the chain as explicitly configured.
    function _setChainDomain(uint64 chainId, uint32 domain) internal {
        chainIdToDomain[chainId] = domain;
        domainToChainId[domain] = chainId;
        domainConfigured[chainId] = true;
    }

    /// @param expectedInitializer_ Address permitted to call initialize (address(0) allows anyone).
    constructor(address expectedInitializer_) BridgeAdapter(expectedInitializer_) {}

    /// @inheritdoc ICctpBridgeAdapter
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address tokenMessenger_,
        address messageTransmitter_,
        string memory version_
    ) external {
        // Initialize parent BridgeAdapter (single source of truth for admin, bridgeEscrow, provider name, version)
        super._initializeBridgeAdapter(admin_, bridgeEscrow_, "CCTP", version_);

        // Initialize CCTP-specific contracts
        _tokenMessenger = ICircleTokenMessengerV2(tokenMessenger_);
        messageTransmitter = IMessageTransmitter(messageTransmitter_);

        // Pre-configure known CCTP domains for supported EVM chains (mainnets)
        // Reference: Circle CCTP MessageTransmitterV2 domains
        _setChainDomain(1, 0); // Ethereum (domain 0 — explicitly configured, NOT a sentinel)
        _setChainDomain(43114, 1); // Avalanche
        _setChainDomain(10, 2); // OP Mainnet
        _setChainDomain(42161, 3); // Arbitrum
        _setChainDomain(8453, 6); // Base
        _setChainDomain(137, 7); // Polygon PoS
        _setChainDomain(130, 10); // Unichain
        _setChainDomain(59144, 11); // Linea
        _setChainDomain(81224, 12); // Codex
        _setChainDomain(146, 13); // Sonic
        _setChainDomain(480, 14); // World Chain
        _setChainDomain(143, 15); // Monad
        _setChainDomain(1329, 16); // Sei
        _setChainDomain(50, 18); // XDC
        _setChainDomain(999, 19); // HyperEVM
        _setChainDomain(57073, 21); // Ink
        _setChainDomain(98866, 22); // Plume
    }

    //
    // Configuration
    //

    /// @inheritdoc ICctpBridgeAdapter
    function setDomainMapping(uint64 chainId, uint32 domain) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setChainDomain(chainId, domain);
    }

    /// @inheritdoc ICctpBridgeAdapter
    function setTokenMessenger(address tokenMessenger_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _tokenMessenger = ICircleTokenMessengerV2(tokenMessenger_);
    }

    /// @inheritdoc ICctpBridgeAdapter
    function setMessageTransmitter(address messageTransmitter_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        messageTransmitter = IMessageTransmitter(messageTransmitter_);
    }

    //
    // BridgeAdapter Implementation
    //

    /// @inheritdoc BridgeAdapter
    /// @dev Receives decoded invoice data struct and converts it to CCTP-specific format.
    ///      Burns USDC to mint on the destination chain to THIS adapter (mintRecipient ==
    ///      destinationCaller == address(this)); the destination adapter re-funds the escrow.
    function _bridge(InvoiceDataLib.InvoiceData memory data) internal override {
        // Get asset address from registry
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));

        // Validate asset is not native (CCTP only supports USDC)
        if (_isNativeToken(asset)) {
            revert InvalidArguments();
        }

        // Pull ERC20 tokens from escrow (escrow approved us in depositAndBridge)
        IERC20(asset).safeTransferFrom(bridgeEscrow, address(this), data.amount);

        // Convert chain ID to CCTP domain — use explicit configuration flag, NOT a domain==0 sentinel
        // (Ethereum's canonical CCTP domain is 0 and must be a valid destination).
        uint64 destChainId = uint64(data.destinationChainId);
        if (!domainConfigured[destChainId]) {
            revert InvalidDomain();
        }
        uint32 destinationDomain = chainIdToDomain[destChainId];

        // New provenance model: mint to THIS adapter on destination and restrict the destination
        // caller to THIS adapter. The destination adapter then funds the escrow + releases.
        bytes32 selfAsBytes32 = bytes32(uint256(uint160(address(this))));
        bytes32 mintRecipient = selfAsBytes32;
        bytes32 destinationCaller = selfAsBytes32;

        // Approve TokenMessenger to spend tokens
        IERC20(asset).forceApprove(address(tokenMessenger()), data.amount);

        // Step 1: Burn USDC using TokenMessengerV2. Creates a message that mints USDC on destination.
        // Use zero maxFee (no fee charged) and standard finality threshold (2000) as per Circle docs.
        tokenMessenger()
            .depositForBurn(
                data.amount,
                destinationDomain,
                mintRecipient,
                asset,
                destinationCaller,
                0, // maxFee: 0 units of USDC
                2000 // minFinalityThreshold: standard (fully finalized) transfers
            );

        // TokenMessengerV2 does not return the message nonce; it is only available in events.
        // Completion verifies provenance from the attested CCTP message body, not from this mapping.
        bytes32 nonce = bytes32(0);

        emit CctpBridgeInitiated(data.invoiceId, destinationDomain, mintRecipient, bytes32(data.amount), nonce);
    }

    /// @inheritdoc BridgeAdapter
    /// @dev Receives the Circle-attested CCTP message: verifies the message matches the invoice, then
    ///      mints USDC to THIS adapter and leaves it here — it does NOT forward the USDC to the escrow.
    ///      Does NOT call releaseByInvoiceId either — the base BridgeAdapter.completeBridge invokes
    ///      _fundAndRelease immediately after this returns, and the escrow pulls the minted balance and
    ///      releases it to the account (funded pass-through, ADR 0012).
    function _completeBridge(bytes calldata messagePayload, bytes calldata protocolData) internal override {
        // Decode protocol data: the raw CCTP message and Circle's attestation over it.
        (bytes memory cctpMessage, bytes memory attestation) = abi.decode(protocolData, (bytes, bytes));

        if (cctpMessage.length == 0 || attestation.length == 0) {
            revert InvalidCompletionData();
        }

        // Decode the invoice we expect this CCTP transfer to settle.
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

        // Resolve the destination asset. Its balance delta across receiveMessage binds the mint — the message's
        // burnToken is a SOURCE-chain token and is intentionally NOT compared to this asset (V2 provenance model).
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));
        if (_isNativeToken(asset)) revert InvalidArguments();

        // ── Parse + verify the CCTP message against the invoice (provenance check) ──
        (uint32 sourceDomain, bytes32 nonce) = _verifyCctpMessage(cctpMessage, data);

        // Replay protection: a (sourceDomain, nonce) message may settle exactly once.
        // (The MessageTransmitter also rejects replays; this is defense in depth and lets us
        // bind a nonce to its invoiceId.)
        if (usedNonces[sourceDomain][nonce]) {
            revert NonceAlreadyUsed(sourceDomain, nonce);
        }
        usedNonces[sourceDomain][nonce] = true;
        messageToInvoiceId[sourceDomain][nonce] = data.invoiceId;
        messagePayloads[data.invoiceId] = messagePayload;

        // Receive the attested CCTP message — reverts unless Circle-attested. Mints the destination
        // asset to mintRecipient (this adapter, verified above). The adapter now holds the minted asset.
        // Verify the DESTINATION asset was actually minted in the invoice amount by measuring its balance
        // delta across receiveMessage. We do NOT compare the message's burnToken to `asset`: CCTP's
        // BurnMessage carries the SOURCE-chain burned token (e.g. Base USDC), which legitimately differs
        // from this chain's asset (e.g. Arbitrum USDC); Circle's TokenMinter maps the (sourceDomain,
        // burnToken) pair to the canonical local token, so the balance delta is the correct invariant.
        uint256 assetBalBefore = IERC20(asset).balanceOf(address(this));
        bool success = messageTransmitter.receiveMessage(cctpMessage, attestation);
        if (!success) {
            revert MessageReceiveFailed();
        }
        // Assert the destination asset rose by at least the invoice amount. Written as `after < before + amount`
        // (not `after - before < amount`) so a balance that somehow did NOT increase reverts with the intended
        // `BurnTokenMismatch`, not a generic underflow panic.
        if (IERC20(asset).balanceOf(address(this)) < assetBalBefore + data.amount) {
            revert BurnTokenMismatch();
        }

        // The adapter now holds the freshly-minted USDC. The base BridgeAdapter.completeBridge calls
        // _fundAndRelease after we return (funded pass-through, ADR 0012): the escrow pulls exactly
        // `amount` from this adapter and forwards it to the account. We do NOT push/release here.
        emit CctpBridgeCompleted(data.invoiceId, data.invoiceId, sourceDomain);
    }

    /// @notice Parses a CCTP message and verifies it matches the decoded invoice.
    /// @param cctpMessage The raw CCTP message (header + BurnMessage body)
    /// @param data The decoded invoice this completion is settling
    /// @return sourceDomain The source CCTP domain from the message header
    /// @return nonce The CCTP message nonce (bytes32, Circle-assigned) from the message header
    /// @dev CCTP **V2** message layout (Circle MessageV2 + BurnMessageV2). Byte offsets in brackets:
    ///        version[0..4] sourceDomain[4..8] destinationDomain[8..12] nonce[12..44]
    ///        sender[44..76] recipient[76..108] destinationCaller[108..140]
    ///        minFinalityThreshold[140..144] finalityThresholdExecuted[144..148] messageBody[148..]
    ///      BurnMessageV2 body (offsets relative to message start, body begins at byte 148):
    ///        body.version[148..152] burnToken[152..184] mintRecipient[184..216] amount[216..248]
    ///        (followed by messageSender/maxFee/feeExecuted/expirationBlock/hookData, not read here)
    ///      We verify: header.recipient == configured TokenMessenger, body.mintRecipient == this adapter,
    ///      body.amount == invoice amount, and domainToChainId[sourceDomain] == invoice.sourceChainId. The
    ///      body.burnToken is NOT compared here — it is the SOURCE-chain token, which differs from the
    ///      destination asset; `_completeBridge` instead asserts the destination asset's balance delta.
    ///      NOTE: V2 widened the header nonce from a uint64 (V1 bytes 12..20) to a bytes32 (bytes 12..44)
    ///      and shifted the recipient (bytes 76 vs V1 bytes 52) and the body (begins at byte 148 vs V1
    ///      byte 116). The configured V2 contracts (TokenMessengerV2/MessageTransmitterV2) emit this layout.
    function _verifyCctpMessage(bytes memory cctpMessage, InvoiceDataLib.InvoiceData memory data)
        internal
        view
        returns (uint32 sourceDomain, bytes32 nonce)
    {
        // Header (148B: through finalityThresholdExecuted) + body version(4) + burnToken(32)
        // + mintRecipient(32) + amount(32) = 248 bytes minimum.
        if (cctpMessage.length < 248) revert InvalidMessage();

        bytes32 headerRecipient;
        bytes32 bodyMintRecipient;
        uint256 bodyAmount;
        assembly ("memory-safe") {
            let base := add(cctpMessage, 32) // first data byte

            // sourceDomain: bytes 4-8 (uint32)
            sourceDomain := shr(224, mload(add(base, 4)))
            // nonce: bytes 12-44 (bytes32, Circle-assigned)
            nonce := mload(add(base, 12))
            // header recipient: bytes 76-108 (bytes32) — the destination TokenMessenger (the on-chain
            // handler MessageTransmitter dispatches to), NOT the mint recipient
            headerRecipient := mload(add(base, 76))
            // body mintRecipient: bytes 184-216 (bytes32)
            bodyMintRecipient := mload(add(base, 184))
            // body amount: bytes 216-248 (uint256)
            bodyAmount := mload(add(base, 216))
        }

        bytes32 selfAsBytes32 = bytes32(uint256(uint160(address(this))));

        // The minted USDC recipient is the CCTP V2 *body* mintRecipient (bytes 184-216) and must be
        // THIS adapter. The *header* recipient (bytes 76-108) is NOT the mint recipient: in a V2 token
        // burn message it is the destination TokenMessenger — the on-chain handler that
        // MessageTransmitter.receiveMessage dispatches to before it mints — so it must equal the
        // configured TokenMessenger, never the adapter. (Checking the header against the adapter, as a
        // prior version did, reverts every real Circle message because the header always carries the
        // TokenMessenger.)
        if (bodyMintRecipient != selfAsBytes32) {
            revert InvalidMintRecipient();
        }
        if (headerRecipient != bytes32(uint256(uint160(address(tokenMessenger()))))) {
            revert InvalidMessage();
        }

        // NOTE: we intentionally do NOT compare the message's burnToken to this chain's `asset`. The CCTP
        // BurnMessage carries the SOURCE-chain burned token (e.g. Base USDC), which legitimately differs
        // from the destination asset (e.g. Arbitrum USDC). The destination asset binding is enforced in
        // `_completeBridge` by asserting the asset's balance rose by `amount` across `receiveMessage`.

        // Minted amount must equal the invoice amount.
        if (bodyAmount != data.amount) {
            revert AmountMismatch();
        }

        // sourceDomain must map back to the invoice's source chain id.
        if (
            !domainConfigured[uint64(data.sourceChainId)] || domainToChainId[sourceDomain] != uint64(data.sourceChainId)
        ) {
            revert SourceDomainMismatch();
        }
    }

    /// @inheritdoc ICctpBridgeAdapter
    function getMessagePayload(bytes32 invoiceId) external view returns (bytes memory) {
        return messagePayloads[invoiceId];
    }

    /// @inheritdoc ICctpBridgeAdapter
    function getDomainForChain(uint64 chainId) external view returns (uint32) {
        return chainIdToDomain[chainId];
    }

    /// @inheritdoc ICctpBridgeAdapter
    function getChainForDomain(uint32 domain) external view returns (uint64) {
        return domainToChainId[domain];
    }
}
