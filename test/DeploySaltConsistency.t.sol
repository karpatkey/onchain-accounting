// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";
import {DeploySalts} from "script/deploy/DeploySalts.sol";

/// @title DeploySaltConsistencyTest
/// @notice Guards the CREATE2-salt derivation that the deterministic placeholder/proxy/impl addresses depend on.
/// @dev The deploy layer derives each salt in two code styles that MUST agree, or the canonical proxy address
///      differs depending on which path deployed a chain:
///        - the forge scripts (01/01_2/02/02_2) call `ConfigReader.computeSalt(name, version)`;
///        - the on-chain atomic deployers compute `keccak256(abi.encodePacked(name, version))` inline.
///      Both now pull `version` from DeploySalts (single source of truth). This test asserts the two derivations
///      are byte-identical for every centralized salt — so if `computeSalt` ever changed (e.g. someone folded in
///      `block.chainid`, which would silently make the address chain-dependent), CI fails here.
contract DeploySaltConsistencyTest is Test {
    function _assertSaltDerivationAgrees(string memory name, uint256 version) internal pure {
        // `computeSalt` (scripts) must equal the inline form used by the atomic deployer contracts.
        assertEq(
            ConfigReader.computeSalt(name, version),
            keccak256(abi.encodePacked(name, version)),
            string.concat("salt derivation diverged for ", name)
        );
    }

    /// @notice Script-style and atomic-deployer-style salt derivation must match for every centralized salt.
    function test_saltDerivationsAgree() public pure {
        _assertSaltDerivationAgrees("ProxyPlaceholderImpl", DeploySalts.PLACEHOLDER_IMPL);
        _assertSaltDerivationAgrees("NAVCalculatorProxy", DeploySalts.NAV_PROXY);
        _assertSaltDerivationAgrees("BridgeEscrowProxy", DeploySalts.BRIDGE_PROXY);
        _assertSaltDerivationAgrees("NAVCalculatorImplementation", DeploySalts.NAV_IMPL);
    }

    /// @notice `computeSalt` must be chain-independent (the canonical addresses are the same on every chain).
    ///         It is `pure` today; this locks that in by deriving under two chain IDs and asserting equality.
    function test_saltIsChainIndependent() public {
        vm.chainId(1);
        bytes32 onMainnet = ConfigReader.computeSalt("NAVCalculatorProxy", DeploySalts.NAV_PROXY);
        vm.chainId(8453);
        bytes32 onBase = ConfigReader.computeSalt("NAVCalculatorProxy", DeploySalts.NAV_PROXY);
        assertEq(onMainnet, onBase, "proxy salt must not depend on chainid");
    }
}
