// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IFluidVaultT1, IFluidVaultResolver} from "src/balances/protocols/FluidVaultLib.sol";

// Mock contracts extracted from FluidVault.t.sol for use by FluidVaultsMeta.t.sol

/// @notice Programmable mock of a Fluid T1 vault contract. Returns a configurable `ConstantViews`
///         from `constantsView()` so tests can stage T1 / zero-token configurations.
contract MockFluidVaultT1 {
    IFluidVaultT1.ConstantViews private _cv;

    function setTokens(address supplyToken_, address borrowToken_) external {
        _cv.supplyToken = supplyToken_;
        _cv.borrowToken = borrowToken_;
    }

    function constantsView() external view returns (IFluidVaultT1.ConstantViews memory) {
        return _cv;
    }
}

/// @notice Programmable mock of the Fluid VaultResolver.
contract MockFluidVaultResolver {
    struct PosData {
        address vault;
        uint256 supply;
        uint256 borrow;
        bool isLiquidated;
    }

    mapping(address => uint256[]) private _userNftIds;
    mapping(uint256 => PosData) private _posByNftId;

    function pushNft(address user, uint256 nftId, address vault, uint256 supply, uint256 borrow, bool isLiquidated)
        external
    {
        _userNftIds[user].push(nftId);
        _posByNftId[nftId] = PosData({vault: vault, supply: supply, borrow: borrow, isLiquidated: isLiquidated});
    }

    function positionsNftIdOfUser(address user) external view returns (uint256[] memory) {
        return _userNftIds[user];
    }

    function vaultByNftId(uint256 nftId) external view returns (address) {
        return _posByNftId[nftId].vault;
    }

    function positionByNftId(uint256 nftId) external view returns (IFluidVaultResolver.UserPosition memory pos) {
        PosData memory pd = _posByNftId[nftId];
        pos.nftId = nftId;
        pos.owner = address(0);
        pos.isLiquidated = pd.isLiquidated;
        pos.supply = pd.supply;
        pos.borrow = pd.borrow;
    }
}

contract MockToken {
    string public symbol;
    uint8 public decimals;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }
}
