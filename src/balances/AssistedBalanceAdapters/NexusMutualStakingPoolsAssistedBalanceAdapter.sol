// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {AssistedBalanceAdapter} from "src/balances/AssistedBalanceAdapter.sol";
import {AssistedNftValuationAdapter} from "src/balances/AssistedBalanceAdapters/AssistedNftValuationAdapter.sol";
// INexusStakingViewer is re-exported here so the existing test keeps resolving it from this file.
import {NexusMutualStakingValuationBase, INexusStakingViewer} from
    "src/balances/AssistedBalanceAdapters/NexusMutualStakingValuationBase.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";

/// @title Nexus Mutual Staking Pools Balance Adapter (id-cached, assistant-fed)
/// @author KPK
/// @notice Assistant-fed Nexus Mutual staking adapter: an off-chain assistant (holder of `ASSISTANT_ROLE`) submits the
///         account's StakingNFT `tokenId`s via `submitTokenIds` (full-set replace); all valuation logic — per-NFT NXM
///         `Staking` + `Rewards` legs, live ownership re-verification, positionId = staking-pool address, display
///         labels — lives in the shared, feeder-agnostic {NexusMutualStakingValuationBase}. Its wrapper-fed sibling,
///         `NexusMutualStakingPoolsBalanceAdapter`, reuses the same valuation base but is fed on-chain by a wrapper
///         contract holding `WRAPPER_ROLE`.
/// @dev Access control + the `ASSISTANT_ROLE`-gated submit/clear surface come from {AssistedNftValuationAdapter}
///      (`DEFAULT_ADMIN_ROLE` administers, `ASSISTANT_ROLE` submits). Everything else is inherited from
///      {NexusMutualStakingValuationBase}. This contract only wires the constructor and reconciles ERC-165.
contract NexusMutualStakingPoolsAssistedBalanceAdapter is
    AssistedNftValuationAdapter,
    NexusMutualStakingValuationBase
{
    /// @param stakingNft_      Nexus StakingNFT. Must be a contract.
    /// @param stakingViewer_   Nexus StakingViewer. Must be a contract.
    /// @param underlyingToken_ NXM token address.
    /// @param navCalculator_   NAVCalculator. Must be a contract.
    /// @param admin_           Holder of `DEFAULT_ADMIN_ROLE` (administers `ASSISTANT_ROLE`). Required.
    /// @param assistant_       Initial holder of `ASSISTANT_ROLE` (optional; pass `address(0)` to grant later).
    constructor(
        address stakingNft_,
        address stakingViewer_,
        address underlyingToken_,
        address navCalculator_,
        address admin_,
        address assistant_
    )
        AssistedNftValuationAdapter(admin_, assistant_)
        NexusMutualStakingValuationBase(stakingNft_, stakingViewer_, underlyingToken_, navCalculator_)
    {}

    /// @inheritdoc IERC165
    /// @dev Adds {IPositionDescribable} on top of the family's base advertisement
    ///      ({IAssistedBalanceAdapter}/{IBalanceAdapter}/{IAccessControl}/{IERC165}).
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AssistedBalanceAdapter, IERC165)
        returns (bool)
    {
        return interfaceId == type(IPositionDescribable).interfaceId || super.supportsInterface(interfaceId);
    }
}
