// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {MANAGER} from "src/constants.sol";
import {
    StaderWithdrawalQueueBalanceAdapter
} from "src/balances/BalanceAdapters/StaderWithdrawalQueueBalanceAdapter.sol";
import {LidoWithdrawalQueueBalanceAdapter} from "src/balances/BalanceAdapters/LidoWithdrawalQueueBalanceAdapter.sol";
import {KelpWithdrawalQueueBalanceAdapter} from "src/balances/BalanceAdapters/KelpWithdrawalQueueBalanceAdapter.sol";
import {
    NexusMutualStakingPoolsAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol";
import {
    EtherFiWithdrawalQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {
    StakeWiseV3ExitQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol";
import {
    NexusMutualStakingPoolsAssistant
} from "src/balances/AssistedBalanceAdapters/assistants/NexusMutualStakingPoolsAssistant.sol";
import {
    EtherFiWithdrawalQueueAssistant
} from "src/balances/AssistedBalanceAdapters/assistants/EtherFiWithdrawalQueueAssistant.sol";
import {
    StakeWiseV3ExitQueueAssistant
} from "src/balances/AssistedBalanceAdapters/assistants/StakeWiseV3ExitQueueAssistant.sol";

/// @notice The configured deployer does not hold the NAV MANAGER role (add/remove would revert on broadcast).
error DeployerMissingManagerRole(address deployer);
/// @notice An old adapter is still registered after the migration.
error OldAdapterStillRegistered(address adapter);
/// @notice A new adapter is not registered after the migration.
error NewAdapterNotRegistered(address adapter);
/// @notice None of the old adapters are still registered — the migration appears to have already run (guards a
///         non-idempotent re-run from deploying + registering a duplicate set).
error MigrationAlreadyApplied();
/// @notice The live adapter count is not the pristine pre-migration baseline. Catches a PARTIAL re-run (the add tx
///         landed but the remove tx did not, leaving +6 adapters) or any out-of-band drift — either of which would
///         let a naive re-run register a SECOND copy of the new adapters (permanent double-count). Inspect manually.
error UnexpectedPreMigrationState(uint256 actualCount, uint256 expectedCount);

/// @title MigrateAssistedAdapters
/// @notice ONE-OFF mainnet migration for PR #141 — EXECUTED 2026-07-02 (live NAV 0x42aC…9f91; the 9 deployed
///         addresses are recorded in `script/config/deployments/1.json`, all 9 Etherscan-verified). Kept in-repo as
///         the historical record; the guards make a re-run abort. Broadcast by the deployer EOA
///         (`0xAa5A…4F72`, which holds NAV DEFAULT_ADMIN_ROLE + MANAGER):
///           1. deploys the 6 new adapters (plain Stader/Lido/Kelp + assisted Nexus/ether.fi/StakeWise) and the
///              3 assistants;
///           2. adds the 6 new adapters to the NAV;
///           3. removes the 7 OLD adapters (Merkl/Stader/ether.fi/Nexus/StakeWise/Lido/Kelp) from the live NAV.
///         Stader/Lido/Kelp are redeployed because PR #141 changed their bytecode (removed the `MAX_REQUESTS_PROBED`
///         cap); they are plain auto-enumerating adapters, so they need no cache re-submission.
///         Merkl is removed and NOT re-added (pending a rewrite). The assisted family is permissionless (ADR 0018) —
///         no roles are granted on the adapters or assistants; the assistants are delegatecall helpers, not NAV
///         adapters, so they are deployed + logged but not registered.
///
///         ⚠️ POST-MIGRATION (manual, per-account): the new assisted adapters start with EMPTY coordinate caches. Any
///         account with an in-flight position tracked on the OLD Nexus/ether.fi/StakeWise adapters will report 0 on
///         the new ones until its OWNER re-submits each coordinate (the cache is permissionless / msg.sender-keyed, so
///         this migration cannot re-submit on anyone's behalf). Have each owner Safe delegatecall the new assistant
///         (or call the new adapter's submit) for its live tokenIds / exit tickets. Stader/Lido/Kelp are plain
///         (auto-enumerating) so they need no re-submission.
///
///         ⚠️ INTER-TX WINDOW: the add (step 2) and remove (step 3) are separate broadcast txs. Between them the old
///         and new plain Stader/Lido/Kelp adapters are both registered, so an account with a Stader/Lido/Kelp
///         withdrawal request is double-counted for that ~1-block window (the assisted adapters start empty, so they
///         don't double-count). Run this migration during a quiesced period — pause the share/sub-redeem layer that
///         prices off NAV — so no mint/redeem transacts on the transient value; the overlap self-heals when step 3
///         removes the old plain adapters. This is NOT idempotent: a guard aborts (MigrationAlreadyApplied) if the old
///         adapters are already gone, but a re-run after a PARTIAL failure needs manual inspection.
/// @dev    Dry-run (no writes):
///           forge script script/development/MigrateAssistedAdapters.s.sol --rpc-url $MAINNET_URL --sender 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72
///         Broadcast + verify all deployed contracts on Etherscan, and persist the new addresses to
///         deployments/1.json (PERSIST_DEPLOYMENTS gates the JSON write so a dry-run can't dirty the committed file):
///           PERSIST_DEPLOYMENTS=1 forge script script/development/MigrateAssistedAdapters.s.sol --rpc-url $MAINNET_URL \
///             --account <keystore> --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
///         (9 contracts get verified: 6 adapters + 3 assistants.) The run rewrites the 6 adapter addresses +
///         adds the 3 assistant keys in deployments/1.json; afterwards delete the obsolete Merkl entry manually
///         (the run logs the exact `jq del` — cheatcodes cannot delete a JSON key).
contract MigrateAssistedAdapters is Script {
    // --- Live NAV (mainnet) ---
    INAVCalculator internal constant NAV = INAVCalculator(0x42aC265991163Af2b0B9E59a222d31d201E39f91);

    /// @notice The committed mainnet deployment record updated with the new addresses at the end of the run (see the
    ///         persistence block; gated by PERSIST_DEPLOYMENTS so a dry-run never dirties it).
    string internal constant DEPLOYMENTS_PATH = "script/config/deployments/1.json";

    /// @notice The intended broadcaster (holds NAV DEFAULT_ADMIN_ROLE + MANAGER). Broadcast this script from this
    ///         account (`--account` for its keystore). The pre-flight checks THIS address, not the script's
    ///         `msg.sender`, which under `forge script` need not equal the actual broadcast sender.
    address internal constant DEPLOYER = 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72;

    // --- Underlyings ---
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // --- Stader ---
    address internal constant STADER_USER_WITHDRAWAL_MANAGER = 0x9F0491B32DBce587c50c4C43AB303b06478193A7;

    // --- Lido ---
    address internal constant LIDO_WITHDRAWAL_QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

    // --- Kelp ---
    address internal constant KELP_WITHDRAWAL_MANAGER = 0x62De59c08eB5dAE4b7E6F7a8cAd3006d6965ec16;

    // --- Nexus Mutual ---
    address internal constant NEXUS_STAKING_NFT = 0xcafea508a477D94c502c253A58239fb8F948e97f;
    address internal constant NEXUS_STAKING_VIEWER = 0xcafea5c7d25a192ba70ECA0E2dB62F835c1cF81F;
    address internal constant NXM = 0xd7c49CEE7E9188cCa6AD8FF264C1DA2e69D4Cf3B;
    address internal constant NEXUS_TOKEN_CONTROLLER = 0x5407381b6c251cFd498ccD4A1d877739CB7960B8;

    // --- ether.fi ---
    address internal constant ETHERFI_WITHDRAW_REQUEST_NFT = 0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c;
    address internal constant ETHERFI_LIQUIDITY_POOL = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address internal constant EETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;

    // --- StakeWise V3 ---
    address internal constant STAKEWISE_VAULTS_REGISTRY = 0x3a0008a588772446f6e656133C2D5029CC4FC20E;
    uint256 internal constant STAKEWISE_EXIT_CLAIM_DELAY = 86_400;

    // --- Pristine pre-migration baseline ---
    /// @notice `NAV.getAdapterCount()` on mainnet at authoring time (2026-07-02), before this migration runs. The
    ///         migration nets -1 (adds 6, removes 7), so a completed run leaves 27; a PARTIAL run where only the add
    ///         landed leaves 34. Asserting the count equals this baseline at entry aborts any non-pristine state (see
    ///         {UnexpectedPreMigrationState}). If adapters are added/removed out-of-band before running, refresh this.
    uint256 internal constant EXPECTED_PRE_MIGRATION_ADAPTER_COUNT = 28;

    // --- OLD adapters registered on the live NAV (from script/config/deployments/1.json) ---
    address internal constant OLD_MERKL = 0x0b8c4954ceb7B4795D479801D829Fc1f5F2E7Da7;
    address internal constant OLD_STADER = 0x98c1C89b34aed91191c447C96fe947782FDF866c;
    address internal constant OLD_ETHERFI = 0xa290B8b24e7ed169fB16F9A35d86a5ED01d173D2;
    address internal constant OLD_NEXUS = 0x8D0237436A4Be679Bf059DCC177e09EA1f6C3094;
    address internal constant OLD_STAKEWISE = 0xa7aCE959c28686c22E239c2Eb8AC79cf7B6FF7e1;
    address internal constant OLD_LIDO = 0xe1C20772f74304cf278AaBe844231A3bD9c35f6E;
    address internal constant OLD_KELP = 0x9CB4DBD309b89cf6BB457AB507e85F56FbbC5C61;

    function run() external {
        // Pre-flight: the caller must hold NAV MANAGER (add/remove) — surfaces a misconfigured account before writes.
        if (!IAccessControl(address(NAV)).hasRole(MANAGER, DEPLOYER)) revert DeployerMissingManagerRole(DEPLOYER);

        // Idempotency guard: this script is NOT idempotent (each run deploys fresh CREATE addresses and step 3 only
        // removes the hardcoded OLD_* set). If none of the old adapters are still registered, the migration already
        // ran — abort rather than deploy + register a duplicate set (which would permanently double-count NAV).
        address[7] memory oldAll = [OLD_MERKL, OLD_STADER, OLD_ETHERFI, OLD_NEXUS, OLD_STAKEWISE, OLD_LIDO, OLD_KELP];
        bool anyOldRegistered;
        for (uint256 i; i < oldAll.length; i++) {
            if (NAV.isAdapterRegistered(oldAll[i])) anyOldRegistered = true;
        }
        if (!anyOldRegistered) revert MigrationAlreadyApplied();

        // Stronger guard against a PARTIAL-failure re-run: the `anyOldRegistered` check above does NOT catch the case
        // where a prior run's ADD tx (step 2) landed but its REMOVE tx (step 3) reverted — the old set is still
        // registered, so a naive re-run would deploy + register a SECOND copy of the new adapters (permanent NAV
        // double-count). Assert the live count is exactly the pristine baseline: a partial add leaves +6, a completed
        // run leaves -1, and any out-of-band drift also trips this — all force manual inspection instead of a re-run.
        uint256 liveCount = NAV.getAdapterCount();
        if (liveCount != EXPECTED_PRE_MIGRATION_ADAPTER_COUNT) {
            revert UnexpectedPreMigrationState(liveCount, EXPECTED_PRE_MIGRATION_ADAPTER_COUNT);
        }

        vm.startBroadcast();

        // 1) Deploy the 4 new adapters + 3 assistants.
        StaderWithdrawalQueueBalanceAdapter stader =
            new StaderWithdrawalQueueBalanceAdapter(STADER_USER_WITHDRAWAL_MANAGER, WETH, address(NAV));

        // Historical (already executed). The trailing DEPLOYER is the ADR 0030 admin argument, added only so this
        // script keeps compiling against the current constructors.
        NexusMutualStakingPoolsAssistedBalanceAdapter nexus = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            NEXUS_STAKING_NFT, NEXUS_STAKING_VIEWER, NXM, address(NAV), DEPLOYER
        );
        NexusMutualStakingPoolsAssistant nexusAssistant =
            new NexusMutualStakingPoolsAssistant(address(nexus), NXM, NEXUS_TOKEN_CONTROLLER);

        EtherFiWithdrawalQueueAssistedBalanceAdapter etherfi = new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            ETHERFI_WITHDRAW_REQUEST_NFT, ETHERFI_LIQUIDITY_POOL, NATIVE_ETH, address(NAV), DEPLOYER
        );
        EtherFiWithdrawalQueueAssistant etherfiAssistant = new EtherFiWithdrawalQueueAssistant(
            address(etherfi), ETHERFI_LIQUIDITY_POOL, ETHERFI_WITHDRAW_REQUEST_NFT, EETH
        );

        StakeWiseV3ExitQueueAssistedBalanceAdapter stakewise = new StakeWiseV3ExitQueueAssistedBalanceAdapter(
            STAKEWISE_VAULTS_REGISTRY, NATIVE_ETH, "osETH", address(NAV), STAKEWISE_EXIT_CLAIM_DELAY, DEPLOYER
        );
        StakeWiseV3ExitQueueAssistant stakewiseAssistant = new StakeWiseV3ExitQueueAssistant(address(stakewise));

        // Plain withdrawal-queue adapters whose bytecode changed in PR #141 (MAX_REQUESTS_PROBED cap removed): redeploy
        // + swap so the live NAV runs the capless version. Both auto-enumerate on-chain, so (like Stader) they need no
        // cache re-submission post-migration.
        LidoWithdrawalQueueBalanceAdapter lido =
            new LidoWithdrawalQueueBalanceAdapter(LIDO_WITHDRAWAL_QUEUE, NATIVE_ETH, address(NAV));
        KelpWithdrawalQueueBalanceAdapter kelp =
            new KelpWithdrawalQueueBalanceAdapter(KELP_WITHDRAWAL_MANAGER, address(NAV));

        // 2) Add the 4 new adapters FIRST (no-downtime pattern). Adding before removing means that if a later step
        //    reverts on-chain, the NAV never ends up with the old set removed and no replacements (a 0-NAV window).
        //    The new assisted adapters start with empty caches (report 0), so registering them alongside the old ones
        //    for the brief inter-tx window does not double-count; only the plain Stader/Lido/Kelp adapters transiently
        //    overlap their old enumerating counterparts, harmlessly, until step 3 removes them.
        address[] memory toAdd = new address[](6);
        toAdd[0] = address(stader);
        toAdd[1] = address(nexus);
        toAdd[2] = address(etherfi);
        toAdd[3] = address(stakewise);
        toAdd[4] = address(lido);
        toAdd[5] = address(kelp);
        NAV.addBalanceAdapters(toAdd);

        // 3) Remove the old adapters (Merkl is removed and not re-added). Filter to those STILL registered:
        //    removeBalanceAdapters reverts atomically on the first unregistered address, so if any old adapter was
        //    already deregistered (e.g. Merkl removed out-of-band) an unfiltered list would revert here. (`oldAll`
        //    is the same array used by the idempotency guard above.)
        address[] memory toRemove = new address[](oldAll.length);
        uint256 n;
        for (uint256 i; i < oldAll.length; i++) {
            if (NAV.isAdapterRegistered(oldAll[i])) toRemove[n++] = oldAll[i];
        }
        assembly {
            mstore(toRemove, n) // shrink to the registered subset
        }
        if (n > 0) NAV.removeBalanceAdapters(toRemove);

        vm.stopBroadcast();

        // --- Post-migration assertions (view calls) ---
        if (NAV.isAdapterRegistered(OLD_MERKL)) revert OldAdapterStillRegistered(OLD_MERKL);
        if (NAV.isAdapterRegistered(OLD_STADER)) revert OldAdapterStillRegistered(OLD_STADER);
        if (NAV.isAdapterRegistered(OLD_ETHERFI)) revert OldAdapterStillRegistered(OLD_ETHERFI);
        if (NAV.isAdapterRegistered(OLD_NEXUS)) revert OldAdapterStillRegistered(OLD_NEXUS);
        if (NAV.isAdapterRegistered(OLD_STAKEWISE)) revert OldAdapterStillRegistered(OLD_STAKEWISE);
        if (NAV.isAdapterRegistered(OLD_LIDO)) revert OldAdapterStillRegistered(OLD_LIDO);
        if (NAV.isAdapterRegistered(OLD_KELP)) revert OldAdapterStillRegistered(OLD_KELP);
        if (!NAV.isAdapterRegistered(address(stader))) revert NewAdapterNotRegistered(address(stader));
        if (!NAV.isAdapterRegistered(address(nexus))) revert NewAdapterNotRegistered(address(nexus));
        if (!NAV.isAdapterRegistered(address(etherfi))) revert NewAdapterNotRegistered(address(etherfi));
        if (!NAV.isAdapterRegistered(address(stakewise))) revert NewAdapterNotRegistered(address(stakewise));
        if (!NAV.isAdapterRegistered(address(lido))) revert NewAdapterNotRegistered(address(lido));
        if (!NAV.isAdapterRegistered(address(kelp))) revert NewAdapterNotRegistered(address(kelp));

        // Net count must be exactly baseline - 1 (6 added, 7 removed): catches an unexpected extra/missing
        // registration (e.g. a duplicate that the per-address checks above would miss) beyond the intended swap.
        uint256 finalCount = NAV.getAdapterCount();
        if (finalCount != EXPECTED_PRE_MIGRATION_ADAPTER_COUNT - 1) {
            revert UnexpectedPreMigrationState(finalCount, EXPECTED_PRE_MIGRATION_ADAPTER_COUNT - 1);
        }

        // --- Log the new addresses (record these in deployments/1.json — Deliverable B) ---
        console2.log("=== New adapters ===");
        console2.log("StaderWithdrawalQueue:              ", address(stader));
        console2.log("NexusMutualStakingPoolsAssisted:    ", address(nexus));
        console2.log("EtherFiWithdrawalQueueAssisted:     ", address(etherfi));
        console2.log("StakeWiseV3ExitQueueAssisted:       ", address(stakewise));
        console2.log("LidoWithdrawalQueue:                ", address(lido));
        console2.log("KelpWithdrawalQueue:                ", address(kelp));
        console2.log("=== New assistants (not NAV-registered) ===");
        console2.log("NexusMutualStakingPoolsAssistant:   ", address(nexusAssistant));
        console2.log("EtherFiWithdrawalQueueAssistant:    ", address(etherfiAssistant));
        console2.log("StakeWiseV3ExitQueueAssistant:      ", address(stakewiseAssistant));
        console2.log("");

        // --- Persist the new addresses into deployments/1.json (Deliverable B) ---
        // Gated by PERSIST_DEPLOYMENTS so a plain dry-run (which still executes run()) never dirties the committed
        // record with simulated CREATE addresses — the broadcast command sets it. Mirrors the normal deploy flow's
        // schema: the 6 adapters under `.balanceAdapters.<Name>` (like ConfigReader.writeAdapterAddress) and the 3
        // assistants as top-level keys (like BaseDeployScript.saveDeployedAddress). `vm.writeJson` updates existing
        // keys / adds new ones but CANNOT delete, so the now-obsolete `MerklRewardsAssisted` entry is removed by the
        // logged one-liner rather than in-script.
        if (vm.envOr("PERSIST_DEPLOYMENTS", false)) {
            vm.writeJson(vm.toString(address(stader)), DEPLOYMENTS_PATH, ".balanceAdapters.StaderWithdrawalQueue");
            vm.writeJson(vm.toString(address(lido)), DEPLOYMENTS_PATH, ".balanceAdapters.LidoWithdrawalQueue");
            vm.writeJson(vm.toString(address(kelp)), DEPLOYMENTS_PATH, ".balanceAdapters.KelpWithdrawalQueue");
            vm.writeJson(
                vm.toString(address(nexus)), DEPLOYMENTS_PATH, ".balanceAdapters.NexusMutualStakingPoolsAssisted"
            );
            vm.writeJson(
                vm.toString(address(etherfi)), DEPLOYMENTS_PATH, ".balanceAdapters.EtherFiWithdrawalQueueAssisted"
            );
            vm.writeJson(
                vm.toString(address(stakewise)), DEPLOYMENTS_PATH, ".balanceAdapters.StakeWiseV3ExitQueueAssisted"
            );
            vm.writeJson(vm.toString(address(nexusAssistant)), DEPLOYMENTS_PATH, ".NexusMutualStakingPoolsAssistant");
            vm.writeJson(vm.toString(address(etherfiAssistant)), DEPLOYMENTS_PATH, ".EtherFiWithdrawalQueueAssistant");
            vm.writeJson(vm.toString(address(stakewiseAssistant)), DEPLOYMENTS_PATH, ".StakeWiseV3ExitQueueAssistant");
            console2.log("Persisted 6 adapter + 3 assistant addresses to", DEPLOYMENTS_PATH);
            console2.log("MANUAL (cheatcodes can't delete a JSON key): remove the obsolete Merkl entry with");
            console2.log("  jq 'del(.balanceAdapters.MerklRewardsAssisted)' script/config/deployments/1.json | sponge");
        } else {
            console2.log("NOT persisted to deployments/1.json (set PERSIST_DEPLOYMENTS=1 on the broadcast to write).");
        }
        console2.log("");
        console2.log(
            "WARNING: new assisted caches are EMPTY. Each owner Safe must re-submit its live Nexus/ether.fi/StakeWise"
        );
        console2.log(
            "coordinates to the new adapters, else those positions read 0 in NAV (Stader/Lido/Kelp are plain, exempt)."
        );
    }
}
