// SPDX-License-Identifier: BUSL-1.1
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
///      NOTE: the external-library salts (`PriceFeedLib`, `NAVRegistryLib`, both version 1) are intentionally
///      NOT centralized here — their addresses are separately pinned in `foundry.toml`/`LibraryPins.sol`, so
///      bumping them must be done in lockstep with a pin regeneration and is deliberately kept local to the
///      implementation scripts to avoid implying they are freely bumpable.
library DeploySalts {
    /// @notice Placeholder UUPS implementation the proxies are CREATE2-deployed against (then upgraded).
    ///         Used by all four proxy-deploy files; feeds every proxy's bytecode, so it must be unified.
    uint256 internal constant PLACEHOLDER_IMPL = 3;

    /// @notice NAVCalculator UUPS proxy salt. Used by 02_DeployProxies, 02_2_DeployNAVProxy, and both atomic deployers.
    uint256 internal constant NAV_PROXY = 7;

    /// @notice BridgeEscrow UUPS proxy salt. Used by 02_DeployProxies + AtomicProxyDeployer +
    ///         AtomicBridgeProxyDeployer. Bumped 3->4 for the clean redeploy: salt 3 resolves to the abandoned,
    ///         front-run/buggy escrow (already initialized → not re-usable), so a fresh salt yields a brand-new
    ///         deterministic address. Bump again (5, 6, …) for any subsequent clean-redeploy attempt.
    uint256 internal constant BRIDGE_PROXY = 4;

    /// @notice NAVCalculator implementation salt. Used by 01_DeployImplementations and 01_2_DeployNAVImplementation.
    uint256 internal constant NAV_IMPL = 3;

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
    // Bumped 1->2: the salt-1 CcipBridgeAdapter had no payable `receive()`, so with `feeToken == address(0)`
    // (native, per the fee-token switch) it could not be funded to pay the native CCIP fee and every deposit
    // reverted (fork tests masked it by funding via vm.deal, which bypasses receive()). Adding `receive()` +
    // this fresh salt re-derive a correct adapter at a new same-address on every chain. Old salt-1 abandoned.
    uint256 internal constant CCIP_ADAPTER = 2;
    // Bumped 1->2: the salt-1 Across adapter hardcoded `outputToken = address(0)` in its V3 deposit, which the
    // current Across SpokePool rejects (InvalidOutputToken). The fix adds a per-route output-token map + setter to
    // the adapter (changing its logic, though args still arrive via initialize), so a fresh salt re-derives a
    // correct adapter at a new same-address on every chain. Old salt-1 Across adapters are abandoned.
    uint256 internal constant ACROSS_ADAPTER = 2;
    uint256 internal constant STARGATE_ADAPTER = 1;
    // Bumped 1->2: the salt-1 Gnosis adapter implemented only the ERC677 `onTokenTransfer` receiver callback, but
    // the real OmniBridge multi-token mediator delivers `relayTokensAndCall` transfers via `onTokenBridged`
    // (IERC20Receiver) — which the adapter lacked, so inbound transfers delivered the token but never completed
    // (mock masked it by calling onTokenTransfer). The fix adds `onTokenBridged` (keeps onTokenTransfer too), so a
    // fresh salt re-derives a correct adapter at a new same-address on every chain. Old salt-1 Gnosis abandoned.
    // Bumped 2->3: salt-2 `_handleInboundDelivery` verified only the invoice-asset balance, never that the token the
    // mediator actually delivered equals the invoice asset — a delivery of a different token could false-release on a
    // stale asset balance. Salt-3 threads the delivered token through `onTokenBridged` and reverts on a mismatch
    // (onTokenTransfer passes address(0) to skip). Fresh salt re-derives a correct same-address adapter on ETH+GC.
    // Bumped 3->4: precision hardening (Copilot/claude-review) — `authenticatedInvoice` is now keyed by the
    // per-operation invoice hash (not the reusable lane `invoiceId`), so the MANAGER fallback completes only the
    // exact authenticated transfer. NOTE: NOT re-deployed — the salt-3 canary adapter is superseded by the
    // post-merge full redeploy from main (which should deploy salt-4); the change is non-exploitable (escrow
    // completedInvoices + funded pass-through already prevent misuse) so the live salt-3 adapter is unaffected.
    // Bumped 4->5: USDC.e support — the adapter now swaps the OmniBridge's legacy USDC (USDC_ON_XDAI) 1:1 to/from
    // the escrow-registered USDC.e (USDC_E) via the immutable USDCTransmuter (inbound `deposit`, outbound
    // `withdraw`), so ETH<->Gnosis USDC lands the USDC.e the fund uses (WETH unaffected). New bytecode + a new
    // `usdcTransmuter` config field (DEFAULT_ADMIN-settable via setUsdcTransmuter) → a fresh same-address adapter
    // on ETH+GC. Deployed by the consolidated redeploy from main (which realigns all salts).
    uint256 internal constant GNOSIS_ADAPTER = 5;
    // Bumped 1->2: the salt-1 CCTP adapter compared the message's burnToken (the SOURCE-chain token, e.g.
    // Base USDC) against the DESTINATION asset (e.g. Arbitrum USDC) and reverted BurnTokenMismatch on every
    // real cross-chain transfer (fork/unit mocks masked it by using one token address for both sides). The
    // fix drops that inverted check and instead asserts the destination asset's balance rose by the invoice
    // amount across receiveMessage, so a fresh salt re-derives a correct adapter at a new same-address on
    // every chain. Old salt-1 CCTP adapters are abandoned.
    // Bumped 2->3: `_completeBridge` balance-delta assertion rewritten from `after - before < amount` to
    // `after < before + amount` (Copilot/claude-review) so a non-increase reverts `BurnTokenMismatch` instead of a
    // generic underflow panic — bytecode change, so a fresh salt re-derives a correct same-address adapter.
    uint256 internal constant CCTP_ADAPTER = 3;
    // Bumped 1->2: the salt-1 Superchain adapter was deployed (Base) via a script bug that initialized it with a
    // stale admin + the abandoned escrow, and initialize is one-shot, so it can't be corrected in place. The fix
    // (05 now takes admin/escrow from the deploy context) plus this fresh salt re-derive a correct adapter at a new
    // same-address on every chain. Only Base had the bad one deployed; nothing was wired to it (06 had aborted).
    // Bumped 2->3: salt-2 `proveWithdrawal` accepted any `l2ChainId` even when an `invoiceId` was supplied, so an
    // operator could prove on the wrong L2's portal and strand the withdrawal (finalize selects the portal from the
    // invoice's sourceChainId). Salt-3 enforces `l2ChainId == invoiceId's encoded sourceChainId` (reverts
    // WithdrawalChainIdMismatch). Fresh salt re-derives a correct same-address adapter on ETH+OP+Base.
    // Bumped 3->4: consistency hardening (Copilot) — `setL2TokenForL2` now enforces `chainId == 1` like its sibling
    // L1-only setters. NOTE: the salt-3 adapter deployed for the canary campaign was NOT re-deployed for this (the
    // function is unused by any canary and the deployment is superseded by the post-merge full redeploy from main);
    // salt-4 is what that full redeploy should deploy.
    uint256 internal constant SUPERCHAIN_ADAPTER = 4;
}
