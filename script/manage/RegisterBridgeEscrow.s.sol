// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {InvoiceDataLib} from "../../src/bridge/InvoiceDataLib.sol";
import {console2} from "forge-std/console2.sol";

/// @title RegisterBridgeEscrow
/// @notice Generates Safe tx to register the CCTP bridge adapter and USDC on the BridgeEscrow proxy.
/// @dev Run per chain (--rpc-url for chain 10, 8453, 42161). Output: safe-transactions/{chainId}-register-bridge-escrow.json
///   - Authorizes CCTP adapter in BridgeEscrow if CCTP is enabled and deployed in chain config.
///   - Registers USDC in BridgeEscrow asset registry if USDC address is in assets.json for this chain.
contract RegisterBridgeEscrow is BaseDeployScript {
    using ConfigReader for *;

    /// @dev bytes6 symbol for USDC in BridgeEscrow (right-padded "USDC  ")
    bytes6 internal constant USDC_SYMBOL = bytes6(0x555344432020);

    function run() public override {
        setUp();

        address bridgeProxy = readDeployedAddress("BridgeEscrowProxy");
        if (bridgeProxy == address(0)) {
            bridgeProxy = readDeployedAddress("BridgeEscrowProxyWithInit");
        }
        require(bridgeProxy != address(0), "BridgeEscrow proxy not in config.");

        console2.log("\n=== Register CCTP + USDC on BridgeEscrow ===");
        console2.log("Chain:", chainConfig.name);
        console2.log("Chain ID:", currentChainId);
        console2.log("BridgeEscrow proxy:", bridgeProxy);
        console2.log("");

        uint256 txCount = 0;
        if (_shouldAddCctpAuthorization()) txCount++;
        if (_shouldAddUsdcRegistration()) txCount++;

        if (txCount == 0) {
            console2.log("Nothing to register: CCTP (enabled+deployed) or USDC address missing for this chain.");
            console2.log(
                "  - Enable bridgeAdapters.CCTP in the chain config (its deployed address lives in deployments/<chainId>.json), or deploy CCTP via 05_DeployBridgeAdapters."
            );
            console2.log("  - Add USDC to assets.json assets for this chain.");
            return;
        }

        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](txCount);
        uint256 idx = 0;

        if (_shouldAddCctpAuthorization()) {
            address cctpAdapter = _readCctpDeployed();
            require(cctpAdapter != address(0), "CCTP deployed address missing");
            transactions[idx] =
                SafeTxBuilder.call(bridgeProxy, 0, abi.encodeCall(BridgeEscrow.authorizeAdapter, (cctpAdapter)));
            console2.log("Added tx: BridgeEscrow.authorizeAdapter(CCTP)", cctpAdapter);
            idx++;
        }

        if (_shouldAddUsdcRegistration()) {
            address usdc = _readUsdcAddress();
            require(usdc != address(0), "USDC address missing in assets.json");
            transactions[idx] = SafeTxBuilder.call(
                bridgeProxy,
                0,
                abi.encodeCall(BridgeEscrow.registerAsset, (InvoiceDataLib.bytes6ToStr(USDC_SYMBOL), usdc))
            );
            console2.log("Added tx: BridgeEscrow.registerAsset(USDC, ...)", usdc);
        }

        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-register-bridge-escrow.json"));
        writeSafeTx(
            filename,
            "Register CCTP adapter and USDC on BridgeEscrow",
            "Authorize CCTP bridge adapter and register USDC in BridgeEscrow asset registry",
            transactions
        );

        console2.log("");
        console2.log(string(abi.encodePacked("Safe transaction written to safe-transactions/", filename)));
    }

    function _shouldAddCctpAuthorization() internal view returns (bool) {
        if (!ConfigReader.isAdapterEnabled(vm, currentChainId, "bridgeAdapters", "CCTP")) {
            return false;
        }
        return _readCctpDeployed() != address(0);
    }

    function _readCctpDeployed() internal view returns (address) {
        return ConfigReader.readDeployedAdapterAddress(vm, currentChainId, "bridgeAdapters", "CCTP");
    }

    function _shouldAddUsdcRegistration() internal view returns (bool) {
        return _readUsdcAddress() != address(0);
    }

    function _readUsdcAddress() internal view returns (address) {
        string memory addrStr = ConfigReader.readAssetAddress(vm, currentChainId, "USDC");
        if (bytes(addrStr).length == 0) return address(0);
        return vm.parseAddress(addrStr);
    }
}
