// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ConditionFlat, ExecutionOptions, Op, ParameterType} from "poc/fundconfig/vendor/RolesV2.sol";
import {Accounting, IPositionModule, PermissionLeaf} from "poc/fundconfig/IPositionModule.sol";
import {Cond} from "poc/fundconfig/PermissionMerge.sol";
import {IAaveDataProvider, IAavePoolAddressesProvider} from "poc/fundconfig/modules/AaveV3Module.sol";

/// @notice Debt leg of one Aave V3 market reserve: borrow and repay the reserve asset on behalf of the fund Safe.
/// @dev One module per market (`DATA_PROVIDER` immutable), instance = reserve underlying asset widened to bytes32.
///      Valuation reuses `AaveV3InstancesMetaBalanceAdapter` with coordinate = data provider and asset filter = the
///      reserve, which emits the reserve's `Borrowed` leg (variable + legacy stable summed, `isDebt` true).
///
///      Limitations inherited from the frozen `IPositionModule` and `FundConfig`:
///      - `interestRateMode` is Pass: either rate mode is permitted. The adapter values both, so NAV holds either way.
///      - `onBehalfOf` must be the Safe, so the fund never borrows against a third party's account.
///      - Removal is blocked while the asset has any Aave balance on the market, including the supply leg of a
///        co-declared `AaveV3Module` position. `Accounting.assetFilter` is per asset, not per leg.
contract AaveV3BorrowModule is IPositionModule {
    error InvalidInstance(bytes32 instance);
    error UnknownReserve(address asset);

    bytes4 private constant SEL_APPROVE = bytes4(keccak256("approve(address,uint256)"));
    bytes4 private constant SEL_BORROW = bytes4(keccak256("borrow(address,uint256,uint256,uint16,address)"));
    bytes4 private constant SEL_REPAY = bytes4(keccak256("repay(address,uint256,uint256,address)"));

    bytes32 public immutable MODULE_ID;

    /// @notice Aave V3 ProtocolDataProvider of the market this module serves.
    IAaveDataProvider public immutable DATA_PROVIDER;

    /// @notice Meta adapter that values this module's positions.
    address public immutable ADAPTER;

    constructor(bytes32 moduleId_, address dataProvider_, address adapter_) {
        MODULE_ID = moduleId_;
        DATA_PROVIDER = IAaveDataProvider(dataProvider_);
        ADAPTER = adapter_;
    }

    /// @inheritdoc IPositionModule
    function moduleId() external view returns (bytes32) {
        return MODULE_ID;
    }

    /// @inheritdoc IPositionModule
    function validate(bytes32 instance) external view {
        address asset = _asset(instance);
        (, , address variableDebtToken) = DATA_PROVIDER.getReserveTokensAddresses(asset);
        if (variableDebtToken == address(0)) revert UnknownReserve(asset);
    }

    /// @inheritdoc IPositionModule
    function permissions(bytes32 instance) external view returns (PermissionLeaf[] memory leaves) {
        address asset = _asset(instance);
        address pool = _pool();

        leaves = new PermissionLeaf[](3);
        leaves[0] = PermissionLeaf({
            target: asset,
            selector: SEL_APPROVE,
            conditions: Cond.t2(Cond.equalTo(pool), Cond.pass()),
            options: ExecutionOptions.Send
        });
        // borrow(asset, amount, interestRateMode, referralCode, onBehalfOf)
        leaves[1] = PermissionLeaf({
            target: pool,
            selector: SEL_BORROW,
            conditions: _args5(
                Cond.equalTo(asset), Cond.pass(), Cond.pass(), Cond.pass(), Cond.equalToAvatar()
            ),
            options: ExecutionOptions.Send
        });
        // repay(asset, amount, interestRateMode, onBehalfOf)
        leaves[2] = PermissionLeaf({
            target: pool,
            selector: SEL_REPAY,
            conditions: Cond.t4(Cond.equalTo(asset), Cond.pass(), Cond.pass(), Cond.equalToAvatar()),
            options: ExecutionOptions.Send
        });
    }

    /// @inheritdoc IPositionModule
    function accounting(bytes32 instance) external view returns (Accounting memory) {
        return Accounting({
            adapter: ADAPTER,
            isMeta: true,
            coordinate: bytes32(uint256(uint160(address(DATA_PROVIDER)))),
            assetFilter: _asset(instance)
        });
    }

    /// @inheritdoc IPositionModule
    function assets(bytes32 instance) external pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = _asset(instance);
    }

    /// @dev Five-argument calldata tree. `Cond` only builds up to four arguments.
    function _args5(
        ConditionFlat memory a,
        ConditionFlat memory b,
        ConditionFlat memory c,
        ConditionFlat memory d,
        ConditionFlat memory e
    ) private pure returns (ConditionFlat[] memory out) {
        out = new ConditionFlat[](6);
        out[0] = ConditionFlat(0, ParameterType.Calldata, Op.MATCHES, "");
        out[1] = a;
        out[2] = b;
        out[3] = c;
        out[4] = d;
        out[5] = e;
    }

    function _asset(bytes32 instance) internal pure returns (address) {
        if (uint256(instance) >> 160 != 0) revert InvalidInstance(instance);
        return address(uint160(uint256(instance)));
    }

    function _pool() internal view returns (address) {
        return IAavePoolAddressesProvider(DATA_PROVIDER.ADDRESSES_PROVIDER()).getPool();
    }
}
