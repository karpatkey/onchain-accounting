// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {IBalances} from "../../src/balances/IBalances.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {InvoiceDataLib} from "../../src/bridge/InvoiceDataLib.sol";
import {IPrices} from "../../src/prices/IPrices.sol";
import {console2} from "forge-std/console2.sol";

/// @title ManageAdapters
/// @notice Manages adapters for NAVCalculator and BridgeEscrow
/// @dev Generates Safe transactions for adapter management operations
contract ManageAdapters is BaseDeployScript {
    // Action types
    enum Action {
        ADD_BALANCE_ORACLE,
        REMOVE_BALANCE_ORACLE,
        SET_PRICE_FEED,
        AUTHORIZE_BRIDGE_ADAPTER,
        AUTHORIZE_BRIDGE_ADAPTER_WITH_CALLBACK,
        REVOKE_BRIDGE_ADAPTER,
        REGISTER_ASSET
    }

    function run() public override {
        setUp();
        validateAddresses();

        console2.log("\n=== Adapter Management Menu ===");
        console2.log("This script helps you manage adapters via Safe multisig.");
        console2.log("Edit this script to specify the action and parameters.");
        console2.log("===============================\n");

        // Example: Uncomment and modify to perform specific actions
        // _addBalanceOracle(0x1234...);
        // _setPriceFeed(0x1234..., 0x5678..., "Chainlink", 86400);
        // _authorizeBridgeAdapter(0x1234...);
        // _registerAsset("USDC  ", 0x1234...);
        //
        // Compose a NAV-wiring Safe batch into ONE file per chain (run with --rpc-url so
        // already-registered/undeployed items are skipped). Helpers: _collectBalanceOracleTxs(names)
        // for addBalanceOracle, _registerAssetTx(...) for registerAsset.

        // --- PR #49: wire newly deployed Alpha balance oracles (+ EIGEN price feed on mainnet) ---
        address navProxy = readDeployedAddress("NAVCalculatorProxy");
        require(navProxy != address(0), "NAVCalculator not deployed");
        require(navProxy.code.length > 0, "No code at NAVCalculator proxy. Provide --rpc-url.");

        if (currentChainId == 1) {
            string[] memory names = new string[](5);
            names[0] = "MorphoVault_kpkUSDCYield";
            names[1] = "MorphoVault_kpkUSDTPrime";
            names[2] = "MorphoVault_kpkETHYield";
            names[3] = "StakeWiseV3OsToken_osETH";
            names[4] = "ERC4626Wrap_sGHO";
            SafeTxBuilder.Transaction[] memory oracleTxs = _collectBalanceOracleTxs(navProxy, names);

            // EIGEN: register the token priced by the Chainlink EIGEN/USD feed (8 decimals, 86400s heartbeat).
            SafeTxBuilder.Transaction memory eigenTx = _registerAssetTx(
                navProxy,
                0xec53bF9167f50cDEB3Ae105f56099aaaB9061F83, // EIGEN
                0xf2917e602C2dCa458937fad715bb1E465305A4A1, // Chainlink EIGEN/USD
                IPrices.PriceType.Chainlink,
                86_400
            );
            console2.log("  Batched registerAsset: EIGEN 0xec53bF9167f50cDEB3Ae105f56099aaaB9061F83");

            SafeTxBuilder.Transaction[] memory all = new SafeTxBuilder.Transaction[](oracleTxs.length + 1);
            for (uint256 i = 0; i < oracleTxs.length; i++) {
                all[i] = oracleTxs[i];
            }
            all[oracleTxs.length] = eigenTx;

            _writeNavWiring(
                string(
                    abi.encodePacked(
                        vm.toString(oracleTxs.length), " new balance oracle(s) + EIGEN price-feed registration"
                    )
                ),
                all
            );
        } else if (currentChainId == 42161) {
            string[] memory names = new string[](1);
            names[0] = "MorphoVault_kpkUSDCYieldV2";
            SafeTxBuilder.Transaction[] memory oracleTxs = _collectBalanceOracleTxs(navProxy, names);
            _writeNavWiring(
                string(abi.encodePacked(vm.toString(oracleTxs.length), " new balance oracle(s)")), oracleTxs
            );
        }
    }

    /// @notice Adds a balance oracle to NAVCalculator
    /// @param adapter The balance adapter address
    function _addBalanceOracle(address adapter) internal {
        address navProxy = readDeployedAddress("NAVCalculatorProxy");
        require(navProxy != address(0), "NAVCalculator not deployed");

        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](1);
        transactions[0] = SafeTxBuilder.call(navProxy, 0, abi.encodeCall(NAVCalculator.addBalanceOracle, (adapter)));

        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-add-balance-oracle.json"));

        writeSafeTx(
            filename,
            "Add Balance Oracle to NAVCalculator",
            string(abi.encodePacked("Adds balance oracle: ", vm.toString(adapter))),
            transactions
        );

        console2.log("Safe transaction generated:", filename);
        console2.log("Balance oracle to add:", adapter);
    }

    /// @notice Builds `addBalanceOracle` txs for the given config names (no file write).
    /// @dev Reads each adapter's deployed address from chains/<id>.json by name, so no addresses are
    ///      hardcoded. Run 04_DeployBalanceAdapters.s.sol first to populate them. Requires --rpc-url;
    ///      skips names whose deployed address is missing or already registered (addBalanceOracle
    ///      reverts DuplicateBalanceOracle on a registered oracle), so only genuinely-new adapters
    ///      are returned.
    /// @param adapterNames Config names under balanceAdapters (e.g. "ERC4626Wrap_sGHO").
    function _collectBalanceOracleTxs(address navProxy, string[] memory adapterNames)
        internal
        view
        returns (SafeTxBuilder.Transaction[] memory txs)
    {
        address[] memory toAdd = new address[](adapterNames.length);
        uint256 count;
        for (uint256 i = 0; i < adapterNames.length; i++) {
            address deployed = _readDeployedBalanceAdapter(adapterNames[i]);
            if (deployed == address(0)) {
                console2.log("  SKIP (not deployed):", adapterNames[i]);
                continue;
            }
            if (IBalances(navProxy).isOracleRegistered(deployed)) {
                console2.log("  SKIP (already registered):", adapterNames[i], deployed);
                continue;
            }
            toAdd[count++] = deployed;
            console2.log("  Batched addBalanceOracle:", adapterNames[i], deployed);
        }

        txs = new SafeTxBuilder.Transaction[](count);
        for (uint256 i = 0; i < count; i++) {
            txs[i] = SafeTxBuilder.call(navProxy, 0, abi.encodeCall(NAVCalculator.addBalanceOracle, (toAdd[i])));
        }
    }

    /// @notice Builds a single NAVCalculator.registerAsset tx (no file write).
    /// @dev For a Chainlink-priced asset use `priceType = Chainlink` and pass the feed's heartbeat (s).
    ///      registerAsset reverts on-chain if the asset is already registered, so only include
    ///      genuinely-new assets in the batch.
    function _registerAssetTx(
        address navProxy,
        address asset,
        address priceFeed,
        IPrices.PriceType priceType,
        uint256 chainlinkHeartbeat
    ) internal pure returns (SafeTxBuilder.Transaction memory) {
        return SafeTxBuilder.call(
            navProxy, 0, abi.encodeCall(NAVCalculator.registerAsset, (asset, priceFeed, priceType, chainlinkHeartbeat))
        );
    }

    /// @notice Writes a NAV-wiring Safe batch to `<chainSlug>-nav-wiring.json` (e.g. `eth-nav-wiring.json`).
    function _writeNavWiring(string memory description, SafeTxBuilder.Transaction[] memory txs) internal {
        require(txs.length > 0, "Nothing to wire (all skipped)");
        string memory filename = string(abi.encodePacked(_chainSlug(currentChainId), "-nav-wiring.json"));
        writeSafeTx(filename, "NAV v2 wiring", description, txs);
        console2.log("Safe transaction generated:", filename);
        console2.log("Transactions batched:", txs.length);
    }

    /// @notice Short human-readable chain slug for Safe-batch filenames; falls back to the chain id.
    function _chainSlug(uint256 chainId) internal view returns (string memory) {
        if (chainId == 1) return "eth";
        if (chainId == 42161) return "arb";
        if (chainId == 8453) return "base";
        if (chainId == 10) return "op";
        if (chainId == 100) return "gnosis";
        return vm.toString(chainId);
    }

    /// @notice Reads a deployed balance-adapter address from the chain config by name.
    /// @dev Mirrors the config read in 06_2_AddBalanceOracles.s.sol. Returns address(0) if unset.
    function _readDeployedBalanceAdapter(string memory adapterName) internal view returns (address) {
        string memory deployed =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "deployed");
        if (bytes(deployed).length == 0) return address(0);
        return vm.parseAddress(deployed);
    }

    /// @notice Removes a balance oracle from NAVCalculator
    /// @param adapter The balance adapter address to remove
    function _removeBalanceOracle(address adapter) internal {
        address navProxy = readDeployedAddress("NAVCalculatorProxy");
        require(navProxy != address(0), "NAVCalculator not deployed");

        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](1);
        transactions[0] = SafeTxBuilder.call(navProxy, 0, abi.encodeCall(NAVCalculator.removeBalanceOracle, (adapter)));

        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-remove-balance-oracle.json"));

        writeSafeTx(
            filename,
            "Remove Balance Oracle from NAVCalculator",
            string(abi.encodePacked("Removes balance oracle: ", vm.toString(adapter))),
            transactions
        );

        console2.log("Safe transaction generated:", filename);
        console2.log("Balance oracle to remove:", adapter);
    }

    /// @notice Sets a price feed for an asset in NAVCalculator
    /// @param asset The asset address
    /// @param priceFeed The price feed adapter address
    /// @param priceType The price type (0 = Chainlink, 1 = Custom)
    /// @param heartbeat The heartbeat in seconds
    function _setPriceFeed(address asset, address priceFeed, IPrices.PriceType priceType, uint256 heartbeat) internal {
        address navProxy = readDeployedAddress("NAVCalculatorProxy");
        require(navProxy != address(0), "NAVCalculator not deployed");

        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](1);
        transactions[0] = SafeTxBuilder.call(
            navProxy, 0, abi.encodeCall(NAVCalculator.setPriceFeed, (asset, priceFeed, priceType, heartbeat))
        );

        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-set-price-feed.json"));

        writeSafeTx(
            filename,
            "Set Price Feed in NAVCalculator",
            string(abi.encodePacked("Sets price feed for asset ", vm.toString(asset), " to ", vm.toString(priceFeed))),
            transactions
        );

        console2.log("Safe transaction generated:", filename);
        console2.log("Asset:", asset);
        console2.log("Price feed:", priceFeed);
    }

    /// @notice Authorizes a bridge adapter in BridgeEscrow
    /// @param adapter The bridge adapter address
    function _authorizeBridgeAdapter(address adapter) internal {
        address bridgeProxy = readDeployedAddress("BridgeEscrowProxy");
        require(bridgeProxy != address(0), "BridgeEscrow not deployed");

        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](1);
        transactions[0] = SafeTxBuilder.call(bridgeProxy, 0, abi.encodeCall(BridgeEscrow.authorizeAdapter, (adapter)));

        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-authorize-bridge-adapter.json"));

        writeSafeTx(
            filename,
            "Authorize Bridge Adapter",
            string(abi.encodePacked("Authorizes bridge adapter: ", vm.toString(adapter))),
            transactions
        );

        console2.log("Safe transaction generated:", filename);
        console2.log("Bridge adapter to authorize:", adapter);
    }

    /// @notice Authorizes a bridge adapter with callback in BridgeEscrow
    /// @param adapter The bridge adapter address
    /// @param selector The callback function selector
    function _authorizeBridgeAdapterWithCallback(address adapter, bytes4 selector) internal {
        address bridgeProxy = readDeployedAddress("BridgeEscrowProxy");
        require(bridgeProxy != address(0), "BridgeEscrow not deployed");

        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](1);
        transactions[0] = SafeTxBuilder.call(
            bridgeProxy, 0, abi.encodeCall(BridgeEscrow.authorizeAdapterWithCallback, (adapter, selector))
        );

        string memory filename =
            string(abi.encodePacked(vm.toString(currentChainId), "-authorize-bridge-adapter-callback.json"));

        writeSafeTx(
            filename,
            "Authorize Bridge Adapter with Callback",
            string(
                abi.encodePacked(
                    "Authorizes bridge adapter with callback: ",
                    vm.toString(adapter),
                    " selector: ",
                    vm.toString(uint32(selector))
                )
            ),
            transactions
        );

        console2.log("Safe transaction generated:", filename);
        console2.log("Bridge adapter:", adapter);
        console2.log("Callback selector:", vm.toString(uint32(selector)));
    }

    /// @notice Revokes a bridge adapter from BridgeEscrow
    /// @param adapter The bridge adapter address to revoke
    function _revokeBridgeAdapter(address adapter) internal {
        address bridgeProxy = readDeployedAddress("BridgeEscrowProxy");
        require(bridgeProxy != address(0), "BridgeEscrow not deployed");

        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](1);
        transactions[0] = SafeTxBuilder.call(bridgeProxy, 0, abi.encodeCall(BridgeEscrow.revokeAdapter, (adapter)));

        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-revoke-bridge-adapter.json"));

        writeSafeTx(
            filename,
            "Revoke Bridge Adapter",
            string(abi.encodePacked("Revokes bridge adapter: ", vm.toString(adapter))),
            transactions
        );

        console2.log("Safe transaction generated:", filename);
        console2.log("Bridge adapter to revoke:", adapter);
    }

    /// @notice Registers an asset in BridgeEscrow
    /// @param symbol The asset symbol (bytes6, e.g., "USDC  ")
    /// @param asset The asset address
    function _registerAsset(bytes6 symbol, address asset) internal {
        address bridgeProxy = readDeployedAddress("BridgeEscrowProxy");
        require(bridgeProxy != address(0), "BridgeEscrow not deployed");

        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](1);
        transactions[0] = SafeTxBuilder.call(
            bridgeProxy, 0, abi.encodeCall(BridgeEscrow.registerAsset, (InvoiceDataLib.bytes6ToStr(symbol), asset))
        );

        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-register-asset.json"));

        writeSafeTx(
            filename,
            "Register Asset in BridgeEscrow",
            string(abi.encodePacked("Registers asset: ", vm.toString(uint48(symbol)), " at ", vm.toString(asset))),
            transactions
        );

        console2.log("Safe transaction generated:", filename);
        console2.log("Asset symbol:", vm.toString(uint48(symbol)));
        console2.log("Asset address:", asset);
    }
}
