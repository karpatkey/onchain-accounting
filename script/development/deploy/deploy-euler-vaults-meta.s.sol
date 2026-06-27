// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {EulerVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/EulerVaultsMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title DeployEulerVaultsMeta (development)
/// @notice Deploys the Euler V2 eVaults meta-adapter on the local anvil fork and registers it on NAVCalculator
///         via addMetaBalanceAdapter(adapter, instances) (register + seed), mirroring 06_Configure. Each instance
///         coordinate is an eVault address widened to bytes32 exactly as MetaBalanceAdapter._toAddress reverses it.
/// @dev Env vars (set by the wrapper shell script):
///        DEV_NAV_PROXY     — deployed NAVCalculator proxy (broadcaster must hold MANAGER)
///        DEV_PROTOCOL_NAME — human-readable name ("Euler")
///        DEV_EULER_VAULTS  — comma-separated eVault addresses
contract DeployEulerVaultsMeta is Script {
    function run() public {
        address navProxy = vm.envAddress("DEV_NAV_PROXY");
        string memory protocolName = vm.envString("DEV_PROTOCOL_NAME");
        address[] memory vaults = vm.envAddress("DEV_EULER_VAULTS", ",");

        bytes32[] memory instances = new bytes32[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            instances[i] = bytes32(uint256(uint160(vaults[i])));
        }

        vm.startBroadcast();
        address adapter = address(new EulerVaultsMetaBalanceAdapter(protocolName, navProxy));
        INAVCalculator(navProxy).addMetaBalanceAdapter(adapter, instances);
        vm.stopBroadcast();

        console2.log("NAV proxy:       ", navProxy);
        console2.log("protocol name:   ", protocolName);
        console2.log("instances:       ", vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            console2.log("  eVault:        ", vaults[i]);
        }
        console2.log("adapter:         ", adapter);
        console2.log(string.concat("DEPLOYED ", vm.toString(adapter)));
    }
}
