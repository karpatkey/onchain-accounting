// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {StaticCallLib} from "src/utils/StaticCallLib.sol";
import {ISickle, ISickleFactory} from "./ISickleFactory.sol";

/// @title SickleHeldPositions
/// @author KPK
/// @notice Meta-adapter mixin for protocols whose positions are held by the account's vfat **Sickle** rather than by
///         the account itself: it answers each instance for the account AND for that account's Sickle, and
///         concatenates the two.
///
/// @dev **WHY THIS EXISTS.** A vfat deposit moves the portfolio's tokens out of the Safe into the Safe's Sickle — a
///      per-owner proxy the factory deploys — and the Sickle is what ends up owning the LP position. NAVCalculator is
///      strictly account-scoped (`getAccountNav(account, quote)`; there is no sub-account aggregation anywhere in its
///      surface), so an adapter that only inspected `account` reports **zero** for a fully deployed portfolio. That is
///      not a theoretical hole: on chain 4663 the whole working book of three live vaults sits behind a Sickle.
///
/// @dev **WHY RESOLUTION IS SAFE HERE, AND WHAT IT IS CHECKED AGAINST.** This is the first adapter family in this repo
///      that reports positions held by an address other than the queried account, so the admission rule is explicit:
///      an address is admitted as a second holder only if **both** immutable vfat contracts agree, in **both**
///      directions — `SICKLE_FACTORY.sickles(account) == sickle` **and** `ISickle(sickle).owner() == account`. The
///      forward map alone would make the factory a single point of authority over what an account appears to own; the
///      reverse attestation alone would admit any contract that returns the right address. Nothing a third party can
///      do — deploying a Sickle, transferring an NFT into one, calling anything on either contract — satisfies both
///      for an account that does not own that Sickle. This mirrors `GearboxV3CreditAccountsMetaBalanceAdapter`, which
///      admits a factory-created Credit Account only after checking `creditAccountInfo(ca).borrower == account`; the
///      difference is that vfat publishes the forward map too, so the check runs both ways. See
///      [ADR 0026](../../../../docs/decisions/0026-sickle-held-positions.md).
///
/// @dev **FAIL-OPEN, DELIBERATELY, AND ONLY HERE.** Every read in {sickleOf} is a bounded `StaticCallLib` probe, and
///      any failure — no Sickle, a factory that does not answer, an owner mismatch — resolves to "this account has no
///      second holder", never to a revert. The direction is the family's: an unresolvable Sickle **under-reports** the
///      account. Reverting instead would be strictly worse than useless, because `PriceFeedLib._getAdapterPositions`
///      reads an adapter revert as "nothing to report", so the whole adapter — every instance, both holders — would
///      silently price at zero.
///
/// @dev **ISOLATION IS THE BASE'S, UNCHANGED.** Both holder reads happen inside ONE `_instancePositions` frame, so
///      {MetaBalanceAdapter}'s per-instance `try`/`catch` and its {GasStipendLib} exhaustion classification apply to
///      the pair exactly as they do to every single-holder adapter: a reverting instance costs that instance's legs
///      for both holders and nothing else, and an instance that runs out of gas still reverts
///      `InstanceGasExhausted` rather than returning a short answer.
///
/// @dev **COST.** Two extra staticcalls per instance (the pair is re-resolved per instance because a `view` adapter
///      has nowhere to cache it). Both hit the same two addresses for the whole fan-out, so only the first instance
///      pays cold-account pricing.
abstract contract SickleHeldPositions is MetaBalanceAdapter {
    /// @notice vfat's `SickleFactory` — the forward `owner → sickle` map. Immutable, per chain.
    ISickleFactory public immutable SICKLE_FACTORY;

    /// @param sickleFactory_ vfat SickleFactory for this chain. Must be a contract.
    constructor(address sickleFactory_) {
        AddressCheckLib.requireContract(sickleFactory_, "SickleFactory");
        SICKLE_FACTORY = ISickleFactory(sickleFactory_);
    }

    /// @notice The Sickle whose positions count as `account`'s, or `address(0)` when there is none to admit.
    /// @dev Admits only on agreement in both directions (see the contract-level `@dev`). Returns `address(0)` when
    ///      the factory does not answer, when no Sickle is recorded, when the recorded address holds no code, when
    ///      the Sickle does not answer `owner()`, or when it names a different owner. Also returns `address(0)` when
    ///      the Sickle IS the account (querying a Sickle directly is supported — it is its own holder and has no
    ///      Sickle of its own), so no holder is ever read twice.
    /// @dev A MALFORMED reply (a word whose upper 96 bits are dirty) is REJECTED, not masked: `address(0)` is a
    ///      meaningful branch value here ("no second holder"), so masking a broken word down to an address would
    ///      admit a holder nobody attested to — which is exactly why {StaticCallLib} offers the strict form.
    ///      Nothing in this function reverts.
    function sickleOf(address account) public view returns (address) {
        (bool okFwd, address sickle, bool badFwd) =
            StaticCallLib.safeAddrStrict(address(SICKLE_FACTORY), abi.encodeCall(ISickleFactory.sickles, (account)));
        if (!okFwd || badFwd || sickle == address(0) || sickle == account || sickle.code.length == 0) {
            return address(0);
        }

        (bool okRev, address owner, bool badRev) =
            StaticCallLib.safeAddrStrict(sickle, abi.encodeCall(ISickle.owner, ()));
        if (!okRev || badRev || owner == address(0) || owner != account) return address(0);

        return sickle;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Reads the instance for the account and for its admitted Sickle, and concatenates. `virtual` so a concrete
    ///      adapter can still specialise, though none needs to.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        virtual
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        INAVCalculator.PositionBalance[] memory own = _holderPositions(account, instance, assetFilter);

        address sickle = sickleOf(account);
        if (sickle == address(0)) return own;

        INAVCalculator.PositionBalance[] memory held = _holderPositions(sickle, instance, assetFilter);
        if (held.length == 0) return own;
        if (own.length == 0) return held;

        INAVCalculator.PositionBalance[] memory all = new INAVCalculator.PositionBalance[](own.length + held.length);
        for (uint256 i; i < own.length; ++i) {
            all[i] = own[i];
        }
        for (uint256 i; i < held.length; ++i) {
            all[own.length + i] = held[i];
        }
        return all;
    }

    /// @notice One holder, one instance: the per-venue read this mixin calls twice.
    /// @dev Implementations receive a HOLDER, not the queried account, and must not re-resolve anything from it.
    function _holderPositions(address holder, bytes32 instance, address assetFilter)
        internal
        view
        virtual
        returns (INAVCalculator.PositionBalance[] memory);
}
