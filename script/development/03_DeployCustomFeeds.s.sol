// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";

// Custom price-oracle adapters used across the supported chains. These are imported wholesale
// so the dev fork has fresh instances that match the CURRENT source-code interface (the live
// production deployments predate the IERC165 supportsInterface() requirement in Prices.sol).
import {wstETH_PriceOracle} from "src/prices/protocols/wstETH_Price.sol";
import {rETH_PriceOracle} from "src/prices/protocols/rETH_Price.sol";
import {weETH_PriceOracle} from "src/prices/protocols/weETH_Price.sol";
import {eETH_PriceOracle} from "src/prices/protocols/eETH_Price.sol";
import {ezETH_PriceOracle} from "src/prices/protocols/ezETH_Price.sol";
import {rsETH_PriceOracle} from "src/prices/protocols/rsETH_Price.sol";
import {ETHx_PriceOracle} from "src/prices/protocols/ETHx_Price.sol";
import {ETHPlus_PriceOracle} from "src/prices/protocols/ETHPlus_Price.sol";
import {sUSDe_PriceOracle} from "src/prices/protocols/sUSDe_Price.sol";
import {sUSDS_PriceOracle} from "src/prices/protocols/sUSDS_Price.sol";
import {sDAI_PriceOracle} from "src/prices/protocols/sDAI_Price.sol";
import {syrupUSDC_PriceOracle} from "src/prices/protocols/syrupUSDC_Price.sol";

import {wstETH_L2_PriceOracle} from "src/prices/protocols/wstETH_L2_Price.sol";
import {weETH_L2_PriceOracle} from "src/prices/protocols/weETH_L2_Price.sol";
import {cbETH_L2_PriceOracle} from "src/prices/protocols/cbETH_L2_Price.sol";
import {rsETH_L2_PriceOracle} from "src/prices/protocols/rsETH_L2_Price.sol";
import {ezETH_L2_PriceOracle} from "src/prices/protocols/ezETH_L2_Price.sol";
import {syrupUSDC_L2_PriceOracle} from "src/prices/protocols/syrupUSDC_L2_Price.sol";

import {sDAI_PriceOracle as sXDAI_PriceOracle} from "src/prices/protocols/sXDAI_Price.sol";

