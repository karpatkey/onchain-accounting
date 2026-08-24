// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgeAdapter} from "../BridgeAdapter.sol";
import {IBridgeEscrow} from "../IBridgeEscrow.sol";
import {InvoiceDataLib} from "../InvoiceDataLib.sol";
import {
    IL1StandardBridge,
    IL2StandardBridge,
    IOptimismPortal,
    ICrossDomainMessenger
} from "./interfaces/ISuperchainInterfaces.sol";
import {Types} from "@optimism/libraries/Types.sol";
import {ISuperchainBridgeAdapter} from "./interfaces/ISuperchainBridgeAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title SuperchainBridgeAdapter
/// @notice Bridge adapter for Optimism Superchain canonical bridges (L1 <-> L2, both directions).
/// @dev The destination recipient is always the sibling adapter (`address(this)`, same address across chains
///      via CREATE2) for both L1->L2 deposits and L2->L1 withdrawals, so delivered ETH/tokens land on the
///      adapter and the destination custody record (hold-then-claim, ADR 0024) is funded from the adapter's own balance.
///
///      Provenance (ADR 0012, D1/D2): there is no escrow fallback dispatcher. Each inbound completion path
///      authenticates the genuine OP Stack contract and the source-chain sender:
///        - L1->L2 deposit: the L1 adapter initiates the canonical bridge deposit AND sends an authenticated
///          `completeDeposit` message via the destination L2's L1CrossDomainMessenger (`l1MessengerForL2`, per-L2 —
///          OP and Base differ) to its L2 sibling. On L2 the deposit's funds are ordered ahead of that message, so
///          `completeDeposit` sees the funds; it requires `msg.sender == l2Messenger` AND
///          `l2Messenger.xDomainMessageSender() == trustedRemoteAdapter[srcChainId]`.
///          (The MANAGER `completeBridge` path remains a backstop if the message is delayed/stuck.)
///        - L2->L1 withdrawal: proof-gated through the OptimismPortal. The adapter computes the REAL OP
///          withdrawal hash (`keccak256(abi.encode(nonce, sender, target, value, gasLimit, data))`,
///          matching `Hashing.hashWithdrawal`) and only completes once the portal reports the withdrawal proven.
///          A real `withdrawTo` withdrawal's portal `target` is the L1CrossDomainMessenger (which relays the
///          L1-bridge call that pays this adapter), NOT this adapter — so completion finalizes idempotently
///          (skipping a front-run finalize) and binds the amount by the adapter's measured balance delta.
/// @author KPK
contract SuperchainBridgeAdapter is BridgeAdapter, ISuperchainBridgeAdapter {
    using SafeERC20 for IERC20;

    //
    // State Variables
    //

    /// @notice L1 Standard Bridge per destination L2 chain id (L1 side only).
    /// @dev OP and Base have distinct L1 standard bridges, so one same-address L1 adapter keys the bridge by
    ///      the destination L2 chain id. Used on L1 → L2 deposits, selected by `data.destinationChainId`.
    mapping(uint256 => IL1StandardBridge) public l1BridgeForL2;

    /// @notice L2 Standard Bridge contract address
    IL2StandardBridge public l2Bridge;

    /// @notice L1 Cross-Domain Messenger contract address (legacy single value; kept for config compatibility).
    /// @dev OUTBOUND deposit completion messages use the per-destination-L2 messenger `l1MessengerForL2` instead —
    ///      OP and Base have DISTINCT L1CrossDomainMessengers, so one same-address L1 adapter must key the messenger
    ///      by the destination L2. This field is no longer read on the L1 execution path.
    address public l1Messenger;

    /// @notice L1 Cross-Domain Messenger per L2 chain id (L1 side only). Used in BOTH directions.
    /// @dev OP and Base have distinct L1CrossDomainMessengers. Deposit (L1 → L2): the adapter sends the authenticated
    ///      `completeDeposit` message through this messenger, selected by `data.destinationChainId`. Withdrawal
    ///      finalize (L2 → L1): the already-finalized (front-run) branch binds the withdrawal's `target` to this
    ///      messenger, selected by `data.sourceChainId`. So it MUST be wired for every L2 the adapter serves in
    ///      EITHER direction — not just deposit destinations — or a front-run withdrawal completion reverts
    ///      `MessengerNotConfigured`. Seeded post-init via `setL1MessengerForL2` (like `l1BridgeForL2`).
    mapping(uint256 => address) public l1MessengerForL2;

    /// @notice L2 Cross-Domain Messenger contract address
    address public l2Messenger;

    /// @notice Optimism Portal per source L2 chain id (L1 side only).
    /// @dev OP and Base have distinct L1 OptimismPortals; the L1 adapter keys the portal by the source L2
    ///      chain id. Used on L2 → L1 withdrawal prove/finalize, selected by `data.sourceChainId`.
    mapping(uint256 => IOptimismPortal) public optimismPortalForL2;

    /// @notice The chain ID where this adapter is deployed (`block.chainid` at init).
    uint256 public chainId;

    /// @notice The chain id that is "the L1 side" for this Superchain deployment (mainnet = 1).
    /// @dev The adapter plays the L1 role when `chainId == l1ChainId` and the L2 role otherwise. Set at init
    ///      (identically on both siblings, so the CREATE2 same-address guarantee is unaffected — it is an init
    ///      arg, not a constructor arg) so direction dispatch + L1-only guards work on any L1 host, not just mainnet.
    uint256 public l1ChainId;

    /// @notice Mapping to store message payloads by invoice ID
    /// @dev Used to retrieve payloads on destination chain
    mapping(bytes32 => bytes) public messagePayloads;

    /// @notice Mapping from withdrawal hash to invoice ID
    /// @dev Used to correlate withdrawal transactions with invoice IDs. The key is the REAL OP withdrawal
    ///      hash (see `_hashWithdrawal`), set on L1 when the manager proves the withdrawal.
    mapping(bytes32 => bytes32) public withdrawalHashToInvoiceId;

    /// @notice Mapping from invoice ID to withdrawal hash
    /// @dev Used to track which withdrawal hash was used for each invoice
    mapping(bytes32 => bytes32) public invoiceToWithdrawalHash;

    /// @notice Full `WithdrawalTransaction` stored at prove time, keyed by the PER-OPERATION invoice HASH (ADR 0025).
    /// @dev Lets the settlement keeper read back the exact struct needed to FINALIZE an already-proven L2->L1
    ///      withdrawal via `getWithdrawalTransaction`, instead of re-deriving it from the source L2 `MessagePassed`
    ///      log over a >7-day window. Keyed by the invoice HASH (the checksum, unique per operation), NOT the route
    ///      `invoiceId` (reused by every same-lane transfer): two same-lane withdrawals proven in the same window
    ///      would otherwise collide, the second overwriting the first's tx. MUST be `private` with an explicit struct
    ///      getter: a `public` auto-getter silently drops the struct's dynamic `data` member.
    mapping(bytes32 => Types.WithdrawalTransaction) private _withdrawalTxByInvoiceHash;

    /// @notice Marks a withdrawal hash whose funds have already settled an invoice on this adapter.
    /// @dev One-shot settlement guard: a single L2->L1 withdrawal delivers its funds once and must settle exactly one
    ///      invoice. The normal finalize branch is naturally one-shot (the portal reverts on a second
    ///      `finalizeWithdrawalTransaction`), but the already-finalized skip-branch keys off the messenger's
    ///      `successfulMessages` flag, which is set PERMANENTLY and never consumed — so without this guard the same
    ///      proven+finalized withdrawal filed under two invoice hashes could settle both from the adapter's balance.
    ///      Set on first settlement in `_finalizeWithdrawal`; a re-use reverts.
    mapping(bytes32 => bool) private _settledWithdrawals;

    /// @notice L1 token -> L2 token per destination L2 chain id (L1 side only).
    /// @dev Used for ERC20 deposits (L1 → L2). Unmapped (zero) falls back to the same address (standard
    ///      bridge tokens). Keyed per L2 because the same L1 token maps to different L2 token addresses.
    mapping(uint256 => mapping(address => address)) public l1ToL2TokenForL2;

    /// @notice Default L2 gas limit for deposits
    uint32 public defaultL2GasLimit = 200000;

    /// @notice Default L1 gas limit for withdrawals
    uint32 public defaultL1GasLimit = 200000;

    /// @notice Min-gas limit for the authenticated `completeDeposit` cross-domain message (L1 → L2).
    /// @dev Sized for the L2 relay to run `completeDeposit` → `escrow.recordDelivery` (heavier than a bare deposit),
    ///      so 200k (`defaultL2GasLimit`) would risk a failed relay. Set in `initialize` (an inline initializer does
    ///      not reach proxy storage); adjustable via `setCompleteDepositGasLimit`.
    uint32 public completeDepositGasLimit;

    /// @param expectedInitializer_ Address permitted to call initialize (address(0) allows anyone).
    constructor(address expectedInitializer_) BridgeAdapter(expectedInitializer_) {}

    /// @inheritdoc ISuperchainBridgeAdapter
    /// @dev The L1 per-L2 bridges/portals are seeded post-init via setL1BridgeForL2 / setOptimismPortalForL2
    ///      (one call per destination/source L2), since a single value cannot key a map by L2 chain id.
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address l2Bridge_,
        address l1Messenger_,
        address l2Messenger_,
        uint256 l1ChainId_,
        string memory version_
    ) external {
        // Initialize parent BridgeAdapter (single source of truth for admin, bridgeEscrow, provider name, version)
        super._initializeBridgeAdapter(admin_, bridgeEscrow_, "Superchain", version_);
        chainId = block.chainid;
        if (l1ChainId_ == 0) revert InvalidChainId();
        l1ChainId = l1ChainId_;
        // Set here (not as an inline initializer, which does not reach proxy storage).
        completeDepositGasLimit = 500000;

        // The adapter plays the L1 role when it is deployed on the configured L1 chain. On L1 the per-L2 bridges /
        // portals / messengers are seeded post-init via setters; the legacy single `l1Messenger` is stored for
        // config compatibility but the OUTBOUND deposit message uses `l1MessengerForL2` (per destination L2).
        if (chainId == l1ChainId_) {
            // Fail closed on a deploy-config role flip: L1 mode must NOT be given L2-only contracts. If an L2
            // deployment mis-sets `l1ChainId_ == block.chainid`, its L2-shaped args (l2Bridge/l2Messenger, always
            // supplied on an L2 deploy) trip this immediately at init instead of failing on the first bridge (RE5-L-01).
            if (l2Bridge_ != address(0) || l2Messenger_ != address(0)) revert InvalidChainId();
            l1Messenger = l1Messenger_;
        } else {
            // On L2, only initialize L2 contracts
            if (l2Bridge_ == address(0)) revert InvalidL2Bridge();
            if (l2Messenger_ == address(0)) revert InvalidCrossDomainMessenger();

            l2Bridge = IL2StandardBridge(l2Bridge_);
            l2Messenger = l2Messenger_;
        }
    }

    //
    // Configuration
    //

    /// @inheritdoc ISuperchainBridgeAdapter
    function setL1BridgeForL2(uint256 l2ChainId, address l1Bridge_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (chainId != l1ChainId) revert InvalidChainId();
        if (l1Bridge_ == address(0)) revert InvalidL1Bridge();
        l1BridgeForL2[l2ChainId] = IL1StandardBridge(l1Bridge_);
    }

    /// @inheritdoc ISuperchainBridgeAdapter
    function setL2Bridge(address l2Bridge_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (chainId == l1ChainId) revert InvalidChainId();
        if (l2Bridge_ == address(0)) revert InvalidL2Bridge();
        l2Bridge = IL2StandardBridge(l2Bridge_);
    }

    /// @inheritdoc ISuperchainBridgeAdapter
    function setL1Messenger(address l1Messenger_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (chainId != l1ChainId) revert InvalidChainId();
        if (l1Messenger_ == address(0)) revert InvalidCrossDomainMessenger();
        l1Messenger = l1Messenger_;
    }

    /// @inheritdoc ISuperchainBridgeAdapter
    function setL1MessengerForL2(uint256 l2ChainId, address l1Messenger_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (chainId != l1ChainId) revert InvalidChainId();
        if (l1Messenger_ == address(0)) revert InvalidCrossDomainMessenger();
        l1MessengerForL2[l2ChainId] = l1Messenger_;
    }

    /// @inheritdoc ISuperchainBridgeAdapter
    function setL2Messenger(address l2Messenger_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (chainId == l1ChainId) revert InvalidChainId();
        if (l2Messenger_ == address(0)) revert InvalidCrossDomainMessenger();
        l2Messenger = l2Messenger_;
    }

    /// @inheritdoc ISuperchainBridgeAdapter
    function setOptimismPortalForL2(uint256 l2ChainId, address optimismPortal_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (chainId != l1ChainId) revert InvalidChainId();
        if (optimismPortal_ == address(0)) revert InvalidOptimismPortal();
        optimismPortalForL2[l2ChainId] = IOptimismPortal(optimismPortal_);
    }

    /// @notice Sets the default L2 gas limit for deposits
    /// @param gasLimit The gas limit to use
    /// @dev Only callable by admin role
    function setDefaultL2GasLimit(uint32 gasLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        defaultL2GasLimit = gasLimit;
    }

    /// @notice Sets the default L1 gas limit for withdrawals
    /// @param gasLimit The gas limit to use
    /// @dev Only callable by admin role
    function setDefaultL1GasLimit(uint32 gasLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        defaultL1GasLimit = gasLimit;
    }

    /// @notice Sets the min-gas limit for the authenticated `completeDeposit` cross-domain message.
    /// @param gasLimit The gas limit to use (sized for the L2 `completeDeposit` → `recordDelivery` relay).
    /// @dev Only callable by admin role.
    function setCompleteDepositGasLimit(uint32 gasLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        completeDepositGasLimit = gasLimit;
    }

    /// @notice Sets the L2 token address for a given (destination L2 chain id, L1 token).
    /// @param l2ChainId The destination L2 chain id
    /// @param l1Token The L1 token address
    /// @param l2Token The corresponding L2 token address
    /// @dev Only callable by admin role. L1-only (the map is read only in the L1→L2 deposit path), so it enforces
    ///      `chainId == l1ChainId` like `setL1BridgeForL2`/`setOptimismPortalForL2`. An unmapped ERC20 fails closed
    ///      in `_depositToL2` (it must NOT default to the L1 address).
    function setL2TokenForL2(uint256 l2ChainId, address l1Token, address l2Token)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (chainId != l1ChainId) revert InvalidChainId();
        l1ToL2TokenForL2[l2ChainId][l1Token] = l2Token;
    }

    //
    // BridgeAdapter Implementation (outbound)
    //

    /// @inheritdoc BridgeAdapter
    /// @dev Handles both L1 → L2 deposits and L2 → L1 withdrawals
    function _bridge(InvoiceDataLib.InvoiceData memory data) internal override {
        // Encode messagePayload for Cross-Domain Messenger
        bytes memory messagePayload = InvoiceDataLib.encode(data);

        // Get asset address from registry
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));
        bool isEth = _isNativeToken(asset);

        // If we're on L1 (mainnet), it's an L1 → L2 deposit; otherwise an L2 → L1 withdrawal.
        if (chainId == l1ChainId) {
            if (address(l1BridgeForL2[data.destinationChainId]) == address(0)) revert InvalidL1Bridge();
            _depositToL2(data, asset, isEth, messagePayload);
        } else {
            if (address(l2Bridge) == address(0)) revert InvalidL2Bridge();
            _withdrawToL1(data, asset, isEth, messagePayload);
        }
    }

    /// @notice Handles L1 → L2 deposit
    /// @dev Recipient on L2 is the sibling adapter (`address(this)`, same address via CREATE2). The canonical
    ///      bridge delivers the ETH/tokens to the L2 sibling; the L1 adapter also sends an AUTHENTICATED
    ///      `completeDeposit` message through the L1CrossDomainMessenger so the L2 sibling records the delivery
    ///      with provenance (not merely a MANAGER-attested balance check). Deposit funds are ordered ahead of
    ///      the message on L2 (portal deposit nonce order), so `completeDeposit` sees the funds already present.
    function _depositToL2(
        InvoiceDataLib.InvoiceData memory data,
        address asset,
        bool isEth,
        bytes memory messagePayload
    ) internal {
        address receiver = address(this);

        // Select the L1 standard bridge for the destination L2 (OP vs Base have distinct bridges).
        IL1StandardBridge bridge = l1BridgeForL2[data.destinationChainId];

        if (isEth) {
            bridge.depositETHTo{value: data.amount}(receiver, defaultL2GasLimit, messagePayload);
        } else {
            // Resolve the L2 token BEFORE pulling funds. Fail closed: an unmapped ERC20 must NOT default to the
            // L1 address (wrong on L2 for tokens like WETH → the deposit would be unfinalizable / locked). Any ERC20
            // Superchain route must be wired via `setL2TokenForL2` first.
            address l2Token = l1ToL2TokenForL2[data.destinationChainId][asset];
            if (l2Token == address(0)) revert L2TokenNotConfigured(data.destinationChainId, asset);

            // Pull ERC20 tokens from escrow (escrow approved us in depositAndBridge), approve, and deposit to L2.
            IERC20(asset).safeTransferFrom(bridgeEscrow, address(this), data.amount);
            IERC20(asset).forceApprove(address(bridge), data.amount);
            bridge.depositERC20To(asset, l2Token, receiver, data.amount, defaultL2GasLimit, messagePayload);
            // Reset the allowance (the standard bridge pulls exactly `amount`; leave no dangling approval).
            IERC20(asset).forceApprove(address(bridge), 0);
        }

        // Deliver an authenticated completion to the L2 sibling via the destination L2's L1CrossDomainMessenger.
        // OP and Base have DISTINCT L1 messengers, so it MUST be keyed per destination L2 (a single messenger would
        // route Base deposits through OP's messenger). The canonical bridge deposit above is ordered ahead of this
        // message on L2, so when the sibling's `completeDeposit` runs the funds have landed. Without this message the
        // L2-side authenticated path is unreachable (the standard bridge relays to the L2 bridge with empty calldata,
        // never the adapter), leaving only the un-provenanced MANAGER `completeBridge` backstop.
        address messenger = l1MessengerForL2[data.destinationChainId];
        if (messenger == address(0)) revert MessengerNotConfigured(data.destinationChainId);
        ICrossDomainMessenger(messenger)
            .sendMessage(
                address(this),
                abi.encodeWithSelector(this.completeDeposit.selector, messagePayload),
                completeDepositGasLimit
            );

        // Store messagePayload for later retrieval, keyed by the per-operation invoice hash (concurrent same-lane
        // transfers reuse the route invoiceId, so keying by it would overwrite a sibling operation's payload).
        messagePayloads[bytes32(uint256(uint192(data.checksum24)))] = messagePayload;

        emit SuperchainBridgeInitiated(data.invoiceId, uint64(data.destinationChainId), bytes32(data.amount), isEth);
    }

    /// @notice Handles L2 → L1 withdrawal
    /// @dev Recipient on L1 is the sibling adapter (`address(this)`). The real OP withdrawal hash is only
    ///      known on L1 (it depends on the L2ToL1MessagePasser nonce), so invoice↔withdrawalHash correlation
    ///      is established on L1 at prove time (see `proveWithdrawal`) from the actual WithdrawalTransaction.
    function _withdrawToL1(
        InvoiceDataLib.InvoiceData memory data,
        address asset,
        bool isEth,
        bytes memory messagePayload
    ) internal {
        address receiver = address(this);

        if (isEth) {
            // For ETH, _l2Token is the legacy ERC20 ETH predeploy.
            address legacyErc20Eth = 0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000;
            l2Bridge.withdrawTo{value: data.amount}(
                legacyErc20Eth, receiver, data.amount, defaultL1GasLimit, messagePayload
            );
        } else {
            // Pull ERC20 tokens from escrow (escrow approved us in depositAndBridge)
            IERC20(asset).safeTransferFrom(bridgeEscrow, address(this), data.amount);

            IERC20(asset).forceApprove(address(l2Bridge), data.amount);
            l2Bridge.withdrawTo(asset, receiver, data.amount, defaultL1GasLimit, messagePayload);
            // Reset the allowance (leave no dangling approval to the L2 bridge).
            IERC20(asset).forceApprove(address(l2Bridge), 0);
        }

        // Store messagePayload for later retrieval (withdrawal hash is set on L1 at prove time), keyed by the
        // per-operation invoice hash so concurrent same-lane withdrawals don't overwrite each other's payload.
        messagePayloads[bytes32(uint256(uint192(data.checksum24)))] = messagePayload;

        emit SuperchainWithdrawalInitiated(
            data.invoiceId, uint64(data.destinationChainId), bytes32(data.amount), bytes32(0)
        );
    }

    //
    // Provenance helpers
    //

    /// @notice Computes the canonical OP Stack withdrawal hash for a withdrawal transaction.
    /// @dev Matches `Hashing.hashWithdrawal`: `keccak256(abi.encode(nonce, sender, target, value, gasLimit, data))`.
    function _hashWithdrawal(Types.WithdrawalTransaction memory wtx) internal pure returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encode(wtx.nonce, wtx.sender, wtx.target, wtx.value, wtx.gasLimit, wtx.data));
    }

    /// @notice Authenticates an inbound cross-domain message relayed by the L2CrossDomainMessenger.
    /// @dev Provenance check for L1 → L2 deposit completion: the genuine messenger must be the caller and the
    ///      original source-chain sender (revealed by `xDomainMessageSender()`) must be the trusted sibling
    ///      adapter configured for `srcChainId`.
    /// @param srcChainId The source chain id carried in the invoice (the L1 chain for a deposit).
    function _authenticateMessengerSource(uint64 srcChainId) internal view {
        if (msg.sender != l2Messenger) revert NotAuthorized();
        bytes32 expected = trustedRemoteAdapter[srcChainId];
        if (expected == bytes32(0)) revert NotAuthorized();
        address xSender = ICrossDomainMessenger(l2Messenger).xDomainMessageSender();
        if (_toBytes32(xSender) != expected) revert NotAuthorized();
    }

    //
    // BridgeAdapter Implementation (inbound completion)
    //

    /// @inheritdoc BridgeAdapter
    /// @dev MANAGER-operated completion. Performs only protocol verification here; the base
    ///      (`completeBridge`) then funds the escrow, which records the delivery into custody (hold-then-claim, ADR 0024).
    ///      - On L1 (an L2 → L1 withdrawal completion): finalize the proven withdrawal through the portal,
    ///        which delivers the ETH to this adapter; the base then releases.
    ///      - On L2 (an L1 → L2 deposit completion fallback): the canonical bridge already delivered the
    ///        tokens to this adapter; nothing to do here beyond bookkeeping. (The trust-minimized auto path
    ///        is `completeDeposit`, authenticated against the L2CrossDomainMessenger.)
    function _completeBridge(
        bytes calldata messagePayload,
        bytes calldata /* protocolData */
    )
        internal
        override
    {
        if (messagePayload.length == 0) revert InvalidCompletionData();

        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

        if (chainId == l1ChainId) {
            // L2 → L1 withdrawal: finalize via the portal (proof-gated). Bind the withdrawal to THIS invoice by
            // reading the tx stored at prove time under the per-operation invoice hash (ADR 0025), rather than
            // trusting the operator-supplied protocolData — the route invoiceId is reused per lane and cannot
            // distinguish concurrent same-lane withdrawals, so an unbound protocolData could settle invoice B with
            // invoice A's withdrawal. `protocolData` is now ignored (kept for ABI parity).
            bytes32 invoiceHash = bytes32(uint256(uint192(data.checksum24)));
            Types.WithdrawalTransaction memory withdrawalTx = _withdrawalTxByInvoiceHash[invoiceHash];
            // A real stored tx targets the L1CrossDomainMessenger (nonzero); a zero target means nothing was proven
            // for this exact invoice.
            if (withdrawalTx.target == address(0)) revert WithdrawalNotProven();
            address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));
            // Finalize through the portal for the SOURCE L2 (the same L2 whose portal proved it).
            _finalizeWithdrawal(withdrawalTx, data.amount, asset, uint256(data.sourceChainId));
            // Clear the per-operation prove-time state now that the withdrawal is finalized (storage hygiene; the
            // escrow's replay guard already prevents re-completion). The route-keyed correlation map is left as-is
            // (reused per lane, overwritten on the next prove).
            delete withdrawalHashToInvoiceId[_hashWithdrawal(withdrawalTx)];
            delete _withdrawalTxByInvoiceHash[invoiceHash];
            delete messagePayloads[invoiceHash];
        } else {
            // On L2 the tokens were delivered to this adapter by the canonical bridge; the base verifies the adapter
            // balance covers `amount` in `_fundAndRelease`. Record the payload (keyed per-op) for bookkeeping.
            messagePayloads[bytes32(uint256(uint192(data.checksum24)))] = messagePayload;
        }

        emit SuperchainBridgeCompleted(data.invoiceId, uint64(data.sourceChainId));
    }

    /// @notice Trust-minimized L1 → L2 deposit completion: the L2CrossDomainMessenger relays the deposit
    ///         message to this adapter, which authenticates the messenger + source sender, then funds the
    ///         escrow, which records the delivery into custody (hold-then-claim, ADR 0024).
    /// @param messagePayload The encoded invoice payload authored on L1 (forwarded through the messenger).
    /// @dev Authenticated path (no MANAGER role): `msg.sender == l2Messenger` and
    ///      `l2Messenger.xDomainMessageSender() == trustedRemoteAdapter[srcChainId]`. The canonical bridge
    ///      credits the adapter with the bridged ETH/tokens before the messenger relays this call.
    function completeDeposit(bytes calldata messagePayload) external nonReentrant {
        if (messagePayload.length == 0) revert InvalidCompletionData();

        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

        // Provenance: genuine L2 messenger + trusted sibling adapter as the L1 source sender.
        _authenticateMessengerSource(uint64(data.sourceChainId));

        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));

        // Keyed by the per-operation invoice hash (concurrent same-lane deposits reuse the route invoiceId).
        messagePayloads[bytes32(uint256(uint192(data.checksum24)))] = messagePayload;

        // Funds-and-releases: the escrow validates checksum/replay/account and forwards to the account.
        _fundAndRelease(messagePayload, asset, data.amount);

        emit SuperchainBridgeCompleted(data.invoiceId, uint64(data.sourceChainId));
    }

    /// @notice Finalizes a proven withdrawal (L2 → L1) through the portal so the funds are delivered to this adapter.
    /// @param withdrawalTx The withdrawal transaction, read from storage bound to the invoice (see `_completeBridge`).
    /// @param amount The invoiced amount.
    /// @param asset The delivered asset (native sentinel or ERC20); selects the balance to measure.
    /// @param l2ChainId The source L2 chain id selecting the OptimismPortal.
    /// @dev A withdrawal initiated via `L2StandardBridge.withdrawTo` does NOT produce a portal transaction whose
    ///      `target` is this adapter: the L2 messenger sends it to the L1CrossDomainMessenger (the portal `target`),
    ///      which relays `finalizeBridge{ETH,ERC20}` to the L1 StandardBridge, and only that nested call pays this
    ///      adapter (the `withdrawTo` receiver). Two consequences handled here:
    ///        1. Idempotency (H-01): the portal's finalize is PERMISSIONLESS and reverts on a second call, so a
    ///           third party can front-run it. If already finalized, skip the re-finalize instead of reverting the
    ///           whole completion — but confirm the withdrawal's relay was delivered (see 3; recipient axis is a
    ///           documented MANAGER-gated residual, not bound on-chain).
    ///        2. Amount binding (M-02): the amount is bound not by the portal `target`/`value` but by what the
    ///           adapter actually receives across the finalize — measure the asset-balance delta and require it to
    ///           cover `amount` (for BOTH native and ERC20).
    ///        3. Front-run delivery check (RE4-M-01): the portal marks a withdrawal finalized even if its inner
    ///           relay FAILED (funds undelivered). For an already-finalized withdrawal (no measurable delta), require
    ///           the L1CrossDomainMessenger to report the withdrawal's inner message delivered (a FAILED relay is
    ///           rejected). NOTE this proves the relay reached its ENCODED recipient, not that the recipient is this
    ///           adapter — the inner `to` is not decoded here; a MANAGER mis-pairing to a genuine third-party-paying
    ///           withdrawal remains a documented residual (see the skip-branch body + ADR 0026), MANAGER-gated, no theft.
    ///      Provenance comes from the proven withdrawal hash (keyed by this adapter as proof submitter, fault-proof
    ///      OP2) + portal Merkle proof; the portal enforces the proof-maturity + dispute-game-finality air-gap.
    function _finalizeWithdrawal(
        Types.WithdrawalTransaction memory withdrawalTx,
        uint256 amount,
        address asset,
        uint256 l2ChainId
    ) internal {
        // Select the OptimismPortal for the source L2 (the same L2 whose portal the withdrawal was proven on).
        IOptimismPortal portal = optimismPortalForL2[l2ChainId];
        if (address(portal) == address(0)) revert InvalidOptimismPortal();

        bytes32 withdrawalHash = _hashWithdrawal(withdrawalTx);

        // Verify the withdrawal has been proven (fault-proof OP2: keyed by hash AND proof submitter — this adapter,
        // which called `proveWithdrawalTransaction`; proven ⟺ a non-zero dispute game is recorded).
        (address disputeGameProxy,) = portal.provenWithdrawals(withdrawalHash, address(this));
        if (disputeGameProxy == address(0)) revert WithdrawalNotProven();

        // One-shot settlement: a withdrawal delivers its funds once, so it settles exactly one invoice. This makes
        // the already-finalized skip-branch (which keys off the messenger's PERMANENT `successfulMessages` flag) as
        // reuse-proof as the normal branch (where the portal reverts on a second finalize) — the same proven+finalized
        // withdrawal filed under two invoice hashes cannot settle both from the adapter's balance. Set before any
        // external call; a revert below rolls it back.
        if (_settledWithdrawals[withdrawalHash]) revert InvalidWithdrawalFinalization();
        _settledWithdrawals[withdrawalHash] = true;

        // Finalize idempotently: skip if a front-run already finalized it (the portal's finalize is permissionless
        // and reverts on a second call).
        if (!portal.finalizedWithdrawals(withdrawalHash)) {
            bool isEth = _isNativeToken(asset);
            uint256 balanceBefore = isEth ? address(this).balance : IERC20(asset).balanceOf(address(this));
            portal.finalizeWithdrawalTransaction(withdrawalTx);
            uint256 balanceAfter = isEth ? address(this).balance : IERC20(asset).balanceOf(address(this));
            // Bind the amount to THIS finalize: the delivered delta must cover `amount` (not merely the adapter's
            // total balance, which stray/donated funds could satisfy).
            if (balanceAfter < balanceBefore + amount) revert InvalidWithdrawalFinalization();
        } else {
            // Already finalized (front-run): the delivered delta cannot be measured for a past finalize, and the
            // portal marks a withdrawal finalized even when its inner relay FAILED (funds not delivered) — so a bare
            // absolute-balance check could settle THIS invoice from stray/sibling funds. Confirm the withdrawal's
            // relay message was successfully delivered: the L1CrossDomainMessenger (the withdrawal `target`) records a
            // message as successful only if its nested `finalizeBridge{ETH,ERC20}` call did not revert. For a Bedrock v1
            // message the versioned hash equals keccak256 of the relayMessage calldata, which is exactly
            // `withdrawalTx.data` (what the portal delivered to the messenger). Bind the `target` to THIS L2's
            // configured L1CrossDomainMessenger first, so `successfulMessages` is read from the genuine messenger and
            // not an attacker-authored withdrawal whose `target` is a contract returning a spoofed `true`.
            // ⚠ RESIDUAL (MANAGER-gated, no theft): `successfulMessages` proves the relay succeeded to the recipient
            // ENCODED IN `withdrawalTx.data`, NOT that that recipient is THIS adapter — the inner `to` is not decoded
            // here (a version-brittle relayMessage→finalizeBridge decode). Combined with the base's ABSOLUTE-balance
            // settle, a MANAGER mis-pairing invoice B to a genuine third-party-paying withdrawal, while the adapter
            // holds another invoice's funds, could settle B from those funds (cross-invoice MISALLOCATION, not
            // exfiltration). Same class as the ERC20 amount residual — validated at the real L2->L1 e2e before deploy
            // (ADR 0026). The normal (non-front-run) branch has no such gap (its measured balance delta binds delivery).
            // The source L2's L1CrossDomainMessenger must be wired (l1MessengerForL2 is used for BOTH deposit dest-L2
            // routing AND this withdrawal-finalize target binding). A distinct error makes a partial config (portal
            // wired via setOptimismPortalForL2 but messenger not) obvious rather than a generic finalize revert.
            if (l1MessengerForL2[l2ChainId] == address(0)) revert MessengerNotConfigured(l2ChainId);
            if (withdrawalTx.target != l1MessengerForL2[l2ChainId]) revert InvalidWithdrawalFinalization();
            // Bind the delivered amount the normal branch's delta would have enforced. For a StandardBridge ETH
            // withdrawal the portal delivers `withdrawalTx.value` to the adapter, so a mis-paired smaller withdrawal
            // (value < amount) settling this invoice from stray/sibling funds is rejected here. (ERC20 carries the
            // amount inside the relay calldata with value==0, so this native-only check can't bind it — Superchain is
            // ETH-primary + ERC20 deposits are fail-closed; the ERC20 amount/recipient binding is validated at the
            // real L2->L1 e2e before the lane deploys.)
            if (_isNativeToken(asset) && withdrawalTx.value < amount) revert InvalidWithdrawalFinalization();
            // forge-lint: disable-next-line(asm-keccak256)
            bytes32 innerMessageHash = keccak256(withdrawalTx.data);
            if (!ICrossDomainMessenger(withdrawalTx.target).successfulMessages(innerMessageHash)) {
                revert InvalidWithdrawalFinalization();
            }
        }
    }

    /// @notice Proves a withdrawal transaction and correlates it to its invoice.
    /// @param l2ChainId The source L2 chain id selecting the OptimismPortal. MUST equal the invoice's
    ///        `sourceChainId` — completion (`_finalizeWithdrawal`) selects the portal from the invoice's
    ///        `sourceChainId`, so proving against a different L2's portal here would make finalize revert
    ///        `WithdrawalNotProven` (no fund loss, but the withdrawal cannot be completed until re-proven).
    ///        Enforced on-chain against the payload's encoded source chain id (reverts `WithdrawalChainIdMismatch`).
    /// @param withdrawalTx The withdrawal transaction to prove (its `target` is the L1CrossDomainMessenger, which
    ///        relays the L1-bridge call that pays this adapter as the `withdrawTo` receiver — see `_finalizeWithdrawal`).
    /// @param disputeGameIndex The dispute-game index the withdrawal is proven against (fault-proof OP2; was the L2
    ///        output index on the legacy portal)
    /// @param outputRootProof The output root proof
    /// @param withdrawalProof The withdrawal proof
    /// @param messagePayload The encoded invoice payload (the same bytes used at deposit/completion). BOTH keys — the
    ///        route `invoiceId` and the per-operation `invoiceHash` (ADR 0025) — are DERIVED from it on-chain, exactly
    ///        as `_completeBridge` derives them, so an operator can never supply a mismatched/typo'd key that overwrites
    ///        another operation's stored tx or files the tx under a key completion never looks up.
    /// @dev MANAGER-driven on L1 after the withdrawal is initiated on L2. Computes the REAL OP withdrawal
    ///      hash and records the invoice correlation so completion can be tracked.
    function proveWithdrawal(
        uint256 l2ChainId,
        Types.WithdrawalTransaction memory withdrawalTx,
        uint256 disputeGameIndex,
        Types.OutputRootProof memory outputRootProof,
        bytes[] calldata withdrawalProof,
        bytes calldata messagePayload
    ) external onlyRole(MANAGER_ROLE) {
        // Derive BOTH invoice keys on-chain from the invoice payload — EXACTLY as `_completeBridge` does — so the
        // operator cannot supply a mismatched/typo'd `invoiceHash` that overwrites another op's stored tx (or files
        // the tx under a key completion never looks up). This removes the operator-supplied-key mis-correlation class.
        if (messagePayload.length == 0) revert InvalidWithdrawalProof();
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);
        // Mirror the escrow's `recordDelivery` payload validation at prove time (amount + checksum), because the
        // `WithdrawalTransaction` is STORED here with no later validation of the key's genuineness — completion trusts
        // the stored tx. Two guards, in the escrow's order:
        //   1. amount != 0 — a zero-amount payload can never complete (recordDelivery rejects it), so storing a tx
        //      under its key is pure un-completable dust; reject it at the source.
        //   2. checksum bound to the payload's OWN (invoiceId, amount, timestamp, nonce) — without this, an
        //      internally-inconsistent payload whose checksum (hence `invoiceHash` key) is borrowed from another live
        //      operation but whose `invoiceId` differs would derive that operation's key and overwrite its stored tx
        //      (and cross-wire the correlation maps). Anchoring the key to a self-consistent checksum makes the two
        //      keys jointly non-forgeable, not merely non-typo'able.
        if (data.amount == 0) revert InvalidWithdrawalProof();
        if (
            data.checksum24 != InvoiceDataLib.calculateChecksum(data.invoiceId, data.amount, data.timestamp, data.nonce)
        ) {
            revert InvalidWithdrawalProof();
        }
        bytes32 invoiceId = data.invoiceId;
        bytes32 invoiceHash = bytes32(uint256(uint192(data.checksum24)));
        if (invoiceId == bytes32(0) || invoiceHash == bytes32(0)) revert InvalidWithdrawalProof();

        // Enforce the payload's encoded source chain id matches l2ChainId (top 3 bytes of
        // the invoice id — see BridgeEscrow._generateInvoiceId). Finalize selects the portal from the invoice's
        // sourceChainId, so proving against a different L2's portal would strand the withdrawal (WithdrawalNotProven
        // until re-proven). Fail fast on the operator mistake instead of proving on the wrong portal.
        uint256 encodedSrc = uint256(invoiceId) >> 232;
        if (encodedSrc != l2ChainId) revert WithdrawalChainIdMismatch(l2ChainId, encodedSrc);

        // Prove against the portal for the source L2; finalize must later use the SAME l2ChainId
        // (the invoice's sourceChainId flows through both, so they match).
        IOptimismPortal portal = optimismPortalForL2[l2ChainId];
        if (address(portal) == address(0)) revert InvalidOptimismPortal();

        bytes32 withdrawalHash = _hashWithdrawal(withdrawalTx);

        portal.proveWithdrawalTransaction(withdrawalTx, disputeGameIndex, outputRootProof, withdrawalProof);

        // Correlate invoice ↔ real withdrawal hash (both keys are guaranteed non-zero by the guard above).
        withdrawalHashToInvoiceId[withdrawalHash] = invoiceId;
        invoiceToWithdrawalHash[invoiceId] = withdrawalHash;
        emit SuperchainWithdrawalProven(invoiceId, withdrawalHash);

        // Store the tx under the PER-OPERATION invoice hash (ADR 0025) so the keeper can finalize without an L2 log
        // re-read. The hash is derived on-chain above (from the payload), so it is exactly the key completion looks up
        // — no operator mismatch and no cross-operation overwrite is possible.
        _withdrawalTxByInvoiceHash[invoiceHash] = withdrawalTx;
    }

    //
    // View Functions
    //

    /// @inheritdoc ISuperchainBridgeAdapter
    function getMessagePayload(bytes32 invoiceHash) external view returns (bytes memory) {
        return messagePayloads[invoiceHash];
    }

    /// @inheritdoc ISuperchainBridgeAdapter
    function getWithdrawalTransaction(bytes32 invoiceHash) external view returns (Types.WithdrawalTransaction memory) {
        return _withdrawalTxByInvoiceHash[invoiceHash];
    }

    /// @inheritdoc ISuperchainBridgeAdapter
    function getWithdrawalHashByInvoiceId(bytes32 invoiceId) external view returns (bytes32) {
        return invoiceToWithdrawalHash[invoiceId];
    }

    /// @inheritdoc ISuperchainBridgeAdapter
    function getInvoiceIdByWithdrawalHash(bytes32 withdrawalHash) external view returns (bytes32) {
        return withdrawalHashToInvoiceId[withdrawalHash];
    }

    /// @inheritdoc ISuperchainBridgeAdapter
    function isWithdrawalProven(uint256 l2ChainId, bytes32 withdrawalHash) external view returns (bool) {
        IOptimismPortal portal = optimismPortalForL2[l2ChainId];
        if (address(portal) == address(0)) return false;
        // Fault-proof OP2: proven ⟺ a non-zero dispute game is recorded for (hash, this adapter as proof submitter).
        (address disputeGameProxy,) = portal.provenWithdrawals(withdrawalHash, address(this));
        return disputeGameProxy != address(0);
    }

    /// @inheritdoc ISuperchainBridgeAdapter
    function canFinalizeWithdrawal(uint256 l2ChainId, bytes32 withdrawalHash) external view returns (bool) {
        // The portal enforces the actual proof-maturity + dispute-game air-gap at finalize; this reports proven-ness.
        IOptimismPortal portal = optimismPortalForL2[l2ChainId];
        if (address(portal) == address(0)) return false;
        (address disputeGameProxy,) = portal.provenWithdrawals(withdrawalHash, address(this));
        return disputeGameProxy != address(0);
    }

    /// @notice Computes the canonical OP Stack withdrawal hash for a withdrawal transaction.
    /// @param withdrawalTx The withdrawal transaction
    /// @return The real OP withdrawal hash (matches `Hashing.hashWithdrawal`)
    function hashWithdrawal(Types.WithdrawalTransaction memory withdrawalTx) external pure returns (bytes32) {
        return _hashWithdrawal(withdrawalTx);
    }

    //
    // Receive Function
    //

    /// @notice Receives native ETH (canonical bridge deposits / portal withdrawal finalization deliver here).
    receive() external payable {}
}
