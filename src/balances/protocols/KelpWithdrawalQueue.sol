// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {IPositionDescribable} from "../IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {InvalidArguments} from "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Kelp DAO rsETH Withdrawal Queue Balance Oracle
/// @author kpk
/// @notice Reports assets owed to an account from open requests in Kelp DAO's rsETH exit queue
///         (the `LRTWithdrawalManager`).
/// @dev When a user unstakes rsETH, the rsETH is burned and a per-(asset, user) withdrawal request
///      is recorded denominated in the LST the user chose to receive (stETH, ETHx or native ETH).
///      Until claimed, that value is invisible to wallet/receipt-token oracles — it only lives as a
///      pending claim on the manager. This oracle surfaces it: for every asset Kelp supports it sums
///      the account's open requests (`expectedAssetAmount`) and emits one credit position per asset.
///      The supported-asset set is discovered at runtime from `lrtConfig().getSupportedAssetList()`
///      rather than hardcoded, mirroring the dynamic-discovery pattern in `AaveUmbrella.sol`.
contract KelpWithdrawalQueueBalanceOracle is IBalanceOracleAdapter, IPositionDescribable {
    //
    // Constants
    //

    /// @notice Hard cap on the number of open requests summed per (asset, account).
    /// @dev Bounds gas so a pathological account with many open requests can't make NAV reads run
    ///      out of gas (an out-of-gas revert is NOT caught by NAVCalculator's try/catch, so it would
    ///      DoS the whole NAV call). Mirrors `StaderWithdrawalQueue` and the queue-family note in
    ///      `docs/roadmap/balance-adapter-coverage.md`. In practice an account never has more than a
    ///      handful of pending requests per asset.
    uint256 public constant MAX_REQUESTS_PROBED = 256;

    bytes32 private constant PROTOCOL_ID = ProtocolIds.KELP_WITHDRAWAL;

    //
    // State
    //

    /// @notice Kelp DAO LRTWithdrawalManager contract (the rsETH exit queue).
    ILRTWithdrawalManager public immutable WITHDRAWAL_MANAGER;

    /// @notice Reference to NAVCalculator for asset registry access.
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param withdrawalManager_ Address of Kelp's LRTWithdrawalManager contract.
    /// @param navCalculator_ The NAVCalculator address used for asset-registry filtering.
    constructor(address withdrawalManager_, address navCalculator_) {
        if (withdrawalManager_ == address(0)) {
            revert InvalidArguments();
        }
        require(withdrawalManager_.code.length > 0, "WithdrawalManager must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        WITHDRAWAL_MANAGER = ILRTWithdrawalManager(withdrawalManager_);
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // Balance computation
    //

    /// @notice Sums the `expectedAssetAmount` across all of `account`'s open requests for `asset`.
    /// @dev `userAssociatedNonces` is the public getter of an OZ `DoubleEndedQueue.Uint256Deque`; the
    ///      number of open requests is `end - begin`. `getUserWithdrawalRequest(asset, account, i)`
    ///      resolves to the deque's `.at(i)` for `i ∈ [0, end-begin)` — claimed requests are popped
    ///      off the front, so this only ever counts live claims. No out-of-bounds probing is needed.
    ///      The scan is capped at `MAX_REQUESTS_PROBED` to bound gas (see that constant's NatSpec).
    function _owedForAsset(address asset, address account) internal view returns (uint256 total) {
        if (account == address(0)) {
            return 0;
        }

        (uint128 begin, uint128 end) = WITHDRAWAL_MANAGER.userAssociatedNonces(asset, account);
        uint256 count = end - begin;
        if (count > MAX_REQUESTS_PROBED) {
            count = MAX_REQUESTS_PROBED;
        }
        for (uint256 i = 0; i < count; i++) {
            (, uint256 expectedAssetAmount,,) = WITHDRAWAL_MANAGER.getUserWithdrawalRequest(asset, account, i);
            total += expectedAssetAmount;
        }
    }

    /// @notice Returns the set of assets Kelp's exit queue can pay out, discovered from LRTConfig.
    function _supportedAssets() internal view returns (address[] memory) {
        return ILRTConfig(WITHDRAWAL_MANAGER.lrtConfig()).getSupportedAssetList();
    }

    /// @notice Looks up `asset` in a pre-fetched NAVCalculator registered-asset set.
    /// @dev Pure in-memory search: the caller fetches `getRegisteredAssets()` once and reuses it
    ///      across every supported asset, rather than re-fetching per lookup (cf. `AaveUmbrella`).
    /// @return found Whether the asset is registered (and therefore priced) in NAV.
    /// @return info The registered Asset tuple (zeroed if not found).
    function _findRegisteredAsset(INAVCalculator.Asset[] memory reg, address asset)
        internal
        pure
        returns (bool found, INAVCalculator.Asset memory info)
    {
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == asset) {
                return (true, reg[i]);
            }
        }
    }

    //
    // IBalanceOracleAdapter
    //

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        return _supportedAssets();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId
            || interfaceId == type(IPositionDescribable).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function protocolName() external pure returns (string memory) {
        return "Kelp DAO";
    }

    function describePosition(bytes calldata) external pure returns (string memory) {
        return "rsETH withdrawal queue";
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        // No explicit supported-asset guard needed: for any asset this queue does not track, the
        // `userAssociatedNonces` deque is empty, so `_owedForAsset` returns 0.
        if (asset == address(0)) {
            return (0, false);
        }
        return (_owedForAsset(asset, account), false);
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

        address[] memory supported = _supportedAssets();
        address[] memory tmpAssets = new address[](supported.length);
        uint256[] memory tmpAmounts = new uint256[](supported.length);
        uint256 count;

        for (uint256 i = 0; i < supported.length; i++) {
            uint256 owed = _owedForAsset(supported[i], account);
            if (owed > 0) {
                tmpAssets[count] = supported[i];
                tmpAmounts[count] = owed;
                count++;
            }
        }

        assets = new address[](count);
        amounts = new uint256[](count);
        isDebt = new bool[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = tmpAssets[i];
            amounts[i] = tmpAmounts[i];
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns balance-only positions for the account's open exit-queue requests.
    /// @dev One credit position per Kelp-supported asset with a non-zero owed amount that is also
    ///      registered in NAVCalculator. Requests for assets not registered in NAV are dropped.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0)) {
            return new INAVCalculator.PositionBalance[](0);
        }

        address[] memory supported = _supportedAssets();
        // Fetch the NAV registry once and reuse it for every supported asset.
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](supported.length);
        uint256 count;

        for (uint256 i = 0; i < supported.length; i++) {
            address asset = supported[i];
            if (assetFilter != address(0) && assetFilter != asset) {
                continue;
            }

            (bool registered, INAVCalculator.Asset memory underlying) = _findRegisteredAsset(reg, asset);
            if (!registered) {
                continue;
            }

            uint256 owed = _owedForAsset(asset, account);
            if (owed == 0) {
                continue;
            }

            tmp[count++] = INAVCalculator.PositionBalance({
                balanceAsset: underlying,
                balanceOracle: address(this),
                amount: owed,
                isDebt: false,
                protocolId: PROTOCOL_ID,
                positionId: "",
                positionKind: PositionKind.Supplied
            });
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = tmp[i];
        }
    }
}

