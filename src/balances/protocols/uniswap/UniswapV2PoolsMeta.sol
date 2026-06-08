// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceOracle} from "src/balances/MetaBalanceOracle.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {UniswapV2PairLib} from "src/balances/protocols/uniswap/UniswapV2PairLib.sol";

/// @title Uniswap V2 Pools Meta Balance Adapter
/// @author kpk
/// @notice One immutable adapter that reports an account's Uniswap V2 LP across *any* pair — the dilution-adjusted
///         pro-rata share of both reserves, emitted as one `Supply` leg per token. The instance coordinate is the
///         pair address, widened to bytes32; the active pair set lives on NAVCalculator (`setMetaInstances`).
///         Identity is derived on-chain (positionId = pair address; name = `sym0/sym1 LP`). See ADR 0010.
/// @dev The pro-rata + protocol-fee dilution math is delegated to `UniswapV2PairLib`, which mirrors the
///      leg-for-leg. Works with canonical Uniswap V2
///      and standard forks (SushiSwap, PancakeSwap V2) that preserve the `_mintFee` formula.
contract UniswapV2PoolsMetaBalanceAdapter is MetaBalanceOracle {
    /// @notice Protocol identifier reported on every emitted position. `virtual` so byte-compatible forks
    ///         (PancakeSwap V2, SushiSwap) report their own slug while sharing the `(address pair)` positionId
    ///         schema. Defaults to `uniswap-v2`.
    function _protocolId() internal pure virtual returns (bytes32) {
        return ProtocolIds.UNISWAP_V2;
    }

    /// @param protocolName_ Human-readable protocol name (e.g. "Uniswap V2").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocolName_, address navCalculator_) MetaBalanceOracle(protocolName_, navCalculator_) {}

    /// @inheritdoc MetaBalanceOracle
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
        (address token0, address token1, uint256 amount0, uint256 amount1) = UniswapV2PairLib.pairAmounts(pair, account);

        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](2);
        uint256 count;

        (INAVCalculator.Asset memory a0, bool f0) = _eligible(token0, assetFilter);
        if (f0 && amount0 > 0) temp[count++] = _row(a0, amount0, pid);

        (INAVCalculator.Asset memory a1, bool f1) = _eligible(token1, assetFilter);
        if (f1 && amount1 > 0) temp[count++] = _row(a1, amount1, pid);

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceOracle
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

    function _row(INAVCalculator.Asset memory asset, uint256 amount, bytes memory positionId)
        private
        view
        returns (INAVCalculator.PositionBalance memory)
    {
        return INAVCalculator.PositionBalance({
            balanceAsset: asset,
            balanceOracle: address(this),
            amount: amount,
            isDebt: false,
            protocolId: _protocolId(),
            positionId: positionId,
            positionKind: PositionKind.Supplied
        });
    }

    /// @inheritdoc MetaBalanceOracle
    function describePosition(bytes calldata pid) external view override returns (string memory) {
        if (pid.length < 32) return "";
        address pair = abi.decode(pid, (address));
        (address token0, address token1,,) = UniswapV2PairLib.pairAmounts(pair, address(0));
        return string.concat(_symbol(token0), "/", _symbol(token1), " LP");
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
