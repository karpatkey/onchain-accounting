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

    /// @notice Every pin check above is only as good as the artifact it reads. This asserts the artifact was built
    ///         from THIS source tree, so a stale `out/` cannot produce a stale pin reading that passes.
    /// @dev    The gap this closes, and why a timestamp check would not close it.
    ///
    ///         With `dynamic_test_linking` enabled, `type(X).creationCode` compiles to a call to forge's VM address
    ///         — it becomes `vm.getCode`, a read of the artifact from disk at RUNTIME. So the pin value is not "what
    ///         this compilation unit would produce", it is *whatever artifact happens to be on disk when the test
    ///         runs*. The two expressions do not diverge under the flag; they are the same read. What can separate
    ///         them from the truth is STALENESS, and staleness alone.
    ///
    ///         That is not hypothetical. CI's Unit job does not build — it downloads the Build job's artifacts, and
    ///         those come off a repo-wide cache keyed only by repository, which has been observed serving stale
    ///         bytecode. Stale artifact in, stale address out, test green. It mechanically explains the
    ///         `0xeA694009` PriceFeedLib value seen on the branch that sets the flag, against `0x8b7e4fA9` at
    ///         build scope.
    ///
    ///         **Content-hash, not mtime, and that choice is load-bearing.** Artifacts restored from a cache are
    ///         WRITTEN at restore time, so their mtimes are newer than the checkout that produced the sources — a
    ///         stale artifact looks freshly built by every timestamp comparison. Solc records a keccak256 per input
    ///         source in the artifact's own metadata; re-hashing those files answers "was this compiled from the
    ///         tree I am looking at" with no reference to clocks.
    ///
    ///         Verified against real data while writing this: a local `out/` two hours behind main mismatched on
    ///         exactly three sources — `PriceFeedLib.sol`, `IPrices.sol`, `INAVCalculator.sol` — which is precisely
    ///         PriceFeedLib's compilation closure. The mismatch set is the closure, computed rather than inferred.
    ///
    ///         Deliberately checks BOTH pinned libraries and ALL of their recorded sources, `lib/` included: a
    ///         submodule bump changes library bytecode and therefore the pin just as a `src/` edit does, and this
    ///         repo has a recorded history of `foundry.lock` disagreeing with its gitlinks.
    function test_pinnedLibraryArtifactsWereBuiltFromThisTree() public view {
        _assertArtifactBuiltFromTree("out/PriceFeedLib.sol/PriceFeedLib.json", "PriceFeedLib");
        _assertArtifactBuiltFromTree("out/NAVRegistryLib.sol/NAVRegistryLib.json", "NAVRegistryLib");
    }

    /// @dev Re-hashes every source the artifact records, and requires at least one — an artifact with an empty or
    ///      unreadable `metadata.sources` would otherwise pass this vacuously, which is the same
    ///      counted-but-unchecked shape that hid a defect in the refresh harness earlier today.
    function _assertArtifactBuiltFromTree(string memory artifactPath, string memory label) internal view {
        string memory json = vm.readFile(artifactPath);
        string[] memory sources = vm.parseJsonKeys(json, ".metadata.sources");
        assertGt(
            sources.length,
            0,
            string.concat(label, ": artifact records no sources - cannot establish freshness, so refuse to pass")
        );

        for (uint256 i = 0; i < sources.length; i++) {
            bytes32 recorded =
                vm.parseJsonBytes32(json, string.concat('.metadata.sources.["', sources[i], '"].keccak256'));
            bytes32 onDisk = keccak256(bytes(vm.readFile(sources[i])));
            assertEq(
                onDisk,
                recorded,
                string.concat(
                    label,
                    ": STALE ARTIFACT. out/ was not built from this tree - ",
                    sources[i],
                    " on disk does not hash to what the artifact records. Every pin assertion in this file, in "
                    "01/01_2 and in UpgradeNAVCalculator is reading that artifact, so none of them is currently "
                    "reasoning about deployable bytecode. Run `forge clean && forge build`; in CI, suspect the "
                    "Build-job artifact cache."
                )
            );
        }
    }

    function test_priceFeedLib_pinMatchesCurrentBytecode() public pure {
        bytes32 salt = ConfigReader.computeSalt("PriceFeedLib", 1);
        address computed =
            vm.computeCreate2Address(salt, keccak256(type(PriceFeedLib).creationCode), CANONICAL_CREATE2_DEPLOYER);
        assertEq(computed, LibraryPins.PRICE_FEED_LIB, "PriceFeedLib pin drift: regenerate LibraryPins + foundry.toml");
    }

    function test_navRegistryLib_pinMatchesCurrentBytecode() public pure {
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
    function test_navCalculator_creationCodeLinkedAgainstPins() public pure {
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
