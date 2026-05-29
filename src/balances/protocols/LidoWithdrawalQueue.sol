// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {InvalidArguments} from "src/errors.sol";
import {PositionType} from "src/utils/PositionType.sol";

/// @title Lido Withdrawal Queue Balance Oracle
/// @author kpk
/// @notice Reports stETH owed to an account from open requests in Lido's `WithdrawalQueueERC721`.
/// @dev When a user requests an unstake, stETH is locked and an ERC721 request id is minted. Until
///      claimed, the value lives as stETH owed by the queue and is invisible to wallet/receipt-token
///      oracles. This oracle enumerates the account's request ids (`getWithdrawalRequests`), reads
///      their status (`getWithdrawalStatus`), and sums `amountOfStETH` across all **un-claimed**
///      requests into a single position denominated in `UNDERLYING_TOKEN` (stETH). `amountOfStETH`
///      is fixed at request time; NAVCalculator prices it via the registered stETH feed.
contract LidoWithdrawalQueueBalanceOracle is IBalanceOracleAdapter {
    //
    // Constants
    //

    /// @notice Hard cap on the number of request ids probed per account.
    /// @dev Bounds gas so a pathological account with many open requests can't make NAV reads run
    ///      out of gas (an out-of-gas revert is NOT caught by NAVCalculator's try/catch, so it would
    ///      DoS the whole NAV call). In practice an account never has more than a handful of requests.
    uint256 public constant MAX_REQUESTS_PROBED = 256;

    //
    // State
    //

    /// @notice Lido WithdrawalQueueERC721 contract.
    ILidoWithdrawalQueue public immutable WITHDRAWAL_QUEUE;

    /// @notice The asset under which positions are reported (stETH).
    /// @dev Pricing is added by NAVCalculator from this asset's registered price feed.
    address public immutable UNDERLYING_TOKEN;

    /// @notice Reference to NAVCalculator for asset registry access.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Protocol identifier emitted on every PositionBalance.
    string private _protocol;
    /// @notice JSON metadata base (no closing `}`) emitted on every PositionBalance.
    string private _positionDetail;
    /// @notice Stable hex identifier for this adapter instance (withdrawalQueue address).
    string private _positionId;

    //
    // Constructor
    //

    /// @param withdrawalQueue_ Address of Lido's WithdrawalQueueERC721 contract.
    /// @param underlyingToken_ Address of the asset positions are denominated in (stETH).
    /// @param protocol_ Protocol identifier (e.g. "Lido").
    /// @param positionDetail_ JSON metadata base without closing `}`.
    /// @param positionId_ Stable hex identifier for this adapter instance (withdrawalQueue address).
    /// @param navCalculator_ The NAVCalculator address used for asset-registry filtering.
    constructor(
        address withdrawalQueue_,
        address underlyingToken_,
        string memory protocol_,
        string memory positionDetail_,
        string memory positionId_,
        address navCalculator_
    ) {
        if (withdrawalQueue_ == address(0) || underlyingToken_ == address(0)) {
            revert InvalidArguments();
        }
        require(withdrawalQueue_.code.length > 0, "WithdrawalQueue must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        WITHDRAWAL_QUEUE = ILidoWithdrawalQueue(withdrawalQueue_);
        UNDERLYING_TOKEN = underlyingToken_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
        _protocol = protocol_;
        _positionDetail = positionDetail_;
        _positionId = positionId_;
    }

    //
    // Balance computation
    //

    /// @notice Sums `amountOfStETH` across all of `account`'s open (un-claimed) withdrawal requests.
    /// @dev Enumerates request ids via `getWithdrawalRequests` (capped at `MAX_REQUESTS_PROBED`),
    ///      reads their status via `getWithdrawalStatus`, and skips claimed requests. `amountOfStETH`
    ///      is the stETH locked at request time; pre/post finalization it is the value owed.
    function _stEthOwed(address account) internal view returns (uint256 total) {
        if (account == address(0)) {
            return 0;
        }

        uint256[] memory ids = WITHDRAWAL_QUEUE.getWithdrawalRequests(account);
        if (ids.length == 0) {
            return 0;
        }

        // Bound the scan; if the account has more requests than the cap, probe the first MAX.
        if (ids.length > MAX_REQUESTS_PROBED) {
            uint256[] memory capped = new uint256[](MAX_REQUESTS_PROBED);
            for (uint256 i = 0; i < MAX_REQUESTS_PROBED; i++) {
                capped[i] = ids[i];
            }
            ids = capped;
        }

        ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory statuses = WITHDRAWAL_QUEUE.getWithdrawalStatus(ids);
        for (uint256 i = 0; i < statuses.length; i++) {
            if (!statuses[i].isClaimed) {
                total += statuses[i].amountOfStETH;
            }
        }
    }

    //
    // IBalanceOracleAdapter
    //

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](1);
        assets[0] = UNDERLYING_TOKEN;
        return assets;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (asset == address(0) || asset != UNDERLYING_TOKEN) {
            return (0, false);
        }
        return (_stEthOwed(account), false);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        if (account == address(0)) {
            return (new address[](0), new uint256[](0), new bool[](0));
        }

        uint256 total = _stEthOwed(account);
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

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns the account's open withdrawal-queue position as a single stETH credit.
    /// @dev Dropped if the underlying asset is not registered in NAVCalculator.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        // Asset-filter mismatch → no positions for this oracle.
        if (assetFilter != address(0) && assetFilter != UNDERLYING_TOKEN) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Underlying must be registered in NAVCalculator for the position to count in NAV.
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        INAVCalculator.Asset memory underlying;
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

        uint256 total = _stEthOwed(account);
        if (total == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        positions = new INAVCalculator.PositionBalance[](1);
        positions[0] = INAVCalculator.PositionBalance({
            underlyingAsset: underlying,
            balanceOracle: address(this),
            amount: total,
            isDebt: false,
            protocol: _protocol,
            positionDetail: PositionType.withType(_positionDetail, PositionType.STAKING),
            positionId: _positionId
        });
    }
}

/// @notice Minimal interface for Lido's WithdrawalQueueERC721.
interface ILidoWithdrawalQueue {
    /// @notice Per-request status tuple.
    /// @param amountOfStETH stETH locked at request time (the value owed).
    /// @param amountOfShares Lido shares locked at request time.
    /// @param owner Owner of the request NFT.
    /// @param timestamp Request creation timestamp.
    /// @param isFinalized Whether the request has been finalized by an oracle report.
    /// @param isClaimed Whether the ETH has already been claimed (request burned).
    struct WithdrawalRequestStatus {
        uint256 amountOfStETH;
        uint256 amountOfShares;
        address owner;
        uint256 timestamp;
        bool isFinalized;
        bool isClaimed;
    }

    /// @notice Returns all request ids owned by `_owner` (full on-chain enumeration).
    function getWithdrawalRequests(address _owner) external view returns (uint256[] memory requestsIds);

    /// @notice Returns the status for each of `_requestIds`.
    function getWithdrawalStatus(uint256[] calldata _requestIds)
        external
        view
        returns (WithdrawalRequestStatus[] memory statuses);
}
