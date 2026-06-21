// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title DeploySalts
/// @author kpk
/// @notice Single source of truth for the CREATE2 salt *versions* used to derive the deterministic
///         placeholder/proxy/implementation addresses. The canonical addresses must be identical on every chain
///         AND across both deploy paths — the full path (`01_DeployImplementations` + `02_DeployProxies` +
///         `AtomicProxyDeployer`) and the NAV-only path (`01_2_DeployNAVImplementation` + `02_2_DeployNAVProxy` +
///         `AtomicNAVProxyDeployer`). They only stay identical if every file that derives a given salt uses the
///         SAME version.
/// @dev These versions used to be hand-written literals scattered across six files; they drifted (the proxy
///      layer was `2` in the full path but `3` in the NAV-only path), which would have produced a *different*
///      NAVCalculator proxy address depending on which script deployed a chain — silently breaking the
///      "same canonical address on every chain" guarantee. Centralizing them here makes that drift impossible:
///      a version bump (e.g. to dodge a front-run) is one edit that updates every deriving site at once.
///
///      Pure constants only (no cheatcodes / no Vm), so this is safe to import into the on-chain atomic deployer
///      CONTRACTS as well as the forge scripts. Each contract's salt string is its name; the salt is
///      `keccak256(abi.encodePacked(name, version))` — identical whether derived via `ConfigReader.computeSalt`
///      (scripts) or inline (atomic deployers).
///
///      NOTE: the external-library salts (`PriceFeedLib`, `NavRegistryLib`, both version 1) are intentionally
///      NOT centralized here — their addresses are separately pinned in `foundry.toml`/`LibraryPins.sol`, so
///      bumping them must be done in lockstep with a pin regeneration and is deliberately kept local to the
///      implementation scripts to avoid implying they are freely bumpable.
library DeploySalts {
    /// @notice Placeholder UUPS implementation the proxies are CREATE2-deployed against (then upgraded).
    ///         Used by all four proxy-deploy files; feeds every proxy's bytecode, so it must be unified.
    uint256 internal constant PLACEHOLDER_IMPL = 3;

    /// @notice NAVCalculator UUPS proxy salt. Used by 02_DeployProxies, 02_2_DeployNAVProxy, and both atomic deployers.
    uint256 internal constant NAV_PROXY = 3;

    /// @notice BridgeEscrow UUPS proxy salt. Used by the full path (02_DeployProxies + AtomicProxyDeployer).
    uint256 internal constant BRIDGE_PROXY = 3;

    /// @notice NAVCalculator implementation salt. Used by 01_DeployImplementations and 01_2_DeployNAVImplementation.
    uint256 internal constant NAV_IMPL = 2;

    //
    // Bridge adapters (ADR 0012, D7 — CREATE2 same-address across chains)
    //
    // Each bridge adapter is a plain (non-proxied) AccessControl contract deployed via the canonical CREATE2
    // deployer in 05_DeployBridgeAdapters. Adapters take their constructor args via `initialize(...)` (not the
    // constructor), so their creation bytecode carries no per-chain arguments and the same salt yields the SAME
    // address on every chain. That same-address guarantee is what `trustedRemoteAdapter` (D2) and the CCTP
    // `mintRecipient`/`destinationCaller` + Superchain `receiver` assumptions rely on, so these salts MUST stay
    // identical across the 7 target chains (1, 10, 100, 137, 42161, 56, 8453). Bumping a version (e.g. to dodge a
    // front-run of the deterministic address) re-derives that adapter's address on every chain at once.
    uint256 internal constant CCIP_ADAPTER = 1;
    uint256 internal constant ACROSS_ADAPTER = 1;
    uint256 internal constant STARGATE_ADAPTER = 1;
    uint256 internal constant GNOSIS_ADAPTER = 1;
    uint256 internal constant CCTP_ADAPTER = 1;
    uint256 internal constant SUPERCHAIN_ADAPTER = 1;
}
