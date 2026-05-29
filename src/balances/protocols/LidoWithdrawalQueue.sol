// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {InvalidArguments} from "src/errors.sol";
import {PositionType} from "src/utils/PositionType.sol";

/// @title Lido Withdrawal Queue Balance Oracle
/// @author kpk
/// @notice Reports the ETH owed to an account from open requests in Lido's `WithdrawalQueueERC721`.
/// @dev When a user requests an unstake, stETH is locked and an ERC721 request id is minted. The
///      claim pays out **native ETH** (the stETH is burned), so the position is denominated in ETH —
///      not stETH — matching what the account actually receives (and pricing it via ETH/USD rather
///      than stETH/USD, so a stETH depeg can't mis-value a claim that settles in full ETH). While
///      queued the value is invisible to wallet/receipt-token oracles. This oracle enumerates the
///      account's request ids (`getWithdrawalRequests`), reads their status (`getWithdrawalStatus`),
///      and sums `amountOfStETH` across all **un-claimed** requests into a single position
///      denominated in `UNDERLYING_TOKEN` (native ETH). `amountOfStETH` is fixed at request time and
///      equals the ETH paid on claim (verified on-chain; it can differ only on a negative rebase
///      between request and finalization, where Lido caps the payout). NAVCalculator prices it via
///      the registered ETH feed.
contract LidoWithdrawalQueueBalanceOracle is IBalanceOracleAdapter {
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
    /// @param underlyingToken_ Address of the asset positions are denominated in — what Lido pays on
    ///        claim (native ETH; the ERC-7528 sentinel on mainnet).
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

    /// @notice Sums `amountOfStETH` (= the ETH owed) across `account`'s open (un-claimed) requests.
    /// @dev Reads `balanceOf` (the count of open request NFTs — claiming burns the NFT) FIRST, in
    ///      O(1), so the unbounded id list is never materialised when the count is pathological.
    ///      Lido's `WithdrawalQueueERC721` is NOT `ERC721Enumerable` (no `tokenOfOwnerByIndex`) and
    ///      `getWithdrawalRequests` returns the *entire* id set, so there is no way to read a bounded
    ///      slice. If the count exceeds `MAX_REQUESTS_PROBED` we skip (return 0) rather than risk
    ///      OOG'ing the NAV read on a list an attacker can inflate by transferring withdrawal NFTs in
    ///      — an OOG is NOT caught by NAVCalculator's try/catch. A real account never approaches the
    ///      cap; the per-adapter fork test covers the live path. Claimed requests are skipped via
    ///      `isClaimed`. `amountOfStETH` is the stETH locked at request time (the value owed).
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
        return (_ethOwed(account), false);
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

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns the account's open withdrawal-queue position as a single ETH credit.
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

        uint256 total = _ethOwed(account);
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
}
