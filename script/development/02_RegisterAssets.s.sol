// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";

/// @title RegisterAssets (development)
/// @notice Registers every asset in script/config/assets.json on the dev NAV proxy for this chain,
///         using the same Chainlink/custom feed addresses production already uses. Custom feeds
///         exist on the forked chains at their live addresses, so we just point at them — no need
///         to redeploy the price-feed adapter contracts.
///
/// @dev Env vars expected (set by deploy.sh):
///        DEV_NAV_PROXY  — the NAV proxy address for the current chain (from state/<cid>-addresses.json)
///
/// @dev Idempotent: skips assets already wired with the configured feed; sets/updates otherwise.
contract RegisterAssets is Script {
    /// @dev ERC-7528 native token sentinel. Pre-registered by NAVCalculator.initialize.
    address private constant NATIVE_SENTINEL = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    function run() public {
        address navProxy = vm.envAddress("DEV_NAV_PROXY");
        uint256 chainId = block.chainid;
        string[] memory symbols = _symbolsForChain(chainId);

        console2.log("=== RegisterAssets (dev) ===");
        console2.log("chain id:    ", chainId);
        console2.log("NAV proxy:   ", navProxy);
        console2.log("symbols:     ", symbols.length);

        NAVCalculator nav = NAVCalculator(navProxy);

        uint256 registered;
        uint256 setFeed;
        uint256 skipped;
        uint256 failed;

        vm.startBroadcast();
        for (uint256 i = 0; i < symbols.length; i++) {
            string memory symbol = symbols[i];

            string memory addrStr = ConfigReader.readTokenAddress(vm, chainId, symbol);
            if (bytes(addrStr).length == 0) { _logSkip(symbol, "no address"); skipped++; continue; }
            address asset = vm.parseAddress(addrStr);
            if (asset == address(0)) { _logSkip(symbol, "invalid address"); skipped++; continue; }

            if (!ConfigReader.hasTokenOracle(vm, chainId, symbol)) { _logSkip(symbol, "no oracle"); skipped++; continue; }

            string memory typeStr = ConfigReader.readTokenType(vm, chainId, symbol);
            if (!_eq(typeStr, "Chainlink") && !_eq(typeStr, "Custom")) { _logSkip(symbol, "unknown type"); skipped++; continue; }

            // Phase 2a: skip Custom-type assets. The custom price-feed contracts deployed in production
            // pre-date the current `checkPriceOracleSupport` IERC165 check, so registering them against
            // a fresh NAV reverts with InvalidPriceOracle(). Phase 2b will deploy fresh Custom price-feed
            // contracts on each fork (mirroring script/deploy/03_DeployPriceFeeds.s.sol) and register
            // those instead.
            if (_eq(typeStr, "Custom")) { _logSkip(symbol, "custom (phase 2b)"); skipped++; continue; }

            address feed = vm.parseAddress(ConfigReader.readTokenOracle(vm, chainId, symbol));
            if (feed == address(0)) { _logSkip(symbol, "no feed addr"); skipped++; continue; }

            // Non-native assets must have code. Native sentinel never has code (handled in init).
            if (asset != NATIVE_SENTINEL && asset.code.length == 0) { _logSkip(symbol, "no token contract"); skipped++; continue; }
            if (feed.code.length == 0) { _logSkip(symbol, "no feed contract"); skipped++; continue; }

            uint256 heartbeat = vm.parseUint(ConfigReader.readTokenHeartbeat(vm, chainId, symbol));
            IPrices.PriceType priceType = IPrices.PriceType.Chainlink; // gated by skip above

            bool already = nav.isAssetRegistered(asset);
            if (already) {
                try nav.setPriceFeed(asset, feed, priceType, heartbeat) {
                    _logAction(symbol, "setPriceFeed", asset, feed);
                    setFeed++;
                } catch (bytes memory reason) {
                    _logFail(symbol, "setPriceFeed", reason);
                    failed++;
                }
            } else {
                try nav.registerAsset(asset, feed, priceType, heartbeat) {
                    _logAction(symbol, "registerAsset", asset, feed);
                    registered++;
                } catch (bytes memory reason) {
                    _logFail(symbol, "registerAsset", reason);
                    failed++;
                }
            }
        }
        vm.stopBroadcast();

        console2.log("--- summary ---");
        console2.log("registered:  ", registered);
        console2.log("setPriceFeed:", setFeed);
        console2.log("failed:      ", failed);
        console2.log("skipped:     ", skipped);
        console2.log("REGISTERED_ASSETS_DONE");
    }

    function _logFail(string memory symbol, string memory action, bytes memory reason) private pure {
        bytes4 sel = reason.length >= 4 ? bytes4(reason[0]) | (bytes4(reason[1]) >> 8) | (bytes4(reason[2]) >> 16) | (bytes4(reason[3]) >> 24) : bytes4(0);
        console2.log(string.concat("  FAIL ", action, " ", symbol, "  selector=", vm.toString(sel)));
    }

    function _logAction(string memory symbol, string memory action, address asset, address feed) private pure {
        console2.log(string.concat("  ", action, " ", symbol, "  asset=", vm.toString(asset), "  feed=", vm.toString(feed)));
    }

    function _logSkip(string memory symbol, string memory reason) private pure {
        console2.log(string.concat("  skip ", symbol, " - ", reason));
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @notice Per-chain symbol lists. Must match keys in script/config/assets.json under tokens.{chainId}.
    /// @dev Kept in sync with script/manage/RegisterAssets.s.sol::_symbolsForChain. When that changes
    ///      (production adds a token), copy the symbol over here too.
    function _symbolsForChain(uint256 chainId) private pure returns (string[] memory) {
        if (chainId == 1) {
            string[] memory s = new string[](31);
            s[0]="ETH"; s[1]="WETH"; s[2]="wstETH"; s[3]="eETH"; s[4]="weETH"; s[5]="rETH";
            s[6]="ETH+"; s[7]="ezETH"; s[8]="rsETH"; s[9]="MORPHO"; s[10]="USDC"; s[11]="BAL";
            s[12]="AURA"; s[13]="RPL"; s[14]="GEAR"; s[15]="stETH"; s[16]="CRV"; s[17]="CVX";
            s[18]="USDS"; s[19]="USDT"; s[20]="DAI"; s[21]="GHO"; s[22]="USDe"; s[23]="sUSDe";
            s[24]="RLUSD"; s[25]="crvUSD"; s[26]="sUSDS"; s[27]="syrupUSDC"; s[28]="COMP";
            s[29]="WBTC"; s[30]="AAVE";
            return s;
        }
        if (chainId == 10) {
            string[] memory s = new string[](6);
            s[0]="ETH"; s[1]="WETH"; s[2]="wstETH"; s[3]="USDC"; s[4]="USDT"; s[5]="COMP";
            return s;
        }
        if (chainId == 100) {
            string[] memory s = new string[](7);
            s[0]="xDAI"; s[1]="WXDAI"; s[2]="WETH"; s[3]="wstETH"; s[4]="USDCe"; s[5]="sDAI"; s[6]="GHO";
            return s;
        }
        if (chainId == 42161) {
            string[] memory s = new string[](12);
            s[0]="ETH"; s[1]="WETH"; s[2]="wstETH"; s[3]="weETH"; s[4]="ezETH"; s[5]="rsETH";
            s[6]="MORPHO"; s[7]="USDC"; s[8]="USDT"; s[9]="GHO"; s[10]="syrupUSDC"; s[11]="COMP";
            return s;
        }
        if (chainId == 8453) {
            string[] memory s = new string[](9);
            s[0]="ETH"; s[1]="WETH"; s[2]="wstETH"; s[3]="weETH"; s[4]="cbETH"; s[5]="MORPHO";
            s[6]="USDC"; s[7]="GHO"; s[8]="COMP";
            return s;
        }
        return new string[](0);
    }
}
