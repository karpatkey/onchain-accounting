// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceOracle} from "src/balances/MetaBalanceOracle.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PositionType} from "src/utils/PositionType.sol";
import {IUniswapV3Pool} from "src/balances/protocols/uniswap/UniswapV3Pool.sol";
import {UniswapV3PoolLib} from "src/balances/protocols/uniswap/UniswapV3PoolLib.sol";

/// @title Uniswap V3 Pools Meta Balance Adapter
/// @author kpk
/// @notice One immutable adapter that reports an account's Uniswap V3 LP across *any* pool — both the in-range
///         liquidity (`Supply`) and the unclaimed fees (`Fees`) of the account's NFT positions. The instance
///         coordinate is the pool address, widened to bytes32; the active pool set lives on NAVCalculator
///         (`setMetaInstances`). The NonfungiblePositionManager is the chain-level constant pinned in the
///         constructor. Identity is derived on-chain (positionId = pool address; name = `sym0/sym1 <feeTier>`).
///         See ADR 0010.
/// @dev Position discovery and the principal/fee math are delegated to `UniswapV3PoolLib`, which mirrors the
///      per-instance `UniswapV3PoolBalanceOracle` leg-for-leg (parity fork-tested). `slot0` is read via the
///      `_slot0` virtual hook so forks with a divergent `slot0()` ABI (PancakeSwap V3) override just that read.
///      Licensing: links the GPL-2.0-or-later Uniswap math via the lib → combined work is GPL-2.0-or-later
///      (ADR 0008).
contract UniswapV3PoolsMetaBalanceAdapter is MetaBalanceOracle {
    using Strings for address;
    using Strings for uint256;

    /// @notice The Uniswap V3 NonfungiblePositionManager (chain-level constant; same for all V3 pools on a chain).
    address public immutable POSITION_MANAGER;

    /// @param positionManager_ The NonfungiblePositionManager address (per-chain canonical NPM).
    /// @param protocol_ Protocol identifier (e.g. "Uniswap V3").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address positionManager_, string memory protocol_, address navCalculator_)
        MetaBalanceOracle(protocol_, navCalculator_)
    {
        require(positionManager_.code.length > 0, "PositionManager must be a contract");
        POSITION_MANAGER = positionManager_;
    }

    /// @inheritdoc MetaBalanceOracle
    /// @dev `instance` is the pool address. Emits up to 4 legs — `Supply` ×2 (in-range liquidity) and `Fees` ×2
    ///      (unclaimed fees) — dropping zeros and unregistered assets, respecting `assetFilter`.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        address pool = _toAddress(instance);
        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();

        (uint160 sqrtPriceX96, int24 tick) = _slot0(pool);
        (uint256 liq0, uint256 liq1, uint256 fee0, uint256 fee1) =
            UniswapV3PoolLib.accountAggregates(pool, POSITION_MANAGER, account, sqrtPriceX96, tick);

        string memory positionId = pool.toHexString();
        string memory base = _detailBase(pool, token0, token1);
        string memory supplyDetail = PositionType.withType(base, PositionType.SUPPLY);
        string memory feesDetail = PositionType.withType(base, PositionType.FEES);

        // Up to 4 legs: (token0 supply, token1 supply, token0 fees, token1 fees).
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](4);
        uint256 count;

        (INAVCalculator.Asset memory a0, bool f0reg) = _eligible(token0, assetFilter);
        (INAVCalculator.Asset memory a1, bool f1reg) = _eligible(token1, assetFilter);

        if (f0reg && liq0 > 0) temp[count++] = _row(a0, liq0, positionId, supplyDetail);
        if (f1reg && liq1 > 0) temp[count++] = _row(a1, liq1, positionId, supplyDetail);
        if (f0reg && fee0 > 0) temp[count++] = _row(a0, fee0, positionId, feesDetail);
        if (f1reg && fee1 > 0) temp[count++] = _row(a1, fee1, positionId, feesDetail);

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceOracle
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        address pool = _toAddress(instance);
        assets = new address[](2);
        assets[0] = IUniswapV3Pool(pool).token0();
        assets[1] = IUniswapV3Pool(pool).token1();
    }

    /// @notice Reads `(sqrtPriceX96, tick)` from the pool's `slot0`.
    /// @dev `virtual` so a fork with a divergent `slot0()` ABI overrides this single read. The first override is
    ///      `PancakeSwapV3PoolsMetaBalanceAdapter` (PancakeSwap V3's `slot0().feeProtocol` is `uint32`, not `uint8`).
    function _slot0(address pool) internal view virtual returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    /// @notice Returns `(assetInfo, eligible)` where eligible == registered AND passes `assetFilter`.
    function _eligible(address token, address assetFilter)
        private
        view
        returns (INAVCalculator.Asset memory assetInfo, bool eligible)
    {
        if (assetFilter != address(0) && token != assetFilter) return (assetInfo, false);
        (assetInfo, eligible) = _getAssetInfo(token);
    }

    function _row(INAVCalculator.Asset memory asset, uint256 amount, string memory positionId, string memory detail)
        private
        view
        returns (INAVCalculator.PositionBalance memory)
    {
        return INAVCalculator.PositionBalance({
            underlyingAsset: asset,
            balanceOracle: address(this),
            amount: amount,
            isDebt: false,
            protocol: _protocol,
            positionDetail: detail,
            positionId: positionId
        });
    }

    /// @notice positionDetail JSON base (no closing `}`); name derived on-chain as `sym0/sym1 <feeTier>`.
    function _detailBase(address pool, address token0, address token1) private view returns (string memory) {
        string memory name =
            string.concat(_symbol(token0), "/", _symbol(token1), " ", _feeTierLabel(IUniswapV3Pool(pool).fee()));
        return string.concat("{\"protocol\":\"", _protocol, "\",\"product\":\"LP\",\"name\":\"", name, "\"");
    }

    /// @notice Reads an ERC20 symbol, falling back to "?" for non-standard tokens (e.g. bytes32 symbols).
    function _symbol(address token) private view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory s) {
            return bytes(s).length == 0 ? "?" : s;
        } catch {
            return "?";
        }
    }

    /// @notice Renders a Uniswap V3 fee tier (hundredths of a bip) as a percent string: 3000→"0.3%",
    ///         500→"0.05%", 10000→"1%", 100→"0.01%", 2500→"0.25%".
    function _feeTierLabel(uint24 fee) private pure returns (string memory) {
        uint256 whole = uint256(fee) / 10_000;
        uint256 frac = uint256(fee) % 10_000; // fractional part out of 10_000
        if (frac == 0) return string.concat(whole.toString(), "%");

        // 4-digit zero-padded fractional, trailing zeros trimmed.
        bytes memory digits = bytes(frac.toString());
        bytes memory padded = new bytes(4);
        uint256 lead = 4 - digits.length;
        for (uint256 i = 0; i < 4; i++) {
            padded[i] = i < lead ? bytes1(0x30) : digits[i - lead]; // 0x30 == ASCII '0'
        }
        uint256 end = 4;
        while (end > 0 && padded[end - 1] == 0x30) {
            end--;
        }
        bytes memory fracTrim = new bytes(end);
        for (uint256 i = 0; i < end; i++) {
            fracTrim[i] = padded[i];
        }
        return string.concat(whole.toString(), ".", string(fracTrim), "%");
    }
}
