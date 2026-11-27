// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @notice Balance adapter that reports no positions. A swap holds no position of its own: the output token is valued
///         as a wallet balance through the module's `assets()`, so the adapter route only needs to exist.
contract NoPositionAdapter is IBalanceAdapter {
    /// @inheritdoc IBalanceAdapter
    function getAdapterPositions(address, address)
        external
        pure
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        positions = new INAVCalculator.PositionBalance[](0);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address)
        external
        pure
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        assets = new address[](0);
        amounts = new uint256[](0);
        isDebt = new bool[](0);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address, address) external pure returns (uint256 amount, bool isDebt) {
        return (0, false);
    }

    /// @inheritdoc IBalanceAdapter
    function underlyingAssetsSupported() external pure returns (address[] memory underlyingAssets) {
        underlyingAssets = new address[](0);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IBalanceAdapter).interfaceId;
    }
}
