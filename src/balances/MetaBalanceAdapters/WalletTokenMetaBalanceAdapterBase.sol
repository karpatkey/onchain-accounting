// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

/// @title Wallet-Held Yield Token Meta Balance Adapter (base)
/// @author KPK
/// @notice Shared base for the adapters that report a **wallet-held yield-bearing token** as the protocol
///         position it actually is, rather than as an anonymous wallet holding.
/// @dev **Why this family exists.** `ERC20DefaultBalanceAdapter` stamps every registered asset with
///      `protocolId = wallet` and `positionKind = Wallet` — it has no per-asset branch at all, so a wstETH
///      balance is shaped identically to a WETH one. That is not a wrong classification so much as an absent
///      one: the default adapter has no mechanism to express which protocol a token belongs to.
///
///      Reporting a wallet-held token as a protocol position is **already the established pattern** in this
///      repo, not a new idea. `PositionKind` says so outright — *"LP principal sitting unstaked in the wallet
///      is `Supplied`"* — and `CapStablecoinBalanceAdapter` reads a plain `balanceOf` of a wallet token and
///      emits `ProtocolIds.CAP` + `Supplied`. Wallet-held Curve/Balancer LP and Morpho/Euler/Fluid vault
///      shares do the same. Yield-bearing assets were the gap only because they ARE registered NAV assets, so
///      the default adapter picks them up and no protocol adapter could claim them without double-counting.
///
///      **De-duplication is enforced HERE, on every read — the ordering is no longer load-bearing.** An
///      earlier version of this comment said the opposite, and it was true when written: the caller had to
///      call `NAVCalculator.excludeAssetFromDefaultAdapter` BEFORE adding the token to this adapter's
///      instance set, and reversing that pair double-reported the holding under two reconciliation keys with
///      no health flag — the +$11,375.92 species of issue #335.
///
///      `_reportedByDefaultAdapter` closed that. While the token is still in the default adapter's inclusion
///      list this adapter reports NOTHING, so the two can never both report and a reversed order now
///      UNDER-reports instead — the direction this repo licenses everywhere. Exclusion is still required, but
///      as the step that ENABLES reporting here, not as a safety measure whose omission over-reports.
///
///      **The balanceAsset is the token itself**, not an underlying. These tokens are registered and priced
///      NAV assets already, so the pricing path is untouched and the reported value is bit-identical to what
///      the default adapter produced. Only the identity fields change. This is deliberately unlike the
///      ERC-4626 vault adapters, which convert shares to an underlying because the SHARE is not a registered
///      asset there.
///
///      Identity is per-adapter and compile-time (`_protocolBrand`/`_protocolId`/`_protocolSubId` are `pure`),
///      which is why this is a base plus one thin subclass per protocol rather than one configurable adapter:
///      a single contract could only ever stamp one protocol across every instance, which would replace
///      `wallet` with an equally uninformative label.
abstract contract WalletTokenMetaBalanceAdapterBase is MetaBalanceAdapter {
    /// @notice The `ERC20DefaultBalanceAdapter` this NAV deploys in `initialize`, or `address(0)` if it has none.
    /// @dev Resolved ONCE at construction because it is set-once on the NAV: `Balances._setErc20DefaultBalanceAdapter`
    ///      reverts `InvalidArguments` if it is already non-zero, so it can never change under us and a per-read
    ///      lookup would buy nothing. Read by low-level staticcall because `INAVCalculator` does not declare the
    ///      getter, even though `Balances` makes it `public`.
    address public immutable ERC20_DEFAULT_ADAPTER;

    /// @notice The NAV did not answer `erc20DefaultBalanceAdapter()`, so the de-dup guard could not be armed.
    /// @dev Deploy-time and loud on purpose. Silently deploying with the guard disarmed is how the double-count
    ///      this family exists to avoid gets back in.
    error DefaultAdapterUnresolvable(address navCalculator);

    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address navCalculator_) MetaBalanceAdapter(navCalculator_) {
        (bool ok, bytes memory data) =
            navCalculator_.staticcall(abi.encodeWithSignature("erc20DefaultBalanceAdapter()"));
        if (!ok || data.length != 32) revert DefaultAdapterUnresolvable(navCalculator_);
        address dflt = abi.decode(data, (address));
        // ZERO IS REJECTED. An earlier version accepted it, reasoning that "a NAV with no default adapter
        // cannot double-count" — true at that instant, and false forever after, because
        // `_setErc20DefaultBalanceAdapter` is precisely a zero -> non-zero transition. The address is
        // `immutable`, so a zero read at construction disarms the de-dup guard for the contract's life with
        // no way to re-arm: exactly the outcome this error exists to prevent. Reachable by constructing
        // against the NAVCalculator IMPLEMENTATION rather than its proxy, or against a proxy deployed but
        // not yet initialized — both of which satisfy the base class's `getRegisteredAsset` probe.
        if (dflt == address(0)) revert DefaultAdapterUnresolvable(navCalculator_);
        ERC20_DEFAULT_ADAPTER = dflt;
    }

    /// @notice Whether `ERC20DefaultBalanceAdapter` is CURRENTLY also reporting `token`.
    /// @dev The de-dup guard. `registerAsset` unconditionally adds every asset to the default adapter's inclusion
    ///      list (`NAVCalculator.sol:181`), so each of this family's tokens starts out reported there. Until an
    ///      operator calls `excludeAssetFromDefaultAdapter`, both adapters emit a well-formed leg for the same
    ///      `balanceOf` under different reconciliation keys with no health flag — the +$11,375.92 species of
    ///      issue #335, reachable 17 more ways. Enforcing the ordering in a docstring alone leaves an
    ///      over-report one forgotten transaction away, so it is enforced here instead.
    ///
    ///      Fails CLOSED: an unreadable answer is treated as "still included", which suppresses this leg. That
    ///      is an under-report, the direction this repo licenses everywhere; the alternative fails toward the
    ///      double-count.
    function _reportedByDefaultAdapter(address token) internal view returns (bool) {
        // No zero check: the constructor rejects a zero address, so this is non-zero for the contract's life.
        // An earlier version returned `false` (report) on zero, which was the disarmed branch the constructor
        // guard exists to make impossible — keeping it would read as if zero were still a supported state.
        (bool ok, bytes memory data) =
            ERC20_DEFAULT_ADAPTER.staticcall(abi.encodeWithSignature("isSupportedByDefault(address)", token));
        if (!ok || data.length != 32) return true;
        return abi.decode(data, (bool));
    }

    /// @notice The `PositionKind` every instance of this adapter reports.
    /// @dev Per-adapter rather than per-instance: the kind follows the PROTOCOL's par-exit verb, and each
    ///      protocol in this family has exactly one. `Staking` when exiting at par means an unstake — a
    ///      withdrawal queue, cooldown, or validator-exit-gated redemption of staked principal. `Supplied`
    ///      when it means redeeming deposit or vault shares. Secondary-market sellability does not enter into
    ///      it (a freely tradable stcUSD is still `Staking`), nor does a wrapper's own liquidity buffer
    ///      fronting the queue (rETH is still `Staking`).
    function _positionKind() internal pure virtual returns (PositionKind);

    /// @notice The label category leaf, e.g. "LST" / "Savings" / "Vault".
    function _labelCategory() internal pure virtual returns (string memory);

    /// @inheritdoc MetaBalanceAdapter
    /// @dev The instance coordinate IS the token address, so `balanceAsset` and the position coordinate are
    ///      the same address. Returns empty — never reverts — when the token is unregistered, filtered out, or
    ///      the balance is zero, so one instance can never zero out the rest of the configured set.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        address token = _toAddress(instance);

        if (assetFilter != address(0) && assetFilter != token) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Unregistered is not an error here. An operator can remove an asset from the NAV without also
        // clearing this adapter's instance set (`unregisterAsset` does not touch meta instances), and the
        // residue must degrade to an under-report rather than a revert that takes the whole read down.
        (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(token);
        if (!found) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // The de-dup guard. Must sit AFTER the registry check so an unregistered token still short-circuits on
        // the cheaper path, and BEFORE the balance read so a suppressed leg costs no external call.
        if (_reportedByDefaultAdapter(token)) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // The raw balance, exactly as the default adapter read it. No conversion, no preview: the token is
        // itself the registered, priced asset, so any transformation here would change the NAV value and
        // break the invariant that this migration is value-neutral.
        uint256 amount = IERC20(token).balanceOf(account);
        if (amount == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](1);
        positions[0] = _leg(assetInfo, amount, false, _instancePositionId(instance), _positionKind());
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev The instance IS the asset — no vault indirection to resolve.
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = _toAddress(instance);
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `[category, <symbol>]` using the token's ERC20 `symbol()`; an unreadable symbol collapses to just
    ///      `[category]`. Uses the SYMBOL rather than the name, because these are tickers operators recognise
    ///      (wstETH, sDAI) where the full name is noise.
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        return _addressLabels(pid, _labelCategory(), true);
    }
}
