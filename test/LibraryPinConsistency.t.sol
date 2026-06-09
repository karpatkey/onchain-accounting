// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {PriceFeedLib} from "src/prices/PriceFeedLib.sol";
import {NavRegistryLib} from "src/nav/NavRegistryLib.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";

/// @title LibraryPinConsistencyTest
/// @notice Guards the deterministic external-library addresses pinned in foundry.toml (`libraries`)
///         and mirrored in 01_2_DeployNAVImplementation.s.sol (LINKED_* constants).
/// @dev    NAVCalculator's bytecode is linked against these fixed addresses; a fresh deploy
///         CREATE2-deploys each library and it MUST land at the linked address, or initialize()
///         DELEGATECALLs empty code and reverts. The library bytecode — and hence its CREATE2 address
///         — is held stable by `solc_version` + `bytecode_hash = "none"` in foundry.toml. If a
///         compiler bump, a real library code change, or a build-config change shifts the bytecode,
///         these assertions fail in CI: regenerate the pins (this file + foundry.toml + the 01_2
///         LINKED_* constants) for the new bytecode. The salt mirrors ConfigReader.computeSalt(name, 1)
///         = keccak256(abi.encodePacked(name, uint256(1))).
contract LibraryPinConsistencyTest is Test {
    address internal constant CANONICAL_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Keep in lockstep with foundry.toml `libraries` and 01_2 LINKED_*.
    address internal constant PINNED_PRICE_FEED_LIB = 0x6F0C6f68728Ec474FecB4DE7cdd72E28C2D42715;
    address internal constant PINNED_NAV_REGISTRY_LIB = 0x7BFBA7637aC35D6796a46258EccE9866AFB14Ca9;

    function test_priceFeedLib_pinMatchesCurrentBytecode() public pure {
        bytes32 salt = keccak256(abi.encodePacked("PriceFeedLib", uint256(1)));
        address computed =
            vm.computeCreate2Address(salt, keccak256(type(PriceFeedLib).creationCode), CANONICAL_CREATE2_DEPLOYER);
        assertEq(computed, PINNED_PRICE_FEED_LIB, "PriceFeedLib pin drift: regenerate foundry.toml + 01_2 + this test");
    }

    function test_navRegistryLib_pinMatchesCurrentBytecode() public pure {
        bytes32 salt = keccak256(abi.encodePacked("NavRegistryLib", uint256(1)));
        address computed =
            vm.computeCreate2Address(salt, keccak256(type(NavRegistryLib).creationCode), CANONICAL_CREATE2_DEPLOYER);
        assertEq(
            computed, PINNED_NAV_REGISTRY_LIB, "NavRegistryLib pin drift: regenerate foundry.toml + 01_2 + this test"
        );
    }

    /// @notice End-to-end guard: NAVCalculator's linked creation bytecode must embed BOTH pinned library
    ///         addresses. forge links the `libraries` mapping (foundry.toml) into `creationCode`, so this
    ///         catches a foundry.toml pin edit that drifts from the constants above — which the per-library
    ///         CREATE2 checks cannot, since they compare the computed address only against this file's
    ///         constants — and confirms NAVCalculator is actually wired to the pinned libraries.
    function test_navCalculator_creationCodeLinkedAgainstPins() public pure {
        bytes memory code = type(NAVCalculator).creationCode;
        assertTrue(
            _contains(code, PINNED_PRICE_FEED_LIB),
            "NAVCalculator not linked against pinned PriceFeedLib (foundry.toml `libraries` drift?)"
        );
        assertTrue(
            _contains(code, PINNED_NAV_REGISTRY_LIB),
            "NAVCalculator not linked against pinned NavRegistryLib (foundry.toml `libraries` drift?)"
        );
    }

    /// @dev True if the 20-byte `needle` address appears anywhere in `haystack`.
    function _contains(bytes memory haystack, address needle) private pure returns (bool) {
        if (haystack.length < 20) return false;
        bytes20 n = bytes20(needle);
        for (uint256 i = 0; i + 20 <= haystack.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < 20; j++) {
                if (haystack[i + j] != n[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}
