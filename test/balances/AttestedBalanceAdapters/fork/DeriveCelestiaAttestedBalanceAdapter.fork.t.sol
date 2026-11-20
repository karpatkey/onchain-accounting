// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    DeriveCelestiaAttestedBalanceAdapter,
    IDeriveVerifiableApp
} from "src/balances/AttestedBalanceAdapters/DeriveCelestiaAttestedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title DeriveCelestiaAttestedBalanceAdapterForkTest
/// @notice End to end against the REAL Derive `VerifiableApp` on Ethereum mainnet: a real subaccount record, proven
///         against the commitment VAPP held at the fixture's block, lands in the cache and reads back through the
///         NAV-facing reads.
/// @dev The fixture (`test/integration/derive-celestia/fork-collateral-only.json`) is produced by
///      `script/test/derive-celestia-proof.py --pick-collateral-only --out <fixture>`: it reads the newest Derive
///      batch, picks a USDC/USDT-only subaccount in it, and records `forkBlock`, the commitment and the proof. Any
///      block from that batch until the next one (about 10 minutes) works; the test forks at `forkBlock`. The
///      first assertion checks the pin, so a stale fixture fails loudly rather than vacuously.
contract DeriveCelestiaAttestedBalanceAdapterForkTest is BalanceAdapterTestBase {
    address internal constant VAPP = 0xd330145C17fB6EF2a21ACf1275Ce683A305F58BB;
    /// @dev The program and verifier VAPP ran when the fixture was taken (the vkey was last rotated through the
    ///      timelock at block 26,364,645).
    bytes32 internal constant VKEY = 0x00bc954fe627a8c36173e608608795425e22b4134914c7da5bd233b4718c855b;
    address internal constant VERIFIER = 0x3B6041173B80E77f038f3F2C0f9744f04837185e;

    address internal constant DERIVE_USDC = 0x57B03E14d409ADC7fAb6CFc44b5886CAD2D5f02b;
    address internal constant DERIVE_USDT = 0x5E72430EC945CCc183c34e2860FFC2b5bac712c2;

    string internal json;
    DeriveCelestiaAttestedBalanceAdapter internal adapter;
    address internal account;

    function _setupFork() internal override {
        json =
            vm.readFile(string.concat(vm.projectRoot(), "/test/integration/derive-celestia/fork-collateral-only.json"));
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), vm.parseJsonUint(json, ".forkBlock"));
        address[] memory registered = new address[](2);
        (registered[0], registered[1]) = (MAINNET_USDC, MAINNET_USDT);
        balances = _deployBalancesForAdapter(registered);

        address[] memory ids = new address[](2);
        address[] memory toks = new address[](2);
        (ids[0], ids[1]) = (DERIVE_USDC, DERIVE_USDT);
        (toks[0], toks[1]) = (MAINNET_USDC, MAINNET_USDT);
        adapter =
            new DeriveCelestiaAttestedBalanceAdapter(VAPP, address(balances), address(this), VKEY, VERIFIER, ids, toks);
        adapter.grantRole(adapter.SUBMITTER_ROLE(), address(this));
        account = vm.parseJsonAddress(json, ".account");
    }

    function test_fixtureIsTheNewestBatchAtForkBlock() public view {
        assertEq(
            IDeriveVerifiableApp(VAPP).celestiaLastCommitment(),
            vm.parseJsonBytes32(json, ".commitment"),
            "fixture commitment is not VAPP's at forkBlock"
        );
    }

    function test_realRecord_landsAndReadsBack() public {
        adapter.submit(account, _payload());
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".expected[", vm.toString(n), "]"))) {
            string memory k = string.concat(".expected[", vm.toString(n), "]");
            address token = vm.parseJsonAddress(json, string.concat(k, ".token"));
            (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(account, token);
            assertEq(amount, vm.parseJsonUint(json, string.concat(k, ".amount")), "attested amount");
            assertFalse(isDebt);
            assertTrue(adapter.isAttestationLive(account, token));
            ++n;
        }
        assertGt(n, 0, "fixture has no expected balance");
    }

    function test_realRecord_previewMatchesCache() public {
        bytes memory data = _payload();
        INAVCalculator.PositionBalance[] memory preview = adapter.previewPositions(account, data);
        adapter.submit(account, data);
        INAVCalculator.PositionBalance[] memory cached = adapter.getAdapterPositions(account, address(0));
        assertEq(preview.length, cached.length);
        for (uint256 i; i < cached.length; ++i) {
            assertEq(preview[i].amount, cached[i].amount);
            assertEq(preview[i].balanceAsset.asset, cached[i].balanceAsset.asset);
        }
    }

    function test_realRecord_otherOwnerRefused() public {
        bytes memory data = _payload();
        vm.expectRevert(
            abi.encodeWithSelector(
                DeriveCelestiaAttestedBalanceAdapter.WrongOwner.selector,
                vm.parseJsonUint(json, ".proofs[0].subaccountId"),
                account
            )
        );
        adapter.submit(makeAddr("notTheOwner"), data);
    }

    function test_realRecord_alteredShareRefused() public {
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps = _proofs();
        bytes memory s = ps[0].shares[0].share;
        s[200] = bytes1(uint8(s[200]) ^ 0x01);
        vm.expectRevert(DeriveCelestiaAttestedBalanceAdapter.InvalidShareProof.selector);
        adapter.submit(account, abi.encode(ps));
    }

    function _payload() internal view returns (bytes memory) {
        return abi.encode(_proofs());
    }

    function _proofs() internal view returns (DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps) {
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".proofs[", vm.toString(n), "]"))) ++n;
        ps = new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](n);
        for (uint256 i; i < n; ++i) {
            string memory k = string.concat(".proofs[", vm.toString(i), "]");
            ps[i].subaccountId = vm.parseJsonUint(json, string.concat(k, ".subaccountId"));
            ps[i].numSubtrees = vm.parseJsonUint(json, string.concat(k, ".numSubtrees"));
            ps[i].recordOffset = vm.parseJsonUint(json, string.concat(k, ".recordOffset"));
            ps[i].usePrevious = vm.parseJsonBool(json, string.concat(k, ".usePrevious"));
            ps[i].prevOffset = vm.parseJsonUint(json, string.concat(k, ".prevOffset"));
            uint256 m;
            while (vm.keyExistsJson(json, string.concat(k, ".shares[", vm.toString(m), "]"))) ++m;
            ps[i].shares = new DeriveCelestiaAttestedBalanceAdapter.ShareProof[](m);
            for (uint256 j; j < m; ++j) {
                string memory s = string.concat(k, ".shares[", vm.toString(j), "]");
                ps[i].shares[j].index = vm.parseJsonUint(json, string.concat(s, ".index"));
                ps[i].shares[j].share = vm.parseJsonBytes(json, string.concat(s, ".share"));
                ps[i].shares[j].subtree = vm.parseJsonUint(json, string.concat(s, ".subtree"));
                ps[i].shares[j].position = vm.parseJsonUint(json, string.concat(s, ".position"));
                ps[i].shares[j].nmtSiblings = vm.parseJsonBytesArray(json, string.concat(s, ".nmtSiblings"));
                ps[i].shares[j].rfcSiblings = vm.parseJsonBytes32Array(json, string.concat(s, ".rfcSiblings"));
            }
        }
    }
}
