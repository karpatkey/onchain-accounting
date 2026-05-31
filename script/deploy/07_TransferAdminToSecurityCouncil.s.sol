// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MANAGER} from "../../src/constants.sol";
import {console2} from "forge-std/console2.sol";

/// @title TransferAdminToSecurityCouncil
/// @notice Final deploy step: hands governance of the NAVCalculator and BridgeEscrow proxies from the deployer EOA
///         to the security-council Safe, then strips the deployer of all roles.
/// @dev EOA flow (no Safe executes anything here — the deployer EOA broadcasts these txs while it still holds
///      DEFAULT_ADMIN_ROLE):
///        1. grant DEFAULT_ADMIN_ROLE + MANAGER to `chainConfig.securityCouncil` on both proxies
///        2. revoke MANAGER from the deployer EOA
///        3. renounce DEFAULT_ADMIN_ROLE from the deployer EOA (OZ v5: callerConfirmation must equal msg.sender)
///      After this the council Safe is the sole admin/manager and the deployer holds nothing. Run LAST, after all
///      configuration (assets registered, balance oracles added + meta instances set, bridge adapters authorized).
///      Set DEPLOYER_EOA to the deployer account address (same as --account $DEPLOYER_NAME).
///      Run with: forge script script/deploy/07_TransferAdminToSecurityCouncil.s.sol \
///                --rpc-url $RPC_URL --account $DEPLOYER_NAME --broadcast
contract TransferAdminToSecurityCouncil is BaseDeployScript {
    bytes32 private constant DEFAULT_ADMIN_ROLE = bytes32(0);

    function run() public override {
        setUp();

        address navProxy = readDeployedAddress("NAVCalculatorProxy");
        address bridgeProxy = readDeployedAddress("BridgeEscrowProxy");
        require(navProxy != address(0) || bridgeProxy != address(0), "No proxies deployed.");

        address deployer = vm.envAddress("DEPLOYER_EOA");
        require(deployer != address(0), "Set DEPLOYER_EOA env var to the deployer EOA address.");

        address council = chainConfig.securityCouncil;
        require(council != address(0), "chainConfig.securityCouncil not set.");
        require(council != deployer, "securityCouncil must differ from the deployer EOA.");

        console2.log("\n=== Transfer admin to security council (EOA -> Safe) ===");
        console2.log("Deployer EOA (losing roles):", deployer);
        console2.log("Security council (new admin/manager):", council);

        if (navProxy != address(0)) {
            require(navProxy.code.length > 0, "No code at NAVCalculator proxy. Provide --rpc-url.");
            _handoff(navProxy, "NAVCalculator", deployer, council);
        }
        if (bridgeProxy != address(0)) {
            require(bridgeProxy.code.length > 0, "No code at BridgeEscrow proxy. Provide --rpc-url.");
            _handoff(bridgeProxy, "BridgeEscrow", deployer, council);
        }

        console2.log("\n=== Handoff complete ===");
        console2.log("The deployer EOA no longer holds any privileged role.");
    }

    /// @notice Grants admin+manager to `council`, revokes manager from + renounces admin for `deployer`, on `target`.
    function _handoff(address target, string memory label, address deployer, address council) internal {
        require(
            IAccessControl(target).hasRole(DEFAULT_ADMIN_ROLE, deployer),
            string(abi.encodePacked(label, ": deployer EOA does not hold DEFAULT_ADMIN_ROLE; cannot hand off."))
        );

        console2.log(string(abi.encodePacked("\n--- ", label, " ---")));

        vm.startBroadcast();

        // 1. Grant DEFAULT_ADMIN_ROLE + MANAGER to the council (while the deployer still holds admin).
        if (!IAccessControl(target).hasRole(DEFAULT_ADMIN_ROLE, council)) {
            IAccessControl(target).grantRole(DEFAULT_ADMIN_ROLE, council);
            console2.log("[OK] Granted DEFAULT_ADMIN_ROLE to council");
        } else {
            console2.log("[SKIP] Council already has DEFAULT_ADMIN_ROLE");
        }
        if (!IAccessControl(target).hasRole(MANAGER, council)) {
            IAccessControl(target).grantRole(MANAGER, council);
            console2.log("[OK] Granted MANAGER to council");
        } else {
            console2.log("[SKIP] Council already has MANAGER");
        }

        // 2. Revoke MANAGER from the deployer EOA.
        if (IAccessControl(target).hasRole(MANAGER, deployer)) {
            IAccessControl(target).revokeRole(MANAGER, deployer);
            console2.log("[OK] Revoked MANAGER from deployer EOA");
        }

        // 3. Renounce DEFAULT_ADMIN_ROLE from the deployer EOA (OZ v5: 2nd arg must equal msg.sender = deployer).
        IAccessControl(target).renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        console2.log("[OK] Renounced DEFAULT_ADMIN_ROLE from deployer EOA");

        vm.stopBroadcast();

        // Post-flight verification (best-effort).
        _logRole(target, "deployer DEFAULT_ADMIN_ROLE", DEFAULT_ADMIN_ROLE, deployer);
        _logRole(target, "deployer MANAGER", MANAGER, deployer);
        _logRole(target, "council DEFAULT_ADMIN_ROLE", DEFAULT_ADMIN_ROLE, council);
        _logRole(target, "council MANAGER", MANAGER, council);
    }

    function _logRole(address target, string memory roleLabel, bytes32 role, address account) internal view {
        (bool ok, bytes memory data) =
            target.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", role, account));
        if (ok && data.length >= 32) {
            console2.log(string(abi.encodePacked("  ", roleLabel, ":")), abi.decode(data, (bool)));
        } else {
            console2.log(string(abi.encodePacked("  ", roleLabel, ": unknown (hasRole reverted)")));
        }
    }
}
