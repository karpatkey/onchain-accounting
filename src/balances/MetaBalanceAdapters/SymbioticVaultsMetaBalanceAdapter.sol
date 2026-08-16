// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626RedeemLib} from "src/balances/ERC4626RedeemLib.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Symbiotic Vaults Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports the underlying-asset balance for an account's position in *any*
///         Symbiotic ERC4626 vault. The set of vaults to query is configured on NAVCalculator (per-adapter,
///         MANAGER-gated) and passed in as `bytes32` instance coordinates (vault addresses widened to bytes32).
/// @dev Per-instance identity is encoded as `abi.encode(address(vault))`.
/// @dev **WHAT TIES THESE VAULTS TO SYMBIOTIC, positively.** Measured on mainnet 2026-08-15 for
///      `KPK USDC LiquidLane` `0x8BcD7469…`: it is a registered entity of the Symbiotic **VaultFactory**
///      `0xAEb6bdd95c502390db8f52c8909F703E9Af6a346` (`isEntity(vault) == true`, 357 entities), and its
///      `delegator()` `0xdC94E7D2…` was minted by **one of Symbiotic's TWO DelegatorFactories**,
///      `0xB5eFf01403C0dD3aDa1010919791d6EB82F6a84C` (24 delegators) — NOT the VaultConfigurator-paired
///      one, which is `0x985Ed57AF9D475f1d83c1c1c8826A0E5A34E8C7B` (333). The two sum to exactly the 357
///      vaults, and all share the VaultFactory's owner. The delegator's `vault()` points back at the vault.
///      That binding — not the absence of core-vault methods — is what justifies stamping `symbiotic`
///      identity here, and it is pinned by `test_premise_vaultIsRegisteredInSymbioticFactory` rather than
///      asserted in prose. **Do not restate this as "the paired" or "the canonical" delegator factory: a
///      future Symbiotic vault whose delegator came from `0x985Ed57A…` is equally valid**, and a premise
///      test copied from here with that assumption would fail on it. The test binds through each entity's
///      `FACTORY()` immutable, which is set by the factory at clone time and needs no such guess.
/// @dev **SCOPE — ERC-4626 Symbiotic vaults only, NOT Symbiotic CORE vaults.** Measured on mainnet
///      2026-08-15 against `KPK USDC LiquidLane` (`0x8BcD746976885b5832bAD07B4921E3f2dD1D3703`): the full
///      ERC-4626 surface answers (`asset()` = USDC, `previewRedeem`, `totalAssets`), while the Symbiotic
///      core surface — `collateral()`, `epochDuration()`, `currentEpoch()`, `activeShares()`,
///      `activeStake()`, `burner()` — **all revert**. A Symbiotic CORE vault has the opposite shape
///      (epoch-based `activeBalanceOf` plus a withdrawal queue) and is NOT valued correctly by this
///      adapter; it needs its own, per the roadmap's "vaults + delegations" entry. Registering a core
///      vault as an instance here yields NO position rather than a wrong number, but not for the reason
///      an earlier version of this note gave: `_instancePositions` reverts on its FIRST line, at
///      `vault.asset()`, which a core vault does not implement, and {MetaBalanceAdapter}'s per-instance
///      catch drops that instance. The outcome is an under-report either way — never do rely on it:
///      check the shape before adding an instance.
/// @dev **Single `Supplied` leg is correct — verified, not assumed.** The vault redeems synchronously:
///      `maxRedeem(holder) == balanceOf(holder)` exactly, for all four real holders sampled from Transfer
///      logs at block 25760274, and the ERC-7540 async surface (`pendingRedeemRequest` /
///      `claimableRedeemRequest`) reverts. So there is no pending/claimable withdrawal leg that
///      `balanceOf` would miss. If a future Symbiotic vault gates redemption behind a queue, that queued
///      value would be INVISIBLE here (an under-report, never an over-report) and would need a second leg.
/// @dev Deliberately a separate contract rather than an extra instance on {MorphoVaultsMetaBalanceAdapter}:
///      that adapter is also pure ERC-4626 and would value this vault correctly, but it would stamp
///      `morpho` / `morpho-vaults` identity onto a Symbiotic position, breaking the position-identity
///      schema and the reconciliation key built on it.
contract SymbioticVaultsMetaBalanceAdapter is MetaBalanceAdapter {
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address navCalculator_) MetaBalanceAdapter(navCalculator_) {}

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns an empty array (rather than reverting) when the vault asset is unregistered or the balance is
    ///      zero, so a single vault never zeroes out the rest of the configured set.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        IERC4626 vault = IERC4626(_toAddress(instance));
        address asset = vault.asset();

        // Apply asset filter
        if (assetFilter != address(0) && assetFilter != asset) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Skip unregistered assets (NAVCalculator would drop them anyway)
        (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(asset);
        if (!found) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Fee-aware share→asset value: previewRedeem, net of any EIP-4626 §4.3 exit fee. Reports 0 —
        // dropping the position via the `amount == 0` return below — if that read cannot be completed,
        // rather than substituting `convertToAssets`, which ignores the fee and so can only value the
        // position UPWARD. See {ERC4626RedeemLib.redeemValue}.
        uint256 amount = ERC4626RedeemLib.redeemValue(address(vault), vault.balanceOf(account));
        if (amount == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](1);
        positions[0] = _leg(assetInfo, amount, false, _instancePositionId(instance), PositionKind.Supplied);
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = IERC4626(_toAddress(instance)).asset();
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["Vault", <name>]` using the vault's ERC4626 `name()`; an unreadable name collapses to just
    ///      `["Vault"]` (empty-leaf convention in {_labels}). Returns an empty array for a malformed positionId (see {_pidAddress}).
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        return _addressLabels(pid, "Vault", false);
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.SYMBIOTIC;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.SYMBIOTIC;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.SYMBIOTIC_VAULTS;
    }
}
