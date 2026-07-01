// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {LabelLib} from "src/balances/LabelLib.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {
    INonfungiblePositionManager,
    IUniswapV3Pool,
    UniswapV3PoolLib
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolLib.sol";

/// @title Uniswap V3 Pools Meta Balance Adapter
/// @author KPK
/// @notice One immutable meta-adapter that reports an account's Uniswap V3 LP across every configured pool — the
///         in-range liquidity (`Supplied`) and the full unclaimed fees (`Fees`) of each NFT position the account
///         holds in that pool. The instance coordinate is the pool address (widened to bytes32); the active pool
///         set is governed on NAVCalculator (`addMetaInstances`/`removeMetaInstances`, MANAGER-gated) — adding a
///         pool is a config TX, not a deploy. The NonfungiblePositionManager (NPM) is the chain-level constant
///         pinned in the constructor.
/// @dev Position discovery is fully on-chain: the NPM is `ERC721Enumerable`, so this reads `balanceOf(account)`
///      and iterates `tokenOfOwnerByIndex(account, i)` (bounded by `MAX_POSITIONS`), then `positions(tokenId)`,
///      keeping only the NFTs whose `(token0, token1, fee)` matches this pool. No off-chain assistant is needed
///      (this supersedes an interim assisted variant that cached agent-submitted tokenIds; the NPM being
///      enumerable makes that unnecessary). Because the framework calls
///      `_instancePositions` once per configured pool, an account's NFTs are re-enumerated per pool — O(pools ×
///      NFTs), bounded and cheap for the handful of configured pools.
/// @dev Identity: positionId = `abi.encode(pool)` (each `(token0, token1, fee)` triple is its own deployed pool, so
///      the pool address uniquely identifies pair+fee and is a stable coordinate). The NFT tokenId is the ephemeral
///      per-item coordinate carried in the typed `positionInstanceId` (all of an account's NFTs in one pool share
///      the positionId). Human labels are the verbose-only `["AMM Liquidity Pool", "<sym0>/<sym1> <fee>%"]`
///      breadcrumb via {IPositionDescribable.positionLabels}.
/// @dev **Both pool tokens must be registered in NAVCalculator** or the whole instance is dropped — NAV values an
///      LP from the sum of its two legs, so a half-priced LP would silently understate it. `assetFilter` only gates
///      which of the two legs are emitted.
/// @dev Valuation = instantaneous on-chain amounts (docs/decisions/0017-lp-valuation-instantaneous-amounts.md): the
///      in-range split is computed from the pool's live `slot0().sqrtPriceX96`/`tick` (read via the `_slot0` hook)
///      and the position's `liquidity`; fees are the full unclaimed amount (`feeGrowthInside`-since-poke + settled
///      `tokensOwed`). NAVCalculator prices the reported amounts with external oracles; a forced pool imbalance
///      transiently moves the amounts but cannot be monetised because NAV is consumed by an asynchronous sub/redeem
///      layer (no atomic on-chain consumer) — see the ADR.
/// @dev `_slot0` is `virtual`: it reads `(sqrtPriceX96, tick)` from `IUniswapV3Pool(pool).slot0()`. PancakeSwap
///      V3's `slot0().feeProtocol` is `uint32` (not Uniswap's `uint8`), so the full-tuple decode differs — the
///      `PancakeSwapV3PoolsMetaBalanceAdapter` subclass overrides `_slot0` with a matching ABI.
///      Licensing: links the GPL-2.0-or-later Uniswap math (TickMath, LiquidityAmounts, FixedPoint128 via
///      `UniswapV3PoolLib`) — combined work is GPL-2.0-or-later (docs/decisions/0008-uniswap-v3-math-libs-gpl-license.md).
contract UniswapV3PoolsMetaBalanceAdapter is MetaBalanceAdapter {
    using Strings for uint256;

    /// @notice Bounded iteration limit for per-account position discovery. A real account holds a handful of NFT
    ///         positions, far below this; the cap keeps the per-pool enumeration gas-bounded so a wallet holding a
    ///         pathological number of NPM NFTs can never brick the account's NAV scan.
    /// @dev The cap is over the account's FULL NPM NFT balance (the enumeration runs before the per-pool filter), so
    ///      an account holding more than `MAX_POSITIONS` NFTs globally has any position at enumeration index
    ///      `>= MAX_POSITIONS` silently omitted — an **under-report** (never an over-report), consistent with the
    ///      family's safe-direction bias. 256 is far above any managed portfolio's NFT count; a wallet approaching it
    ///      is an operational signal to split holdings, not a valuation the adapter can safely extend unbounded.
    uint256 public constant MAX_POSITIONS = 256;

    /// @notice The Uniswap V3 NonfungiblePositionManager (chain-level constant; same for all V3 pools on a chain).
    address public immutable POSITION_MANAGER;

    /// @param positionManager_ The NonfungiblePositionManager address (per-chain canonical NPM). Must be a contract.
    /// @param protocolName_    Human-readable protocol name (e.g. "Uniswap V3").
    /// @param navCalculator_   The NAVCalculator contract for asset-registry access. Must be a contract.
    constructor(address positionManager_, string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {
        AddressCheckLib.requireContract(positionManager_, "PositionManager");
        POSITION_MANAGER = positionManager_;
    }

    //
    // Identity hooks
    //

    /// @notice Broadest brand grouping. `virtual` so byte-compatible forks (PancakeSwap V3) report their own brand.
    function _protocolBrand() internal pure virtual override returns (bytes32) {
        return ProtocolIds.UNISWAP;
    }

    /// @notice Ecosystem/version id. `virtual` so forks report their own slug. (For V3 the ecosystem and sub match.)
    function _protocolId() internal pure virtual override returns (bytes32) {
        return ProtocolIds.UNISWAP_V3;
    }

    /// @notice Per-product slug (selects the positionId decode schema). `virtual` so forks report their own slug.
    function _protocolSubId() internal pure virtual override returns (bytes32) {
        return ProtocolIds.UNISWAP_V3;
    }

    //
    // Meta hooks
    //

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the pool address. Enumerates the account's NPM NFTs on-chain, keeps those in this pool,
    ///      and emits up to 4 legs per NFT: `Supplied` x2 (in-range split) + `Fees` x2 (full unclaimed) — dropping
    ///      zeros and honoring `assetFilter`. positionId = abi.encode(pool); the NFT id rides in positionInstanceId.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        address pool = _toAddress(instance);
        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();
        uint24 fee = IUniswapV3Pool(pool).fee();

        // Both tokens must be registered: valuing the LP split needs both oracle prices. `assetFilter` only gates
        // which legs are emitted (f0reg/f1reg).
        (INAVCalculator.Asset memory a0, bool reg0) = _getAssetInfo(token0);
        (INAVCalculator.Asset memory a1, bool reg1) = _getAssetInfo(token1);
        if (!reg0 || !reg1) return new INAVCalculator.PositionBalance[](0);
        bool f0reg = assetFilter == address(0) || assetFilter == token0;
        bool f1reg = assetFilter == address(0) || assetFilter == token1;
        if (!f0reg && !f1reg) return new INAVCalculator.PositionBalance[](0);

        // Live slot0 (ADR 0017 — instantaneous on-chain amounts): sqrtPriceX96 drives the in-range split and tick
        // selects the fee-growth branch. `_slot0` is virtual so PancakeSwap V3's uint32 feeProtocol ABI is handled
        // by the subclass.
        (uint160 sqrtPriceX96, int24 tick) = _slot0(pool);

        uint256 nftBalance = INonfungiblePositionManager(POSITION_MANAGER).balanceOf(account);
        uint256 max = nftBalance > MAX_POSITIONS ? MAX_POSITIONS : nftBalance;

        bytes memory positionId = abi.encode(pool);
        // Up to 4 legs per NFT (liq0, liq1, fee0, fee1).
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](max * 4);
        uint256 count;

        for (uint256 i; i < max; ++i) {
            uint256 tokenId = INonfungiblePositionManager(POSITION_MANAGER).tokenOfOwnerByIndex(account, i);
            UniswapV3PoolLib.Position memory p = UniswapV3PoolLib.readPosition(POSITION_MANAGER, tokenId);

            // Keep only NFTs in THIS pool (a (token0, token1, fee) triple is one deployed pool).
            if (p.token0 != token0 || p.token1 != token1 || p.fee != fee) continue;

            (uint256 liq0, uint256 liq1, uint256 fee0, uint256 fee1) =
                UniswapV3PoolLib.positionAmounts(pool, p, sqrtPriceX96, tick);

            bytes32 instanceId = bytes32(tokenId);
            if (f0reg && liq0 > 0) temp[count++] = _row(a0, liq0, positionId, PositionKind.Supplied, instanceId);
            if (f1reg && liq1 > 0) temp[count++] = _row(a1, liq1, positionId, PositionKind.Supplied, instanceId);
            if (f0reg && fee0 > 0) temp[count++] = _row(a0, fee0, positionId, PositionKind.Fees, instanceId);
            if (f1reg && fee1 > 0) temp[count++] = _row(a1, fee1, positionId, PositionKind.Fees, instanceId);
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; ++i) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        address pool = _toAddress(instance);
        assets = new address[](2);
        assets[0] = IUniswapV3Pool(pool).token0();
        assets[1] = IUniswapV3Pool(pool).token1();
    }

    //
    // Valuation hook
    //

    /// @dev Reads `(sqrtPriceX96, tick)` from the pool's `slot0`. `virtual` so a fork with a divergent `slot0()`
    ///      ABI overrides just this read — `PancakeSwapV3PoolsMetaBalanceAdapter` does so for PancakeSwap V3's
    ///      `uint32 feeProtocol` field (Uniswap V3 packs it as `uint8`).
    function _slot0(address pool) internal view virtual returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    //
    // Display
    //

    /// @inheritdoc IPositionDescribable
    /// @dev `["AMM Liquidity Pool", "<sym0>/<sym1> <fee>%"]` (e.g. `["AMM Liquidity Pool", "USDC/WETH 0.3%"]`) — the
    ///      leaf is read live from the pool decoded out of `positionId`. An unreadable symbol falls back to "?"; a
    ///      reverting pool falls back to just `["AMM Liquidity Pool"]`. Empty for a short/malformed positionId.
    function positionLabels(bytes calldata positionId) external view override returns (string[] memory out) {
        if (positionId.length < 32) return new string[](0);
        string memory leaf = _poolLeaf(abi.decode(positionId, (address)));
        if (bytes(leaf).length == 0) {
            out = new string[](1);
            out[0] = "AMM Liquidity Pool";
            return out;
        }
        out = new string[](2);
        out[0] = "AMM Liquidity Pool";
        out[1] = leaf;
    }

    /// @dev "<sym0>/<sym1> <fee>%" read live from the pool (e.g. "USDC/WETH 0.3%"); "" if a core pool read reverts.
    function _poolLeaf(address pool) private view returns (string memory) {
        uint24 fee;
        try IUniswapV3Pool(pool).fee() returns (uint24 f) {
            fee = f;
        } catch {
            return "";
        }
        address t0;
        address t1;
        try IUniswapV3Pool(pool).token0() returns (address a) {
            t0 = a;
        } catch {
            return "";
        }
        try IUniswapV3Pool(pool).token1() returns (address a) {
            t1 = a;
        } catch {
            return "";
        }
        return string.concat(_symbol(t0), "/", _symbol(t1), " ", _feePercent(fee), "%");
    }

    /// @dev ERC20 symbol with a "?" fallback for non-standard tokens (e.g. bytes32 symbols) or reverts.
    function _symbol(address token) private view returns (string memory) {
        return LabelLib.symbol(token, "?");
    }

    /// @dev Formats a V3 fee (hundredths of a bip: 3000 = 0.3%, 500 = 0.05%, 100 = 0.01%, 10000 = 1%) as a
    ///      percentage string with trailing zeros trimmed.
    function _feePercent(uint24 fee) private pure returns (string memory) {
        uint256 whole = uint256(fee) / 10000;
        uint256 frac = uint256(fee) % 10000; // ten-thousandths of a percent
        if (frac == 0) return whole.toString();
        bytes memory f = bytes(frac.toString());
        bytes memory padded = new bytes(4); // frac < 10000, so it fits in 4 digits
        uint256 lead = 4 - f.length;
        for (uint256 i = 0; i < 4; i++) {
            padded[i] = i < lead ? bytes1("0") : f[i - lead];
        }
        uint256 end = 4;
        while (padded[end - 1] == bytes1("0")) {
            end--; // frac != 0 guarantees a non-zero digit, so this never underflows
        }
        bytes memory trimmed = new bytes(end);
        for (uint256 i = 0; i < end; i++) {
            trimmed[i] = padded[i];
        }
        return string.concat(whole.toString(), ".", string(trimmed));
    }

    /// @dev Builds a PositionBalance leg with the per-NFT `positionInstanceId`. The base `_leg` hardcodes
    ///      positionInstanceId to bytes32(0); Uniswap V3 needs the NFT tokenId there, so it builds the leg inline
    ///      (identity fields still come from the `_protocol*` hooks).
    function _row(
        INAVCalculator.Asset memory asset,
        uint256 amount,
        bytes memory positionId,
        PositionKind kind,
        bytes32 positionInstanceId
    ) private view returns (INAVCalculator.PositionBalance memory) {
        return INAVCalculator.PositionBalance({
            balanceAsset: asset,
            balanceAdapter: address(this),
            amount: amount,
            isDebt: false,
            protocolBrand: _protocolBrand(),
            protocolId: _protocolId(),
            protocolSubId: _protocolSubId(),
            positionId: positionId,
            positionKind: kind,
            isLocked: false, // LP liquidity + unclaimed fees are always withdrawable
            positionInstanceId: positionInstanceId
        });
    }
}
