// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @notice Trivial adapter implementing IBalanceOracleAdapter — used by factory/registry tests.
contract MockBalanceAdapter is IBalanceOracleAdapter {
    function getOraclePositions(address, address)
        external
        pure
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        positions = new INAVCalculator.PositionBalance[](0);
    }

    function getOracleBalances(address)
        external
        pure
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        assets = new address[](0);
        amounts = new uint256[](0);
        isDebt = new bool[](0);
    }

    function getOracleBalanceForAsset(address, address) external pure override returns (uint256, bool) {
        return (0, false);
    }

    function underlyingAssetsSupported() external pure override returns (address[] memory) {
        return new address[](0);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Adapter that does NOT implement IBalanceOracleAdapter via ERC165 — used to
///         test that the registry / factories reject non-adapter contracts.
contract NonAdapter is IERC165 {
    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }
}
