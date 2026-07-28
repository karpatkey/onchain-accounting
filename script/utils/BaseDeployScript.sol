// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ConfigReader} from "./ConfigReader.sol";
import {SafeTxBuilder} from "./SafeTxBuilder.sol";
import {IPrices} from "../../src/prices/IPrices.sol";

/// @title BaseDeployScript
/// @notice Base contract for all deployment scripts with common utilities
abstract contract BaseDeployScript is Script {
    using ConfigReader for *;
    using SafeTxBuilder for *;

    /// @notice The active `FOUNDRY_PROFILE` does not produce deploy-valid bytecode.
    /// @param profile The offending profile name.
    error DeployProfileNotAllowed(string profile);

    /// @notice A `FOUNDRY_*` env override is set that changes compiled bytecode, so the artifacts are not
    ///         deploy-valid regardless of which profile is selected.
    /// @param envVar The offending environment variable.
    /// @param value Its value (empty string when it is exported empty — which is itself the dangerous case for
    ///        `FOUNDRY_LIBRARIES`, since it replaces the pinned array with `[""]`).
    error DeployConfigOverridden(string envVar, string value);

    /// @notice The ALLOWLIST of build profiles whose artifacts are valid to deploy, as `keccak256(name)`.
    /// @dev An allowlist, not a denylist, deliberately: a denylist must be extended every time a profile is added, and
    ///      the failure mode of forgetting is silent and on-chain. PR #156 reached the same conclusion for
    ///      `LibraryPinConsistency`'s skip logic after review pushed back on name-based denylisting.
    ///
    ///      - `default` — the profile the library CREATE2 pins in `foundry.toml` were generated under.
    ///      - `slow` — sets only `threads`, `gas_limit` and `memory_limit`, none of which reach the compiler. Verified
    ///        by diffing resolved configs: `default` and `slow` differ in exactly those three keys, while every
    ///        compiler-relevant key (`solc`, `evm_version`, `optimizer`, `optimizer_runs`, `via_ir`, `bytecode_hash`,
    ///        `libraries`, `cbor_metadata`, `code_size_limit`) is identical. REQUIRED, not merely tolerated: the
    ///        redeploy runbook runs `RegisterAssets` under it, because mainnet's 43 assets otherwise `MemoryOOG`.
    ///
    ///      Everything else is refused, including profiles that do not exist yet. `dev` clears the `libraries` array
    ///      (`libraries = []` is its entire body), so its artifacts link libraries at UNPINNED, auto-deployed
    ///      addresses; `lite` — introduced by PR #156, absent on this branch — clears `libraries` AND disables the
    ///      optimizer AND raises `code_size_limit` 16×.
    ///
    ///      To add a profile, BOTH must hold: (1) it overrides no compiler-relevant key, and (2) there is a real need
    ///      to run a deploy script under it. `coverage` satisfies (1) — its whole body is `no_match_coverage`, so its
    ///      artifacts are byte-identical — but fails (2): `forge coverage` does not execute these scripts, so
    ///      allowlisting it would widen the guard for no caller. Criterion (1) alone is not sufficient; the allowlist
    ///      is kept minimal on purpose.
    ///
    ///      Kept as constants rather than a state array so this adds no storage to the 18 subclasses.
    bytes32 private constant PROFILE_DEFAULT = keccak256(bytes("default"));
    bytes32 private constant PROFILE_SLOW = keccak256(bytes("slow"));

    /// @notice Chain configuration for the current deployment
    ConfigReader.ChainConfig internal chainConfig;

    /// @notice Current chain ID
    uint256 internal currentChainId;

    /// @notice Whether this run should persist on-chain/config side effects (e.g. real broadcast + config writes)
    bool internal shouldBroadcast;

    /// @notice Reverts unless the active build profile produces deploy-valid bytecode.
    /// @dev The accident this exists for: a `FOUNDRY_PROFILE` left exported in the shell. Under `dev` (and `lite`) the
    ///      `libraries` array is empty, so `01_DeployImplementations` would CREATE2-deploy libraries at NON-PINNED,
    ///      auto-deployed addresses — additionally UNOPTIMIZED under `lite`, which is the only one of the two that
    ///      disables the optimizer — and the canonical CREATE2 factory returns `address(0)` rather than reverting on
    ///      a failed deploy, so the script logs success and records a bogus address. `01_2` catches this via its four
    ///      `LibraryPins` assertions; `01` has no `LibraryPins` reference at all, and neither do `03`–`07` or
    ///      `script/manage/**`. This closes that gap for all 18 `BaseDeployScript` subclasses at once. Escalated out
    ///      of PR #156's review, which introduces `[profile.lite]` and makes the pin tests skip under it — removing
    ///      the tripwire that would otherwise have caught the mistake in CI.
    ///
    ///      A profile name is NOT the only way to get invalid artifacts, so the name check alone is not enough — see
    ///      {_assertNoBytecodeOverrides}, which closes the sibling channel.
    ///
    ///      Scope, stated honestly. Two things this cannot see:
    ///      - a doctored `[profile.default]` in `foundry.toml`;
    ///      - per-invocation CLI flags (`forge script --libraries / --optimize / --via-ir / --use / --evm-version /
    ///        --optimizer-runs`), which leave no trace in the environment.
    ///      Both are deliberate acts at the command line rather than stale shell state, which is the accident class
    ///      this guards. The rigorous check is the CREATE2-vs-`LibraryPins` comparison `01_2` already performs,
    ///      deliberately NOT hoisted here — it would fire on every branch while the pin regen (#185) is held open, and
    ///      would impose a pin dependency on `06_Configure`, `RegisterAssets` and the `verify`/`upgrade` scripts, none
    ///      of which deploy library-linked bytecode.
    ///
    ///      There is intentionally no bypass env var: an escape hatch a stray export can also set defeats the guard.
    function _assertDeployProfile() internal view {
        _assertDeployProfileName(_activeProfile());
        _assertNoBytecodeOverrides();
    }

    /// @notice The selected build profile. `FOUNDRY_PROFILE` is the ONLY profile selector — forge 1.7.1 has no
    ///         `--profile` flag — and a profile set via a `.env` file is visible here too, so the channel this observes
    ///         is the same channel that selects.
    /// @dev `virtual` purely as a test seam: it lets the guard's wiring be exercised without `vm.setEnv`, which mutates
    ///      the process environment for the whole `forge test` run and cannot be undone (forge-std has no `unsetEnv`).
    ///      Overriding this in production code would defeat the guard.
    function _activeProfile() internal view virtual returns (string memory) {
        return vm.envOr("FOUNDRY_PROFILE", string("default"));
    }

    /// @notice Reverts if any `FOUNDRY_*` env override that changes compiled bytecode is set.
    /// @dev The profile name is not the only way to get undeployable artifacts. Foundry maps every config key to a
    ///      `FOUNDRY_`-prefixed env var, so the SAME stray-export accident reproduces the exact harm while the profile
    ///      name stays `default`. Measured against this repo with `forge config`:
    ///        `FOUNDRY_LIBRARIES=`          -> `libraries: [""]`   (the pins are GONE)
    ///        `FOUNDRY_OPTIMIZER=false`     -> `optimizer: false`
    ///        `FOUNDRY_VIA_IR=false`        -> `via_ir: false`
    ///        `FOUNDRY_EVM_VERSION=osaka`   -> `evm_version: osaka`
    ///        `FOUNDRY_BYTECODE_HASH=ipfs`  -> `bytecode_hash: ipfs`
    ///      Each yields unpinned or otherwise-mismatched libraries, and the canonical CREATE2 factory returns
    ///      `address(0)` rather than reverting, so the run logs success and records a bogus address.
    ///
    ///      Presence is checked with `vm.envExists`, NOT `vm.envOr`: `FOUNDRY_LIBRARIES=` exported EMPTY is the
    ///      dangerous case, and `envOr` cannot distinguish it from unset. None of these is ever legitimately set in
    ///      this repo — CI sets only `FOUNDRY_PROFILE` — so refusing on mere presence costs nothing.
    /// @dev `virtual` for the same test-seam reason as {_activeProfile}.
    function _assertNoBytecodeOverrides() internal view virtual {
        string[8] memory keys = _bytecodeOverrideKeys();
        for (uint256 i; i < keys.length; ++i) {
            _assertNotOverridden(keys[i], vm.envExists(keys[i]), vm.envOr(keys[i], string("")));
        }
    }

    /// @notice The `FOUNDRY_*` keys whose presence invalidates deploy artifacts.
    /// @dev A `pure` getter so the list itself can be pinned by a test without reading the environment.
    function _bytecodeOverrideKeys() internal pure returns (string[8] memory) {
        return [
            "FOUNDRY_LIBRARIES",
            "FOUNDRY_OPTIMIZER",
            "FOUNDRY_OPTIMIZER_RUNS",
            "FOUNDRY_VIA_IR",
            "FOUNDRY_SOLC",
            "FOUNDRY_SOLC_VERSION",
            "FOUNDRY_EVM_VERSION",
            "FOUNDRY_BYTECODE_HASH"
        ];
    }

    /// @notice The override decision, `pure` so it is testable without touching the environment.
    function _assertNotOverridden(string memory key, bool isSet, string memory value) internal pure {
        if (isSet) revert DeployConfigOverridden(key, value);
    }

    /// @notice The allowlist decision itself, split out so it is `pure` and testable without touching the environment.
    /// @dev Driving this through `vm.setEnv` instead is what an earlier version of the test did, and the cases leaked
    ///      into each other: `setEnv` mutates the environment for the entire `forge test` run, test contracts execute
    ///      in parallel, and forge-std has no `unsetEnv` to restore an inherited-unset variable. Keeping every decision
    ///      parameterised means the whole matrix is deterministic and the suite mutates no shared state at all.
    /// @param profile The profile name to check; empty means forge's own default.
    function _assertDeployProfileName(string memory profile) internal pure {
        // Unset and explicitly-empty both mean forge's own default.
        bytes32 active = bytes(profile).length == 0 ? PROFILE_DEFAULT : keccak256(bytes(profile));
        if (active == PROFILE_DEFAULT || active == PROFILE_SLOW) return;
        revert DeployProfileNotAllowed(profile);
    }

    /// @notice Setup function called before deployment
    function setUp() public virtual {
        _assertDeployProfile();

        currentChainId = block.chainid;
        chainConfig = ConfigReader.readChainConfig(vm, currentChainId);

        // Treat this run as a \"real\" broadcast/persist run only when explicitly opted-in via env.
        // This lets you dry-run scripts without mutating config files.
        // Example: PERSIST_DEPLOYMENTS=1 forge script ... --broadcast ...
        shouldBroadcast = vm.envOr("PERSIST_DEPLOYMENTS", false);

        console2.log("=== Deployment Configuration ===");
        console2.log("Chain ID:", currentChainId);
        console2.log("Chain Name:", chainConfig.name);
        console2.log("Admin (deployer EOA during deploy):", chainConfig.admin);
        console2.log("Manager (deployer EOA during deploy):", chainConfig.manager);
        console2.log("Security council (end-state admin):", chainConfig.securityCouncil);
        console2.log("================================");
    }

    /// @notice Main deployment function - override in child contracts
    function run() public virtual;

    /// @notice Computes CREATE2 address for a contract
    /// @param deployer The deployer address (typically the canonical CREATE2 deployer)
    /// @param salt The CREATE2 salt
    /// @param creationCode The contract creation code
    /// @return The computed CREATE2 address
    function computeCreate2Address(address deployer, bytes32 salt, bytes memory creationCode)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(creationCode)))))
        );
    }

    /// @notice Reads a deployed contract address from deployment files
    /// @param contractName The name of the contract
    /// @return The deployed address, or zero address if not found
    function readDeployedAddress(string memory contractName) internal view returns (address) {
        return ConfigReader.readDeployedAddress(vm, currentChainId, contractName);
    }

    /// @notice Saves a deployed contract address to deployment files (only when persistence is enabled)
    /// @param contractName The name of the contract
    /// @param contractAddress The deployed address
    function saveDeployedAddress(string memory contractName, address contractAddress) internal {
        if (!shouldBroadcast) {
            console2.log(
                string(
                    abi.encodePacked(
                        contractName, " deployed at (NOT persisted to config; set PERSIST_DEPLOYMENTS=1 to write):"
                    )
                ),
                contractAddress
            );
            return;
        }

        ConfigReader.writeDeployedAddress(vm, currentChainId, contractName, contractAddress);
        console2.log(string(abi.encodePacked(contractName, " deployed at:")), contractAddress);
    }

    /// @notice Generates a deterministic CREATE2 salt
    /// @param contractName The contract name
    /// @param version The version number
    /// @return The CREATE2 salt
    function generateSalt(string memory contractName, uint256 version) internal pure returns (bytes32) {
        return ConfigReader.computeSalt(contractName, version);
    }

    /// @notice Writes a Safe transaction to file
    /// @param filename The filename (without path)
    /// @param name Transaction name
    /// @param description Transaction description
    /// @param transactions Array of transactions
    function writeSafeTx(
        string memory filename,
        string memory name,
        string memory description,
        SafeTxBuilder.Transaction[] memory transactions
    ) internal {
        SafeTxBuilder.writeSafeTx(
            vm, currentChainId, filename, name, description, chainConfig.securityCouncil, transactions
        );
    }

    /// @notice Helper to start broadcasting if enabled
    function startBroadcast() internal {
        if (shouldBroadcast) {
            vm.startBroadcast();
        }
    }

    /// @notice Helper to stop broadcasting if enabled
    function stopBroadcast() internal {
        if (shouldBroadcast) {
            vm.stopBroadcast();
        }
    }

    /// @notice Validates that the deploy-phase role addresses are set. In the EOA deploy flow `admin` and `manager`
    ///         are the deployer EOA (they hold the roles through deploy/config); the `securityCouncil` Safe is the
    ///         end-state admin and is required only by the final handoff step (07), which checks it itself.
    function validateAddresses() internal view {
        require(chainConfig.admin != address(0), "Admin address not configured");
        require(chainConfig.manager != address(0), "Manager address not configured");
    }

    /// @notice Checks if a contract is already deployed
    /// @param contractName The contract name to check
    /// @return True if deployed, false otherwise
    function isDeployed(string memory contractName) internal view returns (bool) {
        return readDeployedAddress(contractName) != address(0);
    }

    /// @notice Fails fast when the planned tolerance/monitor config would produce an on-chain call guaranteed to
    ///         revert, so a bad config surfaces at planning time instead of aborting the whole Safe/EOA batch at
    ///         execution. Shared by RegisterAssets and MigrateToMonitorFeeds (single source of truth for the
    ///         on-chain guards in Prices._set*Tolerance and PriceFeedLib.addMonitorFeed).
    /// @dev The divergence-tolerance requirement mirrors the on-chain guard exactly: addMonitorFeed reverts
    ///      DivergenceToleranceRequired unless a non-zero tolerance exists at execution time — set earlier in this
    ///      batch (config `divTol > 0`) OR already on-chain from a prior run. So we only block when a monitor is
    ///      actually being added AND config divTol is 0 AND no on-chain tolerance exists (avoids false-positives on
    ///      idempotent re-runs / out-of-band tolerance management).
    /// @param symbol Asset symbol, used verbatim in revert messages (the concat happens here, not at the call site,
    ///        so the caller passes an already-live local and stays under the via_ir stack limit).
    /// @param monCount Number of monitor feeds the config declares for the asset.
    /// @param divTol Config divergence tolerance (bps).
    /// @param pegTol Config peg tolerance (bps).
    /// @param monitorsBeingAdded True if this run will actually emit at least one addMonitorFeed for the asset.
    function _requireTolerancesPlannable(
        address navProxy,
        address asset,
        string memory symbol,
        uint256 monCount,
        uint256 divTol,
        uint256 pegTol,
        bool monitorsBeingAdded
    ) internal view {
        if (monitorsBeingAdded && divTol == 0) {
            require(
                _onChainDivergenceToleranceBps(navProxy, asset) > 0,
                string.concat(symbol, ": adds monitorFeeds but no divergence tolerance (config or on-chain)")
            );
        }
        // set{Divergence,Peg}Tolerance revert InvalidTolerance for values > 10_000. setDivergenceTolerance is only
        // emitted when monCount > 0 && divTol > 0; setPegTolerance whenever pegTol > 0.
        if (monCount > 0 && divTol > 10_000) {
            revert(string.concat(symbol, ": divergenceToleranceBps > 10000"));
        }
        if (pegTol > 10_000) {
            revert(string.concat(symbol, ": pegToleranceBps > 10000"));
        }
    }

    /// @notice Reads the asset's on-chain divergence tolerance (bps); 0 if unset, not registered, or the call fails.
    function _onChainDivergenceToleranceBps(address navProxy, address asset) private view returns (uint256) {
        (bool ok, bytes memory data) =
            navProxy.staticcall(abi.encodeWithSelector(IPrices.getAssetPricing.selector, asset));
        if (!ok || data.length < 64) return 0;
        IPrices.AssetPricing memory pricing = abi.decode(data, (IPrices.AssetPricing));
        return pricing.divergenceToleranceBps;
    }

    /// @notice Decodes an `Error(string)` revert payload (selector 0x08c379a0) into its message; returns a
    ///         placeholder for empty or custom-error (non-string) reverts. Never reverts. Shared by the manage/
    ///         deploy scripts' `--broadcast` error reporting.
    /// @dev `Error(string)` ABI layout: [0,4) selector · [4,36) offset · [36,68) length · [68,…) string bytes.
    ///      The bounds check is written as `len <= data.length - 68` (not `68 + len`) so a garbage length word
    ///      can't overflow-panic inside the decoder (`data.length >= 68` is guaranteed by the outer guard).
    function _revertMsg(bytes memory data) internal pure returns (string memory) {
        if (data.length >= 68 && data[0] == 0x08 && data[1] == 0xc3 && data[2] == 0x79 && data[3] == 0xa0) {
            uint256 len;
            assembly {
                len := mload(add(add(data, 32), 36))
            }
            if (len <= data.length - 68) {
                bytes memory msgBytes = new bytes(len);
                for (uint256 i = 0; i < len; i++) {
                    msgBytes[i] = data[i + 68];
                }
                return string(msgBytes);
            }
        }
        return data.length > 0 ? "custom error (non-string revert)" : "unknown";
    }
}
