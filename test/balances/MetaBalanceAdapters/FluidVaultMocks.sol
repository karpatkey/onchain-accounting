// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {
    FluidPositionGasExhausted,
    IFluidVaultT1,
    IFluidVaultResolver,
    FluidVaultLib
} from "src/balances/MetaBalanceAdapters/FluidVaultLib.sol";

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

    /// @notice Per-NFT failure mode for `positionByNftId`.
    /// @dev The mock had none, which is why `FluidVaultLib.aggregate`'s starved/unreadable classification —
    ///      logic now on its THIRD revision, defective in the first two — had no test at all. Found in review.
    enum PosMode {
        Ok,
        CheapRevert,
        Short,
        Starve,
        Oversized
    }

    mapping(uint256 => PosMode) private _posMode;

    function setPosMode(uint256 nftId, PosMode m) external {
        _posMode[nftId] = m;
    }

    /// @notice Makes `vaultByNftId` answer with a word carrying dirty bits above 160 for `nftId`.
    /// @dev The ONLY way to reach the in-frame address decode that sits inside the hardened loop but outside
    ///      its starved/unreadable classification. Nothing else in this mock can produce it.
    mapping(uint256 => bool) private _dirtyVaultWord;

    function setDirtyVaultWord(uint256 nftId, bool v) external {
        _dirtyVaultWord[nftId] = v;
    }

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
        if (_dirtyVaultWord[nftId]) {
            assembly {
                mstore(0x00, not(0)) // every bit set: a valid word, not a valid address
                return(0x00, 0x20)
            }
        }
        return _posByNftId[nftId].vault;
    }

    function positionByNftId(uint256 nftId) external view returns (IFluidVaultResolver.UserPosition memory pos) {
        PosMode m = _posMode[nftId];
        if (m == PosMode.CheapRevert) revert("resolver: position unreadable");
        if (m == PosMode.Short) {
            // 383 bytes: one byte under the `>= 384` prefix the reader needs.
            assembly {
                return(0x00, 383)
            }
        }
        if (m == PosMode.Starve) {
            assembly {
                for {} 1 {} { mstore(0x00, keccak256(0x00, 0x20)) }
            }
        }
        PosData memory pd = _posByNftId[nftId];
        pos.nftId = nftId;
        pos.owner = address(0);
        pos.isLiquidated = pd.isLiquidated;
        pos.supply = pd.supply;
        pos.borrow = pd.borrow;
        if (m == PosMode.Oversized) {
            // A correct 384-byte prefix followed by a large tail, to prove the bounded READ_WINDOW copies the
            // prefix faithfully and discards the rest rather than truncating into it.
            uint256 supply = pd.supply;
            uint256 borrow = pd.borrow;
            assembly {
                let out := mload(0x40)
                mstore(add(out, 0x40), 0) // isLiquidated
                mstore(add(out, 0x120), supply) // offset 288
                mstore(add(out, 0x140), borrow) // offset 320
                return(out, 8576)
            }
        }
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

    /// @notice Direct access to the aggregate, so tests assert its RETURN VALUE rather than an indirect effect.
    function aggregate(address vault, address resolver, address account) external view returns (uint256, uint256) {
        return FluidVaultLib.aggregate(vault, resolver, account);
    }

    /// @notice Runs {aggregate} under an explicit gas budget and reports how it ended.
    /// @return status 0 = returned, 1 = raised FluidPositionGasExhausted, 2 = some other revert.
    function aggregateBounded(address vault, address resolver, address account, uint256 budget)
        external
        view
        returns (uint8 status, uint256 collateral, uint256 debt)
    {
        try FluidVaultLibHarness(address(this)).aggregate{gas: budget}(vault, resolver, account) returns (
            uint256 c, uint256 d
        ) {
            return (0, c, d);
        } catch (bytes memory err) {
            if (err.length >= 4 && bytes4(err) == FluidPositionGasExhausted.selector) return (1, 0, 0);
            return (2, 0, 0);
        }
    }

    function vaultInfo(address vault, address resolver) external view returns (address, address, uint256) {
        return FluidVaultLib.vaultInfo(vault, resolver);
    }
}
