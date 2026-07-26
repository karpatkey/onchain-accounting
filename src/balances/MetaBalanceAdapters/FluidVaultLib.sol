// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @notice Minimal Fluid T1 vault interface — just the static `constantsView` getter we use to
///         read the vault's collateral/debt tokens.
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
    /// @notice Vault variant: 10000 = T1, 20000/30000/40000 = the Smart (T2/T3/T4) vaults.
    function getVaultType(address vault) external view returns (uint256 vaultType);

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
/// @author KPK
/// @notice Shared read math for the Fluid T1 vaults meta-adapter. Resolves a vault's collateral/debt tokens and
///         aggregates an account's collateral/debt across its NFT positions in that vault.
/// @dev Ports the Fluid vault's `constantsView` token read + `_aggregateUserPositions` /
///      `_readUserPositionPrefix` verbatim, parameterized by the vault + resolver so one stateless library
///      serves every vault (the per-vault adapter cached the tokens at construction; here they are read per
///      call). Mirrors the per-vault adapter leg-for-leg (parity fork-tested). Only T1 vaults are supported —
///      Smart vaults (T2/T3/T4) have a different `constantsView` layout and must not be configured.
library FluidVaultLib {
    /// @notice Fluid's vault-variant discriminator for a T1 vault (Smart vaults return 20000/30000/40000).
    uint256 internal constant VAULT_TYPE_T1 = 10000;

    /// @notice Reads a T1 vault's `(collateral, debt)` tokens from its `constantsView()`.
    /// @dev Gated on the resolver's `getVaultType` as defence in depth. The T1 `ConstantViews` decode is
    ///      *partially* self-checking today — a Smart vault returns a longer (18-word) blob, and Solidity's
    ///      decoder range-checks the `uint8` decimals slots, so every one of the 80 non-T1 vaults live on
    ///      mainnet currently REVERTS rather than mis-decoding (surveyed across all 181 vaults; the T3 vault
    ///      0xe0E722E9… reverts because its word 6 holds an address). Note `cast`'s decoder does NOT
    ///      range-check `uint8` and will happily "decode" such a blob — do not use it to re-derive this.
    ///      That self-check is incidental, not guaranteed: it depends on where addresses happen to land in a
    ///      layout Fluid controls, so a future Smart variant could decode cleanly into wrong token slots. The
    ///      gate makes the outcome explicit and independent of that luck: a non-T1 vault reads back as zeros,
    ///      so a mis-configured instance reports nothing instead of positions against non-token addresses.
    /// @param vault The vault to read.
    /// @param resolver The Fluid VaultResolver, used for the type check.
    /// @return collateral Supply token, or `address(0)` if `vault` is not a T1 vault.
    /// @return debt Borrow token, or `address(0)` if `vault` is not a T1 vault.
    function tokens(address vault, address resolver) internal view returns (address collateral, address debt) {
        if (!isT1(vault, resolver)) return (address(0), address(0));
        IFluidVaultT1.ConstantViews memory cv = IFluidVaultT1(vault).constantsView();
        return (cv.supplyToken, cv.borrowToken);
    }

    /// @notice True iff the resolver reports `vault` as a T1 vault. Fails closed: an unreadable or unknown vault
    ///         (resolver revert, unexpected return shape) is treated as not-T1.
    function isT1(address vault, address resolver) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            resolver.staticcall(abi.encodeWithSelector(IFluidVaultResolver.getVaultType.selector, vault));
        if (!ok || ret.length < 32) return false;
        return abi.decode(ret, (uint256)) == VAULT_TYPE_T1;
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
