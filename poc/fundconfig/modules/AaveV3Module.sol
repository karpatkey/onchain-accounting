// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ExecutionOptions} from "poc/fundconfig/vendor/RolesV2.sol";
import {Accounting, IPositionModule, PermissionLeaf} from "poc/fundconfig/IPositionModule.sol";
import {Cond} from "poc/fundconfig/PermissionMerge.sol";

interface IAaveDataProvider {
    function ADDRESSES_PROVIDER() external view returns (address);

    function getReserveTokensAddresses(address asset)
        external
        view
        returns (address aToken, address stableDebtToken, address variableDebtToken);
}

interface IAavePoolAddressesProvider {
    function getPool() external view returns (address);
}

/// @notice Position module for one Aave V3 market (`AaveV3InstancesMetaBalanceAdapter`), one reserve per fund position.
/// @dev One module is deployed per market: `DATA_PROVIDER` is immutable. Instance = reserve underlying asset widened
///      to bytes32. The pool is resolved through the data provider's addresses provider. Valuation uses the adapter
///      with coordinate = data provider and asset filter = the reserve.
contract AaveV3Module is IPositionModule {
    error InvalidInstance(bytes32 instance);
    error UnknownReserve(address asset);

    bytes4 private constant SEL_APPROVE = bytes4(keccak256("approve(address,uint256)"));
    bytes4 private constant SEL_SUPPLY = bytes4(keccak256("supply(address,uint256,address,uint16)"));
    bytes4 private constant SEL_WITHDRAW = bytes4(keccak256("withdraw(address,uint256,address)"));

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
        (address aToken,,) = DATA_PROVIDER.getReserveTokensAddresses(asset);
        if (aToken == address(0)) revert UnknownReserve(asset);
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
        leaves[1] = PermissionLeaf({
            target: pool,
            selector: SEL_SUPPLY,
            conditions: Cond.t4(Cond.equalTo(asset), Cond.pass(), Cond.equalToAvatar(), Cond.pass()),
            options: ExecutionOptions.Send
        });
        leaves[2] = PermissionLeaf({
            target: pool,
            selector: SEL_WITHDRAW,
            conditions: Cond.t3(Cond.equalTo(asset), Cond.pass(), Cond.equalToAvatar()),
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

    function _asset(bytes32 instance) internal pure returns (address) {
        if (uint256(instance) >> 160 != 0) revert InvalidInstance(instance);
        return address(uint160(uint256(instance)));
    }

    function _pool() internal view returns (address) {
        return IAavePoolAddressesProvider(DATA_PROVIDER.ADDRESSES_PROVIDER()).getPool();
    }
}