/// @notice Minimal interface for Kelp DAO's LRTWithdrawalManager (the rsETH exit queue).
interface ILRTWithdrawalManager {
    /// @notice Address of the LRTConfig that holds the supported-asset registry.
    function lrtConfig() external view returns (address);

    /// @notice Public getter of the per-(asset, user) `DoubleEndedQueue.Uint256Deque` of open nonces.
    /// @return begin Front index of the deque (advances as requests are claimed).
    /// @return end One-past-the-back index. Open-request count is `end - begin`.
    function userAssociatedNonces(address asset, address user) external view returns (uint128 begin, uint128 end);

    /// @notice Returns the `userIndex`-th open withdrawal request for `(asset, user)`.
    /// @param userIndex Relative index into the user's deque, `0 ..= (end - begin - 1)`.
    /// @return rsETHAmount rsETH burned to create the request.
    /// @return expectedAssetAmount Amount of `asset` the user will receive on claim (the owed value).
    /// @return withdrawalStartBlock Block at which the request was created.
    /// @return userNonce Absolute nonce of the request within the asset's queue.
    function getUserWithdrawalRequest(address asset, address user, uint256 userIndex)
        external
        view
        returns (uint256 rsETHAmount, uint256 expectedAssetAmount, uint256 withdrawalStartBlock, uint256 userNonce);
}

/// @notice Minimal interface for Kelp DAO's LRTConfig.
interface ILRTConfig {
    /// @notice The list of assets Kelp supports (and therefore can pay out from the exit queue).
    function getSupportedAssetList() external view returns (address[] memory);
}
