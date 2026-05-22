// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Script, console2} from "forge-std/Script.sol";
import {UniswapV3PoolBalanceOracle} from "src/balances/protocols/uniswap/UniswapV3Pool.sol";

/// @notice Subclass that exposes the adapter's internal (liq0, liq1, fee0, fee1) split for
///         live cross-check tabulation. The base adapter intentionally keeps the breakdown
///         internal because consumers should sum across legs; this wrapper exists only so the
///         off-chain README can render the principal-vs-fees comparison Uniswap's own UI
///         shows in its "Position" / "Fees earned" tabs.
contract UniswapV3LegSplit is UniswapV3PoolBalanceOracle {
    constructor(
        address pool_,
        address positionManager_,
        string memory protocol_,
        string memory positionDetail_,
        string memory positionId_,
        address navCalculator_
    ) UniswapV3PoolBalanceOracle(pool_, positionManager_, protocol_, positionDetail_, positionId_, navCalculator_) {}

    function legAggregates(address account)
        external
        view
        returns (uint256 liq0, uint256 liq1, uint256 fee0, uint256 fee1)
    {
        return _getAccountAggregates(account);
    }
}

/// @title  Live cross-check helper — Uniswap V3 multi-holder verification
/// @notice One-shot script that forks Ethereum mainnet at the latest available block and
///         prints, per (holder, pool, token), the principal-vs-fees split the V3 balance
///         adapter would emit. Useful for a side-by-side comparison against the live
///         Uniswap UI's "Remove Liquidity" / "Fees earned" tabs, with drift bounded by
///         (now - block.timestamp) — target: seconds-to-minutes.
///
/// @dev    Run with:
///           forge script script/development/test/uniswapV3/query-live-balances.s.sol \
///             --fork-url $MAINNET_URL -vv
///         Read-only — no broadcast.
contract QueryLiveBalances is Script {
    address constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    address constant POOL_USDC_WETH_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address constant POOL_WETH_USDT_3000 = 0x4e68Ccd3E89f51C3074ca5072bbAC773960dFa36;
    address constant POOL_WBTC_WETH_3000 = 0xCBCdF9626bC03E24f779434178A73a0B4bad62eD;

    address constant ACCOUNT_12 = 0x8d27DEB2405717d649346502F52B959AAB4eb3af;
    address constant HOLDER_B = 0xa1097367be4C8bbdEf3D881E3c24E6260Afef36E;

    function run() public {
        console2.log("=== Live Uniswap V3 cross-check ===");
        console2.log("block:", block.number);
        console2.log("timestamp:", block.timestamp);

        // NPM is a contract — passes the adapter constructor's `code.length > 0` check on
        // navCalculator_. `legAggregates` doesn't read NAVCalculator at all.
        UniswapV3LegSplit oUsdcWeth =
            new UniswapV3LegSplit(POOL_USDC_WETH_500, NPM, "Uniswap V3", "{}", "0x0", NPM);
        UniswapV3LegSplit oWethUsdt =
            new UniswapV3LegSplit(POOL_WETH_USDT_3000, NPM, "Uniswap V3", "{}", "0x0", NPM);
        UniswapV3LegSplit oWbtcWeth =
            new UniswapV3LegSplit(POOL_WBTC_WETH_3000, NPM, "Uniswap V3", "{}", "0x0", NPM);

        console2.log("\n-- ACCOUNT_12 0x8d27...3af --");
        _dump("USDC/WETH 0.05%", oUsdcWeth, ACCOUNT_12);
        _dump("WETH/USDT 0.3% ", oWethUsdt, ACCOUNT_12);
        _dump("WBTC/WETH 0.3% ", oWbtcWeth, ACCOUNT_12);

        console2.log("\n-- HOLDER_B 0xa109...36E --");
        _dump("USDC/WETH 0.05%", oUsdcWeth, HOLDER_B);
        _dump("WETH/USDT 0.3% ", oWethUsdt, HOLDER_B);
        _dump("WBTC/WETH 0.3% ", oWbtcWeth, HOLDER_B);
    }

    function _dump(string memory pool, UniswapV3LegSplit adapter, address holder) internal view {
        (uint256 liq0, uint256 liq1, uint256 fee0, uint256 fee1) = adapter.legAggregates(holder);
        console2.log(string.concat("  ", pool, " principal token0:"), liq0);
        console2.log(string.concat("  ", pool, " principal token1:"), liq1);
        console2.log(string.concat("  ", pool, " fees      token0:"), fee0);
        console2.log(string.concat("  ", pool, " fees      token1:"), fee1);
    }
}
