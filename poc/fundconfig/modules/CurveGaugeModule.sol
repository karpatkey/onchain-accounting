// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ConditionFlat, ExecutionOptions} from "poc/fundconfig/vendor/RolesV2.sol";
import {Accounting, IPositionModule, PermissionLeaf} from "poc/fundconfig/IPositionModule.sol";
import {Cond} from "poc/fundconfig/PermissionMerge.sol";
import {CurvePoolLib} from "src/balances/MetaBalanceAdapters/curve/CurvePoolLib.sol";

/// @notice Position module for one Curve gauge (`CurveGaugesMetaBalanceAdapter`).
/// @dev Instance = gauge address widened to bytes32. Covers the staked LP leg: approve the pool LP to the gauge,
///      `deposit`, `withdraw`, and the CRV claim via the CRV Minter's `mint(gauge)` (the legacy 3pool gauge has no `claim_rewards()`). The staked LP and CRV/extra rewards are valued by the gauge adapter
///      (`Staking` coin legs, `Rewards` legs). This is a separate position from `CurvePoolModule` (wallet LP): the
///      two legs have different coordinates and adapters, so one product spans two declared positions.
///      Amounts are unconstrained (empty conditions = allow-function).
contract CurveGaugeModule is IPositionModule {
    error InvalidInstance(bytes32 instance);

    bytes32 public constant MODULE_ID = keccak256("curve-gauges");

    /// @dev Mainnet CRV, the gauge minter reward token. Extra gauge reward tokens are valued by the adapter but not
    ///      declared as assets (the POC declares only CRV as the wallet asset).
    address public constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    /// @dev Mainnet CRV Minter. `mint(gauge)` claims the gauge's accrued CRV to the caller.
    address public constant CRV_MINTER = 0xd061D61a4d941c39E5453435B6345Dc261C2fcE0;

    bytes4 private constant SEL_APPROVE = bytes4(keccak256("approve(address,uint256)"));
    bytes4 private constant SEL_DEPOSIT = bytes4(keccak256("deposit(uint256)"));
    bytes4 private constant SEL_WITHDRAW = bytes4(keccak256("withdraw(uint256)"));
    bytes4 private constant SEL_MINT = bytes4(keccak256("mint(address)"));

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
        _gauge(instance);
    }

    /// @inheritdoc IPositionModule
    function permissions(bytes32 instance) external view returns (PermissionLeaf[] memory leaves) {
        address gauge = _gauge(instance);
        address lp = CurvePoolLib.gaugeLpToken(gauge);
        ConditionFlat[] memory unconstrained = new ConditionFlat[](0);

        leaves = new PermissionLeaf[](4);
        leaves[0] = PermissionLeaf({
            target: lp,
            selector: SEL_APPROVE,
            conditions: Cond.t2(Cond.equalTo(gauge), Cond.pass()),
            options: ExecutionOptions.Send
        });
        leaves[1] = PermissionLeaf({
            target: gauge,
            selector: SEL_DEPOSIT,
            conditions: unconstrained,
            options: ExecutionOptions.Send
        });
        leaves[2] = PermissionLeaf({
            target: gauge,
            selector: SEL_WITHDRAW,
            conditions: unconstrained,
            options: ExecutionOptions.Send
        });
        leaves[3] = PermissionLeaf({
            target: CRV_MINTER,
            selector: SEL_MINT,
            conditions: Cond.t1(Cond.equalTo(gauge)),
            options: ExecutionOptions.Send
        });
    }

    /// @inheritdoc IPositionModule
    function accounting(bytes32 instance) external view returns (Accounting memory) {
        return Accounting({adapter: ADAPTER, isMeta: true, coordinate: instance, assetFilter: address(0)});
    }

    /// @inheritdoc IPositionModule
    function assets(bytes32 instance) external view returns (address[] memory out) {
        _gauge(instance);
        out = new address[](1);
        out[0] = CRV;
    }

    function _gauge(bytes32 instance) private view returns (address gauge) {
        if (uint256(instance) >> 160 != 0) revert InvalidInstance(instance);
        gauge = address(uint160(uint256(instance)));
        if (CurvePoolLib.gaugeLpToken(gauge) == address(0)) revert InvalidInstance(instance);
    }
}
