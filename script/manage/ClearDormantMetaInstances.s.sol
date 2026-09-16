// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";

/// @title ClearDormantMetaInstances
/// @author KPK
/// @notice Clears the dormant meta-instance set left on the superseded PolygonStakingMeta predecessor
///         `0x59039882…`, in the one order that never double-counts.
/// @dev **The residue, and why it still exists after the fix.** This PR makes BOTH removal paths clear
///      `metaInstances`, so no NEW residue can be created — but the clearing lives in the NAVCalculator
///      implementation, and the residue below was created by the PRE-UPGRADE implementation that is still
///      live on the proxy this script targets. The structural fix is present; it is simply not retroactive,
///      which is what this script is for. `removeBalanceAdapter` did not clear `metaInstances`, and
///      the 2026-08-26 swap predated the `removeMetaInstances` step now in `SwapMetaAdapter`. So the
///      deregistered predecessor still advertises validator 192. It is inert while deregistered — but
///      `addMetaBalanceAdapter` APPENDS and accepts an empty list, so a single re-registration of that
///      superseded address revives the coordinate alongside the live adapter and NAV sums both:
///      +$11,375.92 on ACCOUNT_11, with no health flag, because both readings are well-formed.
///
///      **Why five transactions.** The set cannot be cleared directly: `removeMetaInstances` reverts
///      `InvalidBalanceAdapter` for an unregistered adapter, so the adapter must be registered first —
///      which is the dangerous act. The ordering below is the only one where the two adapters are never
///      both reporting. Every intermediate state is SAFE, but they are not all under-reports: after step 2
///      the position is served by the SUPERSEDED predecessor as sole reporter (the fork test asserts exactly
///      that — "residue must be the ONLY reporter"), which is a correct value from a deregistered adapter
///      rather than a missing one. Never two reporters at once is the invariant; "always missing" is not,
///      which is the direction this repo prefers everywhere. Registering the predecessor FIRST would
///      double-count, and that is revert-probed in `DormantInstanceCleanup.fork.t.sol`.
///
///      Rehearsed against mainnet state before broadcasting: the sequence never exceeds one reporter,
///      and the naive ordering was confirmed to produce two.
///
///      Run with `--slow` so the five transactions land in order.
contract ClearDormantMetaInstances is Script {
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address constant LIVE = 0x5144b5855e753Fa6E2BBac95Cc880A73e1eec187;
    address constant RESIDUE = 0x590398827f2a2709e80DF9BD5C7D02BD51FC51fD;
    bytes32 constant V192 = bytes32(uint256(uint160(0x97997023aAB1D6b9760538Eb621bF10cfCD84868)));

    error WrongChain(uint256 chainId);
    error NotManager(address who);
    error NothingToDo();
    error PreconditionLiveNotRegistered();
    error PreconditionResidueRegistered();
    error DoubleCount(uint256 reporters);

    function _one(bytes32 v) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = v;
    }

    function _addrs(address x) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = x;
    }

    function _reporters() internal view returns (uint256 n) {
        address[2] memory c = [LIVE, RESIDUE];
        for (uint256 i; i < 2; ++i) {
            if (!NAVCalculator(NAV).isAdapterRegistered(c[i])) continue;
            bytes32[] memory inst = NAVCalculator(NAV).getMetaInstances(c[i]);
            for (uint256 j; j < inst.length; ++j) {
                if (inst[j] == V192) ++n;
            }
        }
    }

    function run() external {
        if (block.chainid != 1) revert WrongChain(block.chainid);
        address sender = ConfigReader.readChainConfig(vm, 1).manager;
        if (!NAVCalculator(NAV).hasRole(keccak256("MANAGER"), sender)) revert NotManager(sender);

        if (!NAVCalculator(NAV).isAdapterRegistered(LIVE)) revert PreconditionLiveNotRegistered();
        if (NAVCalculator(NAV).isAdapterRegistered(RESIDUE)) revert PreconditionResidueRegistered();
        if (NAVCalculator(NAV).getMetaInstances(RESIDUE).length == 0) revert NothingToDo();

        console2.log("=== clearing dormant meta-instance set ===");
        console2.log("residue      :", RESIDUE);
        console2.log("live         :", LIVE);
        console2.log("reporters now:", _reporters());

        vm.startBroadcast();
        NAVCalculator(NAV).removeMetaInstances(LIVE, _one(V192)); // 1
        NAVCalculator(NAV).addMetaBalanceAdapter(RESIDUE, new bytes32[](0)); // 2
        NAVCalculator(NAV).removeMetaInstances(RESIDUE, _one(V192)); // 3
        NAVCalculator(NAV).removeBalanceAdapters(_addrs(RESIDUE)); // 4
        NAVCalculator(NAV).addMetaInstances(LIVE, _one(V192)); // 5
        vm.stopBroadcast();

        uint256 n = _reporters();
        if (n != 1) revert DoubleCount(n);
        require(NAVCalculator(NAV).getMetaInstances(RESIDUE).length == 0, "residue set not cleared");
        require(NAVCalculator(NAV).getMetaInstances(LIVE).length == 1, "live lost its instance");
        require(NAVCalculator(NAV).getMetaInstances(LIVE)[0] == V192, "live holds the wrong coordinate");
        require(!NAVCalculator(NAV).isAdapterRegistered(RESIDUE), "residue still registered");
        console2.log("done. reporters:", n, "residue set cleared, live restored");
    }
}
