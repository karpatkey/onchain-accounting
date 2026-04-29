// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MANAGER} from "../../src/constants.sol";
import {console2} from "forge-std/console2.sol";

/// @title HandoffRolesToSafe
/// @notice Transfers DEFAULT_ADMIN_ROLE and MANAGER from the deployer EOA to their intended Safe addresses,
///         then revokes and renounces the EOA's own roles, leaving the EOA with no privileged access.
/// @dev
///   - Run AFTER all configuration is complete (assets registered, balance oracles added).
///   - Before running: update chainConfig.admin and chainConfig.manager in the chain JSON to the Safe addresses.
///   - Set DEPLOYER_EOA env var to the deployer account address (same as --account $DEPLOYER_NAME).
///   - Caller must hold DEFAULT_ADMIN_ROLE on NAVCalculator.
///   - DEFAULT_ADMIN_ROLE is bytes32(0) per OpenZeppelin AccessControl.
///   - OZ v5 renounceRole(bytes32, address): the second arg (callerConfirmation) must equal msg.sender.
///   - Run with: forge script script/deploy/07_HandoffRolesToSafe.s.sol \
///               --rpc-url $RPC_URL --account $DEPLOYER_NAME --broadcast
contract HandoffRolesToSafe is BaseDeployScript {
    bytes32 private constant DEFAULT_ADMIN_ROLE = bytes32(0);

    function run() public override {
        setUp();

        address navProxy = readDeployedAddress("NAVCalculatorProxy");
        require(navProxy != address(0), "NAVCalculator not deployed.");
        require(navProxy.code.length > 0, "No code at NAVCalculator proxy. Provide --rpc-url.");

        address deployer = vm.envAddress("DEPLOYER_EOA");
        require(deployer != address(0), "Set DEPLOYER_EOA env var to the deployer EOA address.");

        address newAdmin = chainConfig.admin;
        address newManager = chainConfig.manager;

        require(newAdmin != address(0), "chainConfig.admin not set. Update chain JSON to Safe admin address first.");
        require(
            newManager != address(0), "chainConfig.manager not set. Update chain JSON to Safe manager address first."
        );
        require(newAdmin != deployer, "chainConfig.admin is still the EOA. Update chain JSON to Safe admin first.");

        console2.log("\n=== Role Handoff: EOA -> Safe ===");
        console2.log("NAVCalculator proxy:", navProxy);
        console2.log("Deployer EOA (losing roles):", deployer);
        console2.log("New admin (Safe):", newAdmin);
        console2.log("New manager (Safe):", newManager);

        // Confirm current role state before proceeding
        bool deployerHasAdmin = IAccessControl(navProxy).hasRole(DEFAULT_ADMIN_ROLE, deployer);
        bool deployerHasManager = IAccessControl(navProxy).hasRole(MANAGER, deployer);
        bool newAdminAlreadyHasAdmin = IAccessControl(navProxy).hasRole(DEFAULT_ADMIN_ROLE, newAdmin);
        bool newManagerAlreadyHasManager = IAccessControl(navProxy).hasRole(MANAGER, newManager);

        console2.log("\n--- Pre-flight role check ---");
        console2.log("  EOA has DEFAULT_ADMIN_ROLE:", deployerHasAdmin);
        console2.log("  EOA has MANAGER:", deployerHasManager);
        console2.log("  New admin already has DEFAULT_ADMIN_ROLE:", newAdminAlreadyHasAdmin);
        console2.log("  New manager already has MANAGER:", newManagerAlreadyHasManager);

        require(deployerHasAdmin, "EOA does not hold DEFAULT_ADMIN_ROLE on NAVCalculator. Cannot grant or renounce.");

        vm.startBroadcast();

        // 1. Grant DEFAULT_ADMIN_ROLE to Safe admin
        if (!newAdminAlreadyHasAdmin) {
            IAccessControl(navProxy).grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
            console2.log("[OK] Granted DEFAULT_ADMIN_ROLE to new admin:", newAdmin);
        } else {
            console2.log("[SKIP] New admin already has DEFAULT_ADMIN_ROLE");
        }

        // 2. Grant MANAGER to Safe manager
        if (!newManagerAlreadyHasManager) {
            IAccessControl(navProxy).grantRole(MANAGER, newManager);
            console2.log("[OK] Granted MANAGER to new manager:", newManager);
        } else {
            console2.log("[SKIP] New manager already has MANAGER");
        }

        // 3. Revoke MANAGER from deployer EOA (admin can revoke any role)
        if (deployerHasManager) {
            IAccessControl(navProxy).revokeRole(MANAGER, deployer);
            console2.log("[OK] Revoked MANAGER from deployer EOA:", deployer);
        } else {
            console2.log("[SKIP] Deployer EOA did not hold MANAGER");
        }

        // 4. Renounce DEFAULT_ADMIN_ROLE from deployer EOA
        //    OZ v5: callerConfirmation must equal msg.sender (the EOA executing this tx)
        IAccessControl(navProxy).renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        console2.log("[OK] Renounced DEFAULT_ADMIN_ROLE from deployer EOA:", deployer);

        vm.stopBroadcast();

        // Post-flight verification (staticcall, never reverts)
        console2.log("\n--- Post-handoff role verification ---");
        _logRole(navProxy, "EOA DEFAULT_ADMIN_ROLE", DEFAULT_ADMIN_ROLE, deployer);
        _logRole(navProxy, "EOA MANAGER", MANAGER, deployer);
        _logRole(navProxy, "Safe admin DEFAULT_ADMIN_ROLE", DEFAULT_ADMIN_ROLE, newAdmin);
        _logRole(navProxy, "Safe manager MANAGER", MANAGER, newManager);

        console2.log("\n=== Handoff Complete ===");
        console2.log("The deployer EOA no longer holds any privileged role on NAVCalculator.");
        console2.log("Admin (DEFAULT_ADMIN_ROLE):", newAdmin);
        console2.log("Manager (MANAGER):", newManager);
    }

    function _logRole(address target, string memory label, bytes32 role, address account) internal view {
        (bool ok, bytes memory data) =
            target.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", role, account));
        if (ok && data.length >= 32) {
            console2.log(string(abi.encodePacked("  ", label, ":")), abi.decode(data, (bool)));
        } else {
            console2.log(string(abi.encodePacked("  ", label, ": unknown (hasRole reverted)")));
        }
    }
}
