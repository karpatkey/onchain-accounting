// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgeAdapter} from "../BridgeAdapter.sol";
import {IBridgeEscrow} from "../IBridgeEscrow.sol";
import {InvoiceDataLib} from "../InvoiceDataLib.sol";
import {IOmnibridge, IAMB, IUSDCTransmuter} from "./interfaces/IGnosisInterfaces.sol";
import {IGnosisBridgeAdapter} from "./interfaces/IGnosisBridgeAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title GnosisBridgeAdapter
/// @notice Bridge adapter for Gnosis Omnibridge (Ethereum <-> Gnosis Chain).
/// @dev The destination recipient is the sibling adapter (this contract, same address across chains via CREATE2).
///      The Omnibridge mediator delivers the bridged tokens to the adapter and then calls `onTokenBridged`
///      directly on it. The adapter authenticates the mediator (`msg.sender == omnibridge`) and the AMB-reported
///      source (`amb.messageSender()` == the trusted source Omnibridge mediator `trustedMediator[srcChainId]` — NOT
///      the sibling adapter, `amb.messageSourceChainId()` == the expected source chain), verifies that the
///      delivered token+amount match the invoice, then funds the escrow and
///      releases (funded pass-through, ADR 0012). There is no escrow fallback dispatcher.
/// @author KPK
contract GnosisBridgeAdapter is BridgeAdapter, IGnosisBridgeAdapter {
    using SafeERC20 for IERC20;

    //
    // State Variables
    //

    /// @notice Omnibridge contract address
    IOmnibridge public omnibridge;

    /// @notice AMB contract address (for message provenance verification)
    IAMB public amb;

    /// @notice The Gnosis USDCTransmuter, or address(0) if this adapter's chain has none (e.g. the Ethereum side).
    /// @dev When set (Gnosis side), the adapter converts 1:1 between the legacy OmniBridge USDC the general
    ///      OmniBridge delivers (`USDC_ON_XDAI`) and the USDC.e (`USDC_E`) the escrow registers: inbound legacy is
    ///      swapped to USDC.e before release (`deposit`), outbound USDC.e is swapped to legacy before bridging
    ///      (`withdraw`). address(0) disables the swap (the Ethereum side bridges native USDC directly). Only USDC
    ///      routes are affected; WETH and any other asset always bridge directly with no swap.
    IUSDCTransmuter public usdcTransmuter;

    /// @notice Mapping to store message payloads by invoice ID
    /// @dev Used to retrieve payloads on destination chain
    mapping(bytes32 => bytes) public messagePayloads;

    /// @notice Mapping from AMB transaction hash to invoice ID
    /// @dev Used to correlate AMB messages with invoice IDs
    mapping(bytes32 => bytes32) public transactionHashToInvoiceId;

    /// @notice Mapping from invoice ID to AMB transaction hash
    /// @dev Used to track which transaction hash was used for each invoice
    mapping(bytes32 => bytes32) public invoiceToTransactionHash;

    /// @notice Trusted source Omnibridge mediator per source chain id.
    /// @dev The value `amb.messageSender()` reports for an inbound Omnibridge transfer is the SOURCE
    ///      Omnibridge mediator (the contract that called `amb.requireToPassMessage` on the source), NOT the
    ///      sibling adapter. So source authentication compares against this mediator, not `trustedRemoteAdapter`.
    mapping(uint64 => address) public trustedMediator;

    /// @notice Inbound Omnibridge transfers authenticated at delivery, keyed by the **per-operation invoice hash**
    ///         (`bytes32(uint192(checksum24))`, matching the escrow) — NOT the reusable lane `invoiceId`.
    /// @dev The MANAGER fallback (`_completeBridge`) cannot re-read `amb.messageSender()` (it is only set while
    ///      the AMB is executing a message), so it completes only the exact transfer recorded here at genuine
    ///      delivery — keying by the invoice hash (not `invoiceId`, which is shared by every transfer on the same
    ///      route) prevents a same-lane sibling from being completed on another transfer's authentication. The
    ///      flag is set once and never cleared; a double-record is additionally prevented by the escrow's
    ///      `completedInvoices` replay guard in `recordDelivery` (a second completion reverts there).
    mapping(bytes32 => bool) public authenticatedInvoice;

    //
    // Initialization
    //

    /// @param expectedInitializer_ Address permitted to call initialize (address(0) allows anyone).
    constructor(address expectedInitializer_) BridgeAdapter(expectedInitializer_) {}

    /// @inheritdoc IGnosisBridgeAdapter
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address omnibridge_,
        address amb_,
        string memory version_
    ) external {
        // Initialize parent BridgeAdapter (single source of truth for admin, bridgeEscrow, provider name, version)
        super._initializeBridgeAdapter(admin_, bridgeEscrow_, "Gnosis", version_);

        if (omnibridge_ == address(0)) revert InvalidOmnibridge();
        if (amb_ == address(0)) revert InvalidAMB();

        omnibridge = IOmnibridge(omnibridge_);
        amb = IAMB(amb_);
    }

    //
    // Configuration
    //

    /// @inheritdoc IGnosisBridgeAdapter
    function setOmnibridge(address omnibridge_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (omnibridge_ == address(0)) revert InvalidOmnibridge();
        omnibridge = IOmnibridge(omnibridge_);
    }

    /// @inheritdoc IGnosisBridgeAdapter
    function setAmb(address amb_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amb_ == address(0)) revert InvalidAMB();
        amb = IAMB(amb_);
    }

    /// @inheritdoc IGnosisBridgeAdapter
    function setUsdcTransmuter(address usdcTransmuter_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // address(0) is intentionally allowed: it disables the USDC.e swap on chains with no transmuter
        // (the Ethereum-side adapter), where USDC bridges natively via the OmniBridge.
        usdcTransmuter = IUSDCTransmuter(usdcTransmuter_);
        emit UsdcTransmuterSet(usdcTransmuter_);
    }

    /// @inheritdoc IGnosisBridgeAdapter
    function setTrustedMediator(uint64 srcChainId, address mediator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (mediator == address(0)) revert InvalidBridgeData();
        trustedMediator[srcChainId] = mediator;
        emit TrustedMediatorSet(srcChainId, mediator);
    }

    //
    // BridgeAdapter Implementation
    //

    /// @inheritdoc BridgeAdapter
    /// @dev Receives decoded invoice data struct and converts it to Gnosis Omnibridge format
    function _bridge(InvoiceDataLib.InvoiceData memory data) internal override {
        // Encode messagePayload for Omnibridge message data
        bytes memory messagePayload = InvoiceDataLib.encode(data);

        // Get asset address from registry
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));

        // Validate destination chain is supported (Ethereum or Gnosis Chain).
        // Chain ID 1 = Ethereum, Chain ID 100 = Gnosis Chain.
        // Gnosis Omnibridge only supports bridging between these two chains.
        if (uint64(data.destinationChainId) != 1 && uint64(data.destinationChainId) != 100) {
            revert UnsupportedChain(uint64(data.destinationChainId));
        }

        // Check if asset is native token (address(0) or NATIVE_ADDRESS_ERC7528).
        if (_isNativeToken(asset)) {
            // Native tokens (ETH/xDAI) are not directly supported by Omnibridge;
            // they must be wrapped first (e.g., WETH/WXDAI) before bridging.
            revert NativeTokenNotSupported();
        }

        // Recipient is the sibling adapter on the destination chain (same address via CREATE2).
        // The destination Omnibridge mediator delivers tokens to it and calls onTokenTransfer; it
        // authenticates the AMB-reported source and funds the release.
        address receiver = address(this);

        // Pull ERC20 tokens from escrow (escrow approved us in depositAndBridge)
        IERC20(asset).safeTransferFrom(bridgeEscrow, address(this), data.amount);

        // The OmniBridge only bridges the legacy USDC representation (USDC_ON_XDAI). If this chain holds the
        // escrow-registered USDC.e (USDC_E), swap it 1:1 to legacy via the transmuter first, then bridge legacy.
        // No-op for WETH and for the Ethereum side (no transmuter → bridges its asset directly). A `withdraw`
        // revert (transmuter disabled / reserve short) reverts this whole deposit — funds stay in escrow (fail-safe).
        address bridgeToken = asset;
        IUSDCTransmuter tm = usdcTransmuter;
        if (address(tm) != address(0) && asset == tm.USDC_E()) {
            IERC20(asset).forceApprove(address(tm), data.amount);
            tm.withdraw(data.amount); // burns USDC.e, sends `data.amount` legacy USDC_ON_XDAI to this adapter (1:1)
            bridgeToken = tm.USDC_ON_XDAI();
        }

        // Approve Omnibridge to spend the (possibly swapped) bridge token
        IERC20(bridgeToken).forceApprove(address(omnibridge), data.amount);

        // Relay tokens to the sibling adapter, carrying the invoice payload as the call data.
        omnibridge.relayTokensAndCall(bridgeToken, receiver, data.amount, messagePayload);

        // Store messagePayload for later retrieval
        messagePayloads[data.invoiceId] = messagePayload;

        // Note: AMB transaction hash is not available immediately; it is recorded on the destination chain
        // when the message is received. We emit a zero hash here.
        emit GnosisBridgeInitiated(
            data.invoiceId, uint64(data.destinationChainId), receiver, bytes32(data.amount), bytes32(0)
        );
    }

    /// @inheritdoc BridgeAdapter
    /// @dev MANAGER fallback completion: the Omnibridge mediator normally calls `onTokenTransfer` directly
    ///      (auto path). This manager path is used only if that did not run. It re-authenticates the AMB-reported
    ///      source the same way, records the AMB transaction hash, and verifies the adapter holds the delivered
    ///      tokens; the base then funds the escrow and releases (funded pass-through).
    function _completeBridge(
        bytes calldata messagePayload,
        bytes calldata /* protocolData */
    )
        internal
        override
    {
        if (messagePayload.length == 0) revert InvalidCompletionData();
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

        // The AMB cannot be re-read out of message context, so authenticate against provenance recorded at
        // genuine delivery. Keyed by the per-operation invoice hash (`bytes32(uint192(checksum24))`, matching the
        // escrow) — NOT the reusable lane `invoiceId` — so the fallback completes only the exact transfer that was
        // authenticated at delivery, not any same-lane sibling.
        if (!authenticatedInvoice[bytes32(uint256(uint192(data.checksum24)))]) revert InvalidBridgeData();

        // Verify the adapter actually holds the invoiced tokens (delivered by Omnibridge). If the auto path
        // recorded the invoice but its USDC.e swap did not complete (transmuter disabled/reserve-short at delivery),
        // the adapter still holds the delivered legacy USDC — swap it to USDC.e now, then verify the balance.
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));
        _swapLegacyToUsdcE(asset, data.amount);
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance < data.amount) revert InsufficientBalance(asset, data.amount, balance);

        _recordTransactionHash(data.invoiceId);
        messagePayloads[data.invoiceId] = messagePayload;
        emit GnosisBridgeCompleted(data.invoiceId, uint64(data.sourceChainId), invoiceToTransactionHash[data.invoiceId]);
    }

    /// @inheritdoc IGnosisBridgeAdapter
    /// @dev Auto completion path — the callback the genuine OmniBridge multi-token mediator invokes on the
    ///      destination after `relayTokensAndCall` delivers `value` of `token` to this adapter (the mediator's
    ///      `IERC20Receiver.onTokenBridged`, NOT the ERC677 `onTokenTransfer`). Authenticates the mediator
    ///      (`msg.sender`), the AMB source + chain, verifies the delivered token+amount, then funds+releases.
    function onTokenBridged(address token, uint256 value, bytes calldata data) external nonReentrant {
        if (msg.sender != address(omnibridge)) revert NotAuthorized();
        if (data.length == 0) revert InvalidCompletionData();
        _handleInboundDelivery(token, value, data);
    }

    /// @inheritdoc IGnosisBridgeAdapter
    /// @dev ERC677 delivery callback, kept for any mediator/token that uses the `onTokenTransfer` convention
    ///      instead of `onTokenBridged`. Same authentication + shared handler; harmless if never invoked.
    ///      NOTE: this path carries no delivered-token address (passes the `address(0)` sentinel), so it does NOT
    ///      support the USDC.e transmuter-swap route — the genuine multi-token OmniBridge mediator delivers via
    ///      `onTokenBridged` (IERC20Receiver), which is the path that carries the legacy token for the swap.
    function onTokenTransfer(
        address,
        /* from */
        uint256 value,
        bytes calldata data
    )
        external
        nonReentrant
        returns (bool)
    {
        if (msg.sender != address(omnibridge)) revert NotAuthorized();
        if (data.length == 0) revert InvalidCompletionData();
        // ERC677 `onTokenTransfer` carries no delivered-token address, so pass the sentinel `address(0)` to skip
        // the delivered-token check (the shared handler still verifies the invoice asset balance + amount).
        _handleInboundDelivery(address(0), value, data);
        return true;
    }

    /// @dev Shared inbound-delivery handler for both mediator callbacks. Authenticates the AMB-reported source,
    ///      verifies the delivered token+amount against the invoice, records provenance, then attempts the funded
    ///      pass-through release WITHOUT reverting the mediator callback — the OmniBridge swallows a receiver
    ///      revert, which would strand the delivered tokens with no record; recording first lets the MANAGER
    ///      fallback (`completeBridge`) finish a recorded-but-unreleased invoice later.
    function _handleInboundDelivery(address deliveredToken, uint256 value, bytes calldata data) internal {
        InvoiceDataLib.InvoiceData memory invoiceData = InvoiceDataLib.decode(data);

        // Authenticate the AMB-reported source (trusted source mediator + source chain).
        _authenticateSource(uint64(invoiceData.sourceChainId));

        // Verify the delivered token + amount match the invoice. Omnibridge delivers the token to this adapter
        // before calling back; `value` is the delivered amount and the adapter must hold at least the invoiced amount.
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(invoiceData.assetSymbol));

        // USDC.e swap route: the general OmniBridge delivers the legacy USDC_ON_XDAI, but the escrow registers
        // USDC.e (USDC_E). When a transmuter is configured and the delivered token is exactly the legacy USDC for a
        // USDC.e invoice, accept it — `releaseAuthenticated` swaps it 1:1 to USDC.e before releasing. This is the
        // ONLY accepted token substitution; every other delivered-token mismatch still reverts.
        IUSDCTransmuter tm = usdcTransmuter;
        bool swap = address(tm) != address(0) && deliveredToken != address(0) && deliveredToken == tm.USDC_ON_XDAI()
            && asset == tm.USDC_E();

        // Guard against a mediator delivery of a DIFFERENT token slipping through on a stale `asset` balance: the
        // `onTokenBridged` path reports the delivered token and it must equal the invoice asset (or be the accepted
        // legacy->USDC.e swap route). `onTokenTransfer` passes `address(0)` (no token) and uses the balance check only.
        if (deliveredToken != address(0) && deliveredToken != asset && !swap) {
            revert InvalidDeliveredToken(asset, deliveredToken);
        }
        if (value < invoiceData.amount) revert InvalidBridgeData();
        // The adapter must already hold at least the invoiced amount of the token it received: the swap route holds
        // the delivered legacy USDC (converted to USDC.e at release); every other route holds the invoice asset.
        address heldToken = swap ? deliveredToken : asset;
        uint256 balance = IERC20(heldToken).balanceOf(address(this));
        if (balance < invoiceData.amount) revert InsufficientBalance(heldToken, invoiceData.amount, balance);

        _recordTransactionHash(invoiceData.invoiceId);
        messagePayloads[invoiceData.invoiceId] = data;

        // Record provenance keyed by the per-operation invoice hash (not the reusable lane `invoiceId`).
        authenticatedInvoice[bytes32(uint256(uint192(invoiceData.checksum24)))] = true;
        try this.releaseAuthenticated(data, asset, invoiceData.amount) {
            emit GnosisBridgeCompleted(
                invoiceData.invoiceId,
                uint64(invoiceData.sourceChainId),
                invoiceToTransactionHash[invoiceData.invoiceId]
            );
        } catch {
            emit GnosisBridgeAuthenticatedPendingRelease(invoiceData.invoiceId, uint64(invoiceData.sourceChainId));
        }
    }

    /// @dev Authenticates that the inbound AMB message originated from the trusted source Omnibridge mediator on
    ///      the expected source chain. Reverts unless a trusted mediator is configured for `srcChainId`,
    ///      `amb.messageSender()` equals that mediator, and `amb.messageSourceChainId()` equals `srcChainId`.
    ///      Only valid while the AMB is executing the inbound message (i.e. inside `onTokenTransfer`), since
    ///      `amb.messageSender()` is unset otherwise — the MANAGER fallback uses `authenticatedInvoice` instead.
    function _authenticateSource(uint64 srcChainId) internal view {
        address expectedMediator = trustedMediator[srcChainId];
        if (expectedMediator == address(0)) revert InvalidBridgeData();
        if (amb.messageSender() != expectedMediator) revert InvalidBridgeData();
        if (amb.messageSourceChainId() != bytes32(uint256(srcChainId))) revert InvalidBridgeData();
    }

    /// @notice Self-only external wrapper so `onTokenTransfer` can attempt the release in a try/catch without
    ///         reverting the whole inbound callback (which would discard the recorded provenance and strand the
    ///         tokens with no path to complete). Reverts unless called by this contract.
    function releaseAuthenticated(bytes calldata messagePayload, address asset, uint256 amount) external {
        if (msg.sender != address(this)) revert NotAuthorized();
        _swapLegacyToUsdcE(asset, amount);
        _fundAndRelease(messagePayload, asset, amount);
    }

    /// @dev Converts delivered legacy USDC (`USDC_ON_XDAI`) to the escrow-registered USDC.e (`USDC_E`) 1:1 via the
    ///      transmuter, covering any shortfall between the adapter's current USDC.e balance and `amount`. No-op
    ///      unless a transmuter is configured (Gnosis side) AND `asset` is USDC.e AND the adapter is short USDC.e
    ///      (i.e. it holds the authenticated legacy OmniBridge delivery instead). The OmniBridge credited legacy
    ///      1:1 with the invoice, so the adapter holds >= the shortfall in legacy; `deposit` mints the USDC.e here.
    ///      A revert (transmuter disabled/paused/blacklisted) propagates to the caller's try/catch, leaving the
    ///      legacy delivery + the recorded invoice intact for the MANAGER fallback or `recoverStuckAssets`.
    function _swapLegacyToUsdcE(address asset, uint256 amount) internal {
        IUSDCTransmuter tm = usdcTransmuter;
        if (address(tm) == address(0) || asset != tm.USDC_E()) return;
        uint256 have = IERC20(asset).balanceOf(address(this));
        if (have >= amount) return;
        uint256 shortfall = amount - have;
        address legacy = tm.USDC_ON_XDAI();
        IERC20(legacy).forceApprove(address(tm), shortfall);
        tm.deposit(shortfall);
    }

    /// @dev Records the AMB transaction hash for an invoice (best-effort; tolerates AMB getter reverts).
    function _recordTransactionHash(bytes32 invoiceId) internal {
        try amb.transactionHash() returns (bytes32 txHash) {
            transactionHashToInvoiceId[txHash] = invoiceId;
            invoiceToTransactionHash[invoiceId] = txHash;
        } catch {}
    }

    /// @inheritdoc IGnosisBridgeAdapter
    receive() external payable {
        // Native tokens are not bridged by this adapter (see _bridge: NativeTokenNotSupported). Kept payable so
        // the funded pass-through native branch in the base can never strand value on a misconfigured call.
    }

    //
    // View Functions
    //

    /// @inheritdoc IGnosisBridgeAdapter
    function getMessagePayload(bytes32 invoiceId) external view returns (bytes memory) {
        return messagePayloads[invoiceId];
    }

    /// @inheritdoc IGnosisBridgeAdapter
    function getInvoiceIdByTransactionHash(bytes32 transactionHash) external view returns (bytes32) {
        return transactionHashToInvoiceId[transactionHash];
    }

    /// @inheritdoc IGnosisBridgeAdapter
    function getTransactionHashByInvoiceId(bytes32 invoiceId) external view returns (bytes32) {
        return invoiceToTransactionHash[invoiceId];
    }

    /// @inheritdoc IGnosisBridgeAdapter
    /// @dev Checks if tokens are available in the adapter for a given invoice.
    ///      Omnibridge delivers tokens to the adapter; this reports whether the adapter currently holds
    ///      at least the invoiced amount for a payload it has seen.
    function areTokensAvailable(bytes32 invoiceId, address asset) external view returns (bool) {
        if (_isNativeToken(asset)) {
            return false;
        }

        // Get the expected amount from the stored messagePayload
        bytes memory payload = messagePayloads[invoiceId];
        if (payload.length == 0) {
            return false;
        }

        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(payload);
        uint256 adapterBalance = IERC20(asset).balanceOf(address(this));

        return adapterBalance >= data.amount;
    }

    /// @notice Checks if the contract supports an interface
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
