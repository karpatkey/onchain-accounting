// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {PriceFeedLib} from "src/prices/PriceFeedLib.sol";
import {NAVRegistryLib} from "src/nav/NAVRegistryLib.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {LibraryPins} from "script/utils/LibraryPins.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";

/// @title LibraryPinConsistencyTest
/// @notice Guards the deterministic external-library addresses pinned in foundry.toml (`libraries`) and held in
///         LibraryPins (the single Solidity source of truth, shared with 01_2_DeployNAVImplementation).
/// @dev    NAVCalculator's bytecode is linked against these fixed addresses; a fresh deploy
///         CREATE2-deploys each library and it MUST land at the linked address, or initialize()
///         DELEGATECALLs empty code and reverts. The library bytecode — and hence its CREATE2 address
///         — is held stable by `solc_version` + `bytecode_hash = "none"` in foundry.toml. If a
///         compiler bump, a real library code change, or a build-config change shifts the bytecode,
///         these assertions fail in CI: regenerate the pins (LibraryPins + foundry.toml) for the new
///         bytecode. The salt is computed via ConfigReader.computeSalt — the same routine the deploy path
///         uses (BaseDeployScript.generateSalt → ConfigReader.computeSalt) — and the CREATE2 deployer is the
///         canonical factory address both sides hard-code, so this test can never compute an address the
///         deploy path wouldn't.
contract LibraryPinConsistencyTest is Test {
    address internal constant CANONICAL_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev The `dev` and `lite` profiles deliberately clear foundry.toml's `libraries` array (forge
    ///      auto-deploys + auto-links the two libraries instead), and `lite` also drops the optimizer.
    ///      Both therefore produce library bytecode that CANNOT match the pins, so these assertions are
    ///      meaningless there: skip rather than hand a local `lite` run three red tests, which invites a
    ///      pin regeneration that would break every default-profile build and deploy.
    modifier onlyPinnedProfile() {
        bytes32 profile = keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("default"))));
        vm.skip(profile == keccak256("dev") || profile == keccak256("lite"));
        _;
    }

    function test_priceFeedLib_pinMatchesCurrentBytecode() public onlyPinnedProfile {
        bytes32 salt = ConfigReader.computeSalt("PriceFeedLib", 1);
        address computed =
            vm.computeCreate2Address(salt, keccak256(type(PriceFeedLib).creationCode), CANONICAL_CREATE2_DEPLOYER);
        assertEq(computed, LibraryPins.PRICE_FEED_LIB, "PriceFeedLib pin drift: regenerate LibraryPins + foundry.toml");
    }

    function test_navRegistryLib_pinMatchesCurrentBytecode() public onlyPinnedProfile {
        bytes32 salt = ConfigReader.computeSalt("NavRegistryLib", 1);
        address computed =
            vm.computeCreate2Address(salt, keccak256(type(NAVRegistryLib).creationCode), CANONICAL_CREATE2_DEPLOYER);
        assertEq(
            computed, LibraryPins.NAV_REGISTRY_LIB, "NAVRegistryLib pin drift: regenerate LibraryPins + foundry.toml"
        );
    }

    /// @notice End-to-end guard: NAVCalculator's linked creation bytecode must embed BOTH pinned library
    ///         addresses. forge links the `libraries` mapping (foundry.toml) into `creationCode`, so this
    ///         catches a foundry.toml pin edit that drifts from LibraryPins — which the per-library CREATE2
    ///         checks cannot, since they compare the computed address only against LibraryPins — and confirms
    ///         NAVCalculator is actually wired to the pinned libraries.
    function test_navCalculator_creationCodeLinkedAgainstPins() public onlyPinnedProfile {
        bytes memory code = type(NAVCalculator).creationCode;
        assertTrue(
            LibraryPins.contains(code, LibraryPins.PRICE_FEED_LIB),
            "NAVCalculator not linked against pinned PriceFeedLib (foundry.toml `libraries` drift?)"
        );
        assertTrue(
            LibraryPins.contains(code, LibraryPins.NAV_REGISTRY_LIB),
            "NAVCalculator not linked against pinned NAVRegistryLib (foundry.toml `libraries` drift?)"
        );
    }
}
