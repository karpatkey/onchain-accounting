// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {DeployAssetKindRegistry} from "script/deploy/08_DeployAssetKindRegistry.s.sol";
import {AssetKindRegistry} from "src/nav/AssetKindRegistry.sol";

/// @title AssetKindRegistryGuardsTest
/// @notice **Branch coverage for every guard `08_DeployAssetKindRegistry` declares — issue #253.** Each of the six
///         reverts is reached by driving the script's own `run()` with a tailored config fixture, and each is asserted
///         by SELECTOR AND ARGUMENTS, never by a bare `expectRevert`.
/// @dev **Why "through the script" is the whole point of this file.** #253 was opened because three of #241's late
///      defects lived in this one file and two of four guards written there had wrong failure paths — in both cases
///      because the branch was reasoned about and never executed. A test that calls an inner function containing the
///      same `require` would reproduce that mistake with a green tick: it proves the condition, not the reachability.
///      So every test here constructs the script, calls `setUp()`, and calls `run()`.
///
///      **`setUp()` is called deliberately, and omitting it silently disables two of the six.** `run()` reads the NAV
///      with the local `block.chainid` but reads the existing registry through `BaseDeployScript.readDeployedAddress`,
///      which keys on `currentChainId` — a field set only in `setUp()`. A harness that skips `setUp()` leaves it at
///      **0**, so the idempotency lookup reads `deployments/0.json`, which does not exist, `existing` is always
///      `address(0)`, and the entire `existing != address(0)` branch — {RecordedRegistryHasNoCode} and
///      {RegistryBoundToDifferentNav} — becomes unreachable. `forge script` always calls `setUp()`, so this is a
///      harness property, not a script defect; it is recorded because it is invisible and it silently halves this file.
///
///      **Fixture discipline, inherited from `AssetKindRegistryWiring.t.sol` and for the same reason.** `foundry.toml`
///      grants read-write over all of `script/`, so a mistyped chain id would overwrite a real chain's committed
///      config. Every path is asserted UNOCCUPIED before writing, and the literal id is the only thing separating a
///      fixture from production config.
///
///      **One fixture chain id PER TEST, not per contract.** `forge` reverts EVM state between tests but the
///      FILESYSTEM is shared, so tests writing the same path race: the first to finish deletes the config the others
///      are still reading. `AssetKindRegistryWiring` solved that by collapsing to a single `run()`; that is not
///      available here, because these six guards need six mutually exclusive config states. Distinct ids give the same
///      isolation without the collapse.
///
///      **Cleanup is failure-safe, and that is a deliberate departure from the inherited pattern.**
///      `AssetKindRegistryWiring.t.sol` documents debris as a known limit: with `vm.expectRevert`, a `run()` that
///      reverts with the WRONG error fails the test before cleanup, stranding fixture files that are untracked,
///      un-ignored and enough to break the clean-tree gate. That is not hypothetical — it happened while
///      mutation-testing this very file, where six deliberately-failing runs left eighteen fixture files behind and
///      the next run then failed on `must be unoccupied` rather than on anything real. So these tests call `run()`
///      through a low-level `call`, clean up UNCONDITIONALLY, and only then assert on the captured returndata.
///      Comparing full returndata is exactly as strict as `expectRevert` with encoded arguments — selector and
///      arguments both — while being impossible to strand.
///
///      **No `NAVCalculator` is deployed here, and that is not a shortcut.** Every one of these six branches is reached
///      before the script touches the NAV as a contract: three revert inside the config loop, one on the recorded
///      address being zero, and two on the recorded registry alone. `AssetKindRegistry`'s constructor rejects only
///      `address(0)`, so a registry can be bound to an arbitrary non-zero address to reach
///      {RegistryBoundToDifferentNav}. The happy path — which does need a real NAV, real libraries and a real proxy —
///      is covered by `AssetKindRegistryWiring.t.sol`; this file deliberately covers only what that one does not.
contract AssetKindRegistryGuardsTest is Test {
    /// @dev Distinct from `AssetKindConfigParsing` (987_654_321/322) and `AssetKindRegistryWiring` (987_654_331/332).
    uint256 internal constant CHAIN_ADDR_MISSING = 987_654_341;
    uint256 internal constant CHAIN_ADDR_ZERO = 987_654_342;
    uint256 internal constant CHAIN_KIND_INVALID = 987_654_343;
    uint256 internal constant CHAIN_NO_NAV = 987_654_344;
    uint256 internal constant CHAIN_REGISTRY_NO_CODE = 987_654_345;
    uint256 internal constant CHAIN_REGISTRY_WRONG_NAV = 987_654_346;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @dev Cast rather than checksummed literals: these are arbitrary non-zero markers, and the point is that they
    ///      are DIFFERENT from each other, not that they resemble real proxies.
    address internal constant NAV_A = address(uint160(0xA1));
    address internal constant NAV_B = address(uint160(0xB2));

    string internal root;

    function setUp() public {
        root = vm.projectRoot();
    }

    // ============================================================
    // fixture plumbing
    // ============================================================

    function _chainPath(uint256 id) internal view returns (string memory) {
        return string(abi.encodePacked(root, "/script/config/chains/", vm.toString(id), ".json"));
    }

    function _assetsPath(uint256 id) internal view returns (string memory) {
        return string(
            abi.encodePacked(root, "/script/config/nav-config/assets-and-price-feeds/", vm.toString(id), ".json")
        );
    }

    function _deploymentsPath(uint256 id) internal view returns (string memory) {
        return string(abi.encodePacked(root, "/script/config/deployments/", vm.toString(id), ".json"));
    }

    function _chainJson() internal view returns (string memory) {
        address a = address(this);
        return string(
            abi.encodePacked(
                '{"name":"AssetKindGuardFixture","rpc":"http://127.0.0.1:8545","explorer":"",',
                '"explorerApiKey":"","chainlinkSequencerFeed":"0x0000000000000000000000000000000000000000",',
                '"nativeTokenSymbol":"ETH","addresses":{"admin":"',
                vm.toString(a),
                '","manager":"',
                vm.toString(a),
                '","securityCouncil":"',
                vm.toString(a),
                '"}}'
            )
        );
    }

    /// @dev Writes the fixture set and points the script at it. Returns a constructed, `setUp()`-run script — see the
    ///      contract docstring for why `setUp()` is not optional.
    function _arm(uint256 id, string memory assetsJson, string memory deploymentsJson)
        internal
        returns (DeployAssetKindRegistry s)
    {
        assertFalse(vm.exists(_chainPath(id)), "fixture chain config must be unoccupied");
        assertFalse(vm.exists(_assetsPath(id)), "fixture assets config must be unoccupied");
        assertFalse(vm.exists(_deploymentsPath(id)), "fixture deployments record must be unoccupied");

        vm.writeFile(_chainPath(id), _chainJson());
        vm.writeFile(_assetsPath(id), assetsJson);
        vm.writeFile(_deploymentsPath(id), deploymentsJson);

        vm.chainId(id);
        s = new DeployAssetKindRegistry();
        s.setUp();
    }

    function _cleanup(uint256 id) internal {
        if (vm.exists(_chainPath(id))) vm.removeFile(_chainPath(id));
        if (vm.exists(_assetsPath(id))) vm.removeFile(_assetsPath(id));
        if (vm.exists(_deploymentsPath(id))) vm.removeFile(_deploymentsPath(id));
    }

    /// @dev Calls `run()`, cleans up UNCONDITIONALLY, then asserts. See the contract docstring for why the cleanup
    ///      cannot be allowed to sit behind an assertion. `expected` is the full ABI-encoded custom error, so this
    ///      checks the selector AND every argument — a bare "it reverted" would pass on an unrelated config failure,
    ///      which is precisely how a guard gets credited for a branch it never reached.
    function _runExpectingRevert(DeployAssetKindRegistry s, uint256 id, bytes memory expected, string memory what)
        internal
    {
        (bool ok, bytes memory ret) = address(s).call(abi.encodeCall(DeployAssetKindRegistry.run, ()));

        _cleanup(id);

        assertFalse(ok, string(abi.encodePacked(what, ": run() was expected to revert and did not")));
        assertEq(ret, expected, what);
    }

    // ============================================================
    // the six guards
    // ============================================================

    /// @dev `AssetAddressMissing` — a symbol present in config with no `address` key at all. Distinct from
    ///      {test_guard_assetAddressZero} on purpose: the script names them separately because they are different
    ///      config mistakes, and a test that conflated them would let either selector satisfy both.
    function test_guard_assetAddressMissing_whenSymbolHasNoAddressKey() public {
        uint256 id = CHAIN_ADDR_MISSING;
        DeployAssetKindRegistry s = _arm(id, '{"USDC":{"accrualKind":"None"}}', "{}");

        _runExpectingRevert(
            s,
            id,
            abi.encodeWithSelector(DeployAssetKindRegistry.AssetAddressMissing.selector, "USDC"),
            "AssetAddressMissing"
        );
    }

    /// @dev `AssetAddressZero` — the `address` key is PRESENT and parses to zero. Reaching this requires passing the
    ///      missing-key check first, which is what makes it a distinct branch rather than a rephrasing of it.
    function test_guard_assetAddressZero_whenAddressKeyIsPresentButZero() public {
        uint256 id = CHAIN_ADDR_ZERO;
        DeployAssetKindRegistry s = _arm(
            id,
            '{"USDC":{"address":"0x0000000000000000000000000000000000000000","accrualKind":"None"}}',
            "{}"
        );

        _runExpectingRevert(
            s, id, abi.encodeWithSelector(DeployAssetKindRegistry.AssetAddressZero.selector, "USDC"), "AssetAddressZero"
        );
    }

    /// @dev `AssetKindMissingOrInvalid` — a valid address but an out-of-vocabulary `accrualKind`. Asserts the FIELD
    ///      argument too (`"accrualKind"`), because that string is the only thing telling an operator which key to fix
    ///      and nothing else in the suite would notice if it changed.
    function test_guard_assetKindMissingOrInvalid_whenAccrualKindIsOutOfVocabulary() public {
        uint256 id = CHAIN_KIND_INVALID;
        DeployAssetKindRegistry s = _arm(
            id,
            string(abi.encodePacked('{"USDC":{"address":"', vm.toString(USDC), '","accrualKind":"Accruing"}}')),
            "{}"
        );

        _runExpectingRevert(
            s,
            id,
            abi.encodeWithSelector(DeployAssetKindRegistry.AssetKindMissingOrInvalid.selector, "USDC", "accrualKind"),
            "AssetKindMissingOrInvalid"
        );
    }

    /// @dev `NavCalculatorNotDeployed` — the deployment record carries no `NAVCalculatorProxy`. Reached only after the
    ///      whole config loop passes and after `vm.startBroadcast()`, so an empty asset set is used to get there
    ///      cleanly. Note this is the guard's real production shape: the registry derives ALL authority from the NAV
    ///      address, so constructing against `address(0)` would yield a registry nobody can write to.
    function test_guard_navCalculatorNotDeployed_whenRecordHasNoProxy() public {
        uint256 id = CHAIN_NO_NAV;
        DeployAssetKindRegistry s = _arm(id, "{}", "{}");

        _runExpectingRevert(
            s,
            id,
            abi.encodeWithSelector(DeployAssetKindRegistry.NavCalculatorNotDeployed.selector, id),
            "NavCalculatorNotDeployed"
        );
    }

    /// @dev `RecordedRegistryHasNoCode` — the record names an `AssetKindRegistry` with no code. This is the branch
    ///      #253 called out by name as exercised by nothing.
    ///
    ///      **This test is also what proves the code check runs BEFORE the `NAV()` read**, which the script documents
    ///      as load-bearing. If the order were reversed, `registry.NAV()` on a codeless address would revert with an
    ///      EMPTY reason in the calling frame and this `expectRevert` — which demands the selector AND both arguments —
    ///      would fail. So the ordering is asserted by consequence rather than by inspection.
    function test_guard_recordedRegistryHasNoCode_andProvesTheCodeCheckPrecedesTheNavRead() public {
        uint256 id = CHAIN_REGISTRY_NO_CODE;
        address codeless = address(0xDEAD);
        assertEq(codeless.code.length, 0, "fixture precondition: recorded registry must have no code");

        DeployAssetKindRegistry s = _arm(
            id,
            string(abi.encodePacked('{"USDC":{"address":"', vm.toString(USDC), '","accrualKind":"None"}}')),
            string(
                abi.encodePacked(
                    '{"NAVCalculatorProxy":"', vm.toString(NAV_A), '","AssetKindRegistry":"', vm.toString(codeless), '"}'
                )
            )
        );

        _runExpectingRevert(
            s,
            id,
            abi.encodeWithSelector(DeployAssetKindRegistry.RecordedRegistryHasNoCode.selector, codeless, id),
            "RecordedRegistryHasNoCode"
        );
    }

    /// @dev `RegistryBoundToDifferentNav` — a recorded registry that HAS code but whose immutable `NAV` is a different
    ///      proxy than the record's current `NAVCalculatorProxy`. This is the NAV-redeploy shape the script warns
    ///      about: the `AssetKindRegistry` key survives a NAV redeploy while `NAVCalculatorProxy` moves, and without
    ///      this guard the run completes GREEN while granting the new NAV's `MANAGER` to a registry that writes to the
    ///      old one.
    ///
    ///      Asserting all three arguments matters here: a guard that reported the right selector with the wrong pair
    ///      of addresses would send an operator to the wrong contract.
    function test_guard_registryBoundToDifferentNav_whenTheNavWasRedeployedUnderIt() public {
        uint256 id = CHAIN_REGISTRY_WRONG_NAV;

        // Bound to NAV_A; the record below says the current proxy is NAV_B.
        AssetKindRegistry stale = new AssetKindRegistry(NAV_A);
        assertGt(address(stale).code.length, 0, "fixture precondition: recorded registry must HAVE code");
        assertEq(address(stale.NAV()), NAV_A, "fixture precondition: registry must be bound to NAV_A");

        DeployAssetKindRegistry s = _arm(
            id,
            string(abi.encodePacked('{"USDC":{"address":"', vm.toString(USDC), '","accrualKind":"None"}}')),
            string(
                abi.encodePacked(
                    '{"NAVCalculatorProxy":"',
                    vm.toString(NAV_B),
                    '","AssetKindRegistry":"',
                    vm.toString(address(stale)),
                    '"}'
                )
            )
        );

        _runExpectingRevert(
            s,
            id,
            abi.encodeWithSelector(
                DeployAssetKindRegistry.RegistryBoundToDifferentNav.selector, address(stale), NAV_A, NAV_B
            ),
            "RegistryBoundToDifferentNav"
        );
    }

    // ============================================================
    // the harness property that makes two of the six reachable
    // ============================================================

    /// @dev **Pins the `setUp()` dependency described in the contract docstring, so it cannot regress silently.**
    ///      Without `setUp()`, `currentChainId` is 0, the idempotency lookup reads a non-existent
    ///      `deployments/0.json`, `existing` is `address(0)`, and the script takes the DEPLOY-FRESH branch instead of
    ///      the recorded-registry branch — so {RecordedRegistryHasNoCode} and {RegistryBoundToDifferentNav} are
    ///      unreachable and two tests above would quietly stop testing anything.
    ///
    ///      This asserts the mechanism directly: same fixture as the `no code` case, but `setUp()` is NOT called, and
    ///      the run gets PAST the registry guards to fail on something else entirely. `expectRevert` is deliberately
    ///      absent — the assertion is that the specific guard does NOT fire, which is shown by the call reverting with
    ///      a different payload.
    function test_harness_withoutSetUp_theRecordedRegistryBranchIsUnreachable() public {
        uint256 id = 987_654_347;
        address codeless = address(0xDEAD);

        assertFalse(vm.exists(_chainPath(id)), "fixture chain config must be unoccupied");
        assertFalse(vm.exists(_assetsPath(id)), "fixture assets config must be unoccupied");
        assertFalse(vm.exists(_deploymentsPath(id)), "fixture deployments record must be unoccupied");

        vm.writeFile(_chainPath(id), _chainJson());
        vm.writeFile(_assetsPath(id), "{}");
        vm.writeFile(
            _deploymentsPath(id),
            string(
                abi.encodePacked(
                    '{"NAVCalculatorProxy":"', vm.toString(NAV_A), '","AssetKindRegistry":"', vm.toString(codeless), '"}'
                )
            )
        );

        vm.chainId(id);
        DeployAssetKindRegistry s = new DeployAssetKindRegistry();
        // NOTE: no s.setUp() — that is the point of this test.

        (bool ok, bytes memory ret) = address(s).call(abi.encodeCall(DeployAssetKindRegistry.run, ()));

        _cleanup(id);

        assertFalse(ok, "run() should still fail without setUp, but for an unrelated reason");
        bytes4 noCode = DeployAssetKindRegistry.RecordedRegistryHasNoCode.selector;
        bytes4 got = ret.length >= 4 ? bytes4(ret) : bytes4(0);
        assertTrue(
            got != noCode,
            "without setUp() the recorded-registry branch must be unreachable; if this fires, the harness note is stale"
        );
    }
}