/// @title DeployCustomFeeds (development)
/// @notice Deploys fresh custom price-oracle contracts on the current anvil fork. Reads
///         constructor parameters from the same `script/config/assets.json` production uses
///         under `priceFeeds.<oracleName>.<chainId>.constructor.*`. Outputs each deployed
///         address as a marker line ("FEED <name> <addr>") that deploy.sh captures into
///         script/development/state/<cid>-feeds.json.
///
///         Mirrors `script/deploy/03_DeployPriceFeeds.s.sol` but without writing back to the
///         shared chain config — dev addresses must not pollute production config.
contract DeployCustomFeeds is Script {
    function run() public {
        uint256 chainId = block.chainid;

        console2.log("=== DeployCustomFeeds (dev) ===");
        console2.log("chain id:", chainId);

        vm.startBroadcast();
        if (chainId == 1)         _deployMainnet();
        else if (chainId == 10)   _deployOptimism();
        else if (chainId == 100)  _deployGnosis();
        else if (chainId == 42161) _deployArbitrum();
        else if (chainId == 8453) _deployBase();
        else                       console2.log("no custom feeds configured for chainId", chainId);
        vm.stopBroadcast();

        console2.log("CUSTOM_FEEDS_DONE");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Per-chain orchestration
    // ─────────────────────────────────────────────────────────────────────────

    function _deployMainnet() private {
        _wstETH();
        _rETH();
        _weETH();
        _eETH();
        _ezETH();
        _rsETH();
        _ETHx();
        _ETHPlus();
        _sUSDe();
        _sUSDS();
        _sDAI();
        _syrupUSDC();
    }

    function _deployOptimism() private {
        // No Custom adapters required in production for OP (Alpha funds use Chainlink only).
    }

    function _deployGnosis() private {
        _sXDAI();
        _wstETH_L2();
    }

    function _deployArbitrum() private {
        _wstETH_L2();
        _weETH_L2();
        _rsETH_L2();
        _ezETH_L2();
        _syrupUSDC_L2();
    }

    function _deployBase() private {
        _wstETH_L2();
        _weETH_L2();
        _cbETH_L2();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _addr(string memory name, string memory key) private view returns (address) {
        return vm.parseAddress(ConfigReader.readPriceFeedParam(vm, block.chainid, name, key));
    }
    function _uint(string memory name, string memory key) private view returns (uint256) {
        return vm.parseUint(ConfigReader.readPriceFeedParam(vm, block.chainid, name, key));
    }
    function _emit(string memory name, address deployed) private pure {
        console2.log(string.concat("FEED ", name, " ", vm.toString(deployed)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Mainnet adapters
    // ─────────────────────────────────────────────────────────────────────────

    function _wstETH() private {
        wstETH_PriceOracle o = new wstETH_PriceOracle(
            _addr("wstETH", "wstEth"),
            _addr("wstETH", "ethToUsdChainlinkOracle"),
            _uint("wstETH", "ethToUsdChainlinkHeartbeat")
        );
        _emit("wstETH", address(o));
    }

    function _rETH() private {
        rETH_PriceOracle o = new rETH_PriceOracle(
            _addr("rETH", "rEth"),
            _addr("rETH", "ethToUsdChainlinkOracle"),
            _uint("rETH", "ethToUsdChainlinkHeartbeat")
        );
        _emit("rETH", address(o));
    }

    function _weETH() private {
        weETH_PriceOracle o = new weETH_PriceOracle(
            _addr("weETH", "weEth"),
            _addr("weETH", "weEthToEthChainlinkOracle"),
            _addr("weETH", "ethToUsdChainlinkOracle"),
            _uint("weETH", "weEthToEthChainlinkHeartbeat"),
            _uint("weETH", "ethToUsdChainlinkHeartbeat")
        );
        _emit("weETH", address(o));
    }

    function _eETH() private {
        eETH_PriceOracle o = new eETH_PriceOracle(
            _addr("eETH", "eEth"),
            _addr("eETH", "weEth"),
            _addr("eETH", "weEthToEthChainlinkOracle"),
            _addr("eETH", "ethToUsdChainlinkOracle"),
            _uint("eETH", "weEthToEthChainlinkHeartbeat"),
            _uint("eETH", "ethToUsdChainlinkHeartbeat")
        );
        _emit("eETH", address(o));
    }

    function _ezETH() private {
        ezETH_PriceOracle o = new ezETH_PriceOracle(
            _addr("ezETH", "ezEth"),
            _addr("ezETH", "restakeManager"),
            _addr("ezETH", "ethToUsdChainlinkOracle"),
            _uint("ezETH", "ethToUsdChainlinkHeartbeat")
        );
        _emit("ezETH", address(o));
    }

    function _rsETH() private {
        rsETH_PriceOracle o = new rsETH_PriceOracle(
            _addr("rsETH", "rsEth"),
            _addr("rsETH", "rateProvider"),
            _addr("rsETH", "ethToUsdChainlinkOracle"),
            _uint("rsETH", "ethToUsdChainlinkHeartbeat")
        );
        _emit("rsETH", address(o));
    }

    function _ETHx() private {
        ETHx_PriceOracle o = new ETHx_PriceOracle(
            _addr("ETHx", "ethx"),
            _addr("ETHx", "stakePoolsManager"),
            _addr("ETHx", "ethToUsdChainlinkOracle"),
            _uint("ETHx", "ethToUsdChainlinkHeartbeat")
        );
        _emit("ETHx", address(o));
    }

    function _ETHPlus() private {
        ETHPlus_PriceOracle o = new ETHPlus_PriceOracle(
            _addr("ETHPlus", "ethPlus"),
            _uint("ETHPlus", "reserveProtocolHeartbeat")
        );
        _emit("ETHPlus", address(o));
    }

    function _sUSDe() private {
        sUSDe_PriceOracle o = new sUSDe_PriceOracle(
            _addr("sUSDe", "sUsde"),
            _addr("sUSDe", "usdeToUsdChainlinkAddress"),
            _uint("sUSDe", "usdeToUsdChainlinkHeartbeat")
        );
        _emit("sUSDe", address(o));
    }

    function _sUSDS() private {
        sUSDS_PriceOracle o = new sUSDS_PriceOracle(
            _addr("sUSDS", "sUsds"),
            _addr("sUSDS", "usdsToUsdChainlinkAddress"),
            _uint("sUSDS", "usdsToUsdChainlinkHeartbeat")
        );
        _emit("sUSDS", address(o));
    }

    function _sDAI() private {
        sDAI_PriceOracle o = new sDAI_PriceOracle(
            _addr("sDAI", "sDai"),
            _addr("sDAI", "dsrManager"),
            _addr("sDAI", "daiToUsdChainlinkOracle"),
            _uint("sDAI", "daiToUsdChainlinkHeartbeat")
        );
        _emit("sDAI", address(o));
    }

    function _syrupUSDC() private {
        syrupUSDC_PriceOracle o = new syrupUSDC_PriceOracle(
            _addr("syrupUSDC", "syrupUsdc"),
            _addr("syrupUSDC", "usdcToUsdChainlinkAddress"),
            _uint("syrupUSDC", "usdcToUsdChainlinkHeartbeat")
        );
        _emit("syrupUSDC", address(o));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Gnosis adapters
    // ─────────────────────────────────────────────────────────────────────────

    function _sXDAI() private {
        // sXDAI is a different contract file (sXDAI_Price.sol) sharing the contract name
        // `sDAI_PriceOracle` — aliased import resolves to its 3-arg constructor (no DSR on Gnosis).
        sXDAI_PriceOracle o = new sXDAI_PriceOracle(
            _addr("sXDAI", "sXdai"),
            _addr("sXDAI", "xDaiToUsdChainlinkOracle"),
            _uint("sXDAI", "xDaiToUsdChainlinkHeartbeat")
        );
        _emit("sXDAI", address(o));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // L2 adapters (Arbitrum / Base / Gnosis)
    // ─────────────────────────────────────────────────────────────────────────

    function _wstETH_L2() private {
        wstETH_L2_PriceOracle o = new wstETH_L2_PriceOracle(
            _addr("wstETH_L2", "wstEth"),
            _addr("wstETH_L2", "wstEthToEthChainlink"),
            _addr("wstETH_L2", "ethToUsdChainlinkOracle"),
            _uint("wstETH_L2", "wstEthToEthHeartbeat"),
            _uint("wstETH_L2", "ethToUsdChainlinkHeartbeat")
        );
        _emit("wstETH_L2", address(o));
    }

    function _weETH_L2() private {
        weETH_L2_PriceOracle o = new weETH_L2_PriceOracle(
            _addr("weETH_L2", "weEth"),
            _addr("weETH_L2", "weEthToEthChainlink"),
            _addr("weETH_L2", "ethToUsdChainlinkOracle"),
            _uint("weETH_L2", "weEthToEthHeartbeat"),
            _uint("weETH_L2", "ethToUsdChainlinkHeartbeat")
        );
        _emit("weETH_L2", address(o));
    }

    function _cbETH_L2() private {
        cbETH_L2_PriceOracle o = new cbETH_L2_PriceOracle(
            _addr("cbETH_L2", "cbEth"),
            _addr("cbETH_L2", "cbEthToEthChainlink"),
            _addr("cbETH_L2", "ethToUsdChainlinkOracle"),
            _uint("cbETH_L2", "cbEthToEthHeartbeat"),
            _uint("cbETH_L2", "ethToUsdChainlinkHeartbeat")
        );
        _emit("cbETH_L2", address(o));
    }

    function _rsETH_L2() private {
        rsETH_L2_PriceOracle o = new rsETH_L2_PriceOracle(
            _addr("rsETH_L2", "rsEth"),
            _addr("rsETH_L2", "rsEthToEthChainlink"),
            _addr("rsETH_L2", "ethToUsdChainlinkOracle"),
            _uint("rsETH_L2", "rsEthToEthHeartbeat"),
            _uint("rsETH_L2", "ethToUsdChainlinkHeartbeat")
        );
        _emit("rsETH_L2", address(o));
    }

    function _ezETH_L2() private {
        ezETH_L2_PriceOracle o = new ezETH_L2_PriceOracle(
            _addr("ezETH_L2", "ezEth"),
            _addr("ezETH_L2", "xRenzoDeposit"),
            _addr("ezETH_L2", "ethToUsdChainlinkOracle"),
            _uint("ezETH_L2", "ethToUsdChainlinkHeartbeat")
        );
        _emit("ezETH_L2", address(o));
    }

    function _syrupUSDC_L2() private {
        syrupUSDC_L2_PriceOracle o = new syrupUSDC_L2_PriceOracle(
            _addr("syrupUSDC_L2", "syrupUsdc"),
            _addr("syrupUSDC_L2", "syrupUsdcToUsdcChainlink"),
            _addr("syrupUSDC_L2", "usdcToUsdChainlinkOracle"),
            _uint("syrupUSDC_L2", "syrupUsdcToUsdcHeartbeat"),
            _uint("syrupUSDC_L2", "usdcToUsdChainlinkHeartbeat")
        );
        _emit("syrupUSDC_L2", address(o));
    }
}
