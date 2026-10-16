// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {
    UniswapV3PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolsMetaBalanceAdapter.sol";
import {SickleHeldPositions} from "src/balances/MetaBalanceAdapters/vfat/SickleHeldPositions.sol";

/// @title Uniswap V3 Sickle Pools Meta Balance Adapter
/// @author KPK
/// @notice {UniswapV3PoolsMetaBalanceAdapter} for accounts that LP through vfat: it reports the account's own
///         Uniswap V3 positions AND the positions its vfat **Sickle** holds on its behalf, per NAV-governed pool.
///         Identity, valuation, enumeration, labels and the instance coordinate are the base adapter's, unchanged;
///         the only difference is WHO is enumerated.
///
/// @dev **WHY THIS CONTRACT EXISTS, AND WHY IT IS THIS SMALL.** A vfat deposit moves the portfolio's tokens out of
///      the Safe and into the Safe's Sickle, and the Sickle is what the NonfungiblePositionManager records as the
///      NFT's owner. NAVCalculator is account-scoped, so the base adapter asked about the Safe reports **zero** for
///      a fully deployed portfolio. {SickleHeldPositions} owns the whole of that indirection (resolution, the
///      bidirectional admission check, fail-open), and the base owns the whole of the Uniswap math. This file is
///      the two-line join between them: it contains no valuation code, and must never grow any — a divergence
///      between the two v3 adapters' amounts would be a silent mispricing of whichever book used the stale copy.
///
/// @dev **INSTANCE COORDINATE, AND WHY THE TRIPLE IS THE FACTORY QUESTION.** One governed instance is one v3 pool,
///      carried as the pool address widened to `bytes32`. An NFT belongs to that instance iff its
///      `(token0, token1, fee)` triple equals the pool's. That triple is exactly the key the v3 factory maps to a
///      pool address, so matching on it is the same statement as "the factory would return this pool" — reached
///      without a factory hop, and without trusting any single registry to still be the deployer of the pool the
///      NAV governs. Inherited verbatim from the base adapter.
///
/// @dev **FOUR LEGS PER NFT, AT MOST.** Two `Supplied` legs (the principal, off the liquidity curve at the pool's
///      live `slot0`) and two `Fees` legs. Zero-amount legs are dropped, so an out-of-range never-poked position
///      can yield a single row, or none. `symbol`/`decimals` are overwritten by NAVCalculator from its own
///      registered-asset record, so no token metadata is read on this path.
///
/// @dev **FEES ARE NOT `tokensOwed`, AND THAT MATTERS MORE HERE THAN ANYWHERE.** `tokensOwed{0,1}` only moves when
///      a position is poked (mint/burn/collect). Sickle positions are opened and left alone: measured 16 Oct 2026
///      at block 90,186,157, all six v3 NFTs held by the kRHUSD Sickle
///      (`0x6f94B45B68d9d446706436eB9D55E3a600a723Ba`) report `tokensOwed0 == tokensOwed1 == 0` while their
///      `feeGrowthInside*LastX128` are far behind the pools' current accumulators — real fee income the fund is
///      earning every block. An adapter that reported `tokensOwed` alone would report zero fees on every one of
///      them. The base recomputes the accrued part the way `Position.update` would,
///      `(feeGrowthInside - feeGrowthInsideLast) * liquidity / 2**128`, with the wrapping (`unchecked`) subtraction
///      v3 relies on, and adds the settled `tokensOwed` on top.
///
/// @dev **WHERE THIS PORT DIFFERS FROM THE CHAIN-4663 BUILD IT COMES FROM** (`UniswapV3SickleAdapter`), all three
///      deliberate:
///        1. **`MAX_POSITIONS` is 1000, not 256.** The 4663 contract capped enumeration at 256 NFTs per holder. On
///           2 Oct 2026 that cap became the attack: ERC-721 enumeration appends, so 256 dust mints to a Sickle
///           (≈0.004 ETH, **simulated**) push every later re-centre past the cap. Reproduced on a fork of kRHSPY at
///           block 81,841,547 on 6 Oct 2026: 256 dust NFTs (50,698,570 gas) moved a real tokenId past the cap and
///           NAV fell 51,104.607966 → 50,038.900112 USDG, −2.09% (**simulated**). This port inherits the base's
///           1000 unchanged rather than re-deciding it: the base's cap is documented against the same griefing
///           model, and a second, lower number in the same family would mean two different truncation points for
///           the same chain. The failure direction is identical and bounded either way — positions past the cap
///           are an **under-report**, never an over-report.
///        2. **There is a registered-asset gate.** The 4663 build had none: it emitted `Asset{asset, "", 0}` for
///           anything with a non-zero amount. The base drops the **whole instance** unless **both** pool tokens
///           are registered on NAVCalculator, because NAV values an LP from the sum of its two legs and a
///           half-priced LP silently understates it. On 4663 this is a live distinction, not a hypothetical: META
///           (`0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35`) is a pool leg that was not registered on the NAV
///           (recorded in `config/rh-4663.json`, measured), and the 4663 adapter would have reported its principal
///           into a NAV that then dropped it unpriced.
///        3. **Isolation is per-instance, not per-(holder, instance).** The 4663 base fanned out `holders ×
///           instances` and isolated each cell behind its own gas stipend. Here both holder reads happen inside one
///           {MetaBalanceAdapter} `_instancePositions` frame, so a pool that reverts costs that pool's legs for
///           both holders rather than for one. That is the upstream family's contract and it is the safer default
///           for the exhaustion classification: `INAVCalculator.InstanceGasExhausted` still fires rather than a
///           short answer being returned, and the two holders of one pool can no longer disagree about whether
///           that pool was readable.
///
/// @dev Licensing: links the GPL-2.0-or-later Uniswap math through its base
///      (docs/decisions/0008-uniswap-v3-math-libs-gpl-license.md) — combined work is GPL-2.0-or-later.
contract UniswapV3SicklePoolsMetaBalanceAdapter is UniswapV3PoolsMetaBalanceAdapter, SickleHeldPositions {
    /// @param positionManager_ The Uniswap V3 NonfungiblePositionManager for this chain. Must be a contract.
    /// @param navCalculator_   The NAVCalculator contract for asset-registry access. Must be a contract.
    /// @param sickleFactory_   vfat's SickleFactory for this chain. Must be a contract.
    constructor(address positionManager_, address navCalculator_, address sickleFactory_)
        UniswapV3PoolsMetaBalanceAdapter(positionManager_, navCalculator_)
        SickleHeldPositions(sickleFactory_)
    {}

    /// @inheritdoc SickleHeldPositions
    /// @dev Resolves the ambiguity between the two bases explicitly: the fan-out is the Sickle mixin's (account,
    ///      then the account's admitted Sickle), and the per-holder read below is the Uniswap base's.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override(UniswapV3PoolsMetaBalanceAdapter, SickleHeldPositions)
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return SickleHeldPositions._instancePositions(account, instance, assetFilter);
    }

    /// @inheritdoc SickleHeldPositions
    /// @dev The base adapter's per-account read, called once per holder. `holder` is already resolved — nothing
    ///      here may re-resolve anything from it, or an account's Sickle's Sickle would be walked.
    function _holderPositions(address holder, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return UniswapV3PoolsMetaBalanceAdapter._instancePositions(holder, instance, assetFilter);
    }
}
