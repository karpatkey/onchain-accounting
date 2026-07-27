// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IFluidVaultT1, IFluidVaultResolver, FluidVaultLib} from "src/balances/MetaBalanceAdapters/FluidVaultLib.sol";

// Mock contracts extracted from FluidVault.t.sol for use by FluidVaultsMetaBalanceAdapter.t.sol

/// @notice Programmable mock of a Fluid T1 vault contract. Returns a configurable `ConstantViews`
///         from `constantsView()` so tests can stage T1 / zero-token configurations.
contract MockFluidVaultT1 {
    IFluidVaultT1.ConstantViews private _cv;

    function setTokens(address supplyToken_, address borrowToken_) external {
        _cv.supplyToken = supplyToken_;
        _cv.borrowToken = borrowToken_;
    }

    /// @notice Stages Fluid's per-vault numeric id (the label's uniqueness discriminator).
    function setVaultId(uint256 vaultId_) external {
        _cv.vaultId = vaultId_;
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
    mapping(address => uint256) private _vaultType;
    bool private _vaultTypeReverts;
    bool private _vaultTypeShort;

    function pushNft(address user, uint256 nftId, address vault, uint256 supply, uint256 borrow, bool isLiquidated)
        external
    {
        _userNftIds[user].push(nftId);
        _posByNftId[nftId] = PosData({vault: vault, supply: supply, borrow: borrow, isLiquidated: isLiquidated});
    }

    /// @notice Stages a vault's variant. Unset vaults report T1 (10000) so existing tests need no wiring;
    ///         set 20000/30000/40000 to stage a Smart vault.
    function setVaultType(address vault, uint256 vaultType) external {
        _vaultType[vault] = vaultType;
    }

    /// @notice Makes `getVaultType` revert, mimicking a non-Fluid address or an incompatible resolver version.
    function setVaultTypeReverts(bool v) external {
        _vaultTypeReverts = v;
    }

    /// @notice Makes `getVaultType` return fewer than 32 bytes, exercising the short-returndata guard.
    function setVaultTypeReturnsShort(bool v) external {
        _vaultTypeShort = v;
    }

    /// @notice Mirrors the live resolver: an address it does not know answers 0, NOT T1. Tests must stage a
    ///         type explicitly (`setVaultType(vault, 10000)`), otherwise the vault is treated as unknown —
    ///         which is the dominant rejection path in production.
    function getVaultType(address vault) external view returns (uint256) {
        if (_vaultTypeReverts) revert("resolver: no such vault");
        if (_vaultTypeShort) {
            assembly {
                return(0, 8) // 8 bytes < 32 -> caller must treat as not-T1
            }
        }
        return _vaultType[vault];
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

/// @notice A vault whose `constantsView()` reverts, while the resolver still types it T1 — the only way to
///         reach `positionLabels`' fail-open `catch`, which otherwise has no test.
contract MockRevertingFluidVault {
    error VaultBroken();

    function constantsView() external pure returns (IFluidVaultT1.ConstantViews memory) {
        revert VaultBroken();
    }
}

/// @notice Exposes `FluidVaultLib`'s internal helpers so tests can assert their RETURN VALUE rather than an
///         indirect side effect. Without this, e.g. the short-returndata guard cannot be tested: deleting it
///         makes `abi.decode` revert, the fan-out swallows that, and the observable result is identical.
contract FluidVaultLibHarness {
    function isT1(address vault, address resolver) external view returns (bool) {
        return FluidVaultLib.isT1(vault, resolver);
    }

    function supportsVaultType(address resolver) external view returns (bool) {
        return FluidVaultLib.supportsVaultType(resolver);
    }

    function vaultInfo(address vault, address resolver) external view returns (address, address, uint256) {
        return FluidVaultLib.vaultInfo(vault, resolver);
    }
}
