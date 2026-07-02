// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {AssistedCoordCache} from "src/balances/AssistedBalanceAdapters/AssistedCoordCache.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title Stader Withdrawal Queue Balance Adapter (id-cached, assistant-fed)
/// @author KPK
/// @notice Reports the in-flight ETH owed to an account from open requests in Stader's `UserWithdrawalManager`.
///         Requesting an unstake burns ETHx and records a sequential `requestId` owned by the account; until claimed,
///         the value lives as ETH owed by the manager and is invisible to a wallet/receipt-token scan. Rather than
///         enumerate `requestIdsByUserAddress` on-chain (griefable — anyone can `requestWithdraw(amount, _owner=victim)`
///         to bloat a victim's array), each account tracks its **own** request ids via {submit}, keyed on `msg.sender`.
///         The intended caller is a Safe that **delegatecalls** the `StaderWithdrawalQueueAssistant`.
/// @dev Member of the permissionless assistant-fed assisted family ([ADR 0018](../../../docs/decisions/0018-assistant-fed-assisted-balance-adapters.md)),
///      extending the single {AssistedCoordCache}: the coordinate is `abi.encode(requestId)`. The cache stores **only
///      request ids, never amounts**; every read re-verifies ownership (`userWithdrawRequests(id).owner == account`) and
///      re-values live → a stale or wrong id can only under-report NAV. Denominated in `UNDERLYING_TOKEN` (WETH); the
///      claim pays native ETH whose amount is fixed at finalization. Emits ONE `Supplied` leg per owned cached request
///      (finalized → `isLocked=false`, pending → `true`), all sharing `positionId = abi.encode(USER_WITHDRAWAL_MANAGER)`,
///      the request id in `positionInstanceId`.
contract StaderWithdrawalQueueAssistedBalanceAdapter is AssistedCoordCache, IPositionDescribable {
    /// @notice Hard cap on cached request ids per account (read-loop gas bound). A real account never approaches it.
    uint256 public constant MAX_REQUESTS = 256;

    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.STADER;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.STADER;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.STADER_WITHDRAWAL;

    /// @notice Stader UserWithdrawalManager contract (source of ownership + per-request data).
    IUserWithdrawalManager public immutable USER_WITHDRAWAL_MANAGER;

    /// @param userWithdrawalManager_ Address of Stader's UserWithdrawalManager contract. Must be a contract.
    /// @param underlyingToken_       Address of the asset positions are denominated in (WETH). Must be non-zero.
    /// @param navCalculator_         The NAVCalculator address used for asset-registry filtering. Must be a contract.
    constructor(address userWithdrawalManager_, address underlyingToken_, address navCalculator_)
        AssistedCoordCache(underlyingToken_, navCalculator_)
    {
        if (userWithdrawalManager_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(userWithdrawalManager_, "UserWithdrawalManager");
        USER_WITHDRAWAL_MANAGER = IUserWithdrawalManager(userWithdrawalManager_);
    }

    //
    // Typed feed surface (permissionless, msg.sender-keyed) — routes to the shared coordinate cache.
    //

    /// @notice Track `requestId` for the caller (idempotent). **Reverts** `CoordinateNotOwned` if not currently owned by
    ///         the caller, and `CoordinateCacheFull` past {MAX_REQUESTS}.
    function submit(uint256 requestId) external {
        _submitCoord(abi.encode(requestId));
    }

    /// @notice Stop tracking `requestId` for the caller (once claimed). **Reverts** `CoordinateNotCached` if not tracked,
    ///         and `CoordinateStillLive` if still owned (not yet claimed).
    function remove(uint256 requestId) external {
        _removeCoord(abi.encode(requestId));
    }

    /// @notice Candidate request ids currently cached for `account` (display/debug; not ownership-filtered).
    function requestIdsOf(address account) external view returns (uint256[] memory ids) {
        bytes[] memory coords = _cachedCoords(account);
        ids = new uint256[](coords.length);
        for (uint256 i; i < coords.length; ++i) {
            ids[i] = abi.decode(coords[i], (uint256));
        }
    }

    /// @inheritdoc IPositionDescribable
    function protocolName() external pure returns (string memory) {
        return "Stader";
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `["Withdrawal Queue", "ETHx"]` — category + the receipt-token symbol (matching the sibling queues).
    function positionLabels(bytes calldata) external pure override returns (string[] memory out) {
        out = new string[](2);
        out[0] = "Withdrawal Queue";
        out[1] = "ETHx";
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
        return MAX_REQUESTS;
    }

    /// @inheritdoc AssistedCoordCache
    function _maxLegsPerCoord() internal pure override returns (uint256) {
        return 1;
    }

    /// @inheritdoc AssistedCoordCache
    function _coordId(bytes memory coord) internal pure override returns (uint256) {
        return abi.decode(coord, (uint256));
    }

    /// @inheritdoc AssistedCoordCache
    /// @dev The request must be owned by the caller (the manager records it under `_owner`); a claimed/unknown id reads
    ///      back with `owner == address(0)`.
    function _validateCoord(address account, bytes memory coord) internal view override {
        uint256 requestId = abi.decode(coord, (uint256));
        if (_ownerOf(requestId) != account) revert CoordinateNotOwned(account, requestId);
    }

    /// @inheritdoc AssistedCoordCache
    /// @dev Removable once claimed — the manager deletes the request on claim, so its owner reads back as `address(0)`.
    function _removable(address account, bytes memory coord) internal view override returns (bool) {
        return _ownerOf(abi.decode(coord, (uint256))) != account;
    }

    /// @inheritdoc AssistedCoordCache
    /// @notice ONE ETH `Supplied` leg for the owned cached request (finalized → `isLocked=false`, pending → `true`).
    function _valueCoord(address account, bytes memory coord, INAVCalculator.Asset memory underlying)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        uint256 requestId = abi.decode(coord, (uint256));
        (uint256 amount, bool finalized) = _owedForRequest(account, requestId);
        if (amount == 0) return new INAVCalculator.PositionBalance[](0);
        INAVCalculator.PositionBalance[] memory legs = new INAVCalculator.PositionBalance[](1);
        legs[0] = INAVCalculator.PositionBalance({
            balanceAsset: underlying,
            balanceAdapter: address(this),
            amount: amount,
            isDebt: false,
            protocolBrand: PROTOCOL_BRAND,
            protocolId: PROTOCOL_ID,
            protocolSubId: PROTOCOL_SUB_ID,
            positionId: abi.encode(address(USER_WITHDRAWAL_MANAGER)),
            positionKind: PositionKind.Supplied,
            isLocked: !finalized,
            positionInstanceId: bytes32(requestId)
        });
        return legs;
    }

    /// @dev ETH owed for a single request and whether it is finalized. `amount` is 0 if not owned by `account` (claimed).
    ///      finalized (`ethFinalized > 0`) → exact `ethFinalized`; pending → the rate-converted `ethExpected` estimate.
    function _owedForRequest(address account, uint256 requestId)
        internal
        view
        returns (uint256 amount, bool finalized)
    {
        (address owner,, uint256 ethExpected, uint256 ethFinalized,) =
            USER_WITHDRAWAL_MANAGER.userWithdrawRequests(requestId);
        if (owner != account) return (0, false);
        if (ethFinalized > 0) return (ethFinalized, true);
        return (ethExpected, false);
    }

    /// @dev The request's current owner (zero after a claim — the manager deletes the entry; the getter never reverts).
    function _ownerOf(uint256 requestId) internal view returns (address owner) {
        (owner,,,,) = USER_WITHDRAWAL_MANAGER.userWithdrawRequests(requestId);
    }
}

/// @notice Minimal interface for Stader's UserWithdrawalManager.
interface IUserWithdrawalManager {
    /// @return owner Owner of the request (zero after a successful claim).
    /// @return ethXAmount Amount of ETHx originally burned to create the request.
    /// @return ethExpected Estimated ETH owed at request time (rate-converted).
    /// @return ethFinalized Exact ETH owed once the batch is finalized; zero before finalization.
    /// @return requestBlock Block at which the request was created.
    function userWithdrawRequests(uint256 requestId)
        external
        view
        returns (address owner, uint256 ethXAmount, uint256 ethExpected, uint256 ethFinalized, uint256 requestBlock);
}
