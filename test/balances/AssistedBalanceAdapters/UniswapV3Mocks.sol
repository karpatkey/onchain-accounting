// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

// Mock contracts extracted from UniswapV3Pool.t.sol for use by UniswapV3PoolsMetaBalanceAdapter.t.sol

/// @notice Minimal Uniswap V3 pool mock — exposes the views the adapter reads.
contract MockUniswapV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;
    uint160 internal _sqrtPriceX96;
    int24 internal _tick;
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;
    bool internal _slot0Reverts;

    struct TickInfo {
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
    }

    mapping(int24 => TickInfo) internal _ticks;

    constructor(address token0_, address token1_, uint24 fee_, int24 tickSpacing_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        tickSpacing = tickSpacing_;
    }

    function setSlot0(uint160 sqrtPriceX96_, int24 tick_) external {
        _sqrtPriceX96 = sqrtPriceX96_;
        _tick = tick_;
    }

    function setFeeGrowthGlobal(uint256 fg0, uint256 fg1) external {
        feeGrowthGlobal0X128 = fg0;
        feeGrowthGlobal1X128 = fg1;
    }

    function setTickFeeGrowth(int24 tick, uint256 fgOut0, uint256 fgOut1) external {
        _ticks[tick] = TickInfo(fgOut0, fgOut1);
    }

    /// @notice Make `slot0()` revert, simulating an unreadable pool (e.g. a broken/exotic pool whose live reads
    ///         fail). Used to prove the adapter's per-NFT try/catch isolates the failing pool's NFT from the rest.
    function setSlot0Reverts(bool reverts) external {
        _slot0Reverts = reverts;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        require(!_slot0Reverts, "slot0 reverts");
        return (_sqrtPriceX96, _tick, 0, 0, 0, 0, false);
    }

    function ticks(int24 tick) external view returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool) {
        TickInfo memory info = _ticks[tick];
        return (0, 0, info.feeGrowthOutside0X128, info.feeGrowthOutside1X128, 0, 0, 0, false);
    }
}

/// @notice Minimal PancakeSwap V3 pool mock — identical to {MockUniswapV3Pool} except `slot0().feeProtocol` is
///         `uint32` (PancakeSwap V3 widens Uniswap's `uint8`). Used to prove the PancakeSwap adapter's `_slot0`
///         override decodes a `feeProtocol > uint8.max` without reverting (and that the Uniswap-base `uint8` decode
///         of the same returndata WOULD revert).
contract MockPancakeV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;
    uint160 internal _sqrtPriceX96;
    int24 internal _tick;
    uint32 internal _feeProtocol;
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    struct TickInfo {
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
    }

    mapping(int24 => TickInfo) internal _ticks;

    constructor(address token0_, address token1_, uint24 fee_, int24 tickSpacing_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        tickSpacing = tickSpacing_;
    }

    function setSlot0(uint160 sqrtPriceX96_, int24 tick_, uint32 feeProtocol_) external {
        _sqrtPriceX96 = sqrtPriceX96_;
        _tick = tick_;
        _feeProtocol = feeProtocol_;
    }

    function setFeeGrowthGlobal(uint256 fg0, uint256 fg1) external {
        feeGrowthGlobal0X128 = fg0;
        feeGrowthGlobal1X128 = fg1;
    }

    function setTickFeeGrowth(int24 tick, uint256 fgOut0, uint256 fgOut1) external {
        _ticks[tick] = TickInfo(fgOut0, fgOut1);
    }

    /// @dev PancakeSwap V3 ABI: `feeProtocol` is `uint32` (Uniswap V3 packs it as `uint8`).
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (_sqrtPriceX96, _tick, 0, 0, 0, _feeProtocol, false);
    }

    function ticks(int24 tick) external view returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool) {
        TickInfo memory info = _ticks[tick];
        return (0, 0, info.feeGrowthOutside0X128, info.feeGrowthOutside1X128, 0, 0, 0, false);
    }
}

/// @notice Minimal NonfungiblePositionManager mock — ERC721Enumerable surface + positions().
contract MockPositionManager {
    struct PositionData {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    mapping(uint256 => PositionData) internal _positions;
    mapping(address => uint256[]) internal _ownerTokens;
    mapping(uint256 => address) internal _tokenOwner;

    /// @notice The Uniswap V3 factory the adapter reads in its constructor (and queries for pool addresses).
    address public factory;

    function setFactory(address factory_) external {
        factory = factory_;
    }

    function mint(address owner, uint256 tokenId, PositionData memory data) external {
        _positions[tokenId] = data;
        _ownerTokens[owner].push(tokenId);
        _tokenOwner[tokenId] = owner;
    }

    /// @notice Reassign ownership of an existing tokenId (simulates an NFT transfer). Does NOT update the
    ///         `_ownerTokens` enumeration — tests exercise the id-cache + `ownerOf` re-verification path.
    function setOwner(uint256 tokenId, address owner) external {
        _tokenOwner[tokenId] = owner;
    }

    /// @notice Burn a tokenId so `ownerOf` reverts (simulates a closed/burned position).
    function burn(uint256 tokenId) external {
        delete _tokenOwner[tokenId];
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _ownerTokens[owner].length;
    }

    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256) {
        return _ownerTokens[owner][index];
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = _tokenOwner[tokenId];
        require(o != address(0), "ERC721: invalid token ID");
        return o;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        PositionData memory p = _positions[tokenId];
        return (
            0,
            address(0),
            p.token0,
            p.token1,
            p.fee,
            p.tickLower,
            p.tickUpper,
            p.liquidity,
            p.feeGrowthInside0LastX128,
            p.feeGrowthInside1LastX128,
            p.tokensOwed0,
            p.tokensOwed1
        );
    }
}

/// @notice Minimal Uniswap V3 factory mock — maps `(token0, token1, fee)` to a pool address (the adapter uses the
///         pool address as the positionId via `getPool`).
contract MockUniswapV3Factory {
    mapping(bytes32 => address) internal _pools;

    function _key(address t0, address t1, uint24 fee) internal pure returns (bytes32) {
        return keccak256(abi.encode(t0, t1, fee));
    }

    function setPool(address t0, address t1, uint24 fee, address pool) external {
        _pools[_key(t0, t1, fee)] = pool;
    }

    function getPool(address t0, address t1, uint24 fee) external view returns (address) {
        return _pools[_key(t0, t1, fee)];
    }
}

/// @notice Minimal ERC20-like mock so `address.code.length > 0` checks pass.
contract MockToken {
    string public symbol;
    uint8 public decimals;

    constructor(string memory symbol_, uint8 decimals_) {
        symbol = symbol_;
        decimals = decimals_;
    }
}
