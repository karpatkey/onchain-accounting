// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DeployAssetKindRegistry} from "script/deploy/08_DeployAssetKindRegistry.s.sol";
import {AssetKindRegistry} from "src/nav/AssetKindRegistry.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";
import {LibraryPins} from "script/utils/LibraryPins.sol";
import {AccrualKind} from "src/utils/AssetKind.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

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
///      **Two tests demonstrate the HARM, not merely the revert — and the distinction is the point of this file.**
///      A test that reaches a guard and asserts the error proves the guard FIRES. It does not prove the guard
///      PREVENTS anything: if the fixture is too poor to get past the guard's line, the run would have aborted anyway
///      and the test would fail for an incidental reason. Two of these six had exactly that weakness, so they now run
///      against a REAL `NAVCalculator` and assert the post-state the guard exists to protect:
///        - {AssetKindMissingOrInvalid} — the harm is that the asset would be SILENTLY classified `AccrualKind.None`,
///          which `ConfigReader` is asserted to return for an unrecognised string, so the misclassification is shown
///          to be real rather than argued. The test then asserts nothing was wired.
///        - {RegistryBoundToDifferentNav} — the harm is a run that completes GREEN while granting the NEW NAV's
///          `MANAGER` to a registry that writes to the OLD one. The test asserts that grant did NOT happen.
///      The other four are left asserting the revert, deliberately; see the note on diagnostic guards below.
///
///      **Three of the six are DIAGNOSTIC, not load-bearing, and dressing them up would hide that.** Mutation testing
///      (see the PR that added this file) showed that deleting {AssetAddressMissing}, {AssetAddressZero} or
///      {NavCalculatorNotDeployed} does not change the OUTCOME — the run still aborts. It changes the DIAGNOSIS: a
///      `vm.parseAddress` cheatcode error, or an anonymous `InvalidArguments()` from the registry constructor,
///      instead of an error naming the offending config row. That matches their documented intent, and asserting the
///      revert identity is therefore the correct and complete test for them. Adding post-state assertions to those
///      three would imply they prevent an outcome they do not.
///
///      **No `NAVCalculator` is deployed for the other four, and that is not a shortcut.** Those branches are reached
///      before the script touches the NAV as a contract: {AssetAddressMissing} and {AssetAddressZero} revert inside
///      the config loop, {NavCalculatorNotDeployed} on the recorded address being zero, and {RecordedRegistryHasNoCode}
///      on the recorded registry alone — for which a codeless marker address is not merely sufficient but required.
///      The happy path — which also needs a real NAV, real libraries and a real proxy — is covered by
///      `AssetKindRegistryWiring.t.sol`; this file deliberately covers only what that one does not.
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

    /// @dev `vm.startBroadcast()` with no argument executes subsequent calls as forge's default sender, so THAT is
    ///      the address the script acts as — not this test contract. It must therefore hold the NAV roles `08` uses.
    ///      Same constant, and same reason, as `AssetKindRegistryWiring.t.sol`.
    address internal constant BROADCASTER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

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
        return
            string(
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

    /// @dev Deploys a REAL `NAVCalculator` behind a UUPS proxy, with {BROADCASTER} holding `DEFAULT_ADMIN` and
    ///      `MANAGER`. Needed only by the two harm-demonstrating tests: `08` grants a role on this NAV and points it
    ///      at the registry, so a codeless marker address cannot show whether either actually happened.
    ///
    ///      The `vm.etch` calls are PROVISIONING, not pinning: `NAVCalculator` is pre-linked against two libraries at
    ///      the deterministic CREATE2 addresses in `foundry.toml [libraries]`, and a bare test EVM has no code there,
    ///      so `initialize` would DELEGATECALL into nothing. No pin value is read, written or asserted.
    function _deployRealNav() internal returns (NAVCalculator navProxy) {
        vm.etch(LibraryPins.PRICE_FEED_LIB, vm.deployCode("PriceFeedLib.sol:PriceFeedLib").code);
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, vm.deployCode("NAVRegistryLib.sol:NAVRegistryLib").code);

        address impl = address(new NAVCalculator());
        navProxy = NAVCalculator(
            UnsafeUpgrades.deployUUPSProxy(
                impl, abi.encodeCall(NAVCalculator.initialize, (BROADCASTER, address(0), "ETH"))
            )
        );
        vm.prank(BROADCASTER);
        navProxy.grantRole(MANAGER, BROADCASTER);
    }

    /// @dev Calls `run()`, cleans up UNCONDITIONALLY, then asserts. See the contract docstring for why the cleanup
    ///      cannot be allowed to sit behind an assertion. `expected` is the full ABI-encoded custom error, so this
    ///      checks the selector AND every argument — a bare "it reverted" would pass on an unrelated config failure,
    ///      which is precisely how a guard gets credited for a branch it never reached.
    function _runExpectingRevert(DeployAssetKindRegistry s, uint256 id, bytes memory expected, string memory what)
        internal
    {
        (bool ok, bytes memory ret) = _runCapturing(s, id);

        assertFalse(ok, string(abi.encodePacked(what, ": run() was expected to revert and did not")));
        assertEq(ret, expected, what);
    }

    /// @dev As {_runExpectingRevert}, but hands the outcome back instead of asserting on it. The two harm-
    ///      demonstrating tests use this so they can assert the POST-STATE **first** and the revert identity second.
    ///      Order matters: if the guard is deleted the run completes, and a leading "it did not revert" assertion
    ///      would fail before the harm assertions ever execute — leaving the test failing for a bookkeeping reason
    ///      rather than naming the damage. Asserting the state first means a deleted guard fails with
    ///      "the NEW NAV must NOT have granted MANAGER…", which is the finding, not the symptom.
    function _runCapturing(DeployAssetKindRegistry s, uint256 id) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(s).call(abi.encodeCall(DeployAssetKindRegistry.run, ()));
        _cleanup(id);
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
        DeployAssetKindRegistry s =
            _arm(id, '{"USDC":{"address":"0x0000000000000000000000000000000000000000","accrualKind":"None"}}', "{}");

        _runExpectingRevert(
            s, id, abi.encodeWithSelector(DeployAssetKindRegistry.AssetAddressZero.selector, "USDC"), "AssetAddressZero"
        );
    }

    /// @dev `AssetKindMissingOrInvalid` — a valid address but an out-of-vocabulary `accrualKind`. Asserts the FIELD
    ///      argument too (`"accrualKind"`), because that string is the only thing telling an operator which key to fix
    ///      and nothing else in the suite would notice if it changed.
    function test_guard_assetKindMissingOrInvalid_preventsSilentClassificationAsNone() public {
        uint256 id = CHAIN_KIND_INVALID;
        NAVCalculator nav = _deployRealNav();

        DeployAssetKindRegistry s = _arm(
            id,
            string(abi.encodePacked('{"USDC":{"address":"', vm.toString(USDC), '","accrualKind":"Accruing"}}')),
            string(abi.encodePacked('{"NAVCalculatorProxy":"', vm.toString(address(nav)), '"}'))
        );

        // THE HARM, shown rather than argued: the parser's fallback for an unrecognised string is `None` — which is
        // also a REAL classification (USDC, WETH are legitimately `None`). So without the guard the bad row is not
        // dropped or defaulted-and-flagged; it is written as a value indistinguishable from a correct one.
        (AccrualKind fallbackKind, bool valid) = ConfigReader.readAssetAccrualKind(vm, id, "USDC");
        assertFalse(valid, "fixture precondition: 'Accruing' must be out of vocabulary");
        assertEq(
            uint256(fallbackKind),
            uint256(AccrualKind.None),
            "the value that would be silently written without this guard is AccrualKind.None"
        );

        (bool ok, bytes memory ret) = _runCapturing(s, id);

        // THE CONSEQUENCE, asserted BEFORE the revert identity so a deleted guard fails here and names the damage:
        // the deploy did not proceed, so nothing was classified and nothing was wired. Delete the guard and the
        // script deploys the registry, points the NAV at it and writes USDC as `None`.
        assertEq(
            address(nav.assetKindRegistry()),
            address(0),
            "guard must abort BEFORE any registry is deployed, wired or asked to classify USDC as None"
        );

        assertFalse(ok, "AssetKindMissingOrInvalid: run() was expected to revert and did not");
        assertEq(
            ret,
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
                    '{"NAVCalculatorProxy":"',
                    vm.toString(NAV_A),
                    '","AssetKindRegistry":"',
                    vm.toString(codeless),
                    '"}'
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
    function test_guard_registryBoundToDifferentNav_preventsGrantingTheNewNavsManagerToAStaleRegistry() public {
        uint256 id = CHAIN_REGISTRY_WRONG_NAV;

        // Two REAL NAVs: the one the registry was built against, and the one a redeploy has since put in the record.
        NAVCalculator oldNav = _deployRealNav();
        NAVCalculator newNav = _deployRealNav();
        assertTrue(address(oldNav) != address(newNav), "fixture precondition: the two NAVs must differ");

        AssetKindRegistry stale = new AssetKindRegistry(address(oldNav));
        assertEq(address(stale.NAV()), address(oldNav), "fixture precondition: registry is bound to the OLD NAV");

        DeployAssetKindRegistry s = _arm(
            id,
            string(abi.encodePacked('{"USDC":{"address":"', vm.toString(USDC), '","accrualKind":"None"}}')),
            string(
                abi.encodePacked(
                    '{"NAVCalculatorProxy":"',
                    vm.toString(address(newNav)),
                    '","AssetKindRegistry":"',
                    vm.toString(address(stale)),
                    '"}'
                )
            )
        );

        (bool ok, bytes memory ret) = _runCapturing(s, id);

        // THE CONSEQUENCE, and this is the dangerous one, asserted BEFORE the revert identity: without the guard the
        // run completes GREEN — `setAssetKinds` gates on the OLD NAV's roles, so it succeeds — while the NEW NAV has
        // handed `MANAGER` to a registry that writes somewhere else. Authority pointed at the wrong contract, with a
        // zero exit code. These two assertions are what fail if the guard is deleted.
        assertFalse(
            newNav.hasRole(MANAGER, address(stale)),
            "the NEW NAV must NOT have granted MANAGER to a registry bound to the OLD NAV"
        );
        assertEq(
            address(newNav.assetKindRegistry()),
            address(0),
            "the NEW NAV must NOT have been pointed at a registry that writes to the OLD NAV"
        );

        assertFalse(ok, "RegistryBoundToDifferentNav: run() was expected to revert and did not");
        assertEq(
            ret,
            abi.encodeWithSelector(
                DeployAssetKindRegistry.RegistryBoundToDifferentNav.selector,
                address(stale),
                address(oldNav),
                address(newNav)
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
                    '{"NAVCalculatorProxy":"',
                    vm.toString(NAV_A),
                    '","AssetKindRegistry":"',
                    vm.toString(codeless),
                    '"}'
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
