// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ExecutionOptions} from "poc/fundconfig/vendor/RolesV2.sol";
import {Accounting, IPositionModule, PermissionLeaf} from "poc/fundconfig/IPositionModule.sol";
import {Cond} from "poc/fundconfig/PermissionMerge.sol";

interface IERC4626Min {
    function asset() external view returns (address);
}

/// @notice Position module for Morpho ERC4626 vaults (`MorphoVaultsMetaBalanceAdapter`).
/// @dev Instance = vault address widened to bytes32. Asset = `vault.asset()`.
contract MorphoVaultModule is IPositionModule {
    error InvalidInstance(bytes32 instance);

    bytes32 public constant MODULE_ID = keccak256("morpho-vaults");

    bytes4 private constant SEL_APPROVE = bytes4(keccak256("approve(address,uint256)"));
    bytes4 private constant SEL_DEPOSIT = bytes4(keccak256("deposit(uint256,address)"));
    bytes4 private constant SEL_REDEEM = bytes4(keccak256("redeem(uint256,address,address)"));
    bytes4 private constant SEL_WITHDRAW = bytes4(keccak256("withdraw(uint256,address,address)"));

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
        _vault(instance);
    }

    /// @inheritdoc IPositionModule
    function permissions(bytes32 instance) external view returns (PermissionLeaf[] memory leaves) {
        address vault = _vault(instance);
        address asset = IERC4626Min(vault).asset();

        leaves = new PermissionLeaf[](4);
        leaves[0] = PermissionLeaf({
            target: asset,
            selector: SEL_APPROVE,
            conditions: Cond.t2(Cond.equalTo(vault), Cond.pass()),
            options: ExecutionOptions.Send
        });
        leaves[1] = PermissionLeaf({
            target: vault,
            selector: SEL_DEPOSIT,
            conditions: Cond.t2(Cond.pass(), Cond.equalToAvatar()),
            options: ExecutionOptions.Send
        });
        leaves[2] = PermissionLeaf({
            target: vault,
            selector: SEL_REDEEM,
            conditions: Cond.t3(Cond.pass(), Cond.equalToAvatar(), Cond.equalToAvatar()),
            options: ExecutionOptions.Send
        });
        leaves[3] = PermissionLeaf({
            target: vault,
            selector: SEL_WITHDRAW,
            conditions: Cond.t3(Cond.pass(), Cond.equalToAvatar(), Cond.equalToAvatar()),
            options: ExecutionOptions.Send
        });
    }

    /// @inheritdoc IPositionModule
    function accounting(bytes32 instance) external view returns (Accounting memory) {
        return Accounting({adapter: ADAPTER, isMeta: true, coordinate: instance, assetFilter: address(0)});
    }

    /// @inheritdoc IPositionModule
    function assets(bytes32 instance) external view returns (address[] memory out) {
        out = new address[](1);
        out[0] = IERC4626Min(_vault(instance)).asset();
    }

    function _vault(bytes32 instance) internal view returns (address vault) {
        if (uint256(instance) >> 160 != 0) revert InvalidInstance(instance);
        vault = address(uint160(uint256(instance)));
        IERC4626Min(vault).asset();
    }
}
