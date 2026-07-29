// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {GasStipendLib} from "src/utils/GasStipendLib.sol";

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

/// @notice One of the account's NFT positions in `vault` ran out of the gas its read was given, so the vault's
///         aggregate would be incomplete and nothing downstream could tell.
/// @dev Declared file-local rather than in `src/errors.sol` on purpose: both pinned libraries (`PriceFeedLib`,
///      `NAVRegistryLib`) plain-import that file, so adding to it would pull this symbol into both CREATE2
///      compilation closures for no benefit — only this library raises it, and only `MetaBalanceAdapter`'s
///      existing per-instance `catch` consumes it.
error FluidPositionGasExhausted(address vault, uint256 nftId, uint256 stipend, uint256 consumed);

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

    /// @notice Bytes copied from `positionByNftId`'s reply. Covers the `>= 384` static prefix
    ///         {_readUserPositionPrefix} reads, with one word of slack; the rest is discarded by the EVM.
    uint256 internal constant READ_WINDOW = 416;

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
    /// @dev **The two ways a per-NFT read can fail get opposite answers, because they deserve them.**
    ///
    ///      An earlier revision raised on BOTH, with the reasoning that the caller
    ///      (`MetaBalanceAdapter._positionsForInstances`) already classifies gas across its own `try` boundary,
    ///      so one `revert` would yield both behaviours. That was wrong, and the way it was wrong is worth
    ///      keeping: the caller classifies correctly, but its benign-revert BEHAVIOUR is to drop the whole
    ///      instance. So a single unreadable NFT stopped omitting one NFT's `supply_i - borrow_i` and started
    ///      omitting the vault's entire `sum(supply) - sum(borrow)` — the same unknown-direction omission, at
    ///      larger magnitude, and for a net-debt vault that RAISES reported NAV. It also could not be seen: the
    ///      per-instance catch consumed it and `_positionsForInstances` returned normally. Both review gates
    ///      found this independently.
    ///
    ///        - **Starved** — the read did not answer, and neither will the ones after it, because the ~1/64
    ///          residue cannot fund them. `aggregate` would otherwise RETURN a partial total with nothing
    ///          downstream able to tell. Raises {FluidPositionGasExhausted}, which the caller scores exhausted
    ///          and re-raises as `InstanceGasExhausted`, naming the vault. Loud, and recoverable with more gas.
    ///        - **Genuinely unreadable** — a revert or a short reply. The resolver HAS answered about this one
    ///          NFT. Omit just it, as before. Still an unknown-direction omission, but the smallest one
    ///          available; escalating it to the whole vault trades a small silent error for a large one, and
    ///          failing the account's whole read over one malformed NFT is worse than either.
    ///
    ///      The classification is {GasStipendLib}'s, called rather than restated, so it cannot drift from the
    ///      threshold `MetaBalanceAdapter` and `PriceFeedLib` use.
    ///
    ///      The reply is read into a bounded 416-byte window rather than `(bool, bytes memory)`. Assigning that
    ///      pair makes solc `returndatacopy` the ENTIRE reply — `positionByNftId` returns a large struct pair —
    ///      and the caller pays that quadratically, OUTSIDE the stipend. 416 covers the `>= 384` prefix this
    ///      reads with a word to spare; bytes past it are discarded by the EVM, never copied.
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

            // One sample, used both to derive the stipend and to measure against it — see GasStipendLib.exhausted.
            uint256 available = gasleft();
            uint256 stipend = GasStipendLib.stipendFrom(available);
            bytes memory cd = abi.encodeWithSelector(IFluidVaultResolver.positionByNftId.selector, nftId);
            bytes memory ret = new bytes(READ_WINDOW);
            bool ok;
            uint256 size;
            assembly ("memory-safe") {
                ok := staticcall(stipend, resolver, add(cd, 0x20), mload(cd), add(ret, 0x20), READ_WINDOW)
                size := returndatasize()
            }
            if (!ok || size < 384) {
                uint256 consumed = available - gasleft();
                // Starved: this NFT did not answer, and neither will the ones after it — the residue cannot fund
                // them. Raise, so the caller's classifier turns it into a loud, retryable InstanceGasExhausted.
                if (GasStipendLib.exhausted(stipend, consumed)) {
                    revert FluidPositionGasExhausted(vault, nftId, stipend, consumed);
                }
                // Genuinely unreadable: the resolver has answered for this one NFT. Omit just it.
                continue;
            }

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
