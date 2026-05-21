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
///   - Only tokens with a usable oracle (type Chainlink or Custom, non-empty pricefeed) are considered.
///   - Tokens without an oracle are reported as "SKIP (no oracle)" with optional note from config.
///   - Safe tx batch is only generated when run with --rpc-url so the script can verify on-chain
///     that each asset is not already registered (isAssetRegistered). Without RPC, the script
///     reports status but refuses to write the Safe tx file.
///   - Pre-registered assets (notably the NATIVE_ADDRESS sentinel inserted by NAVCalculator.initialize)
///     are wired up with addPriceFeed instead of registerAsset, so the configured oracle is applied
///     without reverting on duplicate registration.
///   - Output: safe-transactions/{chainId}-register-assets.json
///   - With --broadcast, tx(s) are sent from the keystore signer (--account $DEPLOYER_NAME). registerAsset checks MANAGER on-chain (msg.sender).
contract RegisterAssets is BaseDeployScript {
    using ConfigReader for *;

    /// @dev ERC-7528 native token sentinel; has no code but NAVCalculator handles it in init.
    address private constant NATIVE_SENTINEL = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

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

        uint256 toSetPriceFeed; // pre-registered (e.g. native sentinel from initialize) — needs addPriceFeed
        uint256 skipNoOracle;
        uint256 skipMissingAddress;
        uint256 skipNoContract;
        uint256 toRegisterCount;

        // First pass: report each token and count how many need registration / price-feed set
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
                if (_hasNoCode(asset)) {
                    console2.log("  SKIP (no contract at address):", symbol);
                    skipNoContract++;
                    continue;
                }
                console2.log("  TO REGISTER:", symbol);
                toRegisterCount++;
            } else if (abi.decode(data, (bool))) {
                // Pre-registered (e.g. NATIVE_ADDRESS by NAVCalculator.initialize) — need addPriceFeed
                // to wire the configured oracle.
                console2.log("  TO SET PRICE FEED (pre-registered):", symbol);
                toSetPriceFeed++;
            } else {
                if (_hasNoCode(asset)) {
                    console2.log("  SKIP (no contract at address):", symbol);
                    skipNoContract++;
                    continue;
                }
                console2.log("  TO REGISTER:", symbol);
                toRegisterCount++;
            }
        }

        // Summary
        uint256 totalActions = toRegisterCount + toSetPriceFeed;
        console2.log("");
        console2.log("--- Summary ---");
        console2.log("  To set price feed (pre-registered):", toSetPriceFeed);
        console2.log("  Skipped (no oracle):", skipNoOracle);
        console2.log("  Skipped (missing/invalid address):", skipMissingAddress);
        console2.log("  Skipped (no contract at address):", skipNoContract);
        console2.log("  To register:", toRegisterCount);
        console2.log("  Total actions:", totalActions);

        if (totalActions == 0) {
            console2.log("");
            console2.log("Nothing to register or update. Exiting.");
            return;
        }

        if (navProxy == address(0)) {
            console2.log("");
            console2.log("NAVCalculator not deployed for this chain. Deploy it first, then re-run to generate Safe tx.");
            return;
        }

        // Require RPC so we only include assets that are confirmed not already registered on-chain
        if (navProxy.code.length == 0) {
            console2.log("");
            console2.log(
                "Run with --rpc-url so the script can verify which assets are not yet registered. Refusing to generate Safe tx without this check."
            );
            return;
        }

        // Second pass: build Safe tx batch — registerAsset for new ones, addPriceFeed for pre-registered ones
        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](totalActions);
        uint256 j = 0;
        for (uint256 i = 0; i < symbols.length; i++) {
            string memory symbol = symbols[i];
            string memory addrStr = ConfigReader.readTokenAddress(vm, currentChainId, symbol);
            if (bytes(addrStr).length == 0) continue;
            address asset = vm.parseAddress(addrStr);
            if (asset == address(0)) continue;
            if (!ConfigReader.hasTokenOracle(vm, currentChainId, symbol)) continue;
            (bool ok, bytes memory data) =
                navProxy.staticcall(abi.encodeWithSelector(INAVCalculator.isAssetRegistered.selector, asset));
            bool preRegistered = ok && data.length > 0 && abi.decode(data, (bool));
            if (!preRegistered && _hasNoCode(asset)) continue;

            string memory priceTypeStr = ConfigReader.readTokenType(vm, currentChainId, symbol);
            IPrices.PriceType priceType;
            if (_equals(priceTypeStr, "Chainlink")) priceType = IPrices.PriceType.Chainlink;
            else if (_equals(priceTypeStr, "Custom")) priceType = IPrices.PriceType.Custom;
            else if (_equals(priceTypeStr, "Redstone")) priceType = IPrices.PriceType.Redstone;
            else if (_equals(priceTypeStr, "API3")) priceType = IPrices.PriceType.API3;
            else continue;
            string memory oracleStr = ConfigReader.readTokenOracle(vm, currentChainId, symbol);
            if (bytes(oracleStr).length == 0) continue;
            address oracle = vm.parseAddress(oracleStr);
            if (oracle == address(0)) continue;

            uint256 heartbeat = vm.parseUint(ConfigReader.readTokenHeartbeat(vm, currentChainId, symbol));

            // Pre-registered assets (e.g. NATIVE_ADDRESS via NAVCalculator.initialize) need addPriceFeed,
            // not registerAsset (which would revert with InvalidArguments — already registered).
            bytes memory callData = preRegistered
                ? abi.encodeCall(NAVCalculator.addPriceFeed, (asset, oracle, priceType, heartbeat))
                : abi.encodeCall(NAVCalculator.registerAsset, (asset, oracle, priceType, heartbeat));
            transactions[j] = SafeTxBuilder.call(navProxy, 0, callData);
            j++;
        }

        if (j == 0) {
            console2.log("");
            console2.log("No assets to register after re-check (already registered or invalid). Nothing written.");
            return;
        }

        // Copy to exact-sized array (in case any defensive skips happened in second pass)
        SafeTxBuilder.Transaction[] memory batch = new SafeTxBuilder.Transaction[](j);
        for (uint256 k = 0; k < j; k++) {
            batch[k] = transactions[k];
        }

        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-register-assets.json"));
        writeSafeTx(
            filename,
            "Register assets in NAVCalculator",
            string(abi.encodePacked("Register ", vm.toString(j), " assets from assets.json")),
            batch
        );

        // Additionally, build MultiSend-compatible calldata that a MANAGER can execute directly
        // via a MultiSend contract (e.g. Gnosis Safe MultiSend) to register all assets in one
        // multicall-style transaction.
        bytes memory multiSendData = _buildMultiSendCallData(batch);
        console2.log("");
        console2.log("MultiSend calldata to register all assets (for a MANAGER caller):");
        console2.log(vm.toString(multiSendData));

        // If the broadcast sender (--account $DEPLOYER_NAME) is the configured manager, broadcast registerAsset tx(s) directly.
        _broadcastManagerMultiSend(batch);

        console2.log("");
        console2.log(string(abi.encodePacked("Safe transaction written to safe-transactions/", filename)));
    }

    /// @notice Broadcast one tx per asset from the default signer (msg.sender when txs run). registerAsset reverts if not MANAGER.
    function _broadcastManagerMultiSend(SafeTxBuilder.Transaction[] memory batch) internal {
        vm.startBroadcast();
        for (uint256 i = 0; i < batch.length; i++) {
            (bool success, bytes memory data) = batch[i].to.call(batch[i].data);
            if (!success) {
                string memory msg_ = _revertMsg(data);
                require(false, string(abi.encodePacked("registerAsset failed at index ", vm.toString(i), ": ", msg_)));
            }
        }
        vm.stopBroadcast();
        console2.log("[OK] Broadcast", batch.length, "tx(s); all assets registered.");
    }

    /// @dev Decode Error(string) from revert data (selector 0x08c379a0 + offset + length + data).
    function _revertMsg(bytes memory data) internal pure returns (string memory) {
        if (data.length >= 68 && data[0] == 0x08 && data[1] == 0xc3 && data[2] == 0x79 && data[3] == 0xa0) {
            uint256 len;
            assembly {
                len := mload(add(add(data, 32), 36))
            }
            if (data.length >= 68 + 32 + len) {
                bytes memory msgBytes = new bytes(len);
                for (uint256 i = 0; i < len; i++) {
                    msgBytes[i] = data[i + 68 + 32];
                }
                return string(msgBytes);
            }
        }
        if (data.length > 0) return string(abi.encodePacked("0x", _toHex(data.length > 64 ? 64 : data.length, data)));
        return "unknown";
    }

    function _toHex(uint256 len, bytes memory data) private pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory out = new bytes(len * 2);
        for (uint256 i = 0; i < len; i++) {
            out[i * 2] = hexChars[uint8(data[i]) >> 4];
            out[i * 2 + 1] = hexChars[uint8(data[i]) & 0x0f];
        }
        return string(out);
    }

    /// @dev True if asset has no code (not a contract). Native sentinel is allowed (handled in NAVCalculator init).
    function _hasNoCode(address asset) private view returns (bool) {
        if (asset == NATIVE_SENTINEL) return false;
        return asset.code.length == 0;
    }

    function _equals(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @notice Encodes an array of Safe transactions into MultiSend format
    /// @dev Format per tx: operation (1 byte) | to (20 bytes) | value (32 bytes) | dataLength (32 bytes) | data (N bytes)
    function _encodeMultiSend(SafeTxBuilder.Transaction[] memory txs) private pure returns (bytes memory encoded) {
        for (uint256 i = 0; i < txs.length; i++) {
            encoded = abi.encodePacked(
                encoded, bytes1(txs[i].operation), txs[i].to, txs[i].value, uint256(txs[i].data.length), txs[i].data
            );
        }
    }

    /// @notice Builds calldata for a MultiSend-style multicall to execute all registerAsset calls
    /// @dev Caller (sender) must have MANAGER role on NAVCalculator for these calls to succeed.
    function _buildMultiSendCallData(SafeTxBuilder.Transaction[] memory txs) private pure returns (bytes memory) {
        return abi.encodeWithSignature("multiSend(bytes)", _encodeMultiSend(txs));
    }

    /// @notice Token symbols to process per chain. Must match keys in assets.json tokens.{chainId}.
    ///         Add new tokens to assets.json and append the symbol here for the right chain.
    function _symbolsForChain(uint256 chainId) private pure returns (string[] memory) {
        if (chainId == 1) {
            string[] memory s = new string[](31);
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
            s[18] = "USDS";
            s[19] = "USDT";
            s[20] = "DAI";
            s[21] = "GHO";
            s[22] = "USDe";
            s[23] = "sUSDe";
            s[24] = "RLUSD";
            s[25] = "crvUSD";
            s[26] = "sUSDS";
            s[27] = "syrupUSDC";
            s[28] = "COMP";
            s[29] = "WBTC";
            s[30] = "AAVE";
            return s;
        }
        if (chainId == 42161) {
            string[] memory s = new string[](12);
            s[0] = "ETH";
            s[1] = "WETH";
            s[2] = "wstETH";
            s[3] = "weETH";
            s[4] = "ezETH";
            s[5] = "rsETH";
            s[6] = "MORPHO";
            s[7] = "USDC";
            s[8] = "USDT";
            s[9] = "GHO";
            s[10] = "syrupUSDC";
            s[11] = "COMP";
            return s;
        }
        if (chainId == 100) {
            // Include all tokens defined for chain 100 in assets.json
            string[] memory s = new string[](7);
            s[0] = "xDAI";
            s[1] = "WXDAI";
            s[2] = "WETH";
            s[3] = "wstETH";
            s[4] = "USDCe";
            s[5] = "sDAI";
            s[6] = "GHO";
            return s;
        }
        if (chainId == 8453) {
            string[] memory s = new string[](9);
            s[0] = "ETH";
            s[1] = "WETH";
            s[2] = "wstETH";
            s[3] = "weETH";
            s[4] = "cbETH";
            s[5] = "MORPHO";
            s[6] = "USDC";
            s[7] = "GHO";
            s[8] = "COMP";
            return s;
        }
        if (chainId == 10) {
            // Include all tokens defined for chain 10 in assets.json
            string[] memory s = new string[](6);
            s[0] = "ETH";
            s[1] = "WETH";
            s[2] = "wstETH";
            s[3] = "USDC";
            s[4] = "USDT";
            s[5] = "COMP";
            return s;
        }
        if (chainId == 56) {
            // BSC. COW has no Chainlink feed and is intentionally omitted (the V2 PCS adapter
            // still emits it as a position; NAVCalculator drops unregistered assets).
            string[] memory s = new string[](6);
            s[0] = "BNB";
            s[1] = "WBNB";
            s[2] = "USDC";
            s[3] = "USDT";
            s[4] = "ETH";
            s[5] = "CAKE";
            return s;
        }
        if (chainId == 137) {
            // Polygon: native is POL (formerly MATIC). Symbols listed must exist as keys under
            // assets.json `tokens.137`. wstETH/sUSDe/etc. are intentionally not registered yet
            // — they require chain-specific custom price-feed contracts that aren't deployed
            // on Polygon. Add them in a follow-up alongside their feed adapter.
            string[] memory s = new string[](5);
            s[0] = "POL";
            s[1] = "WPOL";
            s[2] = "WETH";
            s[3] = "USDC";
            s[4] = "USDT";
            return s;
        }
        return new string[](0);
    }
}
