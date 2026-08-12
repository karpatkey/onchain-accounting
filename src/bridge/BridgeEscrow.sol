// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBridgeEscrow} from "./IBridgeEscrow.sol";
import {IBridgeAdapter} from "./IBridgeAdapter.sol";
import {InvoiceDataLib} from "./InvoiceDataLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title BridgeEscrow
/// @notice Tracks assets in transit across chains and maintains the invoice ledger.
/// @dev See ADR 0012 and ADR 0024. There is no `fallback()` dispatcher — protocol callbacks are received and
///      authenticated by the adapters directly, and `recordDelivery` is callable only by an authorized adapter
///      (never a public fallback, never MANAGER directly), which closes the *unauthenticated* forged-payload
///      drain (C1's permissionless vector). Under the hold-then-claim model, `recordDelivery` writes a
///      per-invoice custody record funded by the authenticating adapter in the same call (the escrow pulls
///      exactly `amount` from it, or requires `msg.value == amount` for native) and HOLDS the funds; the
///      MANAGER-gated `claim` later pays exactly the recorded amount to the recorded account. So one invoice
///      can never be funded by another's tokens and a claim cannot drain pre-existing funds (H2/H9).
/// @author KPK
contract BridgeEscrow is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable,
    IBridgeEscrow
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    //
    // Constants
    //

    /// @notice Role for managers who can cancel invoices and manage assets
    bytes32 public constant MANAGER_ROLE = MANAGER;

    /// @notice ERC-7528 convention for ETH address representation (used in some L2s)
    address public constant NATIVE_ADDRESS_ERC7528 = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    /// @notice Tolerance absorbing cross-chain clock skew when validating a source-stamped invoice
    ///         timestamp against the destination block time. A genuine deposit's source timestamp can
    ///         read slightly ahead of the destination clock on fast lanes; integrity/replay are enforced
    ///         by the checksum + completedInvoices, so this bound is only a sanity check.
    uint64 public constant TIMESTAMP_SKEW_TOLERANCE = 1 hours;

    //
    // State Variables
    //

    /// @notice Invoice storage keyed by hashed invoice (checksum)
    mapping(bytes32 => Invoice) public invoices;

    /// @notice Active invoices per account
    /// @dev Invariant: only contains invoice hashes with status BRIDGING
    mapping(address => bytes32[]) private _activeInvoices;
    mapping(address => mapping(bytes32 => bool)) private _activeInvoicesSet;

    /// @notice Authorized accounts
    EnumerableSet.AddressSet private _authorizedAccounts;

    /// @notice Authorized bridge adapters
    EnumerableSet.AddressSet private _authorizedAdapters;

    /// @notice Current chain ID
    uint64 public chainId;

    /// @notice Per-account monotonic bridge nonce (next nonce to assign)
    mapping(address => uint256) private _bridgeNonce;

    /// @notice Tracks completed invoices by hashed invoice (replay guard on destination)
    mapping(bytes32 => bool) public completedInvoices;

    /// @notice Maps asset symbol (bytes6, internal) to asset address on this chain
    /// @dev address(0) is valid for native tokens (ETH) - must be explicitly registered
    mapping(bytes6 => address) private _assetRegistry;

    /// @notice List of registered asset symbols (for enumeration and registeredAssets())
    bytes6[] private _registeredSymbols;
    /// @notice 1-based index in _registeredSymbols for O(1) lookup/removal (0 = not registered)
    mapping(bytes6 => uint256) private _registeredSymbolsIndex;

    /// @notice Cached in-transit balances per account and asset
    /// @dev Invariant: equals the sum of amounts from all BRIDGING invoices for that account and asset
    mapping(address => mapping(address => uint256)) private _inTransitBalances;

    /// @notice Cached in-transit balances across all accounts per asset
    /// @dev Invariant: equals the sum of _inTransitBalances[account][asset] across all accounts
    mapping(address => uint256) private _inTransitBalancesAllAccounts;

    /// @notice Destination-side custody records (ADR 0024), keyed by invoiceHash. Written by `recordDelivery`,
    ///         drained by `claim`. The delivered funds are HELD here until claimed.
    mapping(bytes32 => DestinationCustody) public destinationCustody;

    /// @notice Held-but-unclaimed custody per asset (aggregate)
    /// @dev Invariant I1: `balanceOf(asset) >= _heldClaimable[asset]`, and equals the sum of unclaimed
    ///      `destinationCustody` amounts for that asset (== Σ _heldByAccount[*][asset]).
    mapping(address => uint256) private _heldClaimable;

    /// @notice Held-but-unclaimed custody per account and asset (for per-account NAV attribution)
    mapping(address => mapping(address => uint256)) private _heldByAccount;

    //
    // Constructor
    //

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    //
    // Initialization
    //

    /// @notice Initializes the BridgeEscrow contract
    /// @param admin_ The admin address (must be non-zero)
    /// @param chainId_ The chain ID where this contract is deployed
    /// @param initialAccounts Array of initial authorized accounts
    /// @param initialAdapters Array of initial authorized adapters
    function initialize(
        address admin_,
        uint64 chainId_,
        address[] memory initialAccounts,
        address[] memory initialAdapters
    ) external initializer {
        if (admin_ == address(0)) revert InvalidArguments();
        __AccessControl_init();
        __Pausable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        chainId = chainId_;

        for (uint256 i = 0; i < initialAccounts.length; i++) {
            _authorizeAccount(initialAccounts[i]);
        }
        for (uint256 i = 0; i < initialAdapters.length; i++) {
            _authorizeAdapter(initialAdapters[i]);
        }
    }

    /// @notice Allows contract to receive native tokens (e.g. adapter-forwarded native on release)
    receive() external payable {}

    //
    // Core Functions
    //

    /// @inheritdoc IBridgeEscrow
    function depositAndBridge(uint64 destinationChainId, string calldata assetSymbol, uint256 amount, address adapter)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (bytes32 invoiceHash)
    {
        if (!_authorizedAccounts.contains(msg.sender)) revert NotAuthorized();
        if (!_authorizedAdapters.contains(adapter)) revert NotAuthorized();
        if (amount == 0) revert InvalidArguments();
        if (destinationChainId == chainId) revert InvalidArguments(); // Can't bridge to same chain

        bytes6 sym = InvoiceDataLib.strToBytes6(assetSymbol);
        address asset = _assetRegistry[sym];
        if (_registeredSymbolsIndex[sym] == 0) revert InvalidArguments(); // Asset not registered

        // Pull funds and determine the EFFECTIVE amount actually received (fee-on-transfer safe).
        uint256 effectiveAmount;
        if (_isNativeToken(asset)) {
            if (msg.value != amount) revert InvalidValue();
            effectiveAmount = amount;
        } else {
            if (msg.value != 0) revert InvalidValue();
            uint256 balBefore = IERC20(asset).balanceOf(address(this));
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            effectiveAmount = IERC20(asset).balanceOf(address(this)) - balBefore;
            if (effectiveAmount == 0) revert InvalidArguments();
        }

        // Assign a per-account nonce so the invoice identity is unique per operation.
        uint256 nonce = _bridgeNonce[msg.sender]++;

        bytes32 invoiceId;
        bytes memory messagePayload;
        (invoiceHash, invoiceId, messagePayload) =
            _createAndStoreInvoice(destinationChainId, msg.sender, sym, asset, effectiveAmount, nonce, adapter);

        emit InvoiceCreated(invoiceId, msg.sender, asset, effectiveAmount, chainId, destinationChainId);
        emit AssetsDeposited(invoiceId, asset, effectiveAmount);

        // Hand funds to the adapter to dispatch.
        if (_isNativeToken(asset)) {
            (bool success,) = adapter.call{value: effectiveAmount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(asset).forceApprove(adapter, effectiveAmount);
        }

        IBridgeAdapter(adapter).bridge(messagePayload);

        // Defense-in-depth: clear any residual allowance the adapter did not pull (mirrors the
        // approve→use→reset-to-0 pattern in BridgeAdapter._fundAndRelease). A well-behaved adapter pulls
        // exactly `effectiveAmount`, leaving 0; this guarantees no standing approval survives the call.
        if (!_isNativeToken(asset)) {
            IERC20(asset).forceApprove(adapter, 0);
        }

        return invoiceHash;
    }

    /// @inheritdoc IBridgeEscrow
    /// @dev Destination-side delivery recorder (ADR 0024, supersedes the ADR-0012 pass-through here). Callable
    ///      ONLY by an authorized adapter — there is no `fallback()` dispatcher and MANAGER cannot call this
    ///      directly, so an attacker can never reach the custody path (C1). The adapter, having authenticated
    ///      the genuine inbound protocol message and source sender, hands over the funds in the SAME call: the
    ///      escrow pulls exactly `amount` from the adapter (or requires `msg.value == amount` for native),
    ///      MEASURES the balance-delta actually received, writes a `destinationCustody` record, and HOLDS the
    ///      funds. Release to the account happens only via `claim`. Provenance is the adapter (I2); the checksum
    ///      is integrity/replay only.
    function recordDelivery(bytes calldata messagePayload) external payable nonReentrant whenNotPaused {
        if (!_authorizedAdapters.contains(msg.sender)) revert NotAuthorized();

        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

        // Reject a zero-amount delivery symmetrically for native + ERC20. depositAndBridge already enforces
        // amount > 0 and the checksum binds it, so a genuine payload never reaches here with amount == 0; this
        // guard stops a zero-value native call from writing a "completed" but permanently unclaimable record
        // (the ERC20 branch already reverts on measured == 0).
        if (data.amount == 0) revert InvalidArguments();

        // Validate the source-stamped timestamp is not implausibly in the future. A skew tolerance absorbs
        // cross-chain clock differences on fast lanes. Replay/integrity are enforced by checksum + record.
        uint64 currentTimestamp = uint64(block.timestamp);
        if (data.timestamp > currentTimestamp + TIMESTAMP_SKEW_TOLERANCE) {
            revert InvalidTimestamp(data.timestamp, currentTimestamp);
        }

        // Validate checksum (integrity + replay key; provenance is enforced by the adapter).
        bytes24 expectedChecksum =
            InvoiceDataLib.calculateChecksum(data.invoiceId, data.amount, data.timestamp, data.nonce);
        if (data.checksum24 != expectedChecksum) {
            revert InvalidChecksum(data.invoiceId, data.checksum24, expectedChecksum);
        }

        bytes32 invoiceHash = bytes32(uint256(uint192(data.checksum24)));
        // Replay guard: a delivery for this invoice must not already be recorded.
        if (completedInvoices[invoiceHash] || destinationCustody[invoiceHash].amount != 0) {
            revert InvoiceAlreadyExists();
        }

        if (uint64(data.destinationChainId) != chainId) revert InvalidArguments();
        if (!_authorizedAccounts.contains(data.account)) revert NotAuthorized();

        address asset = _assetRegistry[data.assetSymbol];
        if (_registeredSymbolsIndex[data.assetSymbol] == 0) revert InvalidArguments();

        // Pull the delivered funds from the adapter and MEASURE what actually arrived (fee-on-transfer /
        // post-fee safe, I7). The escrow now HOLDS them until `claim`.
        uint256 measured;
        if (_isNativeToken(asset)) {
            if (msg.value != data.amount) revert InvalidValue();
            measured = msg.value;
        } else {
            if (msg.value != 0) revert InvalidValue();
            uint256 balBefore = IERC20(asset).balanceOf(address(this));
            IERC20(asset).safeTransferFrom(msg.sender, address(this), data.amount);
            measured = IERC20(asset).balanceOf(address(this)) - balBefore;
            if (measured == 0) revert InvalidArguments();
        }

        completedInvoices[invoiceHash] = true;
        destinationCustody[invoiceHash] = DestinationCustody({
            account: data.account,
            asset: asset,
            amount: measured,
            adapter: msg.sender,
            deliveredAt: currentTimestamp,
            claimed: false
        });
        _heldClaimable[asset] += measured;
        _heldByAccount[data.account][asset] += measured;

        emit InvoiceCompleted(invoiceHash, data.invoiceId);
        emit DeliveryRecorded(data.invoiceId, invoiceHash, asset, measured, data.account, msg.sender);
    }

    /// @inheritdoc IBridgeEscrow
    /// @dev MANAGER-gated. Moves a held delivery to the recorded account (the safe). Because it can only ever
    ///      pay the account stored at `recordDelivery`, and exactly the recorded amount, the gate controls only
    ///      the TIMING of when funds enter the safe (I4). Strict CEI in `_claim`.
    function claim(bytes32 invoiceHash) external override nonReentrant whenNotPaused onlyRole(MANAGER_ROLE) {
        _claim(invoiceHash);
    }

    /// @inheritdoc IBridgeEscrow
    /// @dev Deliberately **strict / all-or-nothing**: if any hash is unknown or already claimed, the whole batch
    ///      reverts and no funds move. This differs from `markInvoiceCompleted`'s tolerant per-item batching
    ///      (which only mutates bookkeeping and reports skips via `InvoiceCompletionFailed`) precisely because
    ///      `claim` MOVES funds — atomic batches are auditable and never leave a keeper guessing which subset
    ///      settled. A keeper that wants partial progress should simulate first, or fall back to per-hash
    ///      `claim(bytes32)`. A hash claimed concurrently between simulation and inclusion reverts the batch;
    ///      re-submit without it.
    function claim(bytes32[] calldata invoiceHashes)
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(MANAGER_ROLE)
    {
        for (uint256 i = 0; i < invoiceHashes.length; i++) {
            _claim(invoiceHashes[i]);
        }
    }

    /// @notice Releases one held destination delivery to its recorded account (strict CEI; I3/I4).
    function _claim(bytes32 invoiceHash) internal {
        DestinationCustody storage rec = destinationCustody[invoiceHash];
        address account = rec.account;
        address asset = rec.asset;
        uint256 amount = rec.amount;
        if (amount == 0) revert InvoiceNotFound();
        if (rec.claimed) revert AlreadyClaimed();

        // Effects before interaction: flip claimed + decrement the custody aggregates.
        rec.claimed = true;
        _heldClaimable[asset] -= amount;
        _heldByAccount[account][asset] -= amount;

        // Interaction: transfer exactly the recorded `amount` of the recorded asset to the recorded account, and
        // no one else. For every bridged asset (standard ERC20 + native) the account receives exactly `amount`;
        // a fee-on-transfer token would deliver its own post-fee amount (the escrow can only *send* `amount`, not
        // guarantee receipt) — but no fee-on-transfer token is a bridged asset, so the exact-payout holds here.
        if (_isNativeToken(asset)) {
            (bool success,) = account.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(account, amount);
        }

        emit AssetsClaimed(invoiceHash, asset, amount, account);
    }

    //
    // Manager Functions
    //

    /// @inheritdoc IBridgeEscrow
    /// @dev Source-chain bridge-failure recovery. Full CEI + nonReentrant: all bookkeeping completes before
    ///      the refund transfer leaves the contract.
    function cancelInvoice(bytes32 invoiceHash) external override onlyRole(MANAGER_ROLE) nonReentrant whenNotPaused {
        Invoice storage invoice = invoices[invoiceHash];

        if (invoice.invoiceId == bytes32(0)) revert InvoiceNotFound();
        if (invoice.status != InvoiceStatus.BRIDGING) revert InvalidInvoiceStatus();

        address asset = invoice.asset;
        uint256 amount = invoice.amount;
        address account = invoice.account;
        uint64 sourceChainId = invoice.sourceChainId;
        bytes32 invoiceId = invoice.invoiceId;

        // Refund only from the surplus over destination held custody: this single contract is both the source
        // escrow (this refund path) and the destination escrow (recordDelivery/claim), so their funds commingle
        // in one balance. Dipping into _heldClaimable here would drain funds backing a recorded delivery and
        // break I1, stranding that delivery's claim (ADR 0024).
        uint256 balance = _isNativeToken(asset) ? address(this).balance : IERC20(asset).balanceOf(address(this));
        uint256 held = _heldClaimableFor(asset);
        uint256 available = balance > held ? balance - held : 0;
        if (available < amount) revert InsufficientBalance(asset, amount, available);

        // Effects first (CEI).
        invoice.status = InvoiceStatus.CANCELLED;
        _updateInTransitBalance(account, asset, amount, false);
        _removeActiveInvoice(account, invoiceHash);

        // Interaction last.
        if (_isNativeToken(asset)) {
            (bool success,) = account.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(account, amount);
        }

        emit InvoiceStatusUpdated(invoiceId, InvoiceStatus.BRIDGING, InvoiceStatus.CANCELLED);
        emit AssetsReleased(invoiceId, sourceChainId, asset, amount, account);
    }

    /// @inheritdoc IBridgeEscrow
    function markInvoiceCompleted(bytes32[] calldata invoiceHashes)
        external
        override
        onlyRole(MANAGER_ROLE)
        whenNotPaused
    {
        uint256 length = invoiceHashes.length;
        bytes32[] memory failedInvoiceIds = new bytes32[](length);
        uint256 failedCount = 0;

        for (uint256 i = 0; i < length; i++) {
            bytes32 invoiceHash = invoiceHashes[i];
            Invoice storage invoice = invoices[invoiceHash];

            if (invoice.invoiceId == bytes32(0)) {
                failedInvoiceIds[failedCount++] = bytes32(0);
                continue;
            }
            if (invoice.status != InvoiceStatus.BRIDGING) {
                failedInvoiceIds[failedCount++] = invoice.invoiceId;
                continue;
            }

            invoice.status = InvoiceStatus.COMPLETED;
            completedInvoices[invoiceHash] = true;
            _updateInTransitBalance(invoice.account, invoice.asset, invoice.amount, false);
            _removeActiveInvoice(invoice.account, invoiceHash);

            emit InvoiceStatusUpdated(invoice.invoiceId, InvoiceStatus.BRIDGING, InvoiceStatus.COMPLETED);
        }

        if (failedCount > 0) {
            bytes32[] memory failed = new bytes32[](failedCount);
            for (uint256 i = 0; i < failedCount; i++) {
                failed[i] = failedInvoiceIds[i];
            }
            emit InvoiceCompletionFailed(failed);
        }
    }

    /// @notice Registers an asset with its symbol on this chain
    /// @param symbol The asset symbol as string (max 6 chars, right-padded internally)
    /// @param asset The asset address (address(0) for native ETH/tokens)
    /// @dev Re-pointing a symbol that has active invoices is forbidden (would strand the in-transit cache).
    function registerAsset(string calldata symbol, address asset) external onlyRole(MANAGER_ROLE) {
        bytes6 sym = InvoiceDataLib.strToBytes6(symbol);
        if (_registeredSymbolsIndex[sym] != 0) {
            // Already registered: only allow a no-op or a repoint when the OLD asset has neither source-side
            // active invoices nor destination held custody — otherwise the repoint would hide that outstanding
            // obligation from the symbol-enumerating views (getHeldBalance*), even though the old record stays
            // claimable by raw hash. Mirrors the unregisterAsset guard.
            if (
                _assetRegistry[sym] != asset
                    && (_hasActiveInvoicesForAsset(sym) || _heldClaimable[_assetRegistry[sym]] != 0)
            ) {
                revert AssetHasActiveInvoices(symbol);
            }
            _assetRegistry[sym] = asset;
        } else {
            _assetRegistry[sym] = asset;
            _registeredSymbols.push(sym);
            _registeredSymbolsIndex[sym] = _registeredSymbols.length; // 1-based
        }
        emit AssetRegistered(sym, asset);
    }

    /// @notice Unregisters an asset symbol
    /// @dev Reverts if symbol was never registered or has active invoices
    function unregisterAsset(string calldata symbol) external onlyRole(MANAGER_ROLE) {
        bytes6 sym = InvoiceDataLib.strToBytes6(symbol);
        uint256 idx = _registeredSymbolsIndex[sym];
        if (idx == 0) revert AssetNotRegistered(symbol);
        if (_hasActiveInvoicesForAsset(sym)) revert AssetHasActiveInvoices(symbol);
        // Also block unregistering while destination custody still holds this asset: getHeldBalance* enumerate
        // registered symbols, so dropping the symbol would hide still-held (claimable) funds from NAV even though
        // claim(invoiceHash) by raw hash would still pay them out. Held custody is an outstanding obligation, so
        // it gates unregistration exactly like a source-side active invoice.
        if (_heldClaimable[_assetRegistry[sym]] != 0) revert AssetHasActiveInvoices(symbol);

        uint256 lastIdx = _registeredSymbols.length;
        bytes6 lastSymbol = _registeredSymbols[lastIdx - 1];
        _registeredSymbols[idx - 1] = lastSymbol;
        _registeredSymbolsIndex[lastSymbol] = idx;
        _registeredSymbols.pop();
        delete _registeredSymbolsIndex[sym];
        delete _assetRegistry[sym];

        emit AssetUnregistered(sym);
    }

    //
    // View Functions
    //

    /// @inheritdoc IBridgeEscrow
    function assetRegistry(string calldata symbol) external view override returns (address) {
        return _assetRegistry[InvoiceDataLib.strToBytes6(symbol)];
    }

    /// @inheritdoc IBridgeEscrow
    function registeredAssets() external view override returns (string[] memory symbols, address[] memory assets) {
        uint256 n = _registeredSymbols.length;
        symbols = new string[](n);
        assets = new address[](n);
        for (uint256 i; i < n; i++) {
            symbols[i] = InvoiceDataLib.bytes6ToStr(_registeredSymbols[i]);
            assets[i] = _assetRegistry[_registeredSymbols[i]];
        }
    }

    /// @inheritdoc IBridgeEscrow
    function bridgeNonce(address account) external view override returns (uint256) {
        return _bridgeNonce[account];
    }

    /// @inheritdoc IBridgeEscrow
    function getInvoice(bytes32 invoiceHash) external view override returns (Invoice memory) {
        return invoices[invoiceHash];
    }

    /// @inheritdoc IBridgeEscrow
    function getActiveInvoices(address account) external view override returns (Invoice[] memory) {
        bytes32[] memory activeInvoiceHashes = _activeInvoices[account];
        uint256 length = activeInvoiceHashes.length;
        Invoice[] memory activeInvoices = new Invoice[](length);
        for (uint256 i = 0; i < length; i++) {
            activeInvoices[i] = invoices[activeInvoiceHashes[i]];
        }
        return activeInvoices;
    }

    /// @inheritdoc IBridgeEscrow
    function getInTransitBalancesForAccount(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts)
    {
        bytes32[] memory activeInvoiceHashes = _activeInvoices[account];
        uint256 length = activeInvoiceHashes.length;

        address[] memory tempAssets = new address[](length);
        uint256[] memory tempAmounts = new uint256[](length);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < length; i++) {
            Invoice storage invoice = invoices[activeInvoiceHashes[i]];
            address asset = invoice.asset;
            uint256 amount = invoice.amount;

            bool found = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (tempAssets[j] == asset) {
                    tempAmounts[j] += amount;
                    found = true;
                    break;
                }
            }
            if (!found) {
                tempAssets[uniqueCount] = asset;
                tempAmounts[uniqueCount] = amount;
                uniqueCount++;
            }
        }

        assets = new address[](uniqueCount);
        amounts = new uint256[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount; i++) {
            assets[i] = tempAssets[i];
            amounts[i] = tempAmounts[i];
        }
    }

    /// @inheritdoc IBridgeEscrow
    function getInTransitBalanceForAsset(address asset, address account) external view override returns (uint256) {
        if (account == address(0)) return _inTransitBalancesAllAccounts[asset];
        return _inTransitBalances[account][asset];
    }

    /// @inheritdoc IBridgeEscrow
    function getHeldBalanceForAsset(address asset, address account) external view override returns (uint256) {
        // Aggregate (account == 0) query routes through _heldClaimableFor so a native query sums BOTH native
        // representations (address(0) + the ERC-7528 sentinel), matching the cancelInvoice/emergencyWithdraw
        // surplus caps and BridgeHeldBalanceAdapter's point getter; a raw single-key lookup here would
        // under-report native held custody when queried via the "other" native key. Non-native is unchanged.
        if (account == address(0)) return _heldClaimableFor(asset);
        return _heldByAccount[account][asset];
    }

    /// @inheritdoc IBridgeEscrow
    /// @dev Enumerates registered assets (bounded, small) and reports the account's held-but-unclaimed custody.
    function getHeldBalancesForAccount(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts)
    {
        uint256 symCount = _registeredSymbols.length;
        address[] memory tempAssets = new address[](symCount);
        uint256[] memory tempAmounts = new uint256[](symCount);
        uint256 n = 0;
        for (uint256 i = 0; i < symCount; i++) {
            address asset = _assetRegistry[_registeredSymbols[i]];
            uint256 amt = _heldByAccount[account][asset];
            if (amt == 0) continue;
            // Registration enforces unique symbols, not unique asset addresses; `_heldByAccount` is keyed by
            // asset, so two symbols aliasing one token would otherwise emit that token (and its full held
            // amount) twice — double-counting it downstream (e.g. in BridgeHeldBalanceAdapter). Dedupe by asset.
            bool seen = false;
            for (uint256 j = 0; j < n; j++) {
                if (tempAssets[j] == asset) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            tempAssets[n] = asset;
            tempAmounts[n] = amt;
            n++;
        }
        assets = new address[](n);
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            assets[i] = tempAssets[i];
            amounts[i] = tempAmounts[i];
        }
    }

    /// @inheritdoc IBridgeEscrow
    function isAuthorizedAccount(address safe) external view override returns (bool) {
        return _authorizedAccounts.contains(safe);
    }

    /// @inheritdoc IBridgeEscrow
    function isAuthorizedAdapter(address adapter) external view override returns (bool) {
        return _authorizedAdapters.contains(adapter);
    }

    /// @inheritdoc IBridgeEscrow
    function isInvoiceCompleted(bytes32 invoiceHash) external view override returns (bool) {
        return completedInvoices[invoiceHash];
    }

    /// @inheritdoc IBridgeEscrow
    function getInvoicesCompletionStatus(bytes32[] calldata invoiceHashes)
        external
        view
        override
        returns (bool[] memory isCompleted)
    {
        uint256 length = invoiceHashes.length;
        isCompleted = new bool[](length);
        for (uint256 i = 0; i < length; i++) {
            isCompleted[i] = completedInvoices[invoiceHashes[i]];
        }
    }

    /// @inheritdoc IBridgeEscrow
    function getAuthorizedAdapters() external view override returns (address[] memory adapters) {
        uint256 n = _authorizedAdapters.length();
        adapters = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            adapters[i] = _authorizedAdapters.at(i);
        }
    }

    //
    // Admin Functions
    //

    /// @notice Authorizes an account
    function authorizeAccount(address safe) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _authorizeAccount(safe);
        emit AccountAuthorized(safe);
    }

    /// @notice Revokes authorization for an account
    /// @dev Reverts if the account still has active (BRIDGING) invoices. `_hasActiveInvoicesForAsset` only
    ///      scans authorized accounts, so revoking an account with in-flight invoices would hide them and let
    ///      `registerAsset`/`unregisterAsset` repoint/remove a symbol that still has pending destination
    ///      releases. Blocking the revoke keeps that guard complete.
    /// @dev Operational caveat: these guards only see state THIS escrow already holds. A cross-chain delivery
    ///      that is in flight but not yet recorded on this (destination) escrow is invisible here, so revoking an
    ///      account mid-flight will make its eventual `recordDelivery` revert (`NotAuthorized`) and leave the
    ///      delivered funds on the adapter — recoverable via the adapter's `recoverStuckAssets`, but a manual
    ///      step. Revoke an account only once it has no in-flight bridge transfers.
    function revokeAccount(address safe) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_activeInvoices[safe].length > 0) revert AccountHasActiveInvoices(safe);
        // Also block revoke while the account still has outstanding destination held custody (ADR 0024): the
        // funds remain claimable to this recorded account, so revoke it only after settlement, mirroring the
        // held-custody guards on register/unregisterAsset. (Held custody is an outstanding obligation like an
        // active invoice, hence the shared error.)
        if (_hasHeldCustody(safe)) revert AccountHasActiveInvoices(safe);
        _authorizedAccounts.remove(safe);
        emit AccountRevoked(safe);
    }

    /// @notice Authorizes a bridge adapter
    function authorizeAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _authorizeAdapter(adapter);
        emit AdapterAuthorized(adapter);
    }

    /// @notice Revokes authorization for a bridge adapter
    /// @dev Reverts if the adapter still has in-flight (BRIDGING) invoices it dispatched. Symmetric with
    ///      `revokeAccount`: revoking an adapter mid-dispatch would orphan those invoices (their
    ///      source-chain recovery and the matching destination release both route through the adapter),
    ///      so the revoke is blocked until they settle.
    function revokeAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_hasActiveInvoicesForAdapter(adapter)) revert AdapterHasActiveInvoices(adapter);
        _authorizedAdapters.remove(adapter);
        emit AdapterRevoked(adapter);
    }

    /// @notice Pauses the contract (prevents deposits and releases)
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses the contract
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Emergency withdrawal (admin break-glass; only while paused)
    /// @param asset The asset address to withdraw (address(0)/ERC-7528 for native)
    /// @param amount The amount to withdraw
    /// @param to The recipient — MUST be an authorized account (no arbitrary-address sweep)
    /// @dev Recipient-restricted (ADR 0012, H10). **Capped to the surplus over destination custody (ADR 0024):**
    ///      the withdrawable amount is `balanceOf(asset) - _heldClaimableFor(asset)`, so a break-glass withdrawal
    ///      can only ever move stray/surplus funds — never the funds backing outstanding `destinationCustody`
    ///      records. This keeps I1 (`balanceOf >= _heldClaimable`) true through the emergency path, so held records
    ///      stay fully claimable after unpause and `getHeldBalance*` / `BridgeHeldBalanceAdapter` never over-report.
    ///      Held custody is not "stuck": `claim` releases it after unpause, and if the escrow itself must be
    ///      abandoned the UUPS upgrade path is the true last resort for held funds. Native held may be keyed under
    ///      `address(0)` (the registry convention) or the ERC-7528 sentinel; `_heldClaimableFor` sums BOTH native
    ///      buckets, so the cap protects native custody registered under either key.
    function emergencyWithdraw(address asset, uint256 amount, address to)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenPaused
        nonReentrant
    {
        if (amount == 0) revert InvalidArguments();
        if (!_authorizedAccounts.contains(to)) revert NotAuthorized();

        // Never dip into funds backing held custody: cap to the surplus over `_heldClaimable` (I1).
        uint256 held = _heldClaimableFor(asset);

        if (_isNativeToken(asset)) {
            uint256 balance = address(this).balance;
            uint256 withdrawable = balance > held ? balance - held : 0;
            if (withdrawable < amount) revert InsufficientBalance(asset, amount, withdrawable);
            (bool success,) = to.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            uint256 balance = IERC20(asset).balanceOf(address(this));
            uint256 withdrawable = balance > held ? balance - held : 0;
            if (withdrawable < amount) revert InsufficientBalance(asset, amount, withdrawable);
            IERC20(asset).safeTransfer(to, amount);
        }

        emit EmergencyWithdrawal(asset, amount, to);
    }

    //
    // Internal Functions
    //

    /// @notice Generates a 32-byte invoice ID (route + account + symbol identity; excludes amount and nonce)
    function _generateInvoiceId(uint64 sourceChainId, uint64 destinationChainId, address account, bytes6 assetSymbol)
        internal
        pure
        returns (bytes32)
    {
        // Pack data: 3 + 3 + 20 + 6 = 32 bytes exactly
        return bytes32(
            (uint256(SafeCast.toUint24(sourceChainId)) << 232) // Bits 232-255 (3 bytes)
                | (uint256(SafeCast.toUint24(destinationChainId)) << 208) // Bits 208-231 (3 bytes)
                | (uint256(uint160(account)) << 48) // Bits 48-207 (20 bytes)
                | (uint256(uint48(assetSymbol))) // Bits 0-47 (6 bytes)
        );
    }

    /// @notice Checks if an address represents a native token
    function _isNativeToken(address token) internal pure returns (bool) {
        return token == address(0) || token == NATIVE_ADDRESS_ERC7528;
    }

    /// @notice Total destination custody currently held for `asset` (ADR 0024).
    /// @dev Sums both native representations (`address(0)` + the ERC-7528 sentinel) so native custody registered
    ///      under either key is covered. Used to keep source-side refunds (`cancelInvoice`) and break-glass
    ///      withdrawals (`emergencyWithdraw`) from dipping into funds that back recorded deliveries (invariant I1).
    function _heldClaimableFor(address asset) internal view returns (uint256) {
        return _isNativeToken(asset)
            ? _heldClaimable[address(0)] + _heldClaimable[NATIVE_ADDRESS_ERC7528]
            : _heldClaimable[asset];
    }

    /// @notice True iff `account` has any outstanding destination held custody across the registered assets.
    /// @dev O(registered symbols); used only by `revokeAccount` (a rare admin op), so the linear scan is fine.
    function _hasHeldCustody(address account) internal view returns (bool) {
        uint256 n = _registeredSymbols.length;
        for (uint256 i = 0; i < n; i++) {
            if (_heldByAccount[account][_assetRegistry[_registeredSymbols[i]]] != 0) return true;
        }
        return false;
    }

    /// @inheritdoc IBridgeEscrow
    function decodeInvoiceId(bytes32 invoiceId)
        external
        pure
        override
        returns (uint24 sourceChainId, uint24 destinationChainId, address account, string memory assetSymbol)
    {
        uint256 id = uint256(invoiceId);
        sourceChainId = SafeCast.toUint24(id >> 232);
        destinationChainId = SafeCast.toUint24((id >> 208) & type(uint24).max);
        account = address(uint160((id >> 48) & type(uint160).max));
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes6 sym = bytes6(uint48(id & type(uint48).max));
        assetSymbol = InvoiceDataLib.bytes6ToStr(sym);
    }

    /// @inheritdoc IBridgeEscrow
    function validateInvoiceIdChecksum(
        bytes32 invoiceId,
        uint256 amount,
        uint64 timestamp,
        uint256 nonce,
        bytes24 checksum24
    ) external pure override returns (bool) {
        return checksum24 == InvoiceDataLib.calculateChecksum(invoiceId, amount, timestamp, nonce);
    }

    /// @notice Creates and stores an invoice with all necessary bookkeeping
    function _createAndStoreInvoice(
        uint64 destinationChainId,
        address account,
        bytes6 assetSymbol,
        address asset,
        uint256 amount,
        uint256 nonce,
        address adapter
    ) internal returns (bytes32 invoiceHash, bytes32 invoiceId, bytes memory messagePayload) {
        invoiceId = _generateInvoiceId(chainId, destinationChainId, account, assetSymbol);
        uint64 timestamp = uint64(block.timestamp);
        bytes24 checksum24 = InvoiceDataLib.calculateChecksum(invoiceId, amount, timestamp, nonce);
        invoiceHash = bytes32(uint256(uint192(checksum24)));

        // With the per-account nonce, identity is unique per operation; collision here is unreachable.
        if (invoices[invoiceHash].invoiceId != bytes32(0)) revert InvoiceAlreadyExists();

        messagePayload = InvoiceDataLib.encode(
            InvoiceDataLib.InvoiceData({
                invoiceId: invoiceId,
                sourceChainId: SafeCast.toUint24(chainId),
                destinationChainId: SafeCast.toUint24(destinationChainId),
                account: account,
                assetSymbol: assetSymbol,
                amount: amount,
                nonce: nonce,
                timestamp: timestamp,
                checksum24: checksum24
            })
        );

        Invoice storage invoice = invoices[invoiceHash];
        invoice.invoiceId = invoiceId;
        invoice.sourceChainId = chainId;
        invoice.destinationChainId = destinationChainId;
        invoice.account = account;
        invoice.asset = asset;
        invoice.amount = amount;
        invoice.nonce = nonce;
        invoice.timestamp = block.timestamp;
        invoice.status = InvoiceStatus.BRIDGING;
        invoice.adapter = adapter;

        _activeInvoices[account].push(invoiceHash);
        _activeInvoicesSet[account][invoiceHash] = true;
        _updateInTransitBalance(account, asset, amount, true);

        return (invoiceHash, invoiceId, messagePayload);
    }

    /// @notice Internal function to authorize an account
    function _authorizeAccount(address safe) internal {
        if (safe == address(0)) revert InvalidArguments();
        _authorizedAccounts.add(safe);
    }

    /// @notice Internal function to authorize an adapter
    function _authorizeAdapter(address adapter) internal {
        if (adapter == address(0)) revert InvalidArguments();
        // Verify adapter implements IBridgeAdapter (ERC165).
        try IERC165(adapter).supportsInterface(type(IBridgeAdapter).interfaceId) returns (bool ok) {
            if (!ok) revert InvalidArguments();
        } catch {
            revert InvalidArguments();
        }
        _authorizedAdapters.add(adapter);
    }

    /// @notice Updates in-transit balance caches when invoices are created or completed/cancelled
    /// @dev Decrement is unguarded: an underflow is a real invariant breach and MUST revert (ADR 0012, H6),
    ///      not be silently swallowed. Both caches move atomically.
    function _updateInTransitBalance(address safe, address asset, uint256 amount, bool increment) internal {
        if (increment) {
            _inTransitBalances[safe][asset] += amount;
            _inTransitBalancesAllAccounts[asset] += amount;
        } else {
            _inTransitBalances[safe][asset] -= amount;
            _inTransitBalancesAllAccounts[asset] -= amount;
        }
    }

    /// @notice Internal function to remove an active invoice (swap-and-pop)
    function _removeActiveInvoice(address account, bytes32 invoiceHash) internal {
        if (!_activeInvoicesSet[account][invoiceHash]) return;
        bytes32[] storage activeList = _activeInvoices[account];
        uint256 length = activeList.length;
        for (uint256 i = 0; i < length; i++) {
            if (activeList[i] == invoiceHash) {
                activeList[i] = activeList[length - 1];
                activeList.pop();
                _activeInvoicesSet[account][invoiceHash] = false;
                break;
            }
        }
    }

    /// @notice Checks if an asset symbol has any active invoices (iterates authorized accounts; MANAGER-gated callers)
    function _hasActiveInvoicesForAsset(bytes6 assetSymbol) internal view returns (bool) {
        uint256 safeCount = _authorizedAccounts.length();
        for (uint256 i = 0; i < safeCount; i++) {
            address safe = _authorizedAccounts.at(i);
            bytes32[] memory activeInvoiceHashes = _activeInvoices[safe];
            for (uint256 j = 0; j < activeInvoiceHashes.length; j++) {
                bytes6 invoiceAssetSymbol = bytes6(uint48(uint256(invoices[activeInvoiceHashes[j]].invoiceId)));
                if (invoiceAssetSymbol == assetSymbol) return true;
            }
        }
        return false;
    }

    /// @notice Checks if a bridge adapter has any in-flight (BRIDGING) invoices it dispatched.
    /// @dev Iterates authorized accounts' active invoices (admin-only caller, same pattern as
    ///      `_hasActiveInvoicesForAsset`). `_activeInvoices` only ever holds BRIDGING hashes.
    function _hasActiveInvoicesForAdapter(address adapter) internal view returns (bool) {
        uint256 safeCount = _authorizedAccounts.length();
        for (uint256 i = 0; i < safeCount; i++) {
            address safe = _authorizedAccounts.at(i);
            // Iterate the storage array directly (no full memory copy) — cheaper as invoice counts grow.
            bytes32[] storage activeInvoiceHashes = _activeInvoices[safe];
            uint256 len = activeInvoiceHashes.length;
            for (uint256 j = 0; j < len; j++) {
                if (invoices[activeInvoiceHashes[j]].adapter == adapter) return true;
            }
        }
        return false;
    }

    /// @notice Authorizes upgrades to new implementations (DEFAULT_ADMIN_ROLE / security council)
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @dev Storage gap for future upgrades. Layout was rewritten clean pre-launch (ADR 0012); the ADR-0024
    ///      destination-custody maps (destinationCustody, _heldClaimable, _heldByAccount) consumed 3 slots.
    ///      Normal append-only discipline applies from here.
    uint256[47] private _gap;
}
