// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalanceAdapter} from "../IBalanceAdapter.sol";
import {IPositionDescribable} from "../IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {InvalidArguments} from "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Lido Withdrawal Queue Balance Adapter
/// @author KPK
/// @notice Reports the ETH owed to an account from open requests in Lido's `WithdrawalQueueERC721`.
/// @dev When a user requests an unstake, stETH is locked and an ERC721 request id is minted. The
///      claim pays out **native ETH** (the stETH is burned), so the position is denominated in ETH —
///      not stETH — matching what the account actually receives (and pricing it via ETH/USD rather
///      than stETH/USD, so a stETH depeg can't mis-value a claim that settles in full ETH). While
///      queued the value is invisible to wallet/receipt-token adapters. This adapter enumerates the
///      account's request ids (`getWithdrawalRequests`), reads their status (`getWithdrawalStatus`),
///      and emits up to **two positions under a single static positionId** denominated in
///      `UNDERLYING_TOKEN` (native ETH): a claimable leg (`isLocked = false`, finalized requests) and a
///      locked/pending leg (`isLocked = true`, not-yet-finalized requests). `amountOfStETH` is fixed
///      at request time and equals the ETH paid on claim (verified on-chain; it can differ only on a
///      negative rebase between request and finalization, where Lido caps the payout — for finalized
///      requests the exact `getClaimableEther` is used). NAVCalculator prices each via the registered
///      ETH feed; the balance methods (`getAdapterBalances`) still report the summed total.
contract LidoWithdrawalQueueBalanceAdapter is IBalanceAdapter, IPositionDescribable {
    //
    // Constants
    //

    /// @notice Hard cap on the number of open requests an account may have for this adapter to read it.
    /// @dev Bounds gas: an account whose open-request count (`balanceOf`) exceeds this is skipped
    ///      (reported as 0) so a pathological account can't make NAV reads run out of gas — an
    ///      out-of-gas revert is NOT caught by NAVCalculator's try/catch, so it would DoS the whole
    ///      NAV call. The check is on `balanceOf` rather than the returned id array because Lido's
    ///      queue is not `ERC721Enumerable`, so `getWithdrawalRequests` can only return the full set.
    ///      In practice an account never has more than a handful of requests.
    uint256 public constant MAX_REQUESTS_PROBED = 256;

    bytes32 private constant PROTOCOL_ID = ProtocolIds.LIDO_WITHDRAWAL;

    //
    // State
    //

    /// @notice Lido WithdrawalQueueERC721 contract.
    ILidoWithdrawalQueue public immutable WITHDRAWAL_QUEUE;

    /// @notice The asset under which positions are reported — the asset Lido pays on claim (native ETH).
    /// @dev Pricing is added by NAVCalculator from this asset's registered price feed (ETH/USD).
    address public immutable UNDERLYING_TOKEN;

    /// @notice Reference to NAVCalculator for asset registry access.
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param withdrawalQueue_ Address of Lido's WithdrawalQueueERC721 contract.
    /// @param underlyingToken_ Address of the asset positions are denominated in — what Lido pays on
    ///        claim (native ETH; the ERC-7528 sentinel on mainnet).
    /// @param navCalculator_ The NAVCalculator address used for asset-registry filtering.
    constructor(address withdrawalQueue_, address underlyingToken_, address navCalculator_) {
        if (withdrawalQueue_ == address(0) || underlyingToken_ == address(0)) {
            revert InvalidArguments();
        }
        require(withdrawalQueue_.code.length > 0, "WithdrawalQueue must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        WITHDRAWAL_QUEUE = ILidoWithdrawalQueue(withdrawalQueue_);
        UNDERLYING_TOKEN = underlyingToken_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // Balance computation
    //

    /// @notice Sums the ETH owed across `account`'s open (un-claimed) withdrawal requests.
    /// @dev Reads `balanceOf` (the count of open request NFTs — claiming burns the NFT) FIRST, in
    ///      O(1), so the unbounded id list is never materialised when the count is pathological.
    ///      Lido's `WithdrawalQueueERC721` is NOT `ERC721Enumerable` (no `tokenOfOwnerByIndex`) and
    ///      `getWithdrawalRequests` returns the *entire* id set, so there is no way to read a bounded
    ///      slice. If the count exceeds `MAX_REQUESTS_PROBED` we skip (return 0) rather than risk
    ///      OOG'ing the NAV read on a list an attacker can inflate by transferring withdrawal NFTs in
    ///      — an OOG is NOT caught by NAVCalculator's try/catch. A real account never approaches the cap.
    /// @dev Per request (since the position is denominated in ETH):
    ///      - **finalized** → use Lido's exact claimable ETH (`getClaimableEther`). Finalization can
    ///        lock in *less* than `amountOfStETH` after a negative rebase, so using `amountOfStETH`
    ///        here would overstate NAV.
    ///      - **not yet finalized** → fall back to `amountOfStETH` (the redemption rate isn't fixed
    ///        until finalization; never invent one). It equals the ETH paid in the normal case.
    ///      The claimable lookup is done per request (single-element arrays) — see the inline note on
    ///      `findCheckpointHints`'s ascending-sorted requirement. Claimed requests are skipped.
    function _ethOwed(address account) internal view returns (uint256 total) {
        if (account == address(0)) {
            return 0;
        }

        uint256 count = WITHDRAWAL_QUEUE.balanceOf(account);
        if (count == 0 || count > MAX_REQUESTS_PROBED) {
            return 0;
        }

        uint256[] memory ids = WITHDRAWAL_QUEUE.getWithdrawalRequests(account);
        ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory statuses = WITHDRAWAL_QUEUE.getWithdrawalStatus(ids);
        uint256 lastCheckpoint = WITHDRAWAL_QUEUE.getLastCheckpointIndex();

        for (uint256 i = 0; i < statuses.length; i++) {
            if (statuses[i].isClaimed) {
                continue;
            }
            if (statuses[i].isFinalized && lastCheckpoint != 0) {
                // Resolve the exact claimable ETH one request at a time. `findCheckpointHints`
                // reverts (`RequestIdsNotSorted`) unless its id array is ascending-sorted, and
                // `getWithdrawalRequests` returns the owner's EnumerableSet order — NOT guaranteed
                // sorted (a claim does swap-and-pop, reordering the set). A single-element array is
                // trivially sorted, so this sidesteps the requirement without sorting in-contract;
                // it also avoids the hint/claimable calls entirely for not-yet-finalized requests.
                uint256[] memory one = new uint256[](1);
                one[0] = ids[i];
                uint256[] memory hint = WITHDRAWAL_QUEUE.findCheckpointHints(one, 1, lastCheckpoint);
                total += WITHDRAWAL_QUEUE.getClaimableEther(one, hint)[0];
            } else {
                total += statuses[i].amountOfStETH;
            }
        }
    }

    //
    // IBalanceAdapter
    //

    /// @inheritdoc IBalanceAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](1);
        assets[0] = UNDERLYING_TOKEN;
        return assets;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IPositionDescribable).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function protocolName() external pure returns (string memory) {
        return "Lido";
    }

    function positionLabels(bytes calldata) external pure returns (string[] memory) {
        string[] memory out = new string[](1);
        out[0] = "stETH Withdrawal Queue";
        return out;
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (asset == address(0) || asset != UNDERLYING_TOKEN) {
            return (0, false);
        }
        return (_ethOwed(account), false);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        if (account == address(0)) {
            return (new address[](0), new uint256[](0), new bool[](0));
        }

        uint256 total = _ethOwed(account);
        if (total == 0) {
            return (new address[](0), new uint256[](0), new bool[](0));
        }

        assets = new address[](1);
        amounts = new uint256[](1);
        isDebt = new bool[](1);
        assets[0] = UNDERLYING_TOKEN;
        amounts[0] = total;
        isDebt[0] = false;
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice Returns up to TWO ETH-denominated `Supplied` legs under a single static positionId — one claimable
    ///         (`isLocked = false`) and one locked/pending (`isLocked = true`).
    /// @dev Both legs share the static `positionId = abi.encode(address(WITHDRAWAL_QUEUE))` and are distinguished only
    ///      by `isLocked`. The account's un-claimed requests are aggregated into two sums: finalized requests
    ///      (`isFinalized && lastCheckpoint != 0`) contribute their exact `getClaimableEther` to the claimable leg;
    ///      all others contribute `amountOfStETH` to the locked leg. Claimed requests are skipped (the NFT is burned).
    ///      The two legs sum to `_ethOwed`'s total. A zero-amount leg is omitted. Dropped entirely if the underlying
    ///      asset is not registered in NAVCalculator. Bounded by `MAX_REQUESTS_PROBED` (over the cap → no positions).
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        // Asset-filter mismatch → no positions for this adapter.
        if (assetFilter != address(0) && assetFilter != UNDERLYING_TOKEN) {
            return new INAVCalculator.PositionBalance[](0);
        }
        if (account == address(0)) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Bound work before materialising the unbounded id list (see `_ethOwed`).
        uint256 count = WITHDRAWAL_QUEUE.balanceOf(account);
        if (count == 0 || count > MAX_REQUESTS_PROBED) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Underlying must be registered in NAVCalculator for the position to count in NAV.
        INAVCalculator.Asset memory underlying;
        {
            INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
            bool registered;
            for (uint256 i = 0; i < reg.length; i++) {
                if (reg[i].asset == UNDERLYING_TOKEN) {
                    underlying = reg[i];
                    registered = true;
                    break;
                }
            }
            if (!registered) {
                return new INAVCalculator.PositionBalance[](0);
            }
        }

        uint256[] memory ids = WITHDRAWAL_QUEUE.getWithdrawalRequests(account);
        ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory statuses = WITHDRAWAL_QUEUE.getWithdrawalStatus(ids);
        uint256 lastCheckpoint = WITHDRAWAL_QUEUE.getLastCheckpointIndex();

        uint256 claimable;
        uint256 locked;
        for (uint256 i = 0; i < ids.length; i++) {
            if (statuses[i].isClaimed) {
                continue;
            }
            if (statuses[i].isFinalized && lastCheckpoint != 0) {
                // Per-request claimable lookup (single-element array sidesteps the ascending-sort
                // requirement of `findCheckpointHints` — see `_ethOwed`).
                uint256[] memory one = new uint256[](1);
                one[0] = ids[i];
                uint256[] memory hint = WITHDRAWAL_QUEUE.findCheckpointHints(one, 1, lastCheckpoint);
                claimable += WITHDRAWAL_QUEUE.getClaimableEther(one, hint)[0];
            } else {
                locked += statuses[i].amountOfStETH;
            }
        }

        return _statusLegs(underlying, abi.encode(address(WITHDRAWAL_QUEUE)), claimable, locked);
    }

    /// @dev Up to two `Supplied` legs sharing the static positionId, distinguished by isLocked. Zero legs omitted.
    function _statusLegs(
        INAVCalculator.Asset memory underlying,
        bytes memory positionId,
        uint256 claimable,
        uint256 locked
    ) internal view returns (INAVCalculator.PositionBalance[] memory positions) {
        uint256 nLegs = (claimable > 0 ? 1 : 0) + (locked > 0 ? 1 : 0);
        positions = new INAVCalculator.PositionBalance[](nLegs);
        uint256 j;
        if (claimable > 0) {
            positions[j++] = INAVCalculator.PositionBalance({
                balanceAsset: underlying,
                balanceAdapter: address(this),
                amount: claimable,
                isDebt: false,
                protocolId: PROTOCOL_ID,
                positionId: positionId,
                positionKind: PositionKind.Supplied,
                isLocked: false
            });
        }
        if (locked > 0) {
            positions[j++] = INAVCalculator.PositionBalance({
                balanceAsset: underlying,
                balanceAdapter: address(this),
                amount: locked,
                isDebt: false,
                protocolId: PROTOCOL_ID,
                positionId: positionId,
                positionKind: PositionKind.Supplied,
                isLocked: true
            });
        }
    }
}

/// @notice Minimal interface for Lido's WithdrawalQueueERC721.
interface ILidoWithdrawalQueue {
    /// @notice Per-request status tuple.
    /// @param amountOfStETH stETH locked at request time (the value owed).
    /// @param amountOfShares Lido shares locked at request time.
    /// @param owner Owner of the request NFT.
    /// @param timestamp Request creation timestamp.
    /// @param isFinalized Whether the request has been finalized by Lido's oracle/accounting report (claimable).
    /// @param isClaimed Whether the ETH has already been claimed (request burned).
    struct WithdrawalRequestStatus {
        uint256 amountOfStETH;
        uint256 amountOfShares;
        address owner;
        uint256 timestamp;
        bool isFinalized;
        bool isClaimed;
    }

    /// @notice ERC721 balance = number of the account's open (un-claimed) request NFTs.
    /// @dev O(1); used to bound work before calling `getWithdrawalRequests` (which returns the full set).
    function balanceOf(address owner) external view returns (uint256);

    /// @notice Returns all request ids owned by `_owner` (full on-chain enumeration).
    function getWithdrawalRequests(address _owner) external view returns (uint256[] memory requestsIds);

    /// @notice Returns the status for each of `_requestIds`.
    function getWithdrawalStatus(uint256[] calldata _requestIds)
        external
        view
        returns (WithdrawalRequestStatus[] memory statuses);

    /// @notice Index of the last finalization checkpoint (0 if none yet).
    function getLastCheckpointIndex() external view returns (uint256);

    /// @notice Per-request checkpoint hint for `getClaimableEther`; 0 for requests not yet finalized.
    function findCheckpointHints(uint256[] calldata _requestIds, uint256 _firstIndex, uint256 _lastIndex)
        external
        view
        returns (uint256[] memory hintIds);

    /// @notice Exact ETH claimable per request given its checkpoint hint; 0 for not-finalized/claimed.
    function getClaimableEther(uint256[] calldata _requestIds, uint256[] calldata _hints)
        external
        view
        returns (uint256[] memory claimableEthValues);
}
