// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {AssistedNftIdCache} from "src/balances/AssistedBalanceAdapters/AssistedNftIdCache.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title Stader Withdrawal Queue Balance Adapter (id-cached, wrapper-fed)
/// @author KPK
/// @notice Reports the in-flight ETH owed to an account from open requests in Stader's `UserWithdrawalManager`.
///         Requesting an unstake burns ETHx and records a sequential `requestId` owned by the account; until claimed,
///         the value lives as ETH owed by the manager and is invisible to a wallet/receipt-token scan. Rather than
///         enumerate `requestIdsByUserAddress` on-chain (griefable — anyone can `requestWithdraw(amount, _owner=victim)`
///         to bloat a victim's array past the probe cap), each account tracks its **own** request ids via {submit},
///         keyed on `msg.sender`. The intended caller is a Safe that **delegatecalls** the `StaderWithdrawalQueueWrapper`,
///         which forwards the Stader `requestWithdraw`/`claim` and updates this cache atomically in the same transaction.
/// @dev Member of the permissionless wrapper-fed assisted family ([ADR 0018](../../../docs/decisions/0018-wrapper-fed-assisted-balance-adapters.md)),
///      extending {AssistedNftIdCache}: the cache stores **only request ids, never amounts**, every read re-verifies
///      ownership (`userWithdrawRequests(id).owner == account`) and re-values live, so a stale or wrong id can only
///      under-report NAV. Denominated in `UNDERLYING_TOKEN` (WETH): the claim pays native ETH whose amount is fixed at
///      finalization. Emits ONE `Supplied` leg per owned cached request, all sharing the static
///      `positionId = abi.encode(address(USER_WITHDRAWAL_MANAGER))`; each leg's `isLocked` reflects the request's state
///      (finalized → `false`, pending → `true`) and its request id rides in `positionInstanceId`. The default
///      {_removable} (removable iff no longer owned) is correct: a claimed request has its owner deleted to `address(0)`.
contract StaderWithdrawalQueueBalanceAdapter is AssistedNftIdCache, IPositionDescribable {
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
        AssistedNftIdCache(underlyingToken_, navCalculator_)
    {
        if (userWithdrawalManager_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(userWithdrawalManager_, "UserWithdrawalManager");
        USER_WITHDRAWAL_MANAGER = IUserWithdrawalManager(userWithdrawalManager_);
    }

    /// @notice Candidate request ids currently cached for `account` (display/debug; not ownership-filtered).
    function requestIdsOf(address account) external view returns (uint256[] memory) {
        return _cachedTokenIds(account);
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

    /// @inheritdoc AssistedNftIdCache
    function _maxTokenIds() internal pure override returns (uint256) {
        return MAX_REQUESTS;
    }

    /// @inheritdoc AssistedNftIdCache
    function _maxLegsPerId() internal pure override returns (uint256) {
        return 1;
    }

    /// @inheritdoc AssistedNftIdCache
    /// @dev A claimed request has its manager storage entry deleted (`owner == address(0)`), so it reads back unowned.
    function _ownerOf(uint256 requestId) internal view override returns (address owner, bool ok) {
        (address o,,,,) = USER_WITHDRAWAL_MANAGER.userWithdrawRequests(requestId);
        return (o, o != address(0));
    }

    /// @inheritdoc AssistedNftIdCache
    /// @notice ONE ETH `Supplied` leg per owned cached request (finalized → `isLocked=false`, pending → `true`); the
    ///         request id rides in `positionInstanceId`, all sharing `positionId = abi.encode(USER_WITHDRAWAL_MANAGER)`.
    function _valueTokenId(address account, uint256 requestId, INAVCalculator.Asset memory underlying)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
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

    /// @dev ETH owed for a single request and whether it is finalized. `amount` is 0 if the request is not owned by
    ///      `account` (claimed → owner deleted). Mirrors the manager's accounting: finalized (`ethFinalized > 0`) → the
    ///      exact `ethFinalized`; pending → the rate-converted `ethExpected` estimate at request time.
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
