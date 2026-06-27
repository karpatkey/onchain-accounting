// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {
    PancakeSwapV3PoolsBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/PancakeSwapV3PoolsBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title DeployPancakeSwapV3 (development)
/// @notice Deploys the PancakeSwap V3 pools assisted adapter on the local anvil fork, registers it on
///         NAVCalculator (addBalanceAdapters) and — if `DEV_ACCOUNT`/`DEV_TOKEN_IDS` are set — submits that
///         account's NFT tokenIds via `submitTokenIds`. This is the assisted-adapter (ADR 0015) successor to the
///         meta-adapter deploy helper: the adapter is fed an account's NFT tokenIds rather than a governed pool set.
/// @dev Reads context from env vars set by the wrapper shell script:
///        DEV_NAV_PROXY     — deployed NAVCalculator proxy (broadcaster must hold MANAGER)
///        DEV_NPM           — PancakeSwap V3 NonfungiblePositionManager (canonical CREATE2 address)
///        DEV_PROTOCOL_NAME — human-readable protocol name (e.g. "PancakeSwap V3")
///        DEV_ACCOUNT       — (optional) account whose NFT tokenIds to seed
///        DEV_TOKEN_IDS     — (optional) comma-separated NFT tokenIds owned by DEV_ACCOUNT
contract DeployPancakeSwapV3 is Script {
    function run() public {
        address navProxy = vm.envAddress("DEV_NAV_PROXY");
        address npm = vm.envAddress("DEV_NPM");
        string memory protocolName = vm.envString("DEV_PROTOCOL_NAME");

        vm.startBroadcast();

        // admin + assistant both = broadcaster on the dev fork, so the same key can submit tokenIds.
        address broadcaster = msg.sender;
        PancakeSwapV3PoolsBalanceAdapter adapter =
            new PancakeSwapV3PoolsBalanceAdapter(npm, protocolName, navProxy, broadcaster, broadcaster);

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        INAVCalculator(navProxy).addBalanceAdapters(adapters);

        address account = vm.envOr("DEV_ACCOUNT", address(0));
        uint256[] memory tokenIds;
        if (account != address(0)) {
            tokenIds = vm.envOr("DEV_TOKEN_IDS", ",", new uint256[](0));
            if (tokenIds.length > 0) adapter.submitTokenIds(account, tokenIds);
        }

        vm.stopBroadcast();

        console2.log("NAV proxy:        ", navProxy);
        console2.log("NPM:              ", npm);
        console2.log("protocol name:    ", protocolName);
        console2.log("account:          ", account);
        console2.log("tokenIds:         ", tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            console2.log("  tokenId:        ", tokenIds[i]);
        }
        console2.log("adapter:          ", address(adapter));

        // Marker line the wrapper greps to capture the adapter address.
        console2.log(string.concat("DEPLOYED ", vm.toString(address(adapter))));
    }
}
