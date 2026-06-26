// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalanceAdapter} from "../IBalanceAdapter.sol";
import {IPositionDescribable} from "../IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {InvalidArguments} from "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Stader Withdrawal Queue Balance Adapter
/// @author KPK
/// @notice Reports ETH owed to an account from open requests in Stader's UserWithdrawalManager.
/// @dev When a user requests an unstake, ETHx is burned and a sequential request id is recorded.
///      Until claimed, the value lives as ETH owed by the manager. This adapter sums all of the
///      account's open requests into a single position denominated in `UNDERLYING_TOKEN` (typically WETH).
contract StaderWithdrawalQueueBalanceAdapter is IBalanceAdapter, IPositionDescribable {
    //
    // Errors
    //

    /// @notice Thrown when `requestIdsByUserAddress` panics with a code other than 0x32 (array OOB).
    /// @dev Surfaces the unexpected panic rather than silently treating it as enumeration end.
    error UnexpectedPanic(uint256 panicCode);

    //
    // Constants
    //

    /// @notice Hard cap on the number of request slots probed per account.
    /// @dev Bounds gas; in practice an account never has more than a handful of pending requests.
    uint256 internal constant MAX_REQUESTS_PROBED = 256;

    bytes32 private constant PROTOCOL_ID = ProtocolIds.STADER_WITHDRAWAL;

    //
    // State
    //

    /// @notice Stader UserWithdrawalManager contract.
    IUserWithdrawalManager public immutable USER_WITHDRAWAL_MANAGER;

    /// @notice The asset under which positions are reported (e.g. WETH).
    /// @dev Pricing is added by NAVCalculator from this asset's registered price feed.
    address public immutable UNDERLYING_TOKEN;

    /// @notice Reference to NAVCalculator for asset registry access.
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param userWithdrawalManager_ Address of Stader's UserWithdrawalManager contract.
    /// @param underlyingToken_ Address of the asset positions are denominated in (e.g. WETH).
    /// @param navCalculator_ The NAVCalculator address used for asset-registry filtering.
    constructor(address userWithdrawalManager_, address underlyingToken_, address navCalculator_) {
        if (userWithdrawalManager_ == address(0) || underlyingToken_ == address(0)) {
            revert InvalidArguments();
        }
        require(userWithdrawalManager_.code.length > 0, "UserWithdrawalManager must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        USER_WITHDRAWAL_MANAGER = IUserWithdrawalManager(userWithdrawalManager_);
        UNDERLYING_TOKEN = underlyingToken_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // Balance computation
    //

    /// @notice Sums the ETH owed across all open withdrawal requests for `account`.
    /// @dev Iterates `requestIdsByUserAddress(account, i)` until the auto-generated getter signals
    ///      array-out-of-bounds, then reads each request via `userWithdrawRequests(id)`. Skips
    ///      entries deleted on claim (owner == address(0)). Uses `ethFinalized` once the batch has
    ///      been finalized; otherwise falls back to `ethExpected` (the rate-converted estimate at
    ///      request time).
    /// @dev OOB enumeration end is detected via two complementary paths:
    ///      1. **Modern Solidity (≥0.8)**: array OOB raises Panic(0x32).
    ///      2. **Legacy Solidity (Stader's deployed UserWithdrawalManager)**: array OOB raises a
    ///         bare empty revert with no return data.
    ///      Any other panic / revert with data propagates as `UnexpectedPanic` / re-thrown bytes
    ///      so NAVCalculator's outer try/catch surfaces the failure rather than the adapter
    ///      silently undercounting NAV.
    function _ethOwed(address account) internal view returns (uint256 total) {
        if (account == address(0)) {
            return 0;
        }

        for (uint256 i = 0; i < MAX_REQUESTS_PROBED; i++) {
            try USER_WITHDRAWAL_MANAGER.requestIdsByUserAddress(account, i) returns (uint256 requestId) {
                (address owner,, uint256 ethExpected, uint256 ethFinalized,) =
                    USER_WITHDRAWAL_MANAGER.userWithdrawRequests(requestId);

                if (owner == address(0)) {
                    // Already claimed: storage entry deleted, but the id may still sit in the user's
                    // index array on some Stader deployments. Skip it.
                    continue;
                }

                total += ethFinalized > 0 ? ethFinalized : ethExpected;
            } catch Panic(uint256 panicCode) {
                // 0x32 = array index out of bounds — list exhausted, return what we have.
                if (panicCode == 0x32) {
                    return total;
                }
                revert UnexpectedPanic(panicCode);
            } catch (bytes memory data) {
                // Legacy-compiled getter raises a bare revert (no return data) when the index is
                // past the end of the array. Treat empty revert as the OOB sentinel; anything else
                // is a real error and is bubbled up.
                if (data.length == 0) {
                    return total;
                }
                assembly {
                    revert(add(data, 0x20), mload(data))
                }
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
        return "Stader";
    }

    function describePosition(bytes calldata) external pure returns (string memory) {
        return "ETHx withdrawal queue";
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
    /// @notice Returns balance-only positions for the account's open withdrawal requests.
    /// @dev Single aggregated PositionBalance, dropped if the underlying asset is not registered in NAVCalculator.
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
            balanceAsset: underlying,
            balanceAdapter: address(this),
            amount: total,
            isDebt: false,
            protocolId: PROTOCOL_ID,
            positionId: "",
            positionKind: PositionKind.Supplied
        });
    }
}

/// @notice Minimal interface for Stader's UserWithdrawalManager.
/// @dev Mirrors the Solidity-auto-generated getters for the public mappings used by the adapter.
interface IUserWithdrawalManager {
    /// @notice Returns the request id at position `index` of the user's request array.
    /// @dev Reverts with array-out-of-bounds when `index >= userRequests.length`.
    function requestIdsByUserAddress(address user, uint256 index) external view returns (uint256 requestId);

    /// @notice Returns the per-request `UserWithdrawInfo` tuple for a given request id.
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
