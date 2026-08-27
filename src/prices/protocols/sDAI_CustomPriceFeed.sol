// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";

/// @title sDAI Custom Price Oracle
/// @notice Returns the USD price of sDAI as `(DAI/USD) × (DAI per sDAI share)`, the vault's live
///         ERC-4626 exchange rate times the NAV's DAI/USD price.
/// @dev Thin {ERC4626VaultRatePriceFeed} subclass — the rate/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the Sky Savings Dai vault, the NAV, and the base asset (DAI).
///
///      NOTE FOR FUTURE MAINTAINERS: a file of this name was deleted once before, in bbd2b490 ("delete the
///      dead sDAI feed"). It was removed because nothing referenced it — mainnet sDAI was not a registered
///      asset and Gnosis had been superseded by sXDAI_CustomPriceFeed — NOT because the recipe was wrong.
///      Mainnet sDAI IS a registered asset now, so this feed is live. Do not delete it again as dead code
///      without first checking script/config/nav-config/assets-and-price-feeds/1.json.
///
///      TRUST MODEL — unlike its Spark Savings siblings (spUSDC/spUSDT/spETH), `SavingsDai` is NOT upgradeable:
///      it has no EIP-1967 implementation slot and derives its rate from the Sky Pot's `chi`/`dsr`. The four are
///      grouped together in config and in the integration fixtures, so the difference is recorded here rather
///      than inferred. The rate is a pure time accumulator — no `totalSupply`, `totalAssets` or `balanceOf` in
///      the path — so it is donation-, inflation- and flash-loan-proof.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract sDAI_CustomPriceFeed is ERC4626VaultRatePriceFeed {
    /// @param sDai_ Address of the Sky Savings Dai vault contract.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (DAI) whose NAV-selected USD price scales the vault rate.
    constructor(address sDai_, address nav_, address baseAsset_) ERC4626VaultRatePriceFeed(sDai_, nav_, baseAsset_) {}
}
