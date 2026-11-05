// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {AssistedCoordCache} from "./AssistedCoordCache.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title StakeWise V3 Exit-Queue Assisted Balance Adapter (coordinate-cached, assistant-fed)
/// @author KPK
/// @notice Reports the in-flight assets owed to an account in StakeWise V3's exit queue, valued entirely from live
///         on-chain reads. The exit position's coordinate is a **tuple** `(vault, positionTicket, timestamp)` — the
///         `StakeWiseV3ExitQueueAssistant` a depositor Safe delegatecalls records it here (adapter sees `msg.sender = Safe`),
///         in the same tx it enters/claims the queue. The exit position is owned on-chain by that same Safe
///         (`receiver = the Safe`), so the valuation (keyed on `receiver = account`) needs no extra bookkeeping.
/// @dev Assistant-fed member ([ADR 0018](../../../docs/decisions/0018-assistant-fed-assisted-balance-adapters.md)),
///      extending {AssistedCoordCache} (tuple coordinate, not a bare uint256). The cache stores **only coordinates,
///      never amounts**; every read values live against `receiver = account` (a tuple that isn't the account's resolves
///      to zero owed and is dropped) → under-report only. StakeWise exit positions have no `ownerOf`, so the ownership
///      proxy is `calculateExitedAssets(account, …) > 0`. Emits up to two `Supplied` legs per cached position — a
///      claimable (`isLocked=false`) and a locked/pending (`isLocked=true`) — sharing `positionId = abi.encode(vault)`,
///      the ticket in `positionInstanceId`. Denominated in the chain's staking asset (native ETH on mainnet).
contract StakeWiseV3ExitQueueAssistedBalanceAdapter is AssistedCoordCache, IPositionDescribable {
    /// @notice Hard cap on cached exit positions per account (read-loop gas bound).
    uint256 public constant MAX_POSITIONS = 256;

    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.STAKEWISE;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.STAKEWISE_V3;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.STAKEWISE_V3_EXIT;

    /// @notice StakeWise VaultsRegistry — `vaults(address)` gates which vaults the cache accepts (write-time hygiene).
    address public immutable VAULTS_REGISTRY;

    /// @notice StakeWise's post-checkpoint claim delay in seconds (24h on V3 mainnet). The exited-but-still-delayed
    ///         portion is reported locked until the delay elapses; it does not affect the owed *amount*.
    uint256 public immutable EXIT_CLAIM_DELAY;

    /// @notice Display symbol of StakeWise's receipt/LST token (`"osETH"` mainnet). Empty ⇒ bare `["Exit Queue"]`.
    string public receiptSymbol;

    /// @param vaultsRegistry_  StakeWise VaultsRegistry. Must be a contract.
    /// @param underlyingToken_ Payout asset (native-ETH sentinel on mainnet). Must be non-zero.
    /// @param receiptSymbol_   Display symbol of StakeWise's receipt/LST token (`"osETH"` mainnet). May be empty.
    /// @param navCalculator_   NAVCalculator. Must be a contract.
    /// @param exitClaimDelay_  StakeWise's post-checkpoint claim delay in seconds (`86400` on V3 mainnet). Must be > 0.
    /// @param admin_           `DEFAULT_ADMIN_ROLE` holder (grants the keeper's `SUBMITTER_ROLE`). Must be non-zero.
    constructor(
        address vaultsRegistry_,
        address underlyingToken_,
        string memory receiptSymbol_,
        address navCalculator_,
        uint256 exitClaimDelay_,
        address admin_
    ) AssistedCoordCache(underlyingToken_, navCalculator_, admin_) {
        if (vaultsRegistry_ == address(0) || exitClaimDelay_ == 0) revert InvalidArguments();
        AddressCheckLib.requireContract(vaultsRegistry_, "VaultsRegistry");
        VAULTS_REGISTRY = vaultsRegistry_;
        receiptSymbol = receiptSymbol_;
        EXIT_CLAIM_DELAY = exitClaimDelay_;
    }

    //
    // Typed owner feed surface (msg.sender-keyed; the keeper path is in the base, ADR 0030).
    //

    /// @notice Track one of the caller's own exit positions. Idempotent. **Reverts** `InvalidCoordinate` if the vault is
    ///         not StakeWise-registered, `CoordinateNotOwned` if the tuple resolves to no live owed amount for the
    ///         caller (the on-chain ownership proxy), and `CoordinateCacheFull` past {MAX_POSITIONS}.
    function submit(address vault, uint256 positionTicket, uint256 timestamp) external {
        _submitCoord(abi.encode(vault, positionTicket, timestamp));
    }

    /// @notice Stop tracking one of the caller's own exit positions (once claimed). **Reverts** `CoordinateNotCached`
    ///         if the tuple is not tracked, and `CoordinateStillLive` if it is still owed (not yet claimed).
    function remove(address vault, uint256 positionTicket, uint256 timestamp) external {
        _removeCoord(abi.encode(vault, positionTicket, timestamp));
    }

    /// @notice Candidate exit positions currently cached for `account` (display/debug; not staleness-filtered).
    function positionsOf(address account) external view returns (ExitPosition[] memory out) {
        bytes[] memory coords = _cachedCoords(account);
        out = new ExitPosition[](coords.length);
        for (uint256 i; i < coords.length; ++i) {
            (address vault, uint256 ticket, uint256 timestamp) = abi.decode(coords[i], (address, uint256, uint256));
            out[i] = ExitPosition(vault, ticket, timestamp);
        }
    }

    /// @param vault          StakeWise V3 vault the exit position lives in.
    /// @param positionTicket Ticket returned by `enterExitQueue`.
    /// @param timestamp      Entry block's `block.timestamp` — part of the exit-request key.
    struct ExitPosition {
        address vault;
        uint256 positionTicket;
        uint256 timestamp;
    }

    /// @inheritdoc IPositionDescribable
    function protocolName() external pure returns (string memory) {
        return "StakeWise V3";
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `["Exit Queue", "<receiptSymbol>"]`, or bare `["Exit Queue"]` if {receiptSymbol} is empty.
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

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IPositionDescribable).interfaceId || super.supportsInterface(interfaceId);
    }

    //
    // Hooks
    //

    /// @inheritdoc AssistedCoordCache
    function _maxCoords() internal pure override returns (uint256) {
        return MAX_POSITIONS;
    }

    /// @inheritdoc AssistedCoordCache
    function _maxLegsPerCoord() internal pure override returns (uint256) {
        return 2;
    }

    /// @inheritdoc AssistedCoordCache
    function _coordId(bytes memory coord) internal pure override returns (uint256 positionTicket) {
        // Decoded as raw words (not `address`), so a coordinate with dirty address bits still yields its ticket for the
        // typed `Coordinate*` errors instead of an opaque decode revert.
        (, positionTicket,) = abi.decode(coord, (uint256, uint256, uint256));
    }

    /// @inheritdoc AssistedCoordCache
    /// @dev Vault must be StakeWise-registered (else `InvalidCoordinate`) AND the tuple must resolve to a live owed
    ///      amount for `account` — the on-chain ownership proxy `calculateExitedAssets(account, …) > 0` — else
    ///      `CoordinateNotOwned`.
    function _validateCoord(address account, bytes memory coord) internal view override {
        (address vault, uint256 ticket, uint256 timestamp) = abi.decode(coord, (address, uint256, uint256));
        bool registeredVault;
        try IStakeWiseVaultsRegistry(VAULTS_REGISTRY).vaults(vault) returns (bool ok) {
            registeredVault = ok;
        } catch {
            registeredVault = false;
        }
        if (!registeredVault) revert InvalidCoordinate(account, ticket);
        (uint256 c, uint256 l) = _owedForPosition(account, vault, ticket, timestamp);
        if (c + l == 0) revert CoordinateNotOwned(account, ticket);
    }

    /// @inheritdoc AssistedCoordCache
    function _coordLength() internal pure override returns (uint256) {
        return 96;
    }

    /// @inheritdoc AssistedCoordCache
    /// @dev Dead only when `calculateExitedAssets` SUCCEEDS and reports nothing at all — StakeWise returns
    ///      `(0, 0, 0)` exactly when no request exists under `(account, timestamp, ticket)` (claimed in full, or
    ///      re-queued under a new ticket after a partial claim). Unlike {_owedForPosition}, a revert is NOT death.
    function _isDead(address account, bytes memory coord) internal view override returns (bool) {
        (address vault, uint256 ticket, uint256 timestamp) = abi.decode(coord, (address, uint256, uint256));
        IStakeWiseExitVault v = IStakeWiseExitVault(vault);
        uint256 queryIdx;
        try v.getExitQueueIndex(ticket) returns (int256 i) {
            queryIdx = i < 0 ? type(uint256).max : uint256(i);
        } catch {
            return false;
        }
        try v.calculateExitedAssets(account, ticket, timestamp, queryIdx) returns (
            uint256 leftTickets, uint256 exitedTickets, uint256 exitedAssets
        ) {
            return leftTickets == 0 && exitedTickets == 0 && exitedAssets == 0;
        } catch {
            return false;
        }
    }

    /// @inheritdoc AssistedCoordCache
    /// @dev Removable once the position is claimed/consumed — it resolves to no live owed amount for `account`.
    function _removable(address account, bytes memory coord) internal view override returns (bool) {
        (address vault, uint256 ticket, uint256 timestamp) = abi.decode(coord, (address, uint256, uint256));
        (uint256 c, uint256 l) = _owedForPosition(account, vault, ticket, timestamp);
        return c + l == 0;
    }

    /// @inheritdoc AssistedCoordCache
    /// @notice Up to two staking-asset `Supplied` legs for one cached exit position — claimable (`isLocked=false`) and
    ///         locked/pending (`isLocked=true`) — both carrying the ticket in `positionInstanceId`, sharing
    ///         `positionId = abi.encode(vault)`.
    function _valueCoord(address account, bytes memory coord, INAVCalculator.Asset memory underlying)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        (address vault, uint256 ticket, uint256 timestamp) = abi.decode(coord, (address, uint256, uint256));
        (uint256 claimable, uint256 locked) = _owedForPosition(account, vault, ticket, timestamp);
        if (claimable + locked == 0) return new INAVCalculator.PositionBalance[](0);

        bytes memory positionId = abi.encode(vault);
        bytes32 instanceId = bytes32(ticket);
        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](2);
        uint256 n;
        if (claimable > 0) tmp[n++] = _leg(underlying, claimable, positionId, instanceId, false);
        if (locked > 0) tmp[n++] = _leg(underlying, locked, positionId, instanceId, true);

        INAVCalculator.PositionBalance[] memory out = new INAVCalculator.PositionBalance[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = tmp[i];
        }
        return out;
    }

    function _leg(
        INAVCalculator.Asset memory asset,
        uint256 amount,
        bytes memory positionId,
        bytes32 instanceId,
        bool isLocked
    ) private view returns (INAVCalculator.PositionBalance memory) {
        return INAVCalculator.PositionBalance({
            balanceAsset: asset,
            balanceAdapter: address(this),
            amount: amount,
            isDebt: false,
            protocolBrand: PROTOCOL_BRAND,
            protocolId: PROTOCOL_ID,
            protocolSubId: PROTOCOL_SUB_ID,
            positionId: positionId,
            positionKind: PositionKind.Supplied,
            isLocked: isLocked,
            positionInstanceId: instanceId
        });
    }

    /// @dev Assets owed for one exit position, split into claimable and locked portions. Both 0 if the position is not
    ///      the account's / claimed / invalid. Mirrors StakeWise's queue math; checkpointed exited assets count as
    ///      claimable only once the post-checkpoint delay has elapsed. All external reads try/catch to 0.
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
}

/// @notice Minimal interface for a StakeWise V3 vault's exit-queue reads.
interface IStakeWiseExitVault {
    /// @notice Checkpoint index for a position ticket, or -1 if not yet checkpointed (fully pending).
    function getExitQueueIndex(uint256 positionTicket) external view returns (int256);

    /// @notice For the exit request keyed by `(receiver, timestamp, positionTicket)`: shares still queued, tickets that
    ///         exited, and the assets those exited tickets are worth. All zero for a tuple that is not a live request.
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
