// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {DeploySalts} from "./DeploySalts.sol";
import {console2} from "forge-std/console2.sol";

import {
    AaveV3InstancesMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/AaveV3InstancesMetaBalanceAdapter.sol";
import {
    AaveV3SafetyModuleBalanceAdapter
} from "../../src/balances/BalanceAdapters/AaveV3SafetyModuleBalanceAdapter.sol";
import {
    BalancerV3PoolsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/balancer/BalancerV3PoolsMetaBalanceAdapter.sol";
import {
    CurvePoolsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/curve/CurvePoolsMetaBalanceAdapter.sol";
import {EulerVaultsMetaBalanceAdapter} from "../../src/balances/MetaBalanceAdapters/EulerVaultsMetaBalanceAdapter.sol";
import {
    MorphoMarketsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/MorphoMarketsMetaBalanceAdapter.sol";
import {
    UniswapV3PoolsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolsMetaBalanceAdapter.sol";
import {FluidVaultsMetaBalanceAdapter} from "../../src/balances/MetaBalanceAdapters/FluidVaultsMetaBalanceAdapter.sol";
import {
    FluidFTokensMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/FluidFTokensMetaBalanceAdapter.sol";
import {
    GearboxV3MarketsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/GearboxV3MarketsMetaBalanceAdapter.sol";
import {
    MorphoVaultsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/MorphoVaultsMetaBalanceAdapter.sol";
import {
    SymbioticVaultsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/SymbioticVaultsMetaBalanceAdapter.sol";

interface INavAdmin {
    function getAllAdapters() external view returns (address[] memory);
    function getMetaInstances(address adapter) external view returns (bytes32[] memory);
    function addBalanceAdapters(address[] calldata adapters) external;
    function addMetaBalanceAdapter(address adapter, bytes32[] calldata instances) external;
    function removeBalanceAdapters(address[] calldata adapters) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title 10_MigrateAdaptersToCreate2
/// @author kpk
/// @notice Re-deploys balance adapters at their CREATE2 addresses and hands each one's registration (and
///         instance set) over from the CREATE-deployed original.
/// @dev **Which adapters, and what each gets.** Two groups, with DIFFERENT guarantees — the entry table below
///      carries both, and conflating them is how a doc ends up promising more than the code delivers.
///
///      *NAV-only* (`paramName == ""`): the constructor takes nothing but the NAV proxy, which is itself
///      CREATE2-identical fleet-wide, so the init-code hash is identical everywhere and one salt yields ONE
///      address on every chain.
///
///      *Protocol-address* (`paramName` set — `UniswapV3PoolsMeta`, `MorphoMarketsMeta`, `FluidVaultsMeta`):
///      the constructor also takes one chain-specific protocol address, read here from the same deploy config
///      `04` uses. The address is a pure function of that argument — a SHARED address across the chains that
///      share it, a different but still deterministic one where they do not. Weaker than the NAV-only
///      guarantee, and documented as such (`☆` rather than `★` in `DEPLOYED_ADDRESSES.md`).
///
///      Adapters taking MORE than one chain-specific address (`CompoundV3CometsMeta`'s rewards + reward token,
///      `StakeWiseV3VaultsMeta`, `BalancerV3GaugesMeta`) stay on plain CREATE: their arguments genuinely differ
///      per chain, so CREATE2 could not give them a shared address and there is nothing to gain.
///
///      **The handover order is load-bearing: remove FIRST, then re-register.** The reverse leaves the old and
///      new adapter both registered at once and, because they report the SAME positions, NAV DOUBLE-COUNTS them
///      — an over-report. Remove-first instead leaves a window in which those positions are absent: an
///      under-report, which is the direction this codebase requires whenever it must pick one. The window is
///      the gap between two transactions in the same broadcast.
///
///      **The real hazard is not the address, it is the instance set.** A meta-adapter's queried instances live
///      on the NAV keyed by adapter ADDRESS, so they do NOT follow the adapter across a redeploy. Re-register
///      with an empty or partial set and NAV silently drops those positions while every address check still
///      passes. This script reads the set BEFORE removing and re-seeds it atomically via
///      `addMetaBalanceAdapter`, and asserts the count round-trips. `test/nav/fork/AdapterSwapParity.fork.t.sol`
///      pins the same property against real mainnet state.
///
///      Idempotent: an adapter already at its CREATE2 address and already registered is skipped.
contract MigrateAdaptersToCreate2 is BaseDeployScript {
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    bytes32 internal constant MANAGER = keccak256("MANAGER");

    error NotManager(address who);
    error InstanceSetLost(address adapter, uint256 expected, uint256 got);

    struct Entry {
        string key; // deployment-record key under .balanceAdapters
        string saltName; // contract name, as used for the salt
        uint256 version;
        bytes creationCode;
        // Name of the ONE chain-specific protocol address this adapter takes ahead of the NAV, as it appears in
        // `contracts-deployment-config/*/<chainId>.json`. Empty for NAV-only adapters. Read inside the loop and
        // only for adapters actually recorded on this chain — reading it up front would revert on every chain
        // that does not deploy the adapter at all.
        string paramName;
    }

    function run() public override {
        uint256 chainId = block.chainid;
        address nav = ConfigReader.readDeployedAddress(vm, chainId, "NAVCalculatorProxy");
        INavAdmin navAdmin = INavAdmin(nav);

        // The address that will actually sign, NOT `msg.sender`. Under `forge script` the two need not be
        // equal, so checking `msg.sender` can fail a valid migration before broadcasting — or, worse, pass
        // one whose real signer lacks the role, leaving the revert to land mid-sequence with the old
        // adapter already removed. The (since removed) one-off `MigrateAssistedAdapters.s.sol` documented the
        // same distinction and pinned the intended broadcaster the same way.
        //
        // Resolved from the chain config rather than hard-coded so a chain with a different manager is not
        // silently checked against mainnet's.
        address sender = ConfigReader.readChainConfig(vm, chainId).manager;
        if (!navAdmin.hasRole(MANAGER, sender)) revert NotManager(sender);

        Entry[] memory entries = _entries();

        for (uint256 i; i < entries.length; ++i) {
            Entry memory e = entries[i];
            address old = _recorded(chainId, e.key);
            if (old == address(0)) continue; // not deployed on this chain

            // NAV-only adapters encode just the NAV; the rest take (protocolAddress, nav) in that order.
            bytes memory ctorArgs = bytes(e.paramName).length == 0
                ? abi.encode(nav)
                : abi.encode(
                    vm.parseAddress(ConfigReader.readAdapterParam(vm, chainId, "balanceAdapters", e.key, e.paramName)),
                    nav
                );

            bytes32 salt = generateSalt(e.saltName, e.version);
            bytes memory initCode = abi.encodePacked(e.creationCode, ctorArgs);
            address predicted = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, salt, initCode);

            // Skip only when the CREATE2 address is BOTH the recorded one AND actually registered on the NAV.
            //
            // ⚠️ The record alone is not sufficient evidence, and this is not hypothetical. `writeAdapterAddress`
            // is ungated, and `forge script` always runs a simulation phase — so a NO-BROADCAST run of this very
            // script writes all nine CREATE2 addresses into the record while nothing reaches the chain. Trusting
            // the record here would then make the real run skip every adapter and report success against a
            // production NAV that was never touched. Registration is checked on-chain because that is the fact
            // the record is only a claim about.
            if (predicted == old && _isRegistered(navAdmin, predicted)) {
                console2.log("[SKIP] already migrated and registered:", e.key, predicted);
                continue;
            }
            if (old == predicted) {
                // Record says migrated, chain disagrees — the signature of a no-broadcast run, whose
                // simulation writes the record through the ungated `writeAdapterAddress` while nothing
                // reaches the chain.
                //
                // Recovery matches the predecessor by CODEHASH, which needs the twin to exist, so the
                // deploy has to happen first. An earlier version looked it up before deploying and always
                // read `codehash == 0`, so every adapter was skipped and the run reported success against
                // an untouched NAV. Deploying first is safe: CREATE2 at an occupied address is a no-op.
                if (predicted.code.length == 0) {
                    vm.startBroadcast();
                    (bool deployed,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
                    vm.stopBroadcast();
                    require(deployed, "CREATE2 adapter deploy failed");
                }
                old = _registeredPredecessor(navAdmin, predicted);
                if (old == address(0)) {
                    console2.log("[WARN] record claims migrated but nothing registered:", e.key);
                    continue;
                }
            }

            // Read the instance set BEFORE the removal wipes it.
            bytes32[] memory instances = navAdmin.getMetaInstances(old);

            vm.startBroadcast();

            if (predicted.code.length == 0) {
                (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
                require(ok, "CREATE2 adapter deploy failed");
            }

            address[] memory one = new address[](1);
            one[0] = old;
            navAdmin.removeBalanceAdapters(one);

            if (instances.length > 0) {
                navAdmin.addMetaBalanceAdapter(predicted, instances);
            } else {
                address[] memory add = new address[](1);
                add[0] = predicted;
                navAdmin.addBalanceAdapters(add);
            }

            vm.stopBroadcast();

            uint256 got = navAdmin.getMetaInstances(predicted).length;
            if (got != instances.length) revert InstanceSetLost(predicted, instances.length, got);

            ConfigReader.writeAdapterAddress(vm, chainId, "balanceAdapters", e.key, predicted);
            console2.log("[OK] migrated:", e.key, predicted);
            console2.log("     instances carried:", instances.length);
        }
    }

    /// @dev Zero when the adapter is not deployed on this chain — the caller skips those.

    /// @notice True when `adapter` is in the NAV's live registered set.
    function _isRegistered(INavAdmin navAdmin, address adapter) internal view returns (bool) {
        address[] memory all = navAdmin.getAllAdapters();
        for (uint256 i; i < all.length; ++i) {
            if (all[i] == adapter) return true;
        }
        return false;
    }

    /// @notice Finds the still-registered adapter that shares `twin`'s runtime code — i.e. the CREATE-deployed
    ///         predecessor this migration is meant to replace.
    /// @dev Used only to recover from a deployment record that was poisoned by a simulation. Matching on
    ///      `codehash` is exact: these adapters are immutable and pin the NAV in an immutable that lives in the
    ///      runtime code, so an identical codehash means an identical adapter bound to the same NAV.
    function _registeredPredecessor(INavAdmin navAdmin, address twin) internal view returns (address) {
        bytes32 target = twin.codehash;
        if (target == bytes32(0)) return address(0);
        address[] memory all = navAdmin.getAllAdapters();
        for (uint256 i; i < all.length; ++i) {
            if (all[i] != twin && all[i].codehash == target) return all[i];
        }
        return address(0);
    }

    function _recorded(uint256 chainId, string memory key) internal view returns (address) {
        return ConfigReader.readDeployedAdapterAddress(vm, chainId, "balanceAdapters", key);
    }

    function _entries() internal pure returns (Entry[] memory e) {
        e = new Entry[](12);
        e[0] = Entry(
            "AaveV3InstancesMeta",
            "AaveV3InstancesMetaBalanceAdapter",
            DeploySalts.AAVE_V3_INSTANCES_META,
            type(AaveV3InstancesMetaBalanceAdapter).creationCode,
            ""
        );
        e[1] = Entry(
            "AaveV3SafetyModule",
            "AaveV3SafetyModuleBalanceAdapter",
            DeploySalts.AAVE_V3_SAFETY_MODULE,
            type(AaveV3SafetyModuleBalanceAdapter).creationCode,
            ""
        );
        e[2] = Entry(
            "BalancerV3PoolsMeta",
            "BalancerV3PoolsMetaBalanceAdapter",
            DeploySalts.BALANCER_V3_POOLS_META,
            type(BalancerV3PoolsMetaBalanceAdapter).creationCode,
            ""
        );
        e[3] = Entry(
            "CurvePoolsMeta",
            "CurvePoolsMetaBalanceAdapter",
            DeploySalts.CURVE_POOLS_META,
            type(CurvePoolsMetaBalanceAdapter).creationCode,
            ""
        );
        e[4] = Entry(
            "EulerVaultsMeta",
            "EulerVaultsMetaBalanceAdapter",
            DeploySalts.EULER_VAULTS_META,
            type(EulerVaultsMetaBalanceAdapter).creationCode,
            ""
        );
        e[5] = Entry(
            "FluidFTokensMeta",
            "FluidFTokensMetaBalanceAdapter",
            DeploySalts.FLUID_FTOKENS_META,
            type(FluidFTokensMetaBalanceAdapter).creationCode,
            ""
        );
        e[6] = Entry(
            "GearboxV3MarketsMeta",
            "GearboxV3MarketsMetaBalanceAdapter",
            DeploySalts.GEARBOX_V3_MARKETS_META,
            type(GearboxV3MarketsMetaBalanceAdapter).creationCode,
            ""
        );
        e[7] = Entry(
            "MorphoVaultsMeta",
            "MorphoVaultsMetaBalanceAdapter",
            DeploySalts.MORPHO_VAULTS_META,
            type(MorphoVaultsMetaBalanceAdapter).creationCode,
            ""
        );
        e[8] = Entry(
            "SymbioticVaultsMeta",
            "SymbioticVaultsMetaBalanceAdapter",
            DeploySalts.SYMBIOTIC_VAULTS_META,
            type(SymbioticVaultsMetaBalanceAdapter).creationCode,
            ""
        );
        // Below: adapters taking ONE chain-specific protocol address. Same migration mechanics, weaker address
        // guarantee — they collapse to a single address only across the chains where that protocol address is
        // the same (see `DeploySalts`). On the chains where it differs the CREATE2 address differs too, which is
        // correct, not a failure: the adapter must bind to the protocol deployment that chain actually has.
        e[9] = Entry(
            "UniswapV3PoolsMeta",
            "UniswapV3PoolsMetaBalanceAdapter",
            DeploySalts.UNISWAP_V3_POOLS_META,
            type(UniswapV3PoolsMetaBalanceAdapter).creationCode,
            "positionManager"
        );
        e[10] = Entry(
            "MorphoMarketsMeta",
            "MorphoMarketsMetaBalanceAdapter",
            DeploySalts.MORPHO_MARKETS_META,
            type(MorphoMarketsMetaBalanceAdapter).creationCode,
            "morpho"
        );
        e[11] = Entry(
            "FluidVaultsMeta",
            "FluidVaultsMetaBalanceAdapter",
            DeploySalts.FLUID_VAULTS_META,
            type(FluidVaultsMetaBalanceAdapter).creationCode,
            "vaultResolver"
        );
    }
}
