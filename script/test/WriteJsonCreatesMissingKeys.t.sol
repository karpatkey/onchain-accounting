// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

/// @title WriteJsonCreatesMissingKeys
/// @author KPK
/// @notice Pins a FORGE CHEATCODE BEHAVIOUR that this repo's documentation depends on: `vm.writeJson`
///         CREATES a JSON key that does not exist, rather than requiring the pointer to pre-exist.
/// @dev WHY THIS TEST EXISTS, and why it is not incidental coverage.
///
///      Four places in this repo used to assert the opposite — that `ConfigReader.writeAdapterAddress`
///      needs the key to pre-exist, and therefore that a new adapter must have a blank key seeded into
///      `script/config/deployments/<chainId>.json` before `04` can record it. That claim was never
///      tested. It was written up authoritatively, believed on provenance, and inherited into a PR
///      (#295) that seeded two blank keys and, to stop the `PositionLabelsProbeCoverage` tripwire
///      reading a reservation as a registration, permanently downgraded that tripwire from
///      key-presence to address-presence — giving up the only guard that catches a new non-meta
///      adapter shipping without a `positionLabels` decision, in exchange for a precondition that does
///      not exist.
///
///      It was measured false on 2026-08-12 against the pinned forge (see FOUNDRY_VERSION in
///      .github/workflows/foundry.yml). The corrections that followed are prose, and prose about
///      external tool behaviour rots silently: bump forge, get the old behaviour back, and every
///      corrected sentence becomes false again with nothing failing — which is the exact shape of the
///      original defect. THIS TEST IS THE CORRECTION; the comments are descriptions of it.
///
///      Referenced from: `script/deploy/preflight/reset_deployment_records.py`,
///      `script/deploy/preflight/verify_step.py`, `script/deploy/REDEPLOY_RUNBOOK.md` §1.1.
///
///      If this test fails after a forge upgrade, do NOT delete it and do NOT re-seed keys
///      defensively: the three documents above are now wrong and must be corrected together with it.
contract WriteJsonCreatesMissingKeysTest is Test {
    /// @dev Written under `out/` — a build directory, gitignored and already `read-write` in
    ///      foundry.toml — so the test never touches a tracked file and leaves no untracked debris.
    ///      Deliberately NOT `script/config/deployments/<id>.json`: exercising the real record would
    ///      risk mutating the only place deployed addresses live.
    ///
    ///      ONE FILE PER TEST, via `_scratch(name)`. An earlier version shared a single path across all
    ///      four tests and three of them failed on each other's writes rather than on the behaviour
    ///      under test — a shared mutable fixture makes a test suite report interference as if it were
    ///      a finding.
    function _scratch(string memory name) internal returns (string memory path) {
        path = string.concat("out/writejson-pin-", name, ".json");
        vm.writeFile(path, FIXTURE);
    }

    /// @dev Mirrors the shape of a real deployment record: a `.balanceAdapters` map with populated
    ///      neighbours, plus a sibling section, so collateral damage is observable.
    ///      Written COMPACT and on one line deliberately: an earlier version built this from adjacent
    ///      multi-line literals and produced malformed JSON, so all four tests failed on the fixture
    ///      rather than on the behaviour under test. A fixture that can be wrong is a test that can
    ///      lie about its subject.
    string internal constant FIXTURE = '{"NAVCalculatorProxy":"0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d",'
        '"balanceAdapters":{"ERC20Default":"0x41967559D0a20Ad102F6e27b7723b1963390aD75",'
        '"Cap":"0x5B50A5FF1C80A178bB8da9fdfF077FBc3DD4e543"},'
        '"customPriceFeeds":{"wstETH":"0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa"}}';

    address internal constant NEW_ADDR = 0x1111111111111111111111111111111111111111;
    address internal constant TOP_ADDR = 0x2222222222222222222222222222222222222222;
    address internal constant NESTED_ADDR = 0x3333333333333333333333333333333333333333;

    /// @notice THE LOAD-BEARING ONE: the exact call shape of `ConfigReader.writeAdapterAddress`.
    /// @dev `writeAdapterAddress` builds `.<section>.<name>` and hands it to `vm.writeJson`, so a
    ///      brand-new adapter's key does not need to be seeded first — `04` records it unaided.
    function test_writeJson_createsAMissingNestedKey_soNewAdaptersNeedNoSeededKey() public {
        string memory f = _scratch("nested");
        string memory pointer = ".balanceAdapters.BrandNewAdapterThatDoesNotExist";
        assertFalse(vm.keyExists(vm.readFile(f), pointer), "fixture already had the key");

        vm.writeJson(vm.toString(NEW_ADDR), f, pointer);

        string memory json = vm.readFile(f);
        assertTrue(vm.keyExists(json, pointer), "vm.writeJson did NOT create the missing key");
        assertEq(vm.parseJsonAddress(json, pointer), NEW_ADDR, "created key holds the wrong value");
    }

    /// @notice A missing TOP-LEVEL key — the `AssetKindRegistry` shape that `CREATE_IF_ABSENT` covers.
    /// @dev Presence of that key is required by `verify_step.step_record_cleared`, which is a READ-path
    ///      requirement. It is NOT required for the write, which is what this asserts.
    function test_writeJson_createsAMissingTopLevelKey() public {
        string memory f = _scratch("toplevel");
        string memory pointer = ".SomeTopLevelKeyThatDoesNotExist";
        assertFalse(vm.keyExists(vm.readFile(f), pointer), "fixture already had the key");

        vm.writeJson(vm.toString(TOP_ADDR), f, pointer);

        string memory json = vm.readFile(f);
        assertTrue(vm.keyExists(json, pointer), "vm.writeJson did NOT create the missing top-level key");
        assertEq(vm.parseJsonAddress(json, pointer), TOP_ADDR, "created key holds the wrong value");
    }

    /// @notice A missing INTERMEDIATE OBJECT — the whole parent is created, not just the leaf.
    function test_writeJson_createsAMissingIntermediateObject() public {
        string memory f = _scratch("intermediate");
        string memory pointer = ".sectionThatDoesNotExist.Leaf";
        assertFalse(vm.keyExists(vm.readFile(f), ".sectionThatDoesNotExist"), "fixture had it");

        vm.writeJson(vm.toString(NESTED_ADDR), f, pointer);

        string memory json = vm.readFile(f);
        assertTrue(vm.keyExists(json, pointer), "vm.writeJson did NOT create the missing parent object");
        assertEq(vm.parseJsonAddress(json, pointer), NESTED_ADDR, "created key holds the wrong value");
    }

    /// @notice KEY ORDER IS LOAD-BEARING AND WAS NOT PINNED. The docstring in
    ///         `reset_deployment_records.py` says "Key order is preserved, so the diff stays
    ///         readable", and the deep copy at `:123` relies on it. Without this, a forge upgrade that
    ///         began REORDERING keys on write would leave every assertion above passing while that
    ///         prose became false and a 24-chain deployment-record diff became unreviewable.
    /// @dev    That is the same silent-rot shape this whole file exists to prevent, reproduced inside
    ///         the file. Recorded rather than quietly fixed: a guard written by whoever understands the
    ///         hazard tends to encode their model of it, including the incomplete part.
    ///
    ///         Asserted cheaply — the RELATIVE ORDER of the pre-existing keys in the raw file, and that
    ///         the first key is still first. Not a full ordering model; enough to fail if forge starts
    ///         reordering.
    function test_creatingAKeyPreservesTheOrderOfExistingKeys() public {
        string memory f = _scratch("order");
        vm.writeJson(vm.toString(NEW_ADDR), f, ".balanceAdapters.BrandNewAdapterThatDoesNotExist");
        string memory json = vm.readFile(f);

        int256 proxy = _indexOf(json, "NAVCalculatorProxy");
        int256 adapters = _indexOf(json, "balanceAdapters");
        int256 erc20 = _indexOf(json, "ERC20Default");
        int256 cap = _indexOf(json, "Cap\"");
        int256 feeds = _indexOf(json, "customPriceFeeds");

        assertGt(proxy, int256(-1), "NAVCalculatorProxy vanished");
        assertLt(proxy, adapters, "top-level order changed: proxy no longer precedes balanceAdapters");
        assertLt(adapters, feeds, "top-level order changed: balanceAdapters no longer precedes feeds");
        assertLt(erc20, cap, "order WITHIN balanceAdapters changed: ERC20Default no longer precedes Cap");
        assertLt(cap, feeds, "a balanceAdapters entry escaped its section");
    }

    /// @dev Byte index of `needle` in `haystack`, or -1. Solidity has no native indexOf.
    function _indexOf(string memory haystack, string memory needle) internal pure returns (int256) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return -1;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool ok = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return int256(i);
        }
        return -1;
    }

    /// @notice "It works" and "it works without collateral damage" are different answers, and the
    ///         second is half of what made this behaviour usable. Every pre-existing key must survive
    ///         a creating write with its value intact, including a sibling section.
    function test_creatingAKeyLeavesEveryOtherKeyIntact() public {
        string memory f = _scratch("intact");
        vm.writeJson(vm.toString(NEW_ADDR), f, ".balanceAdapters.BrandNewAdapterThatDoesNotExist");
        string memory json = vm.readFile(f);

        assertEq(
            vm.parseJsonAddress(json, ".balanceAdapters.ERC20Default"),
            0x41967559D0a20Ad102F6e27b7723b1963390aD75,
            "a neighbour in the written section was altered"
        );
        assertEq(
            vm.parseJsonAddress(json, ".balanceAdapters.Cap"),
            0x5B50A5FF1C80A178bB8da9fdfF077FBc3DD4e543,
            "a neighbour in the written section was altered"
        );
        assertEq(
            vm.parseJsonAddress(json, ".NAVCalculatorProxy"),
            0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d,
            "a top-level key outside the written section was altered"
        );
        assertEq(
            vm.parseJsonAddress(json, ".customPriceFeeds.wstETH"),
            0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa,
            "a SIBLING SECTION was altered by a write into balanceAdapters"
        );
    }
}
