// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ProtocolNames} from "src/utils/ProtocolNames.sol";

/// @title ProtocolNameResolver
/// @author KPK
/// @notice Maps a deploy-config adapter key (`AaveV3InstancesMeta`, `MorphoVaultsMeta`, `CompoundV3_USDC`, …) to the
///         canonical protocol display name that adapter must be constructed with.
/// @dev **Why this exists.** Meta adapters take their display name as a constructor argument
///      (`MetaBalanceAdapter._protocolName`), so — unlike the hardcoded adapters — their name is a *deployment-time*
///      value that appears nowhere in `src/`. Before this resolver, `04_DeployBalanceAdapters` read a free-text
///      `protocol` string out of each chain's JSON, which meant the same protocol's name was re-typed at ~30 call
///      sites across 7 chain files. That is a per-chain, per-call-site literal: two adapters of one protocol could
///      silently receive different names, and the same adapter could receive different names on different chains,
///      with nothing in the repo able to detect it.
///
///      Resolving from `ProtocolNames` instead makes the name a single per-protocol constant. Adapters sharing a
///      `ProtocolIds` protocol id resolve to the same string *by construction*, on every chain, and
///      `test/ProtocolNameConsistency.t.sol` asserts both that property and that the (now purely documentary)
///      `protocol` keys still in the chain configs agree with what actually gets deployed.
///
///      Keys are matched by prefix so the per-instance legacy keys (`CompoundV3_USDC`, `MorphoVault_kpkEURC_V1`,
///      `Fluid_fToken_GHO`, …) resolve too. Longer/more specific prefixes are tested first where two prefixes
///      overlap. An unknown key returns "" — callers decide whether that is fatal.
library ProtocolNameResolver {
    /// @notice Canonical protocol display name for a deploy-config adapter key. "" when the key is unknown.
    /// @param adapterKey The adapter key as it appears in `contracts-deployment-config/{balance,meta-balance}-adapters/<chainId>.json`.
    /// @return The `ProtocolNames` constant this adapter must report from `protocolName()`.
    function protocolNameFor(string memory adapterKey) internal pure returns (string memory) {
        // Aave V3 — lending instances, Safety Module and Umbrella are three products of ONE protocol.
        if (_startsWith(adapterKey, "AaveV3") || _startsWith(adapterKey, "AaveUmbrella")) return ProtocolNames.AAVE_V3;
        if (_startsWith(adapterKey, "SparkLend")) return ProtocolNames.SPARK;
        if (_startsWith(adapterKey, "Morpho")) return ProtocolNames.MORPHO;
        if (_startsWith(adapterKey, "Euler")) return ProtocolNames.EULER;
        if (_startsWith(adapterKey, "CompoundV3")) return ProtocolNames.COMPOUND_V3;
        if (_startsWith(adapterKey, "Fluid")) return ProtocolNames.FLUID;
        if (_startsWith(adapterKey, "Gearbox")) return ProtocolNames.GEARBOX_V3;
        if (_startsWith(adapterKey, "Cap")) return ProtocolNames.CAP;

        if (_startsWith(adapterKey, "BalancerV2")) return ProtocolNames.BALANCER_V2;
        if (_startsWith(adapterKey, "BalancerV3")) return ProtocolNames.BALANCER_V3;
        if (_startsWith(adapterKey, "Curve")) return ProtocolNames.CURVE;
        if (_startsWith(adapterKey, "Convex")) return ProtocolNames.CONVEX;
        if (_startsWith(adapterKey, "UniswapV2")) return ProtocolNames.UNISWAP_V2;
        if (_startsWith(adapterKey, "UniswapV3")) return ProtocolNames.UNISWAP_V3;
        if (_startsWith(adapterKey, "PancakeSwapV2")) return ProtocolNames.PANCAKESWAP_V2;
        if (_startsWith(adapterKey, "PancakeSwapV3")) return ProtocolNames.PANCAKESWAP_V3;

        // StakeWise V3 — the vaults meta-adapter and the exit-queue adapter share `ProtocolIds.STAKEWISE_V3`.
        if (_startsWith(adapterKey, "StakeWise")) return ProtocolNames.STAKEWISE_V3;
        if (_startsWith(adapterKey, "Lido")) return ProtocolNames.LIDO;
        if (_startsWith(adapterKey, "Kelp")) return ProtocolNames.KELP;
        if (_startsWith(adapterKey, "Stader")) return ProtocolNames.STADER;
        if (_startsWith(adapterKey, "EtherFi")) return ProtocolNames.ETHERFI;
        if (_startsWith(adapterKey, "Ethena")) return ProtocolNames.ETHENA;
        if (_startsWith(adapterKey, "NexusMutual")) return ProtocolNames.NEXUS_MUTUAL;

        if (_startsWith(adapterKey, "ERC20Default")) return ProtocolNames.WALLET;

        return "";
    }

    /// @dev ASCII prefix test. `prefix` is always a short compile-time literal here.
    function _startsWith(string memory value, string memory prefix) private pure returns (bool) {
        bytes memory v = bytes(value);
        bytes memory p = bytes(prefix);
        if (v.length < p.length) return false;
        for (uint256 i = 0; i < p.length; i++) {
            if (v[i] != p[i]) return false;
        }
        return true;
    }
}
