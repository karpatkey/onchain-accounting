// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {PoolKey} from "src/balances/MetaBalanceAdapters/uniswap/v4/IUniswapV4.sol";
import {V4StateLibrary} from "src/balances/MetaBalanceAdapters/uniswap/v4/V4StateLibrary.sol";

/// @notice Stand-in for Uniswap V4's PositionManager: Solmate-ERC721 shaped, deliberately NOT enumerable.
/// @dev `ownerOf` REVERTS for an unminted or burned id, which is the behaviour both {V4PositionIndex} and the adapter
///      absorb, and `tokenOfOwnerByIndex` is simply absent — that absence is the premise of the whole V4 design, so
///      the mock must not accidentally provide it.
contract MockV4PositionManager {
    error NotMinted(uint256 tokenId);

    mapping(uint256 => address) private _owner;
    mapping(address => uint256) private _balance;
    mapping(uint256 => PoolKey) private _key;
    mapping(uint256 => uint256) private _info;
    mapping(uint256 => uint128) private _liquidity;

    function mint(address to, uint256 tokenId, PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liq)
        external
    {
        _owner[tokenId] = to;
        _balance[to] += 1;
        _key[tokenId] = key;
        _liquidity[tokenId] = liq;
        _info[tokenId] = packInfo(tickLower, tickUpper);
    }

    function transfer(address from, address to, uint256 tokenId) external {
        _balance[from] -= 1;
        _owner[tokenId] = to;
        _balance[to] += 1;
    }

    function burn(uint256 tokenId) external {
        _balance[_owner[tokenId]] -= 1;
        delete _owner[tokenId];
    }

    /// @dev V4-periphery `PositionInfoLibrary` layout: bit 0 `hasSubscriber`, bits 8..31 `tickLower`, bits 32..55
    ///      `tickUpper`, bits 56.. the truncated pool id. Only the ticks matter to the adapter.
    function packInfo(int24 tickLower, int24 tickUpper) public pure returns (uint256) {
        return (uint256(uint24(tickUpper)) << 32) | (uint256(uint24(tickLower)) << 8);
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = _owner[tokenId];
        if (o == address(0)) revert NotMinted(tokenId);
        return o;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _balance[owner];
    }

    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256) {
        return (_key[tokenId], _info[tokenId]);
    }

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128) {
        return _liquidity[tokenId];
    }
}

/// @notice Stand-in for the V4 PoolManager singleton: a raw word store behind `extsload`.
/// @dev V4 exposes no typed getters, so the only thing to mock is storage. Tests seed the exact slots
///      {V4StateLibrary} derives, which is also the cheapest way to prove the adapter reads the slots it claims to:
///      a derivation change makes every seeded word invisible and the amounts go to zero.
contract MockV4PoolManager {
    mapping(bytes32 => bytes32) public word;

    function set(bytes32 slot, bytes32 value) public {
        word[slot] = value;
    }

    /// @notice Seed one pool's `Slot0` + both fee-growth globals.
    function setPool(bytes32 poolId, uint160 sqrtPriceX96, int24 tick, uint256 feeGrowthGlobal0, uint256 fgg1)
        external
    {
        bytes32 stateSlot = V4StateLibrary.poolStateSlot(poolId);
        uint256 slot0 = uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160);
        set(stateSlot, bytes32(slot0));
        set(bytes32(uint256(stateSlot) + V4StateLibrary.FEE_GROWTH_GLOBAL0_OFFSET), bytes32(feeGrowthGlobal0));
        set(bytes32(uint256(stateSlot) + V4StateLibrary.FEE_GROWTH_GLOBAL1_OFFSET), bytes32(fgg1));
    }

    /// @notice Seed one tick's `feeGrowthOutside{0,1}X128` pair.
    function setTick(bytes32 poolId, int24 tick, uint256 fgOut0, uint256 fgOut1) external {
        bytes32 base = V4StateLibrary.tickBaseSlot(V4StateLibrary.poolStateSlot(poolId), tick);
        set(bytes32(uint256(base) + V4StateLibrary.TICK_FEE_GROWTH_OFFSET), bytes32(fgOut0));
        set(bytes32(uint256(base) + V4StateLibrary.TICK_FEE_GROWTH_OFFSET + 1), bytes32(fgOut1));
    }

    /// @notice Seed one position's `{liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128}`.
    function setPosition(
        bytes32 poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint128 liquidity,
        uint256 last0,
        uint256 last1
    ) external {
        bytes32 stateSlot = V4StateLibrary.poolStateSlot(poolId);
        bytes32 posSlot =
            V4StateLibrary.positionStateSlot(stateSlot, V4StateLibrary.positionKey(owner, tickLower, tickUpper, salt));
        set(posSlot, bytes32(uint256(liquidity)));
        set(bytes32(uint256(posSlot) + 1), bytes32(last0));
        set(bytes32(uint256(posSlot) + 2), bytes32(last1));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return word[slot];
    }

    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory out) {
        out = new bytes32[](nSlots);
        for (uint256 i; i < nSlots; ++i) {
            out[i] = word[bytes32(uint256(startSlot) + i)];
        }
    }

    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory out) {
        out = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            out[i] = word[slots[i]];
        }
    }
}

/// @notice vfat `SickleFactory` stand-in: the forward `owner -> sickle` map.
contract MockSickleFactory {
    mapping(address => address) public sickles;

    function setSickle(address owner, address sickle) external {
        sickles[owner] = sickle;
    }
}

/// @notice vfat `Sickle` stand-in: the reverse `sickle -> owner` attestation {SickleHeldPositions} checks.
contract MockSickle {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }
}
