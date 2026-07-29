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

/// @notice One of the account's NFT positions in `vault` could not be read, so the vault's collateral/debt
///         aggregate would be incomplete by an unknown amount in an unknown direction.
/// @dev Declared file-local rather than in `src/errors.sol` on purpose: both pinned libraries (`PriceFeedLib`,
///      `NAVRegistryLib`) plain-import that file, so adding to it would pull this symbol into both CREATE2
///      compilation closures for no benefit — only this library raises it, and only `MetaBalanceAdapter`'s
///      existing per-instance `catch` consumes it.
error FluidPositionUnreadable(address vault, uint256 nftId);

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
        (collateral, debt,) = vaultInfo(vault, resolver);
    }

    /// @notice Same read as {tokens}, plus Fluid's own per-vault numeric id from the same `constantsView()`.
    /// @dev The id is what makes a label unique: Fluid runs several isolated T1 vaults over the SAME
    ///      collateral/debt pair with different LTV/oracle configs (mainnet: 101 T1 vaults, only 91 distinct
    ///      pairs — every currently configured vault has a live same-pair twin), so the pair alone does not
    ///      identify an instance. Free to read: it comes from the struct {tokens} already decodes.
    /// @return collateral Supply token, or `address(0)` if `vault` is not a T1 vault.
    /// @return debt Borrow token, or `address(0)` if `vault` is not a T1 vault.
    /// @return vaultId Fluid's per-vault id, or 0 if `vault` is not a T1 vault.
    function vaultInfo(address vault, address resolver)
        internal
        view
        returns (address collateral, address debt, uint256 vaultId)
    {
        if (!isT1(vault, resolver)) return (address(0), address(0), 0);
        IFluidVaultT1.ConstantViews memory cv = IFluidVaultT1(vault).constantsView();
        return (cv.supplyToken, cv.borrowToken, cv.vaultId);
    }

    /// @notice True iff `resolver` answers the `getVaultType` selector at all — a deploy-time sanity check,
    ///         since token resolution is gated on it and a resolver without it would silently zero the whole
    ///         adapter (every vault reads as non-T1, so all Fluid legs, assets and labels disappear).
    /// @dev Deliberately weak, and NOT an authenticity check: it only proves the address returns >=32 bytes for
    ///      this selector, so any permissive fallback passes. That is acceptable because the resolver is
    ///      deployer-supplied config, not attacker-supplied, and the failure mode is under-report (a wrong
    ///      resolver types nothing as T1). It catches the realistic mistake — a resolver version that predates
    ///      `getVaultType`.
    ///      Probed with `address(0)` specifically: the live resolver returns 0 for a zero-code address but
    ///      REVERTS for a non-vault contract (verified: `getVaultType(WETH)` reverts), so probing with an
    ///      arbitrary address would reject a perfectly good resolver and abort the whole `04` deploy run —
    ///      `_deployIfEnabled` has no try/catch. A resolver that instead guarded `address(0)` would be wrongly
    ///      rejected here; none exists today.
    function supportsVaultType(address resolver) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            resolver.staticcall(abi.encodeWithSelector(IFluidVaultResolver.getVaultType.selector, address(0)));
        return ok && ret.length >= 32;
    }

    /// @notice True iff the resolver reports `vault` as a T1 vault. Fails closed: an unreadable or unknown
    ///         vault (resolver revert, `0` for an address it does not know, unexpected return shape) is
    ///         treated as not-T1.
    /// @dev Screens out Fluid's OWN Smart (T2/T3/T4) vaults; it does NOT authenticate a vault. The resolver
    ///      forwards to the vault's self-reported `TYPE()`, so a contract that claims `TYPE() == 10000` is
    ///      typed T1 with whatever `constantsView()` it likes. Only the resolver's no-`TYPE()` catch branch
    ///      verifies factory provenance. That is not a regression (there was no gate before) and requires
    ///      MANAGER to configure the impostor as an instance, but do not read this as a trust boundary.
    function isT1(address vault, address resolver) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            resolver.staticcall(abi.encodeWithSelector(IFluidVaultResolver.getVaultType.selector, vault));
        if (!ok || ret.length < 32) return false;
        return abi.decode(ret, (uint256)) == VAULT_TYPE_T1;
    }

    /// @notice Walks the account's Fluid NFTs through the resolver and sums collateral/debt for `vault`.
    /// @dev **An aggregate is either complete or it is not reported.** A per-NFT read that cannot be completed
    ///      raises {FluidPositionUnreadable} rather than being skipped, because skipping it moves the total in an
    ///      UNKNOWN direction. Each NFT contributes a supply and a borrow together, so dropping one changes the
    ///      vault's reported equity by `supply - borrow` — negative for an underwater position, which RAISES the
    ///      reported NAV. "Skip and carry on" is only conservative when the dropped term has a known sign, and
    ///      here it does not.
    ///
    ///      Skipping was also self-propagating in a way that made it invisible. The read is a fail-open
    ///      `staticcall`, so a frame that runs out of gas mid-loop fails this read, `continue`s, then fails every
    ///      remaining read for the same reason — and `aggregate` still RETURNED, with a partial total and no
    ///      indication that it was partial. `MetaBalanceAdapter`'s per-instance classifier never fired because
    ///      nothing had failed from where it stands.
    ///
    ///      Raising restores that classifier, and deliberately does NOT re-implement it. The caller
    ///      (`MetaBalanceAdapter._positionsForInstances`) already measures gas across its own `try` boundary and
    ///      splits the two cases for us, which is why there is no {GasStipendLib} call in this library:
    ///        - **starved** — the staticcall burned ~63/64 of the instance's stipend before this reverts, so the
    ///          caller scores it exhausted and raises `InstanceGasExhausted`, naming the vault. Loud, and
    ///          recoverable by supplying more gas. This is the "make truncation visible" half.
    ///        - **genuinely unreadable** — a short or reverting reply costs almost nothing, so the caller scores
    ///          it a benign revert and drops just this vault's legs. Conservative, and isolated to the one
    ///          instance exactly as before. This is the half that must NOT become loud, or one malformed NFT
    ///          would fail the whole account's NAV read.
    ///      One `revert` therefore yields both behaviours; adding a second classifier here would be a threshold
    ///      that could drift from the shared one.
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
            // NOT `continue`. See the note above: an omitted NFT moves the total in an unknown direction, and
            // the omission was unobservable because this function still returned.
            if (!ok || ret.length < 384) revert FluidPositionUnreadable(vault, nftId);

            (uint256 supply, uint256 borrow, bool isLiquidated) = _readUserPositionPrefix(ret);
            // `isLiquidated` is a protocol ANSWER, not a failed read: Fluid has zeroed the position, so both its
            // terms are genuinely 0 and skipping it omits nothing. This stays a `continue`.
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
