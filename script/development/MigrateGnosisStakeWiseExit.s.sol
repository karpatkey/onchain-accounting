// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {MANAGER} from "src/constants.sol";
import {
    StakeWiseV3ExitQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol";
import {
    StakeWiseV3ExitQueueAssistant
} from "src/balances/AssistedBalanceAdapters/assistants/StakeWiseV3ExitQueueAssistant.sol";

/// @notice The configured deployer does not hold the NAV MANAGER role (add/remove would revert on broadcast).
error DeployerMissingManagerRole(address deployer);
/// @notice An old adapter is still registered after the migration.
error OldAdapterStillRegistered(address adapter);
/// @notice A new adapter is not registered after the migration.
error NewAdapterNotRegistered(address adapter);
/// @notice Neither old adapter is still registered — the migration appears to have already run.
error MigrationAlreadyApplied();
/// @notice The live adapter count is not the pristine pre-migration baseline (partial re-run or out-of-band drift).
error UnexpectedPreMigrationState(uint256 actualCount, uint256 expectedCount);

/// @title MigrateGnosisStakeWiseExit
/// @notice ONE-OFF Gnosis (chain 100) migration, sibling of the mainnet MigrateAssistedAdapters. Broadcast by the
///         deployer EOA (`0xAa5A…4F72`, which holds MANAGER on the Gnosis NAV at the same CREATE2 address as mainnet):
///           1. deploys the new permissionless (ADR 0018) `StakeWiseV3ExitQueueAssistedBalanceAdapter` for Gnosis
///              (osGNO / GNO-denominated) + its `StakeWiseV3ExitQueueAssistant`;
///           2. adds the new adapter to the Gnosis NAV;
///           3. removes the OLD role-based StakeWise exit adapter (`0x1BFe…`) AND the removed-family Merkl adapter
///              (`0x9B9d…`) from the Gnosis NAV.
///         Gnosis has no Nexus/ether.fi adapters, so this is StakeWise-only (+ the Merkl removal). Unlike the mainnet
///         plain-adapter swaps, the new assisted adapter starts with an EMPTY cache (reports 0), so there is NO
///         transient double-count during the add→remove window — the only effect is the StakeWise position reading 0
///         until each owner Safe re-submits its `(vault, ticket, timestamp)` tuples to the new adapter/assistant.
///         Net adapter count: 5 → 4 (add 1, remove 2).
/// @dev    Dry-run (no writes):
///           forge script script/development/MigrateGnosisStakeWiseExit.s.sol --rpc-url $GNOSIS_URL --sender 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72
///         Broadcast + verify + persist to deployments/100.json (PERSIST_DEPLOYMENTS gates the JSON write):
///           PERSIST_DEPLOYMENTS=1 forge script script/development/MigrateGnosisStakeWiseExit.s.sol --rpc-url $GNOSIS_URL \
///             --account <keystore> --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
///         (2 contracts verified: the adapter + assistant. The run rewrites deployments/100.json's
///         StakeWiseV3ExitQueueAssisted + adds the assistant key; delete the obsolete Merkl entry with the logged jq.)
contract MigrateGnosisStakeWiseExit is Script {
    // --- Live NAV (Gnosis, same CREATE2 address as mainnet) ---
    INAVCalculator internal constant NAV = INAVCalculator(0x42aC265991163Af2b0B9E59a222d31d201E39f91);

    string internal constant DEPLOYMENTS_PATH = "script/config/deployments/100.json";

    address internal constant DEPLOYER = 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72;

    // --- Gnosis StakeWise V3 exit-queue constructor args (from contracts-deployment-config/balance-adapters/100.json) ---
    address internal constant STAKEWISE_VAULTS_REGISTRY = 0x7d014B3C6ee446563d4e0cB6fBD8C3D0419867cB;
    address internal constant GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb; // underlying (Gnosis StakeWise settles in GNO)
    string internal constant RECEIPT_SYMBOL = "osGNO";
    uint256 internal constant EXIT_CLAIM_DELAY = 86_400;

    // --- OLD adapters registered on the live Gnosis NAV (from script/config/deployments/100.json) ---
    address internal constant OLD_STAKEWISE = 0x1BFe0952d4176640b817540cEf9571595962dA42;
    address internal constant OLD_MERKL = 0x9B9d51C2aFCB0e0080509C98CEDd349b54790258;

    /// @notice `NAV.getAdapterCount()` on Gnosis at authoring time (2026-07-02) before this migration. Nets -1
    ///         (add 1, remove 2) → 4. A partial re-run (add landed, remove didn't) leaves 6; drift also trips.
    uint256 internal constant EXPECTED_PRE_MIGRATION_ADAPTER_COUNT = 5;

    function run() external {
        if (!IAccessControl(address(NAV)).hasRole(MANAGER, DEPLOYER)) revert DeployerMissingManagerRole(DEPLOYER);

        // Idempotency: if neither old adapter is still registered, the migration already ran.
        bool anyOldRegistered = NAV.isAdapterRegistered(OLD_STAKEWISE) || NAV.isAdapterRegistered(OLD_MERKL);
        if (!anyOldRegistered) revert MigrationAlreadyApplied();

        // Pristine-baseline guard (catches a partial-failure re-run or out-of-band drift; forces manual inspection).
        uint256 liveCount = NAV.getAdapterCount();
        if (liveCount != EXPECTED_PRE_MIGRATION_ADAPTER_COUNT) {
            revert UnexpectedPreMigrationState(liveCount, EXPECTED_PRE_MIGRATION_ADAPTER_COUNT);
        }

        vm.startBroadcast();

        // 1) Deploy the new permissionless adapter (osGNO / GNO-denominated) + its assistant.
        StakeWiseV3ExitQueueAssistedBalanceAdapter stakewise = new StakeWiseV3ExitQueueAssistedBalanceAdapter(
            STAKEWISE_VAULTS_REGISTRY, GNO, RECEIPT_SYMBOL, address(NAV), EXIT_CLAIM_DELAY
        );
        StakeWiseV3ExitQueueAssistant stakewiseAssistant = new StakeWiseV3ExitQueueAssistant(address(stakewise));

        // 2) Add the new adapter FIRST (no 0-NAV window). It starts with an empty cache (reports 0), so registering it
        //    alongside the old one for the inter-tx window does not double-count.
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(stakewise);
        NAV.addBalanceAdapters(toAdd);

        // 3) Remove the old StakeWise exit adapter + the removed-family Merkl adapter. Filter to those still
        //    registered (removeBalanceAdapters reverts atomically on the first unregistered address).
        address[2] memory oldAll = [OLD_STAKEWISE, OLD_MERKL];
        address[] memory toRemove = new address[](oldAll.length);
        uint256 n;
        for (uint256 i; i < oldAll.length; i++) {
            if (NAV.isAdapterRegistered(oldAll[i])) toRemove[n++] = oldAll[i];
        }
        assembly {
            mstore(toRemove, n)
        }
        if (n > 0) NAV.removeBalanceAdapters(toRemove);

        vm.stopBroadcast();

        // --- Post-migration assertions ---
        if (NAV.isAdapterRegistered(OLD_STAKEWISE)) revert OldAdapterStillRegistered(OLD_STAKEWISE);
        if (NAV.isAdapterRegistered(OLD_MERKL)) revert OldAdapterStillRegistered(OLD_MERKL);
        if (!NAV.isAdapterRegistered(address(stakewise))) revert NewAdapterNotRegistered(address(stakewise));
        uint256 finalCount = NAV.getAdapterCount();
        if (finalCount != EXPECTED_PRE_MIGRATION_ADAPTER_COUNT - 1) {
            revert UnexpectedPreMigrationState(finalCount, EXPECTED_PRE_MIGRATION_ADAPTER_COUNT - 1);
        }

        // --- Log ---
        console2.log("=== New Gnosis adapter ===");
        console2.log("StakeWiseV3ExitQueueAssisted:  ", address(stakewise));
        console2.log("StakeWiseV3ExitQueueAssistant: ", address(stakewiseAssistant));
        console2.log("");

        // --- Persist to deployments/100.json (Deliverable B; gated so a dry-run can't dirty the committed file) ---
        if (vm.envOr("PERSIST_DEPLOYMENTS", false)) {
            vm.writeJson(
                vm.toString(address(stakewise)), DEPLOYMENTS_PATH, ".balanceAdapters.StakeWiseV3ExitQueueAssisted"
            );
            vm.writeJson(vm.toString(address(stakewiseAssistant)), DEPLOYMENTS_PATH, ".StakeWiseV3ExitQueueAssistant");
            console2.log("Persisted new adapter + assistant to", DEPLOYMENTS_PATH);
            console2.log("MANUAL (cheatcodes can't delete a JSON key): remove the obsolete Merkl entry with");
            console2.log(
                "  jq 'del(.balanceAdapters.MerklRewardsAssisted)' script/config/deployments/100.json | sponge"
            );
        } else {
            console2.log("NOT persisted to deployments/100.json (set PERSIST_DEPLOYMENTS=1 on the broadcast to write).");
        }
        console2.log("");
        console2.log("WARNING: the new StakeWise cache is EMPTY. Each owner Safe must re-submit its live (vault,");
        console2.log("positionTicket, timestamp) tuples to the new adapter, else those positions read 0 in NAV.");
    }
}
