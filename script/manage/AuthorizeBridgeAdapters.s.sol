// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {console2} from "forge-std/console2.sol";

/// @title AuthorizeBridgeAdapters
/// @notice Authorizes all enabled bridge adapters on BridgeEscrow by broadcasting from the EOA admin.
/// @dev Run with the admin EOA as broadcaster (e.g. --account $DEPLOYER_NAME or --ledger).
///      For each enabled adapter in config: if bridgeAdapters.<Name>.callbackSelector is set,
///      calls authorizeAdapterWithCallback(adapter, selector); otherwise authorizeAdapter(adapter).
///      See script/config/README.md "Bridge adapters: callbacks". If an adapter is already authorized,
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

        string[] memory names = _bridgeAdapterNames();
        vm.startBroadcast();
        for (uint256 i = 0; i < names.length; i++) {
            _authorizeAdapterFromConfig(escrow, names[i]);
        }
        vm.stopBroadcast();

        console2.log("\n=== Done ===");
    }

    /// @dev Authorizes one adapter: with callback if config has callbackSelector, else without.
    function _authorizeAdapterFromConfig(BridgeEscrow escrow, string memory name) internal {
        if (!ConfigReader.isAdapterEnabled(vm, currentChainId, "bridgeAdapters", name)) return;
        address deployed = _readAdapterDeployed("bridgeAdapters", name);
        if (deployed == address(0)) return;

        (bool hasCallback, bytes4 selector) =
            ConfigReader.readAdapterCallbackSelector(vm, currentChainId, "bridgeAdapters", name);
        if (hasCallback && selector != bytes4(0)) {
            escrow.authorizeAdapterWithCallback(deployed, selector);
            console2.log("Authorized (with callback):", name, deployed);
        } else {
            escrow.authorizeAdapter(deployed);
            console2.log("Authorized:", name, deployed);
        }
    }

    /// @dev Ordered list of bridge adapter names to consider (config may omit or disable some).
    function _bridgeAdapterNames() internal pure returns (string[] memory) {
        string[] memory names = new string[](6);
        names[0] = "CCIP";
        names[1] = "Across";
        names[2] = "Stargate";
        names[3] = "Gnosis";
        names[4] = "CCTP";
        names[5] = "Superchain";
        return names;
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
