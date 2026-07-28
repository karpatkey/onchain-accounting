// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {CurvePoolLib} from "./CurvePoolLib.sol";

/// @title CurvePoolsMetaBalanceAdapter
/// @author KPK
/// @notice One immutable adapter that reports an account's **wallet-held** (unstaked) LP position
///         across any configured Curve pool, decomposed pro-rata into the pool's underlying tokens.
///
/// @dev Instance coordinate: `bytes32(uint256(uint160(pool)))` — the pool address widened to bytes32.
///      For pools where the pool contract IS the LP token (classic StableSwap, TriCryptoNG) this is
///      also the LP token address. For pools with a separate LP ERC20 (StableSwap-NG factory, TwoCryptoNG)
///      CurvePoolLib.getLpToken() resolves it via lp_token() or by detecting the self-LP case.
///
///      Supported pool types (see CurvePoolLib for full details):
///        - StableSwap (original, Vyper 0.1.x, int128 indices)
///        - StableSwap-NG / factory plain pools (uint256 indices, separate LP token)
///        - StableSwap-NG Metapools (decomposes meta-coins only, not base-pool coins)
///        - CryptoSwap 2-coin (uint256, separate LP)
///        - TriCryptoNG (uint256, pool IS LP)
///        - TwoCryptoNG (uint256, separate LP with minter() = pool)
///        - Lending pools (reports wrapped-token balances; decimals match the registered asset)
///
///      For each registered pool coin with a non-zero pro-rata amount, one `Supplied` leg is emitted.
///      positionId = abi.encode(address pool)
///
///      Gauge-staked LP and rewards are handled separately by CurveGaugesMetaBalanceAdapter.
///
///      Valuation = instantaneous on-chain amounts (ADR 0017): this adapter reports the position's current
///      pro-rata share of the pool's on-chain balances as per-token `amount`s, which NAVCalculator prices with
///      external oracles — it does NOT compute a manipulation-resistant "fair" value. Imbalancing the pool can
///      transiently move the reported amounts (a donation that arbitrage reverses within a block) but cannot be
///      monetised: NAV is a read-only oracle consumed by an asynchronous sub/redeem layer (no atomic on-chain
///      consumer). See docs/decisions/0017-lp-valuation-instantaneous-amounts.md; revisit if NAV is ever consumed
///      synchronously on-chain.
contract CurvePoolsMetaBalanceAdapter is MetaBalanceAdapter {
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address navCalculator_) MetaBalanceAdapter(navCalculator_) {}

    // ─── MetaBalanceAdapter hooks ──────────────────────────────────────────────

    /// @inheritdoc MetaBalanceAdapter
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address pool = _toAddress(instance);

        // Resolve LP token (pool itself for classic/TriCryptoNG, separate ERC20 for NG factory)
        address lpToken = CurvePoolLib.getLpToken(pool);

        uint256 walletLp = _balanceOf(lpToken, account);
        if (walletLp == 0) return new INAVCalculator.PositionBalance[](0);

        uint256 totalSupply = CurvePoolLib.getTotalSupply(lpToken);
        if (totalSupply == 0) return new INAVCalculator.PositionBalance[](0);

        address[] memory coins = CurvePoolLib.getCoins(pool);
        if (coins.length == 0) return new INAVCalculator.PositionBalance[](0);

        bytes memory pid = _instancePositionId(instance);
        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](coins.length);
        uint256 n;

        for (uint256 i; i < coins.length; ++i) {
            address coin = coins[i];
            if (assetFilter != address(0) && coin != assetFilter) continue;

            (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(coin);
            if (!found) continue;

            uint256 poolBal = CurvePoolLib.getPoolBalance(pool, i);
            uint256 amount = CurvePoolLib.proRataAmount(poolBal, walletLp, totalSupply);
            if (amount == 0) continue;

            tmp[n++] = _leg(assetInfo, amount, false, pid, PositionKind.Supplied);
        }

        positions = new INAVCalculator.PositionBalance[](n);
        for (uint256 i; i < n; ++i) {
            positions[i] = tmp[i];
        }
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory) {
        return CurvePoolLib.getCoins(_toAddress(instance));
    }

    // ─── IPositionDescribable ─────────────────────────────────────────────────

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["AMM Liquidity Pool", "TOKEN0/TOKEN1/…"]`; leaf derived on-chain from coin symbols ("" on failure).
    function positionLabels(bytes calldata pid) external view virtual override returns (string[] memory) {
        (address pool, bool ok) = _pidAddress(pid);
        if (!ok) return new string[](0);
        string memory leaf = "";
        try this.poolCoinSymbols{gas: LABEL_LEAF_GAS_NARROW}(pool) returns (string memory l) {
            leaf = l;
        } catch {}
        return _labels("AMM Liquidity Pool", leaf);
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.CURVE;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.CURVE;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.CURVE_POOLS;
    }

    /// @notice Derives the "TOKEN0/TOKEN1/…" leaf from the pool coins ("" on failure).
    /// @dev The leaf is derived behind a bounded self-call rather than inline. It reads the chain through
    ///      addresses reached from the governed coordinate — pool coins, and an ERC20 `symbol()` per coin — and
    ///      unbounded that work can consume the budget of whatever called in, for a display string. The helper is
    ///      `external` only so this boundary exists; it is the same shape the pool/gauge symbol readers elsewhere
    ///      in the family already use. Exhaustion degrades to the category alone, exactly as an unreadable symbol
    ///      already does.
    function poolCoinSymbols(address pool) external view returns (string memory) {
        address[] memory coins = CurvePoolLib.getCoins(pool);
        if (coins.length == 0) return "";
        return CurvePoolLib.coinSymbols(coins);
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    function _balanceOf(address token, address account) private view returns (uint256) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        if (ok && data.length >= 32) return abi.decode(data, (uint256));
        return 0;
    }
}
