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

    /// @dev These assertions are only meaningful under a profile that actually carries foundry.toml's
    ///      `libraries` pins. `dev` and `lite` deliberately clear that array (forge auto-deploys and
    ///      auto-links the two libraries instead) and `lite` also drops the optimizer, so their library
    ///      bytecode CANNOT match the pins — three red tests that invite a pin regeneration which would
    ///      break every default-profile build and deploy.
    ///
    ///      Deliberately an ALLOWLIST of pin-bearing profiles rather than a denylist of pin-clearing
    ///      ones: an unrecognised profile skips (safe, loses coverage) instead of going red (unsafe,
    ///      invites the repin). `default` is CI's unit job; `slow` overrides only threads/gas/memory and
    ///      inherits the pins, so both must assert. Add any future pin-bearing profile here.
    ///
    ///      Note this cannot key on the observable condition — "is NAVCalculator linked to the pin?" —
    ///      because that is exactly what test_navCalculator_creationCodeLinkedAgainstPins asserts, so
    ///      such a check would make that test skip itself in precisely the case it exists to catch.
    ///
    ///      The freshness assertion carries this too, and deliberately: it exists to make the three pin
    ///      assertions trustworthy, so when they skip it has nothing left to underwrite. Gating it also
    ///      keeps it away from `lite`, whose `extra_output = []` / `ast = false` build is not a tree the
    ///      pins are ever derived from.
    /// @dev The artifact files the pin assertions read. Named so the freshness check and the
    ///      `vm.getCode` binding provably refer to the SAME file rather than to a path literal and
    ///      a bare contract name that only look related.
    string internal constant PRICE_FEED_LIB_ARTIFACT = "out/PriceFeedLib.sol/PriceFeedLib.json";
    string internal constant NAV_REGISTRY_LIB_ARTIFACT = "out/NAVRegistryLib.sol/NAVRegistryLib.json";
    string internal constant NAV_CALCULATOR_ARTIFACT = "out/NAVCalculator.sol/NAVCalculator.json";

    /// @dev The pin-affecting build inputs, mirrored from `[profile.default]` in foundry.toml.
    ///      Asserted against what each artifact RECORDS, because identical sources under a
    ///      different compiler or optimizer setting produce different bytecode and would otherwise
    ///      satisfy every source-hash check in this file. `onlyPinnedProfile` keeps these off
    ///      `[profile.lite]`, which is deliberately not bytecode-compatible.
    string internal constant EXPECTED_COMPILER = "0.8.34+commit.80d5c536";
    string internal constant EXPECTED_EVM_VERSION = "cancun";
    uint256 internal constant EXPECTED_OPTIMIZER_RUNS = 200;
    string internal constant EXPECTED_BYTECODE_HASH = "none";

    modifier onlyPinnedProfile() {
        bytes32 profile = keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("default"))));
        bool pinBearing = profile == keccak256("default") || profile == keccak256("slow") || profile == keccak256("");
        vm.skip(!pinBearing);
        _;
    }

    /// @notice Every pin check below is only as good as the artifact it reads. This asserts the artifact was built
    ///         from THIS source tree, so a stale `out/` cannot produce a stale pin reading that passes.
    /// @dev    The gap this closes, and why a timestamp check would not close it.
    ///
    ///         The exposure is CI's job split, not any one config flag: the Unit job does not build. It downloads
    ///         the Build job's artifacts, and those come off a repo-wide cache keyed only by repository, which has
    ///         been observed serving stale bytecode. Everything this file asserts about pins is then a statement
    ///         about that download rather than about this tree — stale artifact in, stale address out, test green.
    ///
    ///         The pin assertions now read `vm.getCode("X")` at RUNTIME rather than embedding
    ///         `type(X).creationCode` at COMPILE time, and this note used to explain why the embedded form did not
    ///         help. It is worth keeping the reasoning, because it is what makes the runtime read SAFE rather than
    ///         merely cheaper: embedding never closed the gap, it only moved it. Under a downloaded `out/`, THIS
    ///         contract was itself one of the stale artifacts and its embedded constant was whatever the cache
    ///         served — so the compile-time form was already reading the cache, just by a longer path, and it hid
    ///         the fact that `NAVCalculator`'s artifact was never freshness-checked at all.
    ///
    ///         Reading explicitly is strictly better: every value the assertions consume is now a named artifact,
    ///         and `test_pinnedLibraryArtifactsWereBuiltFromThisTree` covers all three of them. Note this is done
    ///         WITHOUT setting `dynamic_test_linking` — that flag was removed for a measured reason (see
    ///         foundry.toml) and its global side effect of routing `new` in test sources through `vm.deployCode` is
    ///         not wanted. Writing the read out by hand in these three places gets the benefit without the flag.
    ///
    ///         **The clean whole-program build is no longer required PER PR** — it existed to make the embedded
    ///         constant trustworthy, at ~993 s on the critical path of every run, and the freshness assertion
    ///         below does that work by content-hash for free. It has NOT gone away: `.github/workflows/
    ///         pin-canary.yml` runs the same clean build and these same assertions weekly and on every push to
    ///         main that can move a pin. That canary is the standing falsifier for the assumption this file now
    ///         rests on — that a contract's creation code is independent of compilation SCOPE. If it ever goes
    ///         red on an unchanged source closure, restore the per-PR job; do not repin.
    ///
    ///         If a future edit reintroduces an embedded `type(X).creationCode` here, it must also reintroduce
    ///         the per-PR build — they are one mechanism.
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
    ///
    ///         Declared residual gap: this interrogates the two LIBRARY artifacts, so it detects the whole-directory
    ///         staleness that a cache restore actually produces. A hypothetically PARTIAL `out/` — both libraries
    ///         fresh, this test contract's own artifact stale — would still pass while the compile-time-embedded
    ///         constant is stale. Not worth a third assertion: no known mechanism restores `out/` per-file.
    /// @dev Covers EVERY artifact the pin assertions below read — that coupling is the whole scheme. The three
    ///      assertions now read creation code out of `out/` via `vm.getCode` instead of embedding
    ///      `type(X).creationCode` at compile time, so a stale artifact would otherwise let them attest bytecode
    ///      that is not this tree's. `NAVCalculator` is listed for exactly that reason: it was NOT covered while
    ///      its creation code was embedded, and adding the read without adding it here would have opened the gap
    ///      this file's own header warns about.
    function test_pinnedLibraryArtifactsWereBuiltFromThisTree() public onlyPinnedProfile {
        _assertArtifactBuiltFromTree(PRICE_FEED_LIB_ARTIFACT, "PriceFeedLib");
        _assertArtifactBuiltFromTree(NAV_REGISTRY_LIB_ARTIFACT, "NAVRegistryLib");
        _assertArtifactBuiltFromTree(NAV_CALCULATOR_ARTIFACT, "NAVCalculator");
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

        // M4 — SOURCES ARE NOT ENOUGH. Bytecode is a function of the source closure AND the
        // compiler build AND the pin-affecting settings. An artifact compiled from byte-identical
        // sources under a different solc, evm_version, optimizer setting or `[libraries]` mapping
        // passes every assertion above with different bytecode. The clean-build job used to pin
        // all of these by construction (fresh checkout + this foundry.toml + FOUNDRY_VERSION);
        // with it gone they must be asserted, and the artifact already records every one of them.
        assertEq(
            vm.parseJsonString(json, ".metadata.compiler.version"),
            EXPECTED_COMPILER,
            string.concat(label, ": artifact was built by a different solc than this tree pins")
        );
        assertTrue(
            vm.parseJsonBool(json, ".metadata.settings.viaIR"),
            string.concat(label, ": artifact was not built with via_ir")
        );
        assertEq(
            vm.parseJsonString(json, ".metadata.settings.evmVersion"),
            EXPECTED_EVM_VERSION,
            string.concat(label, ": artifact was built for a different EVM version")
        );
        assertTrue(
            vm.parseJsonBool(json, ".metadata.settings.optimizer.enabled"),
            string.concat(label, ": artifact was built with the optimizer disabled")
        );
        assertEq(
            vm.parseJsonUint(json, ".metadata.settings.optimizer.runs"),
            EXPECTED_OPTIMIZER_RUNS,
            string.concat(label, ": artifact was built with different optimizer runs")
        );
        // `bytecode_hash` is pin-affecting and foundry.toml says so explicitly: the default ("ipfs")
        // appends a metadata hash of the whole import graph to the creation code, which moves the
        // CREATE2 address. An artifact matching on every field above but built under a different
        // metadata mode has different creation bytecode and would have passed this attestation.
        assertEq(
            vm.parseJsonString(json, ".metadata.settings.metadata.bytecodeHash"),
            EXPECTED_BYTECODE_HASH,
            string.concat(label, ": artifact was built with a different bytecode_hash mode")
        );
    }

    /// @dev M5 — bind the NAME the pin assertions read to the PATH this freshness check attested.
    ///      `vm.getCode("X")` resolves by bare contract name over an `out/` that observably
    ///      accumulates other branches' artifacts, while `_assertArtifactBuiltFromTree` attests a
    ///      specific file. Without this, a leaked artifact defining a same-named contract at a
    ///      different source path could supply the bytes the pin is derived from while the
    ///      freshness check passes on the canonical file. Returns the creation code, having proved
    ///      it is the checked artifact's own.
    ///
    ///      HONEST STATUS: defence in depth against a scenario I could not reproduce. Planting
    ///      `out/ZzLeaked.sol/PriceFeedLib.json` with different bytecode did NOT divert
    ///      `vm.getCode("PriceFeedLib")` — forge still resolved the canonical artifact — so the
    ///      leak path is not demonstrated to be reachable, and this assertion has never fired on a
    ///      real leak. It is kept because the resolution rule for an ambiguous bare name is not
    ///      contracted anywhere, `out/` demonstrably accumulates other branches' artifacts, and
    ///      the cost is one keccak. The assertion itself is not vacuous: pointing it at a
    ///      different artifact makes it fail loudly (verified).
    function _verifiedCode(string memory name, string memory artifactPath) internal view returns (bytes memory) {
        bytes memory byName = vm.getCode(name);
        bytes memory byPath = vm.parseJsonBytes(vm.readFile(artifactPath), ".bytecode.object");
        assertEq(
            keccak256(byName),
            keccak256(byPath),
            string.concat(
                name,
                ": vm.getCode resolved to different bytes than the freshness-checked artifact at ",
                artifactPath,
                " - suspect a same-named artifact leaked into out/ from another branch"
            )
        );
        return byName;
    }

    function test_priceFeedLib_pinMatchesCurrentBytecode() public onlyPinnedProfile {
        bytes32 salt = ConfigReader.computeSalt("PriceFeedLib", 1);
        address computed = vm.computeCreate2Address(
            salt, keccak256(_verifiedCode("PriceFeedLib", PRICE_FEED_LIB_ARTIFACT)), CANONICAL_CREATE2_DEPLOYER
        );
        assertEq(computed, LibraryPins.PRICE_FEED_LIB, "PriceFeedLib pin drift: regenerate LibraryPins + foundry.toml");
    }

    function test_navRegistryLib_pinMatchesCurrentBytecode() public onlyPinnedProfile {
        bytes32 salt = ConfigReader.computeSalt("NavRegistryLib", 1);
        address computed = vm.computeCreate2Address(
            salt, keccak256(_verifiedCode("NAVRegistryLib", NAV_REGISTRY_LIB_ARTIFACT)), CANONICAL_CREATE2_DEPLOYER
        );
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
        bytes memory code = _verifiedCode("NAVCalculator", NAV_CALCULATOR_ARTIFACT);
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
