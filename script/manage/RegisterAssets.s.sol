// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {INAVCalculator} from "../../src/nav/INAVCalculator.sol";
import {IPrices} from "../../src/prices/IPrices.sol";
import {console2} from "forge-std/console2.sol";

/// @title RegisterAssets
/// @notice Reads assets from script/config/assets.json, checks which are not yet registered
///         on NAVCalculator, and either reports status or generates a Safe tx batch to register them.
/// @dev
///   - Token list per chain is defined in this script (_symbolsForChain). Add new tokens to assets.json
///     and to the corresponding array here.
///   - Tokens without an oracle are reported as "SKIP (no oracle)" with optional note from config.
///   - Run with --rpc-url <url> so the script can call NAVCalculator.isAssetRegistered and only
///     include unregistered assets in the Safe tx. Without RPC, all tokens with an oracle are included.
///   - Output: safe-transactions/{chainId}-register-assets.json
contract RegisterAssets is BaseDeployScript {
    using ConfigReader for *;

    function run() public override {
        setUp();

        address navProxy = readDeployedAddress("NAVCalculatorProxy");
        string[] memory symbols = _symbolsForChain(currentChainId);

        console2.log("\n=== Register Assets (from assets.json) ===");
        console2.log("Chain:", chainConfig.name);
        console2.log("Chain ID:", currentChainId);
        console2.log("NAVCalculator proxy:", navProxy);
        console2.log("Tokens in config:", symbols.length);
        console2.log("");

        if (symbols.length == 0) {
            console2.log("No tokens defined for this chain. Add symbols in RegisterAssets.s.sol _symbolsForChain().");
            return;
        }

        uint256 alreadyRegistered;
        uint256 skipNoOracle;
        uint256 skipMissingAddress;
        uint256 toRegisterCount;

        // First pass: report each token and count how many need registration
        for (uint256 i = 0; i < symbols.length; i++) {
            string memory symbol = symbols[i];
            string memory addrStr = ConfigReader.readTokenAddress(vm, currentChainId, symbol);
            if (bytes(addrStr).length == 0) {
                console2.log("  SKIP (missing address):", symbol);
                skipMissingAddress++;
                continue;
            }
            address asset = vm.parseAddress(addrStr);
            if (asset == address(0)) {
                console2.log("  SKIP (invalid address):", symbol);
                skipMissingAddress++;
                continue;
            }
            if (!ConfigReader.hasTokenOracle(vm, currentChainId, symbol)) {
                string memory note = ConfigReader.readTokenNote(vm, currentChainId, symbol);
                if (bytes(note).length > 0) {
                    console2.log("  SKIP (no oracle):", symbol);
                    console2.log("    ->", note);
                } else {
                    console2.log("  SKIP (no oracle):", symbol);
                }
                skipNoOracle++;
                continue;
            }
            if (navProxy == address(0)) {
                console2.log("  WOULD REGISTER (NAV not deployed):", symbol);
                toRegisterCount++;
                continue;
            }
            if (navProxy.code.length == 0) {
                console2.log("  TO REGISTER (NAV not deployed or no RPC):", symbol);
                toRegisterCount++;
                continue;
            }
            (bool ok, bytes memory data) =
                navProxy.staticcall(abi.encodeWithSelector(INAVCalculator.isAssetRegistered.selector, asset));
            if (!ok || data.length == 0) {
                console2.log("  TO REGISTER:", symbol);
                toRegisterCount++;
            } else if (abi.decode(data, (bool))) {
                console2.log("  ALREADY REGISTERED:", symbol);
                alreadyRegistered++;
            } else {
                console2.log("  TO REGISTER:", symbol);
                toRegisterCount++;
            }
        }

        // Summary
        console2.log("");
        console2.log("--- Summary ---");
        console2.log("  Already registered:", alreadyRegistered);
        console2.log("  Skipped (no oracle):", skipNoOracle);
        console2.log("  Skipped (missing/invalid address):", skipMissingAddress);
        console2.log("  To register:", toRegisterCount);

        if (toRegisterCount == 0) {
            console2.log("");
            console2.log("Nothing to register. Exiting.");
            return;
        }

        if (navProxy == address(0)) {
            console2.log("");
            console2.log("NAVCalculator not deployed for this chain. Deploy it first, then re-run to generate Safe tx.");
            return;
        }

        // Second pass: build Safe tx batch for each token that needs registration
        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](toRegisterCount);
        uint256 j = 0;
        for (uint256 i = 0; i < symbols.length; i++) {
            string memory symbol = symbols[i];
            string memory addrStr = ConfigReader.readTokenAddress(vm, currentChainId, symbol);
            if (bytes(addrStr).length == 0) continue;
            address asset = vm.parseAddress(addrStr);
            if (asset == address(0)) continue;
            if (!ConfigReader.hasTokenOracle(vm, currentChainId, symbol)) continue;
            if (navProxy.code.length > 0) {
                (bool ok, bytes memory data) =
                    navProxy.staticcall(abi.encodeWithSelector(INAVCalculator.isAssetRegistered.selector, asset));
                if (ok && data.length > 0 && abi.decode(data, (bool))) continue;
            }

            address oracle = vm.parseAddress(ConfigReader.readTokenOracle(vm, currentChainId, symbol));
            string memory priceTypeStr = ConfigReader.readTokenType(vm, currentChainId, symbol);
            IPrices.PriceType priceType =
                _equals(priceTypeStr, "Chainlink") ? IPrices.PriceType.Chainlink : IPrices.PriceType.Custom;
            uint256 heartbeat = vm.parseUint(ConfigReader.readTokenHeartbeat(vm, currentChainId, symbol));

            transactions[j] = SafeTxBuilder.call(
                navProxy, 0, abi.encodeCall(NAVCalculator.registerAsset, (asset, oracle, priceType, heartbeat))
            );
            j++;
        }

        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-register-assets.json"));
        writeSafeTx(
            filename,
            "Register assets in NAVCalculator",
            string(abi.encodePacked("Register ", vm.toString(toRegisterCount), " assets from assets.json")),
            transactions
        );
        console2.log("");
        console2.log(string(abi.encodePacked("Safe transaction written to safe-transactions/", filename)));
    }

    function _equals(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @notice Token symbols to process per chain. Must match keys in assets.json tokens.{chainId}.
    ///         Add new tokens to assets.json and append the symbol here for the right chain.
    function _symbolsForChain(uint256 chainId) private pure returns (string[] memory) {
        if (chainId == 1) {
            string[] memory s = new string[](18);
            s[0] = "ETH";
            s[1] = "WETH";
            s[2] = "wstETH";
            s[3] = "eETH";
            s[4] = "weETH";
            s[5] = "rETH";
            s[6] = "ETH+";
            s[7] = "ezETH";
            s[8] = "rsETH";
            s[9] = "MORPHO";
            s[10] = "USDC";
            s[11] = "BAL";
            s[12] = "AURA";
            s[13] = "RPL";
            s[14] = "GEAR";
            s[15] = "stETH";
            s[16] = "CRV";
            s[17] = "CVX";
            return s;
        }
        if (chainId == 42161) {
            string[] memory s = new string[](7);
            s[0] = "ETH";
            s[1] = "WETH";
            s[2] = "wstETH";
            s[3] = "weETH";
            s[4] = "ezETH";
            s[5] = "rsETH";
            s[6] = "MORPHO";
            return s;
        }
        if (chainId == 100) {
            string[] memory s = new string[](2);
            s[0] = "WETH";
            s[1] = "wstETH";
            return s;
        }
        if (chainId == 8453) {
            string[] memory s = new string[](6);
            s[0] = "ETH";
            s[1] = "WETH";
            s[2] = "wstETH";
            s[3] = "weETH";
            s[4] = "cbETH";
            s[5] = "MORPHO";
            return s;
        }
        if (chainId == 10) {
            string[] memory s = new string[](2);
            s[0] = "ETH";
            s[1] = "wstETH";
            return s;
        }
        return new string[](0);
    }
}
