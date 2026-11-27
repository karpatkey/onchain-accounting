// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    DeriveCelestiaAttestedBalanceAdapter,
    IDeriveVerifiableApp
} from "src/balances/AttestedBalanceAdapters/DeriveCelestiaAttestedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {DeriveBlobBuilder} from "test/balances/AttestedBalanceAdapters/derive/DeriveBlobBuilder.sol";
import {DeriveForkFixture} from "test/balances/AttestedBalanceAdapters/derive/DeriveForkFixture.sol";

/// @title DeriveCelestiaAttestedBalanceAdapterForkTest
/// @notice End to end against the REAL Derive `VerifiableApp` on Ethereum mainnet: a real subaccount record, proven
///         against the commitment VAPP held at the fixture's block, lands in the cache and reads back through the
///         NAV-facing reads.
/// @dev The fixture (`test/integration/derive-celestia/fork-collateral-only.json`) is produced by
///      `script/test/derive-celestia-proof.py --pick-collateral-only --out <fixture>`: it reads the newest Derive
///      batch, picks a subaccount holding only mapped collateral (USDC, USDT, HYPE), and records `forkBlock`, the
///      commitment and the proof. Any block from that batch until the next one (about 10 minutes) works; the test
///      forks at `forkBlock`. The first assertion checks the pin, so a stale fixture fails loudly rather than
///      vacuously.
contract DeriveCelestiaAttestedBalanceAdapterForkTest is BalanceAdapterTestBase {
    address internal constant VAPP = 0xd330145C17fB6EF2a21ACf1275Ce683A305F58BB;
    /// @dev The program and verifier VAPP ran when the fixture was taken (the vkey was last rotated through the
    ///      timelock at block 26,364,645).
    bytes32 internal constant VKEY = 0x00bc954fe627a8c36173e608608795425e22b4134914c7da5bd233b4718c855b;
    address internal constant VERIFIER = 0x3B6041173B80E77f038f3F2C0f9744f04837185e;

    address internal constant DERIVE_USDC = 0x57B03E14d409ADC7fAb6CFc44b5886CAD2D5f02b;
    address internal constant DERIVE_USDT = 0x5E72430EC945CCc183c34e2860FFC2b5bac712c2;
    address internal constant DERIVE_HYPE = 0x2dd469DB6ee0dBF0277F0f3021fd8a6486A751ce;
    /// @dev The LayerZero HYPE OFT: the token `WithdrawalOutbox.resolveAsset(DERIVE_HYPE)` pays out.
    address internal constant HYPE_OFT = 0x0762365e088Fb8D285b295d782BB7b23690713e2;

    string internal json;
    DeriveCelestiaAttestedBalanceAdapter internal adapter;
    address internal account;

    function _setupFork() internal override {
        json =
            vm.readFile(string.concat(vm.projectRoot(), "/test/integration/derive-celestia/fork-collateral-only.json"));
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), vm.parseJsonUint(json, ".forkBlock"));
        address[] memory registered = new address[](3);
        (registered[0], registered[1], registered[2]) = (MAINNET_USDC, MAINNET_USDT, HYPE_OFT);
        balances = _deployBalancesForAdapter(registered);

        address[] memory ids = new address[](3);
        address[] memory toks = new address[](3);
        (ids[0], ids[1], ids[2]) = (DERIVE_USDC, DERIVE_USDT, DERIVE_HYPE);
        (toks[0], toks[1], toks[2]) = (MAINNET_USDC, MAINNET_USDT, HYPE_OFT);
        adapter = new DeriveCelestiaAttestedBalanceAdapter(
            VAPP, address(balances), address(this), VKEY, VERIFIER, ids, toks, address(0), address(0)
        );
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
        adapter.submit(account, DeriveForkFixture.payload(json));
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
        bytes memory data = DeriveForkFixture.payload(json);
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
        bytes memory data = DeriveForkFixture.payload(json);
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
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps = DeriveForkFixture.proofs(json);
        bytes memory s = ps[0].shares[0].share;
        s[200] = bytes1(uint8(s[200]) ^ 0x01);
        vm.expectRevert(DeriveCelestiaAttestedBalanceAdapter.InvalidShareProof.selector);
        adapter.submit(
            account,
            abi.encode(DeriveForkFixture.share(json, ".firstShare"), ps, abi.encode(DeriveBlobBuilder.noFeeds()))
        );
    }
}
