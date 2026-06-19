// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {PriceFeedLib} from "src/prices/PriceFeedLib.sol";
import {NavRegistryLib} from "src/nav/NavRegistryLib.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {MANAGER} from "src/constants.sol";

/// @dev ERC-7528 native token sentinel — matches Balances.NATIVE_ADDRESS / ERC20DefaultAdapter.NATIVE_ADDRESS.
address constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

/// @title DeployNAV (development)
/// @notice Deploys a fresh NAV implementation + ERC1967 proxy on the local anvil fork, then wires the native
///         asset's Chainlink price feed so getAccountNav/getAccountPositions return a value out of the gate.
/// @dev MUST run under the DEFAULT foundry profile (NOT `dev`): current NAVCalculator DELEGATECALLs the external
///      libraries `PriceFeedLib` + `NavRegistryLib`, and its bytecode is linked against their pinned CREATE2
///      addresses (foundry.toml `[profile.default].libraries`). This script first deploys both libraries to those
///      pinned addresses via the canonical CREATE2 deployer (mirrors prod 01_2_DeployNAVImplementation), so the
///      linked impl is valid and `initialize()` (which DELEGATECALLs NavRegistryLib) doesn't revert. The previous
///      single-shot version compiled under `[profile.dev]` (libraries = [], i.e. auto-deploy), which shifted the
///      deployer nonce between simulation and broadcast and made the proxy point at a non-existent impl
///      (ERC1967InvalidImplementation). Pinned CREATE2 libs are nonce-independent and fix that.
/// @dev Reads chain context from env vars set by deploy.sh: DEV_NATIVE_SYMBOL, DEV_SEQUENCER_FEED,
///      DEV_NATIVE_FEED, DEV_NATIVE_HEARTBEAT.
contract DeployNAV is Script {
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    function run() public {
        string memory nativeSymbol = vm.envString("DEV_NATIVE_SYMBOL");
        address sequencerFeed = vm.envOr("DEV_SEQUENCER_FEED", address(0));
        address nativeFeed = vm.envAddress("DEV_NATIVE_FEED");
        uint256 nativeHeartbeat = vm.envUint("DEV_NATIVE_HEARTBEAT");

        address admin = msg.sender;

        vm.startBroadcast();

        // 1. Deploy the external libraries to their pinned CREATE2 addresses (NAVCalculator's bytecode, linked under
        //    the default profile, DELEGATECALLs them). Salt = keccak256(name ++ uint256(1)), matching prod.
        _create2Deploy("PriceFeedLib", 1, type(PriceFeedLib).creationCode);
        _create2Deploy("NavRegistryLib", 1, type(NavRegistryLib).creationCode);

        // 2. Deploy the impl via CREATE2 too (NOT `new`): a deployer-nonce CREATE after the variable-count CREATE2
        //    factory calls above makes forge mis-predict the impl address between simulation and broadcast, so the
        //    proxy ends up pointing at an empty address (ERC1967InvalidImplementation). CREATE2 is nonce-independent.
        //    Salt matches prod 01_2 (version 2).
        address implAddr = _create2Deploy("NAVCalculatorImplementation", 2, type(NAVCalculator).creationCode);

        // 3. Deploy proxy + initialize (proxy via `new` is fine — its address is read after, never forward-referenced).
        bytes memory initData = abi.encodeCall(NAVCalculator.initialize, (admin, sequencerFeed, nativeSymbol));
        ERC1967Proxy proxy = new ERC1967Proxy(implAddr, initData);
        NAVCalculator nav = NAVCalculator(address(proxy));
        address impl = implAddr;

        // Admin grants itself MANAGER so a single EOA can keep registering assets/adapters in later phases.
        nav.grantRole(MANAGER, admin);

        // initialize() already pre-registers NATIVE_ADDRESS (feedless); attach its Chainlink feed via addPriceFeed.
        nav.addPriceFeed(NATIVE_ADDRESS, nativeFeed, IPrices.PriceType.Chainlink, nativeHeartbeat);

        vm.stopBroadcast();

        address defaultAdapter = nav.erc20DefaultAdapter();

        console2.log("native symbol:    ", nativeSymbol);
        console2.log("sequencer feed:   ", sequencerFeed);
        console2.log("native feed:      ", nativeFeed);
        console2.log("native heartbeat: ", nativeHeartbeat);
        console2.log("admin/manager:    ", admin);
        console2.log("NAV impl:         ", address(impl));
        console2.log("NAV proxy:        ", address(proxy));
        console2.log("ERC20DefaultAdapter:", defaultAdapter);

        // Marker line that deploy.sh greps to capture addresses.
        console2.log(
            string.concat(
                "DEPLOYED ",
                vm.toString(address(impl)),
                " ",
                vm.toString(address(proxy)),
                " ",
                vm.toString(defaultAdapter)
            )
        );
    }

    /// @dev CREATE2-deploys `creationCode` via the canonical deployer if not already present (Arachnid format:
    ///      calldata = salt ++ creationCode), returning the deterministic (nonce-independent) address. Salt =
    ///      keccak256(name ++ version), matching prod (ConfigReader.computeSalt). For the libraries this equals
    ///      the foundry.toml pin for the current solc/bytecode_hash, so the linked impl resolves them.
    function _create2Deploy(string memory name, uint256 version, bytes memory creationCode)
        internal
        returns (address addr)
    {
        bytes32 salt = keccak256(abi.encodePacked(name, version));
        addr = _create2Address(salt, keccak256(creationCode));
        if (addr.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(salt, creationCode));
            require(ok, string.concat(name, " CREATE2 deploy failed"));
            console2.log(string.concat("  [OK] ", name, " at:"), addr);
        } else {
            console2.log(string.concat("  [SKIP] ", name, " at:"), addr);
        }
    }

    function _create2Address(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CANONICAL_CREATE2_DEPLOYER, salt, initCodeHash))))
        );
    }
}
