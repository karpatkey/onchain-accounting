// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {UniswapV2PairLib} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV2PairLib.sol";

/// @title Uniswap V2 Pools Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's Uniswap V2 LP across *any* pair — the dilution-adjusted
///         pro-rata share of both reserves, emitted as one `Supply` leg per token. The instance coordinate is the
///         pair address, widened to bytes32; the active pair set lives on NAVCalculator (`addMetaInstances`).
///         Identity is derived on-chain (positionId = pair address; name = `sym0/sym1`). See ADR 0010.
/// @dev Valuation = instantaneous on-chain amounts (ADR 0017): this adapter reports the position's current
///      pro-rata share of the pair's on-chain reserves as per-token `amount`s, which NAVCalculator prices with
///      external oracles — it does NOT compute a manipulation-resistant "fair" value. Imbalancing the pair can
///      transiently move the reported amounts (a donation that arbitrage reverses within a block) but cannot be
///      monetised: NAV is a read-only oracle consumed by an asynchronous sub/redeem layer (no atomic on-chain
///      consumer). See docs/decisions/0017-lp-valuation-instantaneous-amounts.md; revisit if NAV is ever consumed
///      synchronously on-chain.
/// @dev The pro-rata + protocol-fee dilution math is delegated to `UniswapV2PairLib`, which mirrors the
///      leg-for-leg. Works with canonical Uniswap V2
///      and standard forks (SushiSwap, PancakeSwap V2) that preserve the `_mintFee` formula.
contract UniswapV2PoolsMetaBalanceAdapter is MetaBalanceAdapter {
    /// @notice Protocol identifier reported on every emitted position. `virtual` so byte-compatible forks
    ///         (PancakeSwap V2, SushiSwap) report their own slug while sharing the `(address pair)` positionId
    ///         schema. Defaults to `uniswap-v2`.
    function _protocolId() internal pure virtual override returns (bytes32) {
        return ProtocolIds.UNISWAP_V2;
    }

    /// @notice Protocol sub-identifier (the specific product) reported on every emitted position. `virtual` so
    ///         byte-compatible forks (PancakeSwap V2, SushiSwap) report their own sub-slug. For the V2 single-product
    ///         ecosystem the ecosystem and sub slug are the same value. Defaults to `uniswap-v2`.
    function _protocolSubId() internal pure virtual override returns (bytes32) {
        return ProtocolIds.UNISWAP_V2;
    }

    /// @notice Protocol brand (the broadest layer) reported on every emitted position. `virtual` so byte-compatible
    ///         forks (PancakeSwap V2, SushiSwap) report their own brand. Defaults to `uniswap`.
    function _protocolBrand() internal pure virtual override returns (bytes32) {
        return ProtocolIds.UNISWAP;
    }

    /// @notice `_mintFee` dilution coefficients `(numFactor, rootKCoeff, rootKLastCoeff)` for the protocol-fee LP
    ///         the pair would mint to `feeTo` on the next burn. Uniswap V2 captures 1/6 of fee growth → `(1, 5, 1)`.
    ///         `virtual` so a fork whose protocol-fee fraction differs (PancakeSwap V2 → `(8, 17, 8)`) reports the
    ///         correct burn-equivalent reserve share. SushiSwap shares Uniswap's constants and needs no override.
    function _mintFeeConstants()
        internal
        pure
        virtual
        returns (uint256 numFactor, uint256 rootKCoeff, uint256 rootKLastCoeff)
    {
        return (1, 5, 1);
    }

    /// @param protocolName_ Human-readable protocol name (e.g. "Uniswap V2").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {}

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the pair address. Emits up to 2 `Supply` legs, dropping zeros and unregistered assets,
    ///      respecting `assetFilter`.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        address pair = _toAddress(instance);
        bytes memory pid = _instancePositionId(instance);
        (uint256 numFactor, uint256 rootKCoeff, uint256 rootKLastCoeff) = _mintFeeConstants();
        (address token0, address token1, uint256 amount0, uint256 amount1) =
            UniswapV2PairLib.pairAmounts(pair, account, numFactor, rootKCoeff, rootKLastCoeff);

        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](2);
        uint256 count;

        (INAVCalculator.Asset memory a0, bool f0) = _eligible(token0, assetFilter);
        if (f0 && amount0 > 0) temp[count++] = _leg(a0, amount0, false, pid, PositionKind.Supplied);

        (INAVCalculator.Asset memory a1, bool f1) = _eligible(token1, assetFilter);
        if (f1 && amount1 > 0) temp[count++] = _leg(a1, amount1, false, pid, PositionKind.Supplied);

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        (address token0, address token1,,) = UniswapV2PairLib.pairAmounts(_toAddress(instance), address(0));
        assets = new address[](2);
        assets[0] = token0;
        assets[1] = token1;
    }

    function _eligible(address token, address assetFilter)
        private
        view
        returns (INAVCalculator.Asset memory assetInfo, bool eligible)
    {
        if (assetFilter != address(0) && token != assetFilter) return (assetInfo, false);
        (assetInfo, eligible) = _getAssetInfo(token);
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["AMM Liquidity Pool", "sym0/sym1"]`; leaf derived on-chain from the pair's token symbols.
    function positionLabels(bytes calldata pid) external view virtual override returns (string[] memory) {
        if (pid.length < 32) return new string[](0);
        address pair = abi.decode(pid, (address));
        // External self-call so a revert in the pair token0()/token1() reads (bad/non-pair instance) fails open
        // to the category-only label — a faulty label must never revert the (verbose-only) labels read.
        try this.pairTokenSymbols(pair) returns (string memory leaf) {
            return _labels("AMM Liquidity Pool", leaf);
        } catch {
            return _labels("AMM Liquidity Pool", "");
        }
    }

    /// @notice External wrapper (enables `try/catch` isolation in `positionLabels`): the pair's two token symbols
    ///         joined with "/". Reverts propagate only to the `positionLabels` catch arm.
    function pairTokenSymbols(address pair) external view returns (string memory) {
        (address token0, address token1,,) = UniswapV2PairLib.pairAmounts(pair, address(0));
        return string.concat(_symbol(token0), "/", _symbol(token1));
    }

    /// @notice Reads an ERC20 symbol, falling back to "?" for non-standard tokens (e.g. bytes32 symbols).
    function _symbol(address token) private view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory s) {
            return bytes(s).length == 0 ? "?" : s;
        } catch {
            return "?";
        }
    }
}
