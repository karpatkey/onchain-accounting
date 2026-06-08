// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PancakeSwapV3PoolsMetaBalanceAdapter} from "src/balances/protocols/pancakeswap/PancakeSwapV3PoolsMeta.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title DeployPancakeSwapV3Meta (development)
/// @notice Deploys the PancakeSwap V3 pools meta-adapter on the local anvil fork, registers it on
///         NAVCalculator (addBalanceOracle) and sets its active pool instance set (setMetaInstances).
///         This is the meta-adapter equivalent of the per-pool deploy helpers removed in the ADR-0010
///         refactor: registering a meta-adapter requires BOTH calls (see script/deploy/06_Configure.s.sol).
/// @dev Reads context from env vars set by the wrapper shell script:
///        DEV_NAV_PROXY     — deployed NAVCalculator proxy (broadcaster must hold MANAGER)
///        DEV_NPM           — PancakeSwap V3 NonfungiblePositionManager (canonical CREATE2 address)
///        DEV_PROTOCOL_NAME — human-readable protocol name (e.g. "PancakeSwap V3")
///        DEV_POOLS         — comma-separated PancakeSwap V3 pool addresses to set as meta instances
contract DeployPancakeSwapV3Meta is Script {
    function run() public {
        address navProxy = vm.envAddress("DEV_NAV_PROXY");
        address npm = vm.envAddress("DEV_NPM");
        string memory protocolName = vm.envString("DEV_PROTOCOL_NAME");
        address[] memory pools = vm.envAddress("DEV_POOLS", ",");

        // Pool addresses widen to the bytes32 instance coordinate exactly as MetaBalanceOracle._toAddress
        // reverses it: address(uint160(uint256(instance))). Left-pad the address into bytes32.
        bytes32[] memory instances = new bytes32[](pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            instances[i] = bytes32(uint256(uint160(pools[i])));
        }

        vm.startBroadcast();

        PancakeSwapV3PoolsMetaBalanceAdapter adapter =
            new PancakeSwapV3PoolsMetaBalanceAdapter(npm, protocolName, navProxy);

        INAVCalculator nav = INAVCalculator(navProxy);
        nav.addBalanceOracle(address(adapter));
        nav.setMetaInstances(address(adapter), instances);

        vm.stopBroadcast();

        console2.log("NAV proxy:        ", navProxy);
        console2.log("NPM:              ", npm);
        console2.log("protocol name:    ", protocolName);
        console2.log("pool instances:   ", pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            console2.log("  instance:       ", pools[i]);
        }
        console2.log("adapter:          ", address(adapter));

        // Marker line the wrapper greps to capture the adapter address.
        console2.log(string.concat("DEPLOYED ", vm.toString(address(adapter))));
    }
}
