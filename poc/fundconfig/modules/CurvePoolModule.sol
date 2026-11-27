// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ConditionFlat, ExecutionOptions} from "poc/fundconfig/vendor/RolesV2.sol";
import {Accounting, IPositionModule, PermissionLeaf} from "poc/fundconfig/IPositionModule.sol";
import {Cond} from "poc/fundconfig/PermissionMerge.sol";
import {CurvePoolLib} from "src/balances/MetaBalanceAdapters/curve/CurvePoolLib.sol";

/// @notice Position module for one Curve StableSwap pool (`CurvePoolsMetaBalanceAdapter`).
/// @dev Instance = pool address widened to bytes32. Covers the wallet-held LP leg: `add_liquidity` mints LP to the
///      Safe, `remove_liquidity` burns it. The LP is valued by the pool adapter (`Supplied` coin legs). Supports
///      2- and 3-coin pools (the `uint256[N]` selector is per coin count). Amounts and min-amounts are unconstrained
///      (empty conditions = allow-function): slippage bounds are the Safe's responsibility, as in the other POC modules.
contract CurvePoolModule is IPositionModule {
    error InvalidInstance(bytes32 instance);

    bytes32 public constant MODULE_ID = keccak256("curve-pools");

    bytes4 private constant SEL_APPROVE = bytes4(keccak256("approve(address,uint256)"));

    /// @notice Meta adapter that values this module's positions.
    address public immutable ADAPTER;

    constructor(address adapter_) {
        ADAPTER = adapter_;
    }

    /// @inheritdoc IPositionModule
    function moduleId() external pure returns (bytes32) {
        return MODULE_ID;
    }

    /// @inheritdoc IPositionModule
    function validate(bytes32 instance) external view {
        _coinCount(CurvePoolLib.getCoins(_pool(instance)).length, instance);
    }

    /// @inheritdoc IPositionModule
    function permissions(bytes32 instance) external view returns (PermissionLeaf[] memory leaves) {
        address pool = _pool(instance);
        address[] memory coins = CurvePoolLib.getCoins(pool);
        uint256 n = _coinCount(coins.length, instance);
        ConditionFlat[] memory unconstrained = new ConditionFlat[](0);

        leaves = new PermissionLeaf[](coins.length + 2);
        for (uint256 i; i < coins.length; ++i) {
            leaves[i] = PermissionLeaf({
                target: coins[i],
                selector: SEL_APPROVE,
                conditions: Cond.t2(Cond.equalTo(pool), Cond.pass()),
                options: ExecutionOptions.Send
            });
        }
        leaves[coins.length] = PermissionLeaf({
            target: pool,
            selector: _addSelector(n),
            conditions: unconstrained,
            options: ExecutionOptions.Send
        });
        leaves[coins.length + 1] = PermissionLeaf({
            target: pool,
            selector: _removeSelector(n),
            conditions: unconstrained,
            options: ExecutionOptions.Send
        });
    }

    /// @inheritdoc IPositionModule
    function accounting(bytes32 instance) external view returns (Accounting memory) {
        return Accounting({adapter: ADAPTER, isMeta: true, coordinate: instance, assetFilter: address(0)});
    }

    /// @inheritdoc IPositionModule
    function assets(bytes32 instance) external view returns (address[] memory) {
        return CurvePoolLib.getCoins(_pool(instance));
    }

    function _pool(bytes32 instance) private pure returns (address) {
        if (uint256(instance) >> 160 != 0) revert InvalidInstance(instance);
        return address(uint160(uint256(instance)));
    }

    function _coinCount(uint256 n, bytes32 instance) private pure returns (uint256) {
        if (n == 2 || n == 3) return n;
        revert InvalidInstance(instance);
    }

    function _addSelector(uint256 n) private pure returns (bytes4) {
        if (n == 2) return bytes4(keccak256("add_liquidity(uint256[2],uint256)"));
        return bytes4(keccak256("add_liquidity(uint256[3],uint256)"));
    }

    function _removeSelector(uint256 n) private pure returns (bytes4) {
        if (n == 2) return bytes4(keccak256("remove_liquidity(uint256,uint256[2])"));
        return bytes4(keccak256("remove_liquidity(uint256,uint256[3])"));
    }
}
