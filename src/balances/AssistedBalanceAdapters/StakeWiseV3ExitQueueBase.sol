// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {SingleAssetAssistedGetters} from "src/balances/AssistedBalanceAdapters/SingleAssetAssistedGetters.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title StakeWiseV3ExitQueueBase
/// @author KPK
/// @notice Shared, feed-agnostic base for the StakeWise V3 exit-queue balance adapters. Holds the per-account ticket
///         cache and **all** of the live on-chain valuation — the piece that is identical whether the cache is fed by
///         an off-chain assistant (`StakeWiseV3ExitQueueAssistedBalanceAdapter`, ADR 0014) or on-chain by a depositor
///         Safe through a delegatecalled wrapper (`StakeWiseV3ExitQueueBalanceAdapter`, ADR 0018). A concrete adapter
///         inherits this alongside its access-control base and implements ONLY its own submit/remove surface + role
///         model + `supportsInterface`.
/// @dev The cache stores **only position coordinates** — `(vault, positionTicket, timestamp)` tuples, never amounts —
///      and every read values them entirely from live vault reads keyed on `receiver = account`
///      (`calculateExitedAssets`), so a faulty or compromised feed can only under-report, never over-report. This is
///      the family invariant (ADR 0015). Emits up to two `Supplied` legs PER cached position (per `positionTicket`) —
///      a claimable leg (`isLocked = false`) and a locked/pending leg (`isLocked = true`) — both carrying that
///      ticket's id in the typed `positionInstanceId`, and all legs of a vault sharing one static per-vault
///      `positionId = abi.encode(vault)`. Denominated in the chain's staking asset (native ETH on mainnet). Mainnet
///      only — every StakeWise V3 vault there settles in ETH.
///
///      The exit-request key is `keccak256(abi.encode(receiver, timestamp, positionTicket))`, where `timestamp` is the
///      entry block's `block.timestamp`. Because the valuation call passes `receiver = account`, a tuple that does not
///      belong to `account` resolves to a zero exit request and is dropped — the on-chain ownership check (StakeWise
///      exit positions have no `ownerOf`). Reads never revert (all external reads try/catch to 0).
abstract contract StakeWiseV3ExitQueueBase is SingleAssetAssistedGetters, IPositionDescribable {
    //
    // Types
    //

    /// @param vault          StakeWise V3 vault the exit position lives in.
    /// @param positionTicket Ticket returned by `enterExitQueue` / emitted in `ExitQueueEntered`.
    /// @param timestamp      Entry block's `block.timestamp` — part of the exit-request key.
    struct ExitPosition {
        address vault;
        uint256 positionTicket;
        uint256 timestamp;
    }

    //
    // State
    //

    bytes32 internal constant PROTOCOL_BRAND = ProtocolIds.STAKEWISE;
    bytes32 internal constant PROTOCOL_ID = ProtocolIds.STAKEWISE_V3;
    bytes32 internal constant PROTOCOL_SUB_ID = ProtocolIds.STAKEWISE_V3_EXIT;

    /// @notice Hard cap on cached exit positions per account. `_owedAmount` iterates the whole array on every NAV
    ///         read, and an OOG there is NOT caught by NAVCalculator's try/catch — a bloated cache would brick the
    ///         account's NAV scan. Bounding the cache at write time keeps the read gas-bounded. A real account never
    ///         approaches 256 open exits.
    uint256 public constant MAX_POSITIONS = 256;

    /// @notice StakeWise VaultsRegistry — `vaults(address)` gates which vaults the cache accepts (write-time hygiene;
    ///         the immutable anchor).
    address public immutable VAULTS_REGISTRY;

    /// @notice Display symbol of StakeWise's receipt/LST token for this deployment — `"osETH"` on mainnet, `"osGNO"`
    ///         on Gnosis. Used only to build the `positionLabels` breadcrumb (`["Exit Queue", "<receiptSymbol>"]`).
    ///         Set once at construction (no setter). Empty ⇒ the label falls back to the bare `["Exit Queue"]`.
    string public receiptSymbol;

    /// @notice NAVCalculator — used to look up the registered staking-asset metadata when emitting positions.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice StakeWise's post-checkpoint claim delay, in seconds (24h on V3 mainnet; pinned here as there is no
    ///         public getter). The exited-but-still-delayed portion is reported as **locked** until the delay elapses;
    ///         it does not affect the owed *amount*, only the claimable/locked split.
    uint256 public immutable EXIT_CLAIM_DELAY;

    /// @notice Cached exit positions per account (the only thing the feed supplies).
    mapping(address account => ExitPosition[] positions) private _positions;

    /// @dev `idxPlus1` = index of the position in `_positions[account]` plus 1, keyed by the tuple hash. Zero ⇒ not
    ///      present (dedup + O(1) removal).
    mapping(address account => mapping(bytes32 key => uint256)) private _positionIdxPlus1;

    //
    // Events
    //

    event PositionSubmitted(address indexed account, address indexed vault, uint256 positionTicket, uint256 timestamp);
    event PositionCleared(address indexed account, address indexed vault, uint256 positionTicket, uint256 timestamp);
    event AccountCleared(address indexed account);

    //
    // Constructor
    //

    /// @param vaultsRegistry_ StakeWise VaultsRegistry. Must be a contract.
    /// @param underlyingToken_ Payout asset (native-ETH sentinel on mainnet).
    /// @param receiptSymbol_  Display symbol of StakeWise's receipt/LST token for this chain. May be empty.
    /// @param navCalculator_   NAVCalculator. Must be a contract.
    /// @param exitClaimDelay_  StakeWise's post-checkpoint claim delay in seconds (24h = `86400` on V3 mainnet). Must
    ///                         be non-zero.
    constructor(
        address vaultsRegistry_,
        address underlyingToken_,
        string memory receiptSymbol_,
        address navCalculator_,
        uint256 exitClaimDelay_
    ) SingleAssetAssistedGetters(underlyingToken_) {
        if (vaultsRegistry_ == address(0) || navCalculator_ == address(0) || exitClaimDelay_ == 0) {
            revert InvalidArguments();
        }
        AddressCheckLib.requireContract(vaultsRegistry_, "VaultsRegistry");
        AddressCheckLib.requireContract(navCalculator_, "NAVCalculator");

        VAULTS_REGISTRY = vaultsRegistry_;
        receiptSymbol = receiptSymbol_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
        EXIT_CLAIM_DELAY = exitClaimDelay_;
    }

    //
    // Reads (view, anyone)
    //

    /// @notice Candidate exit positions currently cached for `account` (display/debug; not staleness-filtered).
    function positionsOf(address account) external view returns (ExitPosition[] memory) {
        return _positions[account];
    }

    /// @inheritdoc IPositionDescribable
    function protocolName() external pure returns (string memory) {
        return "StakeWise V3";
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `["Exit Queue", "<receiptSymbol>"]` — category + StakeWise's receipt/LST token symbol. Falls back to the
    ///      bare `["Exit Queue"]` if {receiptSymbol} was left empty. All of a vault's tickets share the per-vault
    ///      `positionId`; the per-ticket coordinate is the typed `positionInstanceId` on each leg (ephemeral), NOT a
    ///      label.
    function positionLabels(bytes calldata) external view override returns (string[] memory out) {
        if (bytes(receiptSymbol).length == 0) {
            out = new string[](1);
            out[0] = "Exit Queue";
            return out;
        }
        out = new string[](2);
        out[0] = "Exit Queue";
        out[1] = receiptSymbol;
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice Returns up to TWO staking-asset `Supplied` legs PER cached exit position (per `positionTicket`) — one
    ///         claimable (`isLocked = false`) and one locked/pending (`isLocked = true`) — each carrying the ticket id
    ///         in the typed `positionInstanceId` field. All legs of a vault share that vault's static `positionId`.
    /// @dev Each cached position is valued live from on-chain reads (`_owedForPosition`). A zero-amount leg is omitted;
    ///      a position that values to 0/0 contributes no legs. All legs sum to `_owedAmount`. Positions not owned by
    ///      `account` / claimed value to 0 and are skipped — the feed can only under-report. Dropped entirely if the
    ///      underlying asset is not registered in NAVCalculator.
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (assetFilter != address(0) && assetFilter != UNDERLYING_TOKEN) {
            return new INAVCalculator.PositionBalance[](0);
        }
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        ExitPosition[] memory list = _positions[account];
        if (list.length == 0) return new INAVCalculator.PositionBalance[](0);

        // Underlying must be registered in NAVCalculator for the position to count in NAV.
        (INAVCalculator.Asset memory underlying, bool registered) =
            RegisteredAssetLib.find(NAV_CALCULATOR.getRegisteredAssets(), UNDERLYING_TOKEN);
        if (!registered) return new INAVCalculator.PositionBalance[](0);

        // Emit up to two legs PER cached position (claimable + locked). Size for two slots per position and resize to
        // the actual count below (a tighter count pre-pass would double the expensive external reads).
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](2 * list.length);
        uint256 n;
        for (uint256 i = 0; i < list.length; i++) {
            n = _appendPositionLegs(account, list[i], underlying, temp, n);
        }

        positions = new INAVCalculator.PositionBalance[](n);
        for (uint256 i = 0; i < n; i++) {
            positions[i] = temp[i];
        }
    }

    /// @dev Appends up to two `Supplied` legs for one cached exit position into `temp` (starting at `n`), returning the
    ///      new count: a claimable leg (`isLocked=false`) if its claimable > 0 and a locked leg (`isLocked=true`) if
    ///      its locked > 0 — both carrying the same ticket `positionInstanceId` and the same per-vault
    ///      `positionId = abi.encode(vault)`. A position that values to 0/0 contributes nothing.
    function _appendPositionLegs(
        address account,
        ExitPosition memory position,
        INAVCalculator.Asset memory underlying,
        INAVCalculator.PositionBalance[] memory temp,
        uint256 n
    ) private view returns (uint256) {
        (uint256 claimable, uint256 locked) =
            _owedForPosition(account, position.vault, position.positionTicket, position.timestamp);
        if (claimable + locked == 0) {
            return n;
        }
        bytes memory positionId = abi.encode(position.vault);
        bytes32 instanceId = bytes32(position.positionTicket);
        if (claimable > 0) {
            temp[n++] = INAVCalculator.PositionBalance({
                balanceAsset: underlying,
                balanceAdapter: address(this),
                amount: claimable,
                isDebt: false,
                protocolBrand: PROTOCOL_BRAND,
                protocolId: PROTOCOL_ID,
                protocolSubId: PROTOCOL_SUB_ID,
                positionId: positionId,
                positionKind: PositionKind.Supplied,
                isLocked: false,
                positionInstanceId: instanceId
            });
        }
        if (locked > 0) {
            temp[n++] = INAVCalculator.PositionBalance({
                balanceAsset: underlying,
                balanceAdapter: address(this),
                amount: locked,
                isDebt: false,
                protocolBrand: PROTOCOL_BRAND,
                protocolId: PROTOCOL_ID,
                protocolSubId: PROTOCOL_SUB_ID,
                positionId: positionId,
                positionKind: PositionKind.Supplied,
                isLocked: true,
                positionInstanceId: instanceId
            });
        }
        return n;
    }

    //
    // Internal — write (shared cache mutation; access control lives in the concrete adapter)
    //

    /// @dev Add one cached position. Idempotent (a duplicate tuple is a no-op). Fail-loud validation: the vault must be
    ///      StakeWise-registered AND the tuple must resolve to a live owed amount for `account` (the on-chain ownership
    ///      proxy). Reverts `PositionCacheFull` past `MAX_POSITIONS` and `InvalidExitPosition` on a bad tuple. Not
    ///      load-bearing for correctness — reads re-verify and value only live, account-owned positions.
    function _addPosition(address account, ExitPosition memory position) internal {
        bytes32 key = _key(position.vault, position.positionTicket, position.timestamp);
        if (_positionIdxPlus1[account][key] != 0) return; // already cached (idempotent no-op)
        if (_positions[account].length >= MAX_POSITIONS) revert PositionCacheFull(account, MAX_POSITIONS);

        bool registeredVault;
        try IStakeWiseVaultsRegistry(VAULTS_REGISTRY).vaults(position.vault) returns (bool ok) {
            registeredVault = ok;
        } catch {
            registeredVault = false;
        }
        if (!registeredVault) revert InvalidExitPosition(account, position.vault, position.positionTicket);
        (uint256 c, uint256 l) = _owedForPosition(account, position.vault, position.positionTicket, position.timestamp);
        if (c + l == 0) revert InvalidExitPosition(account, position.vault, position.positionTicket);

        _positions[account].push(position);
        _positionIdxPlus1[account][key] = _positions[account].length;
        emit PositionSubmitted(account, position.vault, position.positionTicket, position.timestamp);
    }

    /// @dev Drop one cached position by its coordinates. Idempotent — returns false (and emits nothing) if the tuple
    ///      was not cached, true if it was removed (emitting `PositionCleared`).
    function _removePositionByCoords(address account, address vault, uint256 positionTicket, uint256 timestamp)
        internal
        returns (bool)
    {
        bytes32 key = _key(vault, positionTicket, timestamp);
        if (_positionIdxPlus1[account][key] == 0) return false;
        _removePosition(account, key);
        emit PositionCleared(account, vault, positionTicket, timestamp);
        return true;
    }

    /// @dev Delete the account's entire cached position set (storage only, no event).
    function _clearPositions(address account) internal {
        ExitPosition[] storage list = _positions[account];
        for (uint256 i; i < list.length; ++i) {
            delete _positionIdxPlus1[account][_key(list[i].vault, list[i].positionTicket, list[i].timestamp)];
        }
        delete _positions[account];
    }

    function _removePosition(address account, bytes32 key) private {
        uint256 idxPlus1 = _positionIdxPlus1[account][key];
        if (idxPlus1 == 0) return;
        uint256 idx = idxPlus1 - 1;
        ExitPosition[] storage list = _positions[account];
        uint256 lastIdx = list.length - 1;
        if (idx != lastIdx) {
            ExitPosition memory last = list[lastIdx];
            list[idx] = last;
            _positionIdxPlus1[account][_key(last.vault, last.positionTicket, last.timestamp)] = idx + 1;
        }
        list.pop();
        delete _positionIdxPlus1[account][key];
    }

    //
    // Internal — valuation
    //

    /// @inheritdoc SingleAssetAssistedGetters
    /// @dev Total assets owed across the account's cached positions, valued from live on-chain reads. Never reverts.
    function _owedAmount(address account) internal view override returns (uint256 total) {
        ExitPosition[] memory list = _positions[account];
        for (uint256 i; i < list.length; ++i) {
            (uint256 claimable, uint256 locked) =
                _owedForPosition(account, list[i].vault, list[i].positionTicket, list[i].timestamp);
            total += claimable + locked;
        }
    }

    /// @dev Assets owed for a single exit position, split into its claimable and locked portions. Both are 0 if the
    ///      position does not belong to `account` / is claimed / invalid. Mirrors StakeWise's own queue math:
    ///        - `idx = getExitQueueIndex(ticket)`; `idx == -1` ⇒ not yet checkpointed. Passing an out-of-range index to
    ///          `calculateExitedAssets` makes it return `(left = full queued shares, 0, 0)` without reverting, so the
    ///          still-queued portion is valued via `convertToAssets`.
    ///        - otherwise the checkpointed `exitedAssets` are claimable and `leftShares` is the still-queued remainder.
    ///      The checkpointed exited portion counts as claimable ONLY once StakeWise's post-checkpoint delay has elapsed
    ///      (`block.timestamp >= timestamp + EXIT_CLAIM_DELAY`); until then it is locked. The still-queued remainder is
    ///      always locked. The owed *total* (`claimable + locked`) is unaffected by the gate. All external reads
    ///      try/catch to 0.
    function _owedForPosition(address account, address vault, uint256 positionTicket, uint256 timestamp)
        internal
        view
        returns (uint256 claimable, uint256 locked)
    {
        IStakeWiseExitVault v = IStakeWiseExitVault(vault);

        int256 idx;
        try v.getExitQueueIndex(positionTicket) returns (int256 i) {
            idx = i;
        } catch {
            return (0, 0);
        }
        uint256 queryIdx = idx < 0 ? type(uint256).max : uint256(idx);

        uint256 leftShares;
        uint256 exitedAssets;
        try v.calculateExitedAssets(account, positionTicket, timestamp, queryIdx) returns (
            uint256 leftTickets, uint256, uint256 exited
        ) {
            leftShares = leftTickets;
            exitedAssets = exited;
        } catch {
            return (0, 0);
        }

        uint256 queued;
        if (leftShares > 0) {
            try v.convertToAssets(leftShares) returns (uint256 a) {
                queued = a;
            } catch {
                return (0, 0);
            }
        }
        if (block.timestamp >= timestamp + EXIT_CLAIM_DELAY) {
            claimable = exitedAssets;
            locked = queued;
        } else {
            claimable = 0;
            locked = exitedAssets + queued;
        }
    }

    function _key(address vault, uint256 positionTicket, uint256 timestamp) private pure returns (bytes32) {
        return keccak256(abi.encode(vault, positionTicket, timestamp));
    }
}

/// @notice Minimal interface for a StakeWise V3 vault's exit-queue reads.
interface IStakeWiseExitVault {
    /// @notice Checkpoint index for a position ticket, or -1 if not yet checkpointed (fully pending).
    function getExitQueueIndex(uint256 positionTicket) external view returns (int256);

    /// @notice For the exit request keyed by `(receiver, timestamp, positionTicket)`: shares still queued, tickets
    ///         that exited, and the assets those exited tickets are worth. Returns all zero for a tuple that is not a
    ///         live exit request for `receiver`.
    function calculateExitedAssets(address receiver, uint256 positionTicket, uint256 timestamp, uint256 exitQueueIndex)
        external
        view
        returns (uint256 leftTickets, uint256 exitedTickets, uint256 exitedAssets);

    /// @notice Current asset value of `shares` vault shares.
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @notice Minimal interface for the StakeWise VaultsRegistry.
interface IStakeWiseVaultsRegistry {
    /// @notice Whether `vault` is a StakeWise-registered vault.
    function vaults(address vault) external view returns (bool);
}
