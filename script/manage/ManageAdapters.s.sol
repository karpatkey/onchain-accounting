// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
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
        // _addPriceFeed(0x1234..., 0x5678..., IPrices.PriceType.Chainlink, 86400);
        // _authorizeBridgeAdapter(0x1234...);
        // _registerAsset("USDC  ", 0x1234...);
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

    /// @notice Adds a price feed for an asset in NAVCalculator
    /// @param asset The asset address
    /// @param priceFeed The price feed adapter address
    /// @param priceType The price type (0 = Chainlink, 1 = Custom, 2 = Redstone, 3 = Pyth, 4 = API3)
    /// @param heartbeat The heartbeat in seconds
    function _addPriceFeed(address asset, address priceFeed, IPrices.PriceType priceType, uint256 heartbeat) internal {
        address navProxy = readDeployedAddress("NAVCalculatorProxy");
        require(navProxy != address(0), "NAVCalculator not deployed");

        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](1);
        transactions[0] = SafeTxBuilder.call(
            navProxy, 0, abi.encodeCall(NAVCalculator.addPriceFeed, (asset, priceFeed, priceType, heartbeat))
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
