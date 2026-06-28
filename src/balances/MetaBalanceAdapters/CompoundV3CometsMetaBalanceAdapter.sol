// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {CompoundV3CometLib} from "src/balances/MetaBalanceAdapters/CompoundV3CometLib.sol";

/// @title Compound V3 Comets Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's position in *any* Compound V3 (Comet) market — the
///         base-token supply (`Supplied`) or borrow (`Borrowed`), every `Collateral` leg, and unclaimed `Earned`
///         rewards (COMP). The instance coordinate is the comet address, widened to bytes32; the active comet set
///         lives on NAVCalculator (`addMetaInstances`/`removeMetaInstances`). The CometRewards contract and reward token (COMP) are the
///         chain-level constants pinned in the constructor. Identity is encoded as `abi.encode(address(comet))`.
///         See ADR 0010.
/// @dev Read math (base accrual, reward accrual, collateral enumeration) is delegated to `CompoundV3CometLib`,
///      which mirrors the per-comet `CompoundV3Comet` adapter leg-for-leg (parity fork-tested). Multi-role assets
///      (e.g. COMP as both collateral and reward) emit one leg per role, same as the per-comet adapter.
contract CompoundV3CometsMetaBalanceAdapter is MetaBalanceAdapter {
    using SafeCast for int256;

    bytes32 private constant PROTOCOL_ID = ProtocolIds.COMPOUND_V3;

    /// @notice The chain's CometRewards contract (same for every comet on the chain).
    address public immutable COMPOUND_REWARDS;
    /// @notice The reward token (COMP, or the chain's bridged COMP).
    address public immutable REWARD_TOKEN;

    /// @param compoundRewards_ The chain's CometRewards contract.
    /// @param rewardToken_ The reward token (COMP).
    /// @param protocolName_ Human-readable protocol name (e.g. "Compound V3").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address compoundRewards_, address rewardToken_, string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {
        require(compoundRewards_.code.length > 0, "CompoundRewards must be a contract");
        require(rewardToken_ != address(0), "rewardToken=0");
        COMPOUND_REWARDS = compoundRewards_;
        REWARD_TOKEN = rewardToken_;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the comet address. Emits a base `Supplied`/`Borrowed` leg, a `Collateral` leg per
    ///      collateral, and a `Rewards` leg — dropping zeros and unregistered assets, respecting `assetFilter`.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        address comet = _toAddress(instance);
        CompoundV3CometLib.AccountData memory d =
            CompoundV3CometLib.accountData(comet, COMPOUND_REWARDS, REWARD_TOKEN, account);

        bytes memory pid = _instancePositionId(instance);

        INAVCalculator.PositionBalance[] memory temp =
            new INAVCalculator.PositionBalance[](d.collateralAssets.length + 2);
        uint256 count;

        // Base leg (supply or borrow).
        if (d.baseNet != 0) {
            (INAVCalculator.Asset memory a, bool ok) = _eligible(d.baseToken, assetFilter);
            if (ok) {
                bool isDebt = d.baseNet < 0;
                uint256 amount = isDebt ? uint256(-d.baseNet) : uint256(d.baseNet);
                PositionKind kind = isDebt ? PositionKind.Borrowed : PositionKind.Supplied;
                temp[count++] = _row(a, amount, isDebt, pid, kind);
            }
        }

        // Collateral legs.
        for (uint256 i = 0; i < d.collateralAssets.length; i++) {
            if (d.collateralBalances[i] == 0) continue;
            (INAVCalculator.Asset memory a, bool ok) = _eligible(d.collateralAssets[i], assetFilter);
            if (ok) temp[count++] = _row(a, d.collateralBalances[i], false, pid, PositionKind.Collateral);
        }

        // Reward leg.
        if (d.rewardOwed != 0) {
            (INAVCalculator.Asset memory a, bool ok) = _eligible(REWARD_TOKEN, assetFilter);
            if (ok) temp[count++] = _row(a, d.rewardOwed, false, pid, PositionKind.Rewards);
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory) {
        return CompoundV3CometLib.supportedAssets(_toAddress(instance), REWARD_TOKEN);
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["Market", <leaf>]` where the leaf is the comet's ERC20 name ("" if unreadable). Returns an
    ///      empty array for a short positionId.
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        if (pid.length < 32) return new string[](0);
        address comet = abi.decode(pid, (address));
        string memory leaf = "";
        try IERC20Metadata(comet).name() returns (string memory n) {
            leaf = n;
        } catch {}
        return _labels("Market", leaf);
    }

    function _eligible(address token, address assetFilter)
        private
        view
        returns (INAVCalculator.Asset memory assetInfo, bool eligible)
    {
        if (assetFilter != address(0) && token != assetFilter) return (assetInfo, false);
        (assetInfo, eligible) = _getAssetInfo(token);
    }

    function _row(INAVCalculator.Asset memory asset, uint256 amount, bool isDebt, bytes memory pid, PositionKind kind)
        private
        view
        returns (INAVCalculator.PositionBalance memory)
    {
        return INAVCalculator.PositionBalance({
            balanceAsset: asset,
            balanceAdapter: address(this),
            amount: amount,
            isDebt: isDebt,
            protocolId: PROTOCOL_ID,
            positionId: pid,
            positionKind: kind,
            isLocked: false,
            positionInstanceId: bytes32(0)
        });
    }
}
