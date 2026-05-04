// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
import {InvalidArguments} from "src/errors.sol";

// Reuse the GPL-2.0-or-later libs landed by the Uniswap V3 adapter (PR #32, ADR-0008). The
// tick → sqrtPrice mapping, liquidity → token-amount conversion, and Q128 constant are all
// pure-math primitives that PancakeSwap V3 inherits unchanged from Uniswap V3.
import {TickMath} from "src/balances/protocols/uniswap/lib/TickMath.sol";
import {LiquidityAmounts} from "src/balances/protocols/uniswap/lib/LiquidityAmounts.sol";
import {FixedPoint128} from "src/balances/protocols/uniswap/lib/FixedPoint128.sol";

/// @title PancakeSwap V3 Pool Balance Oracle
/// @author kpk
/// @notice Reports an account's underlying token0/token1 balances and accrued (unclaimed) fees for
///         all PancakeSwap V3 NFT positions held in a single pool. One adapter instance per pool.
/// @dev PancakeSwap V3 is a line-for-line Uniswap V3 fork: same `IUniswapV3Pool` view surface
///      (`slot0`, `feeGrowthGlobal*X128`, `ticks`), same NonfungiblePositionManager `positions`
///      struct shape, same fee-growth math, same `LiquidityAmounts.getAmountsForLiquidity` mapping.
///      The adapter is therefore protocol-agnostic — the only PancakeSwap-specific input is the
///      `protocol` string emitted on each `PositionBalance`. PancakeSwap V3's fee tiers differ
///      from Uniswap's (PCS uses 100 / 500 / 2500 / 10000 vs Uniswap's 100 / 500 / 3000 / 10000),
///      but `fee` is just a `uint24` — the adapter passes it through unchanged.
///
/// @dev Position discovery is dynamic: the adapter iterates the account's NFTs from the
///      `NonfungiblePositionManager` (NPM) and filters those whose `(token0, token1, fee)`
///      match this pool. Multiple positions in the same pool are aggregated.
///
///      Returned `PositionBalance[]` is split for auditability: up to 4 entries per query —
///      `(token0 liquidity, token1 liquidity, token0 fees, token1 fees)`. NAVCalculator sums
///      them per asset downstream so the NAV total is unaffected by the split.
///
///      `amount` is always positive; `isDebt` is always false (LPs never carry debt).
///
///      Math:
///        - principal: `LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtA, sqrtB, L)`
///        - fees:      `mulDiv(feeGrowthInside - feeGrowthInsideLast, L, Q128) + tokensOwed`
///          where `feeGrowthInside` is reconstructed from the pool's `feeGrowthGlobal*X128`
///          and the per-tick `feeGrowthOutside*X128` of the position's tick range, branching
///          on the current tick. Mirrors PositionValue._fees from Uniswap v3-periphery, ported
///          to ^0.8 with OpenZeppelin's Math.mulDiv.
///
///      Bounded iteration: `_MAX_POSITIONS = 256` NFTs per query. This is high enough for any
///      realistic LP holder while defending against pathological NFT inboxes that would
///      otherwise grief the `view` call.
///
///      Out of scope (intentional, will land in follow-up PRs):
///        - MasterChefV3 staked NFTs (CAKE rewards) — needs an additional check on the NFT's
///          owner (it's the MasterChefV3 contract while staked) and a `pendingCake` accrual.
///        - Direct LP positions (positions minted directly via `pool.mint()` rather than via
///          the NPM). Adding them would be a sibling adapter using `pool.positions(positionKey)`.
///        - A factory wrapper. The constructor signature is shaped to plug into
///          `BalanceAdapterFactoryBase`'s CREATE2 flow once PR #16 lands.
contract PancakeSwapV3PoolBalanceOracle is IBalanceOracleAdapter {
    //
    // Type Definitions
    //

    /// @dev In-memory snapshot of a single NFT position's relevant fields.
    ///      Mirrors the subset of `INonfungiblePositionManager.positions(...)` we use.
    struct Position {
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

    //
    // State
    //

    /// @notice The PancakeSwap V3 pool this adapter reports on.
    address public immutable POOL;

    /// @notice The PancakeSwap V3 NonfungiblePositionManager. Differs per chain.
    address public immutable POSITION_MANAGER;

    /// @notice Pool token0 (cached at construction).
    address public immutable TOKEN0;

    /// @notice Pool token1 (cached at construction).
    address public immutable TOKEN1;

    /// @notice Pool fee tier (cached at construction). NFTs whose `fee` differs are skipped.
    uint24 public immutable FEE;

    /// @notice Pool tick spacing (cached at construction). Currently informational.
    int24 public immutable TICK_SPACING;

    /// @notice NAVCalculator (asset registry source for `getOraclePositions`).
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Bounded iteration limit for position discovery.
    uint256 internal constant _MAX_POSITIONS = 256;

    /// @notice Protocol identifier emitted on every PositionBalance (e.g. "PancakeSwap V3").
    string private _protocol;

    /// @notice Position detail base string emitted on liquidity entries (e.g. "WETH/COW 0.25%").
    ///         Fee entries append " Fees" to this string.
    string private _positionDetail;

    //
    // Constructor
    //

    /// @param pool_ The PancakeSwap V3 pool address.
    /// @param positionManager_ The NonfungiblePositionManager address (per-chain canonical NPM).
    /// @param protocol_ Protocol identifier (e.g. "PancakeSwap V3").
    /// @param positionDetail_ Position detail base (e.g. "WETH/COW 0.25%"). Liquidity entries use
    ///        this verbatim; fee entries use `"<positionDetail_> Fees"`.
    /// @param navCalculator_ NAVCalculator contract address (asset registry source).
    constructor(
        address pool_,
        address positionManager_,
        string memory protocol_,
        string memory positionDetail_,
        address navCalculator_
    ) {
        if (pool_ == address(0) || positionManager_ == address(0) || navCalculator_ == address(0)) {
            revert InvalidArguments();
        }
        require(pool_.code.length > 0, "Pool must be a contract");
        require(positionManager_.code.length > 0, "PositionManager must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        POOL = pool_;
        POSITION_MANAGER = positionManager_;
        TOKEN0 = IPancakeV3Pool(pool_).token0();
        TOKEN1 = IPancakeV3Pool(pool_).token1();
        FEE = IPancakeV3Pool(pool_).fee();
        TICK_SPACING = IPancakeV3Pool(pool_).tickSpacing();
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
        _protocol = protocol_;
        _positionDetail = positionDetail_;
    }

    //
    // IERC165
    //

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // IBalanceOracleAdapter
    //

    /// @inheritdoc IBalanceOracleAdapter
    /// @dev Returns `[TOKEN0, TOKEN1]`. Both tokens are always supported even if the account
    ///      currently holds no positions.
    function underlyingAssetsSupported() external view override returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = TOKEN0;
        assets[1] = TOKEN1;
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (asset == address(0) || (asset != TOKEN0 && asset != TOKEN1)) return (0, false);
        (uint256 liq0, uint256 liq1, uint256 fee0, uint256 fee1) = _getAccountAggregates(account);
        if (asset == TOKEN0) return (liq0 + fee0, false);
        return (liq1 + fee1, false);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        (uint256 liq0, uint256 liq1, uint256 fee0, uint256 fee1) = _getAccountAggregates(account);
        uint256 total0 = liq0 + fee0;
        uint256 total1 = liq1 + fee1;

        uint256 count = (total0 > 0 ? 1 : 0) + (total1 > 0 ? 1 : 0);
        assets = new address[](count);
        amounts = new uint256[](count);
        isDebt = new bool[](count);

        uint256 idx;
        if (total0 > 0) {
            assets[idx] = TOKEN0;
            amounts[idx] = total0;
            idx++;
        }
        if (total1 > 0) {
            assets[idx] = TOKEN1;
            amounts[idx] = total1;
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @dev Returns up to 4 entries: `(token0 liquidity, token1 liquidity, token0 fees, token1 fees)`,
    ///      dropping zeros. Only emits entries whose `underlyingAsset.asset` is registered on
    ///      NAVCalculator. If `assetFilter != address(0)`, clips to entries for that asset.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        // Filter supported tokens against NAVCalculator's registry.
        address[] memory supported = new address[](2);
        supported[0] = TOKEN0;
        supported[1] = TOKEN1;

        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        address[] memory registered = new address[](reg.length);
        for (uint256 i = 0; i < reg.length; i++) {
            registered[i] = reg[i].asset;
        }
        address[] memory eligible = ArrayLib.intersection(supported, registered);
        if (eligible.length == 0) return new INAVCalculator.PositionBalance[](0);

        bool token0Eligible = _contains(eligible, TOKEN0);
        bool token1Eligible = _contains(eligible, TOKEN1);

        if (assetFilter != address(0)) {
            if (assetFilter != TOKEN0 && assetFilter != TOKEN1) return new INAVCalculator.PositionBalance[](0);
            if (assetFilter == TOKEN0 && !token0Eligible) return new INAVCalculator.PositionBalance[](0);
            if (assetFilter == TOKEN1 && !token1Eligible) return new INAVCalculator.PositionBalance[](0);
            token0Eligible = token0Eligible && (assetFilter == TOKEN0);
            token1Eligible = token1Eligible && (assetFilter == TOKEN1);
        }

        (uint256 liq0, uint256 liq1, uint256 fee0, uint256 fee1) = _getAccountAggregates(account);

        // Pre-allocate max-size temp array (4 entries: liq0, liq1, fee0, fee1) and slice at end.
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](4);
        uint256 count;

        string memory liquidityDetail = _positionDetail;
        string memory feesDetail = string.concat(_positionDetail, " Fees");

        if (token0Eligible && liq0 > 0) {
            temp[count++] = _makePosition(TOKEN0, liq0, liquidityDetail);
        }
        if (token1Eligible && liq1 > 0) {
            temp[count++] = _makePosition(TOKEN1, liq1, liquidityDetail);
        }
        if (token0Eligible && fee0 > 0) {
            temp[count++] = _makePosition(TOKEN0, fee0, feesDetail);
        }
        if (token1Eligible && fee1 > 0) {
            temp[count++] = _makePosition(TOKEN1, fee1, feesDetail);
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
    }

    //
    // Internal Helpers
    //

    /// @notice Aggregates principal + fees totals for `account` across all of its NFTs in this pool.
    /// @return liq0 Total token0 derivable from in-range liquidity.
    /// @return liq1 Total token1 derivable from in-range liquidity.
    /// @return fee0 Total unclaimed token0 fees (settled `tokensOwed0` + accruing).
    /// @return fee1 Total unclaimed token1 fees (settled `tokensOwed1` + accruing).
    function _getAccountAggregates(address account)
        internal
        view
        returns (uint256 liq0, uint256 liq1, uint256 fee0, uint256 fee1)
    {
        if (account == address(0)) return (0, 0, 0, 0);

        // Pool snapshot read once and reused for every NFT.
        (uint160 sqrtPriceX96, int24 tickCurrent) = _slot0();
        uint256 fgGlobal0 = IPancakeV3Pool(POOL).feeGrowthGlobal0X128();
        uint256 fgGlobal1 = IPancakeV3Pool(POOL).feeGrowthGlobal1X128();

        uint256 nftBalance = INonfungiblePositionManager(POSITION_MANAGER).balanceOf(account);
        uint256 max = nftBalance > _MAX_POSITIONS ? _MAX_POSITIONS : nftBalance;

        for (uint256 i = 0; i < max; i++) {
            uint256 tokenId = INonfungiblePositionManager(POSITION_MANAGER).tokenOfOwnerByIndex(account, i);
            Position memory p = _readPosition(tokenId);

            // Filter: only positions in *this* pool.
            if (p.token0 != TOKEN0 || p.token1 != TOKEN1 || p.fee != FEE) continue;

            // Principal: amounts derivable from `liquidity` at the current price.
            if (p.liquidity > 0) {
                (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
                    sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(p.tickLower),
                    TickMath.getSqrtRatioAtTick(p.tickUpper),
                    p.liquidity
                );
                liq0 += a0;
                liq1 += a1;
            }

            // Fees: settled tokensOwed* plus accrued-since-last-update from the feeGrowth delta.
            (uint256 f0, uint256 f1) = _computeFees(p, tickCurrent, fgGlobal0, fgGlobal1);
            fee0 += f0;
            fee1 += f1;
        }
    }

    /// @notice Computes unclaimed fees for a single position.
    ///         Mirrors PositionValue._fees and _getFeeGrowthInside from Uniswap v3-periphery
    ///         (PancakeSwap V3 inherits the same accumulator math byte-for-byte).
    /// @dev Subtractions intentionally wrap (`unchecked`): `feeGrowthGlobal*X128` and the per-tick
    ///      `feeGrowthOutside*X128` are designed to overflow uint256, with the wrap cancelling out
    ///      when we later subtract `feeGrowthInsideLast`. This is the same pattern Uniswap uses
    ///      internally and the rationale is documented in the v3 whitepaper §6.3.
    function _computeFees(Position memory p, int24 tickCurrent, uint256 fgGlobal0, uint256 fgGlobal1)
        internal
        view
        returns (uint256 f0, uint256 f1)
    {
        (uint256 fgOutLower0, uint256 fgOutLower1) = _ticksFeeGrowthOutside(p.tickLower);
        (uint256 fgOutUpper0, uint256 fgOutUpper1) = _ticksFeeGrowthOutside(p.tickUpper);

        unchecked {
            uint256 fgInside0;
            uint256 fgInside1;
            if (tickCurrent < p.tickLower) {
                fgInside0 = fgOutLower0 - fgOutUpper0;
                fgInside1 = fgOutLower1 - fgOutUpper1;
            } else if (tickCurrent < p.tickUpper) {
                fgInside0 = fgGlobal0 - fgOutLower0 - fgOutUpper0;
                fgInside1 = fgGlobal1 - fgOutLower1 - fgOutUpper1;
            } else {
                fgInside0 = fgOutUpper0 - fgOutLower0;
                fgInside1 = fgOutUpper1 - fgOutLower1;
            }

            f0 = Math.mulDiv(fgInside0 - p.feeGrowthInside0LastX128, p.liquidity, FixedPoint128.Q128) + p.tokensOwed0;
            f1 = Math.mulDiv(fgInside1 - p.feeGrowthInside1LastX128, p.liquidity, FixedPoint128.Q128) + p.tokensOwed1;
        }
    }

    /// @notice Reads `(feeGrowthOutside0X128, feeGrowthOutside1X128)` from the pool's tick state.
    function _ticksFeeGrowthOutside(int24 tick) internal view returns (uint256 fgOut0, uint256 fgOut1) {
        (,, uint256 _fgOut0, uint256 _fgOut1,,,,) = IPancakeV3Pool(POOL).ticks(tick);
        return (_fgOut0, _fgOut1);
    }

    /// @notice Reads `(sqrtPriceX96, tick)` from the pool's `slot0`.
    function _slot0() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,,,,) = IPancakeV3Pool(POOL).slot0();
    }

    /// @notice Reads a single NFT position from the NPM and returns the subset we use.
    function _readPosition(uint256 tokenId) internal view returns (Position memory p) {
        (
            ,,
            address token0_,
            address token1_,
            uint24 fee_,
            int24 tickLower_,
            int24 tickUpper_,
            uint128 liquidity_,
            uint256 fgInside0Last_,
            uint256 fgInside1Last_,
            uint128 tokensOwed0_,
            uint128 tokensOwed1_
        ) = INonfungiblePositionManager(POSITION_MANAGER).positions(tokenId);
        p = Position({
            token0: token0_,
            token1: token1_,
            fee: fee_,
            tickLower: tickLower_,
            tickUpper: tickUpper_,
            liquidity: liquidity_,
            feeGrowthInside0LastX128: fgInside0Last_,
            feeGrowthInside1LastX128: fgInside1Last_,
            tokensOwed0: tokensOwed0_,
            tokensOwed1: tokensOwed1_
        });
    }

    /// @notice Builds a single PositionBalance entry for the given asset/amount/detail.
    function _makePosition(address asset, uint256 amount, string memory detail)
        internal
        view
        returns (INAVCalculator.PositionBalance memory)
    {
        return INAVCalculator.PositionBalance({
            underlyingAsset: _getAssetInfo(asset),
            balanceOracle: address(this),
            amount: amount,
            isDebt: false,
            protocol: _protocol,
            positionDetail: detail
        });
    }

    /// @notice Looks up asset metadata from the NAVCalculator registry.
    function _getAssetInfo(address asset) internal view returns (INAVCalculator.Asset memory) {
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == asset) return reg[i];
        }
        revert("Asset not found in NAVCalculator");
    }

    /// @notice Returns true iff `arr` contains `target`.
    function _contains(address[] memory arr, address target) internal pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == target) return true;
        }
        return false;
    }
}

// ---------------------------
// Interface Section
// ---------------------------

/// @notice Minimal PancakeSwap V3 pool interface (matches Uniswap V3 byte-for-byte).
interface IPancakeV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );
}

/// @notice Minimal NPM interface (ERC721Enumerable surface + `positions`).
interface INonfungiblePositionManager {
    function balanceOf(address owner) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
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
        );
}
