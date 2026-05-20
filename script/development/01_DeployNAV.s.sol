// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {MANAGER} from "src/constants.sol";

/// @dev ERC-7528 native token sentinel — matches Balances.NATIVE_ADDRESS / ERC20DefaultOracle.NATIVE_ADDRESS.
address constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

/// @title DeployNAV (development)
/// @notice Deploys a fresh NAV implementation + ERC1967 proxy on the local anvil fork, then wires
///         the native asset's Chainlink price feed so getAccountNav/getAccountPositions can return
///         a value for any account holding native ETH/xDAI right out of the gate.
/// @dev Reads chain context from env vars set by deploy.sh:
///        DEV_NATIVE_SYMBOL        — "ETH", "xDAI", ...
///        DEV_SEQUENCER_FEED       — L2 sequencer-uptime feed (0x0 on L1)
///        DEV_NATIVE_FEED          — Chainlink ETH/USD (or xDAI/USD) aggregator on this chain
///        DEV_NATIVE_HEARTBEAT     — feed heartbeat in seconds
contract DeployNAV is Script {
    function run() public {
        string memory nativeSymbol = vm.envString("DEV_NATIVE_SYMBOL");
        address sequencerFeed = vm.envOr("DEV_SEQUENCER_FEED", address(0));
        address nativeFeed = vm.envAddress("DEV_NATIVE_FEED");
        uint256 nativeHeartbeat = vm.envUint("DEV_NATIVE_HEARTBEAT");

        address admin = msg.sender;

        vm.startBroadcast();

        NAVCalculator impl = new NAVCalculator();

        bytes memory initData = abi.encodeCall(
            NAVCalculator.initialize,
            (admin, sequencerFeed, nativeSymbol)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        NAVCalculator nav = NAVCalculator(address(proxy));

        // Admin grants itself MANAGER so a single EOA can keep registering assets in later phases.
        nav.grantRole(MANAGER, admin);

        // Wire the Chainlink price feed for the pre-registered native asset.
        nav.setPriceFeed(NATIVE_ADDRESS, nativeFeed, IPrices.PriceType.Chainlink, nativeHeartbeat);

        vm.stopBroadcast();

        address defaultOracle = nav.erc20DefaultOracle();

        console2.log("native symbol:    ", nativeSymbol);
        console2.log("sequencer feed:   ", sequencerFeed);
        console2.log("native feed:      ", nativeFeed);
        console2.log("native heartbeat: ", nativeHeartbeat);
        console2.log("admin/manager:    ", admin);
        console2.log("NAV impl:         ", address(impl));
        console2.log("NAV proxy:        ", address(proxy));
        console2.log("ERC20DefaultOracle:", defaultOracle);

        // Marker line that deploy.sh greps to capture addresses without parsing the full log.
        console2.log(
            string.concat(
                "DEPLOYED ",
                vm.toString(address(impl)),
                " ",
                vm.toString(address(proxy)),
                " ",
                vm.toString(defaultOracle)
            )
        );
    }
}
