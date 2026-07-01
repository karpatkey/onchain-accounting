// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title IAssistedBalanceAdapter
/// @author KPK
/// @notice Marker interface for balance adapters that cannot derive a position purely from on-chain state and
///         therefore require externally assisted state updates — a trusted party submits verifiable data (merkle
///         proofs, request/queue coordinates, token ids) via transactions so the positions become queryable from a
///         `view` read. Examples: Merkl reward proofs, ether.fi / StakeWise withdrawal-queue coordinates, and the
///         NFT token ids of Nexus Mutual staking positions (no per-account enumeration on-chain). (Uniswap V3 /
///         PancakeSwap V3 are NOT in this family — their NonfungiblePositionManager is `ERC721Enumerable`, so they
///         are ordinary meta-adapters.)
/// @dev The interface only *identifies* this family and exposes the role gating the assistance; it deliberately does
///      NOT prescribe how the data is submitted or verified — that is per-adapter, and each adapter must preserve the
///      family invariant that the assistant can only under-report, never over-report (values are read live on-chain
///      and ownership is re-verified per read). Role administration follows OpenZeppelin AccessControl:
///      `DEFAULT_ADMIN_ROLE` administers `ASSISTANT_ROLE`.
interface IAssistedBalanceAdapter is IAccessControl, IBalanceAdapter {
    /// @notice Role allowed to assist the adapter by submitting verifiable data.
    /// @return The `bytes32` role identifier (`keccak256("ASSISTANT_ROLE")`).
    function ASSISTANT_ROLE() external view returns (bytes32);
}
