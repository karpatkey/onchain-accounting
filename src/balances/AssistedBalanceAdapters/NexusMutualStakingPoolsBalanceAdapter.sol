// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {WrapperFedBalanceAdapter} from "src/balances/WrapperFedBalanceAdapter.sol";
import {WrapperFedNftValuationAdapter} from "src/balances/AssistedBalanceAdapters/WrapperFedNftValuationAdapter.sol";
import {NexusMutualStakingValuationBase} from
    "src/balances/AssistedBalanceAdapters/NexusMutualStakingValuationBase.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";

/// @title Nexus Mutual Staking Pools Balance Adapter (id-cached, wrapper-fed)
/// @author KPK
/// @notice Wrapper-fed Nexus Mutual staking adapter: a trusted wrapper contract (holder of `WRAPPER_ROLE` — the
///         {NexusMutualStakingPoolsWrapper}) pushes/pops the account's StakingNFT `tokenId`s via `submit`/`remove`
///         **atomically as it forwards deposits/withdrawals** to the Nexus staking pool, so the id cache is kept
///         current on-chain in the same transaction that changes the position. All valuation logic — per-NFT NXM
///         `Staking` + `Rewards` legs, live ownership re-verification, positionId = staking-pool address, display
///         labels — lives in the shared, feeder-agnostic {NexusMutualStakingValuationBase}, identical to the
///         assistant-fed sibling `NexusMutualStakingPoolsAssistedBalanceAdapter`. Only the feeder and submit surface
///         differ: `WRAPPER_ROLE` + incremental single add/remove here vs. `ASSISTANT_ROLE` + off-chain full-set
///         replace there.
/// @dev Access control + the `WRAPPER_ROLE`-gated {submit}/{remove} surface come from {WrapperFedNftValuationAdapter}
///      (`DEFAULT_ADMIN_ROLE` administers, `WRAPPER_ROLE` feeds). The family invariant is unchanged (cache ids only,
///      value live, re-verify ownership per read → the wrapper can only under-report). This contract only wires the
///      constructor and reconciles ERC-165.
contract NexusMutualStakingPoolsBalanceAdapter is WrapperFedNftValuationAdapter, NexusMutualStakingValuationBase {
    /// @param stakingNft_      Nexus StakingNFT. Must be a contract.
    /// @param stakingViewer_   Nexus StakingViewer. Must be a contract.
    /// @param underlyingToken_ NXM token address.
    /// @param navCalculator_   NAVCalculator. Must be a contract.
    /// @param admin_           Holder of `DEFAULT_ADMIN_ROLE` (administers `WRAPPER_ROLE`). Required.
    /// @param wrapper_         Initial holder of `WRAPPER_ROLE` (the wrapper contract; optional — pass `address(0)` and
    ///        grant after the wrapper is deployed, since the wrapper needs this adapter's address at construction).
    constructor(
        address stakingNft_,
        address stakingViewer_,
        address underlyingToken_,
        address navCalculator_,
        address admin_,
        address wrapper_
    )
        WrapperFedNftValuationAdapter(admin_, wrapper_)
        NexusMutualStakingValuationBase(stakingNft_, stakingViewer_, underlyingToken_, navCalculator_)
    {}

    /// @inheritdoc IERC165
    /// @dev Adds {IPositionDescribable} on top of the wrapper-fed base advertisement
    ///      ({IWrapperFedBalanceAdapter}/{IBalanceAdapter}/{IAccessControl}/{IERC165}).
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(WrapperFedBalanceAdapter, IERC165)
        returns (bool)
    {
        return interfaceId == type(IPositionDescribable).interfaceId || super.supportsInterface(interfaceId);
    }
}
