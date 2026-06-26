// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AaveV3InstancesMetaBalanceAdapter} from "src/balances/protocols/AaveV3InstancesMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title DeployAaveInstancesMeta (development)
/// @notice Deploys the Aave V3 instances meta-adapter on the local anvil fork, registers it on
///         NAVCalculator (addBalanceAdapter) and sets its active instance set (addMetaInstances). The instance
///         coordinate is each instance's ProtocolDataProvider address widened to bytes32, exactly as
///         AaveV3InstancesMeta._instancePositions decodes it via _toAddress. Registering a
///         meta-adapter requires BOTH calls — the meta-adapter equivalent of script/deploy/06_Configure.s.sol.
/// @dev Env vars set by the wrapper shell script:
///        DEV_NAV_PROXY      — deployed NAVCalculator proxy (broadcaster must hold MANAGER)
///        DEV_PROTOCOL_NAME  — human-readable name ("Aave V3")
///        DEV_DATA_PROVIDERS — comma-separated instance ProtocolDataProvider addresses
contract DeployAaveInstancesMeta is Script {
    function run() public {
        address navProxy = vm.envAddress("DEV_NAV_PROXY");
        string memory protocolName = vm.envString("DEV_PROTOCOL_NAME");
        address[] memory dataProviders = vm.envAddress("DEV_DATA_PROVIDERS", ",");

        // DataProvider addresses widen to the bytes32 instance coordinate exactly as
        // MetaBalanceAdapter._toAddress reverses it: address(uint160(uint256(instance))).
        bytes32[] memory instances = new bytes32[](dataProviders.length);
        for (uint256 i = 0; i < dataProviders.length; i++) {
            instances[i] = bytes32(uint256(uint160(dataProviders[i])));
        }

        vm.startBroadcast();

        address adapter = address(new AaveV3InstancesMetaBalanceAdapter(protocolName, navProxy));

        INAVCalculator nav = INAVCalculator(navProxy);
        nav.addMetaBalanceAdapter(adapter, instances);

        vm.stopBroadcast();

        console2.log("NAV proxy:       ", navProxy);
        console2.log("protocol name:   ", protocolName);
        console2.log("instances:       ", dataProviders.length);
        for (uint256 i = 0; i < dataProviders.length; i++) {
            console2.log("  dataProvider:  ", dataProviders[i]);
        }
        console2.log("adapter:         ", adapter);

        // Marker line the wrapper greps to capture the adapter address.
        console2.log(string.concat("DEPLOYED ", vm.toString(adapter)));
    }
}
