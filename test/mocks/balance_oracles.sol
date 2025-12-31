// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBalanceOracleCustom} from "src/balances/IBalanceOracleCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Mock custom balance oracle
contract Mock_CustomBalanceOracle is IBalanceOracleCustom {
    IBalanceOracleCustom.PositionMetadata public metadata;
    mapping(address => mapping(address => int256)) public balances;
    address[] public underlyingAssets;

    constructor() {
        metadata = IBalanceOracleCustom.PositionMetadata({
            protocol: "Mock Protocol",
            position: "Mock Position",
            positionType: "Mock Type"
        });
    }

    function setBalance(address underlyingAsset, address account, int256 balance) external {
        balances[underlyingAsset][account] = balance;
    }

    function setUnderlyingAssetsSupported(address[] memory assets) external {
        underlyingAssets = assets;
    }

    function setPositionMetadata(IBalanceOracleCustom.PositionMetadata memory metadata_) external {
        metadata = metadata_;
    }

    function balanceOf(address underlyingAsset, address account) external view override returns (int256) {
        return balances[underlyingAsset][account];
    }

    function underlyingAssetsSupported() external view override returns (address[] memory) {
        return underlyingAssets;
    }

    function positionMetadata() external view override returns (IBalanceOracleCustom.PositionMetadata memory) {
        return metadata;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IBalanceOracleCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
