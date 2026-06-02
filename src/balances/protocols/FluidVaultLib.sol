// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @notice Minimal Fluid T1 vault interface — just the static `constantsView` getter we use to
///         read the vault's collateral/debt tokens at construction time.
interface IFluidVaultT1 {
    struct ConstantViews {
        address liquidity;
        address factory;
        address adminImplementation;
        address secondaryImplementation;
        address supplyToken;
        address borrowToken;
        uint8 supplyDecimals;
        uint8 borrowDecimals;
        uint256 vaultId;
        bytes32 liquiditySupplyExchangePriceSlot;
        bytes32 liquidityBorrowExchangePriceSlot;
        bytes32 liquidityUserSupplySlot;
        bytes32 liquidityUserBorrowSlot;
    }

    function constantsView() external view returns (ConstantViews memory);
}

/// @notice Minimal Fluid VaultResolver interface — only the views the adapter calls at runtime.
interface IFluidVaultResolver {
    /// @notice All NFT IDs owned by `user` across every Fluid vault.
    function positionsNftIdOfUser(address user) external view returns (uint256[] memory nftIds);

    /// @notice Vault address that minted `nftId`.
    function vaultByNftId(uint256 nftId) external view returns (address vault);

    /// @notice Per-NFT position details.
    function positionByNftId(uint256 nftId) external view returns (UserPosition memory userPosition);

    struct UserPosition {
        uint256 nftId;
        address owner;
        bool isLiquidated;
        bool isSupplyPosition;
        int256 tick;
        uint256 tickId;
        uint256 beforeSupply;
        uint256 beforeBorrow;
        uint256 beforeDustBorrow;
        uint256 supply;
        uint256 borrow;
        uint256 dustBorrow;
    }
}

/// @title FluidVaultLib
/// @author kpk
/// @notice Shared read math for the Fluid T1 vaults meta-adapter. Resolves a vault's collateral/debt tokens and
///         aggregates an account's collateral/debt across its NFT positions in that vault.
/// @dev Ports the Fluid vault 's `constantsView` token read + `_aggregateUserPositions` /
///      `_readUserPositionPrefix` verbatim, parameterized by the vault + resolver so one stateless library
///      serves every vault (the per-vault adapter cached the tokens at construction; here they are read per
///      call). Mirrors the per-vault adapter leg-for-leg (parity fork-tested). Only T1 vaults are supported —
///      Smart vaults (T2/T3/T4) have a different `constantsView` layout and must not be configured.
library FluidVaultLib {
    /// @notice Reads a T1 vault's `(collateral, debt)` tokens from its `constantsView()`.
    function tokens(address vault) internal view returns (address collateral, address debt) {
        IFluidVaultT1.ConstantViews memory cv = IFluidVaultT1(vault).constantsView();
        return (cv.supplyToken, cv.borrowToken);
    }

    /// @notice Walks the account's Fluid NFTs through the resolver and sums collateral/debt for `vault`.
    /// @return collateralTotal Total collateral (collateral-token decimals).
    /// @return debtTotal Total debt (debt-token decimals).
    function aggregate(address vault, address resolver, address account)
        internal
        view
        returns (uint256 collateralTotal, uint256 debtTotal)
    {
        if (account == address(0)) return (0, 0);

        uint256[] memory nftIds = IFluidVaultResolver(resolver).positionsNftIdOfUser(account);
        for (uint256 i = 0; i < nftIds.length; i++) {
            uint256 nftId = nftIds[i];
            if (IFluidVaultResolver(resolver).vaultByNftId(nftId) != vault) continue;

            (bool ok, bytes memory ret) =
                resolver.staticcall(abi.encodeWithSelector(IFluidVaultResolver.positionByNftId.selector, nftId));
            if (!ok || ret.length < 384) continue;

            (uint256 supply, uint256 borrow, bool isLiquidated) = _readUserPositionPrefix(ret);
            if (isLiquidated) continue;
            collateralTotal += supply;
            debtTotal += borrow;
        }
    }

    /// @notice Reads the static `UserPosition` prefix (`isLiquidated`@64, `supply`@288, `borrow`@320) from a
    ///         `(UserPosition, VaultEntireData)` ABI-encoded return; the trailing payload is ignored.
    function _readUserPositionPrefix(bytes memory ret)
        private
        pure
        returns (uint256 supply, uint256 borrow, bool isLiquidated)
    {
        uint256 isLiquidatedWord;
        assembly {
            let dataPtr := add(ret, 32) // skip the bytes-length prefix
            isLiquidatedWord := mload(add(dataPtr, 64))
            supply := mload(add(dataPtr, 288))
            borrow := mload(add(dataPtr, 320))
        }
        isLiquidated = isLiquidatedWord != 0;
    }
}
