// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @notice Uniswap V4 `PoolKey`, field-for-field.
/// @dev V4-core declares `currency0`/`currency1` as the `Currency` user-defined value type over `address` and `hooks`
///      as `IHooks`. Both are ABI-identical to `address`, so `abi.encode` of this struct produces the same five words
///      as the canonical one — which is what makes `keccak256(abi.encode(poolKey))` here equal the pool id V4 itself
///      uses. Verified on chain 4663 (measured, 16 Oct 2026): the key
///      `(USDG 0x5fc5360D…d168, META 0xc0D6457C…2f35, fee 3000, tickSpacing 60, hooks 0x0)` read off tokenId 3214040
///      hashes to `0x5875d407a42965b0e768c8925cea290e06fa50603ef34fc99eb92a1050e6ae36`, whose top 200 bits are
///      exactly the truncated pool id the PositionManager packs into that position's `PositionInfo`.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @notice The slice of the Uniswap V4 `PositionManager` the V4 adapter family calls.
/// @dev **NOT enumerable.** `balanceOf` works; `tokenOfOwnerByIndex` REVERTS — V4's PositionManager inherits Solmate's
///      ERC721, which implements no enumeration extension (measured on 4663: the selector is simply absent from the
///      deployed `0x58daec31…4fa7`). That single fact is why {V4PositionIndex} exists: unlike V3's
///      `ERC721Enumerable` NonfungiblePositionManager, a holder's V4 tokenIds are not derivable from chain state at
///      all — they exist only in `Transfer` logs, which a `view` on the NAV hot path cannot read.
interface IV4PositionManager {
    /// @dev Reverts for a nonexistent (never-minted or burned) tokenId.
    function ownerOf(uint256 tokenId) external view returns (address);

    function balanceOf(address owner) external view returns (uint256);

    /// @notice The position's pool key together with its packed `PositionInfo`.
    /// @dev `info` packing (v4-periphery `PositionInfoLibrary`): bits 56..255 truncated pool id, bits 32..55
    ///      `tickUpper` (int24), bits 8..31 `tickLower` (int24), bit 0 `hasSubscriber`.
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory poolKey, uint256 info);

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);

    function poolManager() external view returns (address);

    function nextTokenId() external view returns (uint256);
}

/// @notice V4-core's `Extsload` — raw storage reads against the PoolManager singleton.
/// @dev V4 replaced V3's per-pool contract with one singleton and exposes NO typed getters for pool state at all;
///      `extsload` is the sanctioned read path. The array form is what the valuation uses, so that one position's
///      whole snapshot (slot0, both fee-growth globals, both boundary ticks' fee-growth-outside pairs, and the
///      position's own three words) costs a SINGLE call rather than ten.
interface IExtsload {
    function extsload(bytes32 slot) external view returns (bytes32);
    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory);
    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory);
}
