// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {AcrossBridgeAdapter} from "../../src/bridge/adapters/AcrossBridgeAdapter.sol";
import {CcipBridgeAdapter} from "../../src/bridge/adapters/CcipBridgeAdapter.sol";
import {StargateBridgeAdapter} from "../../src/bridge/adapters/StargateBridgeAdapter.sol";
import {console2} from "forge-std/console2.sol";

/// @title AuthorizeBridgeAdapters
/// @notice Authorizes all enabled bridge adapters on BridgeEscrow by broadcasting from the EOA admin.
/// @dev Run with the admin EOA as broadcaster (e.g. --private-key or ledger).
///      Uses authorizeAdapterWithCallback for Across, CCIP, Stargate (so protocol callbacks work);
///      uses authorizeAdapter for CCTP and Superchain. If an adapter is already authorized,
///      authorizeAdapterWithCallback will revert — use BridgeEscrow.updateAdapterConfig(adapter, selector) instead.
contract AuthorizeBridgeAdapters is BaseDeployScript {
    function run() public override {
        setUp();

        address bridgeProxy = readDeployedAddress("BridgeEscrowProxy");
        if (bridgeProxy == address(0)) {
            bridgeProxy = readDeployedAddress("BridgeEscrowProxyWithInit");
        }
        require(bridgeProxy != address(0), "BridgeEscrow proxy not in config.");
        require(chainConfig.admin != address(0), "Admin not configured.");

        console2.log("\n=== Authorize Bridge Adapters (EOA) ===");
        console2.log("Chain:", chainConfig.name);
        console2.log("BridgeEscrow:", bridgeProxy);
        console2.log("Admin (broadcaster):", chainConfig.admin);
        console2.log("");

        BridgeEscrow escrow = BridgeEscrow(payable(bridgeProxy));

        vm.startBroadcast();

        _authorizeAdapter(escrow, "CCIP", CcipBridgeAdapter.ccipReceive.selector);
        _authorizeAdapter(escrow, "Across", AcrossBridgeAdapter.handleAcrossMessage.selector);
        _authorizeAdapter(escrow, "Stargate", StargateBridgeAdapter.lzReceive.selector);
        _authorizeAdapterNoCallback(escrow, "CCTP");
        _authorizeAdapterNoCallback(escrow, "Superchain");

        vm.stopBroadcast();

        console2.log("\n=== Done ===");
    }

    /// @dev Authorizes adapter with callback selector (for CCIP, Across, Stargate).
    function _authorizeAdapter(BridgeEscrow escrow, string memory name, bytes4 callbackSelector) internal {
        if (!ConfigReader.isAdapterEnabled(vm, currentChainId, "bridgeAdapters", name)) return;
        address deployed = _readAdapterDeployed("bridgeAdapters", name);
        if (deployed == address(0)) return;

        escrow.authorizeAdapterWithCallback(deployed, callbackSelector);
        console2.log("Authorized (with callback):", name, deployed);
    }

    /// @dev Authorizes adapter without callback (for CCTP, Superchain).
    function _authorizeAdapterNoCallback(BridgeEscrow escrow, string memory name) internal {
        if (!ConfigReader.isAdapterEnabled(vm, currentChainId, "bridgeAdapters", name)) return;
        address deployed = _readAdapterDeployed("bridgeAdapters", name);
        if (deployed == address(0)) return;

        escrow.authorizeAdapter(deployed);
        console2.log("Authorized:", name, deployed);
    }

    function _readAdapterDeployed(string memory adapterType, string memory adapterName)
        internal
        view
        returns (address)
    {
        string memory deployed = ConfigReader.readAdapterParam(vm, currentChainId, adapterType, adapterName, "deployed");
        if (bytes(deployed).length == 0) return address(0);
        return vm.parseAddress(deployed);
    }
}
