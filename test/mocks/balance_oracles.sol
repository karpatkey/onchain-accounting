// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBalanceOracleCustom} from "src/balances/IBalanceOracleCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract Mock_CustomBalanceOracle is IBalanceOracleCustom {
    mapping(address => mapping(address => int256)) public balances;
    address[] public underlyingAassetsSupported;
    PositionMetadata internal _positionMetadata;

    function setBalance(address token, address account, int256 balance) external {
        balances[token][account] = balance;
    }

    function balanceOf(address token, address account) external view returns (int256) {
        return int256(balances[token][account]);
    }

    function setUnderlyingAssetsSupported(address[] calldata underlyingAssets) external {
        for (uint256 i = 0; i < underlyingAssets.length; i++) {
            underlyingAassetsSupported.push(underlyingAssets[i]);
        }
    }

    function underlyingAssetsSupported() external view returns (address[] memory) {
        return underlyingAassetsSupported;
    }

    function setPositionMetadata(PositionMetadata memory positionMetadata_) external {
        _positionMetadata = positionMetadata_;
    }

    // Optional helper for tests; not part of IBalanceOracleCustom
    function positionMetadata() external view returns (PositionMetadata memory) {
        return _positionMetadata;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
