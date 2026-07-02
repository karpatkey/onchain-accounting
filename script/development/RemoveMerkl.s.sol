// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {MANAGER} from "src/constants.sol";

error DeployerMissingManagerRole(address deployer);
error MerklNotRegistered(address merkl);
error UnexpectedPreState(uint256 actualCount, uint256 expectedCount);
error MerklStillRegistered(address merkl);
error UnsupportedChain(uint256 chainId);

/// @title RemoveMerkl
/// @notice ONE-OFF removal of the removed-family `MerklRewardsAssisted` adapter from a chain's NAV (PR #141 dropped the
///         Merkl adapter). Chain-parameterized by `block.chainid`: resolves the Merkl address + pristine adapter-count
///         baseline for Optimism (10), Arbitrum (42161) and Base (8453) — mainnet (1) + Gnosis (100) removed Merkl in
///         their own migrations. Broadcast by the deployer EOA `0xAa5A…4F72` (MANAGER on every chain's NAV at the same
///         CREATE2 address). Guards abort a re-run / drift. This does NOT touch deployments/*.json — the caller runs the
///         `jq del(.balanceAdapters.MerklRewardsAssisted)` afterward for the JSON record.
/// @dev    Per chain, dry-run first then broadcast (same command, add --account/--broadcast):
///           forge script script/development/RemoveMerkl.s.sol --rpc-url $OP_URL       --sender 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72
///           forge script script/development/RemoveMerkl.s.sol --rpc-url $ARBITRUM_URL --sender 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72
///           forge script script/development/RemoveMerkl.s.sol --rpc-url $BASE_URL     --sender 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72
contract RemoveMerkl is Script {
    INAVCalculator internal constant NAV = INAVCalculator(0x42aC265991163Af2b0B9E59a222d31d201E39f91);
    address internal constant DEPLOYER = 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72;

    /// @dev Resolves (merklAdapter, pristineAdapterCount) for the connected chain. Baselines captured 2026-07-02.
    function _chainParams() internal view returns (address merkl, uint256 expectedCount) {
        uint256 id = block.chainid;
        if (id == 10) return (0x12133cA6532cda38510Ae3a6242e36011aD18efB, 4); // Optimism
        if (id == 42_161) return (0xdC1a1d15163aaad6B8f3094ee03b25AF915781f6, 9); // Arbitrum
        if (id == 8453) return (0x9342c17c7fc7FE5BE167a0342745BE6f3e6Efef8, 8); // Base
        revert UnsupportedChain(id);
    }

    function run() external {
        (address merkl, uint256 expectedCount) = _chainParams();

        if (!IAccessControl(address(NAV)).hasRole(MANAGER, DEPLOYER)) revert DeployerMissingManagerRole(DEPLOYER);
        if (!NAV.isAdapterRegistered(merkl)) revert MerklNotRegistered(merkl); // already removed / wrong addr
        uint256 liveCount = NAV.getAdapterCount();
        if (liveCount != expectedCount) revert UnexpectedPreState(liveCount, expectedCount);

        vm.startBroadcast();
        address[] memory toRemove = new address[](1);
        toRemove[0] = merkl;
        NAV.removeBalanceAdapters(toRemove);
        vm.stopBroadcast();

        if (NAV.isAdapterRegistered(merkl)) revert MerklStillRegistered(merkl);
        uint256 finalCount = NAV.getAdapterCount();
        if (finalCount != expectedCount - 1) revert UnexpectedPreState(finalCount, expectedCount - 1);

        console2.log("chainId:", block.chainid);
        console2.log("Removed MerklRewardsAssisted:", merkl);
        console2.log("adapter count:", finalCount);
    }
}
