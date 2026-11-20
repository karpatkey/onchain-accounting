// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {DeriveBlobBuilder} from "test/balances/AttestedBalanceAdapters/derive/DeriveBlobBuilder.sol";
import {MockDeriveVapp} from "test/balances/AttestedBalanceAdapters/DeriveConformance.t.sol";
import {
    DeriveCelestiaAttestedBalanceAdapter
} from "src/balances/AttestedBalanceAdapters/DeriveCelestiaAttestedBalanceAdapter.sol";
import {CelestiaShareProof} from "src/balances/AttestedBalanceAdapters/derive/CelestiaShareProof.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

/// @notice Unit tests for `DeriveCelestiaAttestedBalanceAdapter`: every acceptance rule on synthetic blobs, plus
///         two real Derive batches whose commitments were recorded on Ethereum.
contract DeriveCelestiaAttestedBalanceAdapterTest is BalanceAdapterTestBase {
    using DeriveBlobBuilder for DeriveBlobBuilder.Blob;

    address internal constant DERIVE_A = address(0xD1);
    address internal constant DERIVE_SIX = address(0xD6);
    /// @dev Derive's HYPE protocol asset id (`WithdrawalOutbox.resolveAsset` → HYPE OFT, 18 decimals).
    address internal constant DERIVE_HYPE = 0x2dd469DB6ee0dBF0277F0f3021fd8a6486A751ce;
    /// @dev hype-split Portfolio Safe, owner of real subaccount 122119.
    address internal constant HYPE_SPLIT_SAFE = 0x8C79753AAD88183f5747C91684d6C0CBfCB27476;

    MockDeriveVapp internal vapp;
    DeriveCelestiaAttestedBalanceAdapter internal adapter;
    Mock_ERC20 internal tokenA;
    Mock_ERC20 internal tokenSix;
    Mock_ERC20 internal hype;
    address internal keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        vapp = new MockDeriveVapp();
        tokenA = new Mock_ERC20("A", 18);
        tokenSix = new Mock_ERC20("SIX", 6);
        hype = new Mock_ERC20("HYPE", 18);
        balances.addSupportedAssetForTest(address(tokenA));
        balances.addSupportedAssetForTest(address(tokenSix));
        balances.addSupportedAssetForTest(address(hype));
        adapter = _deploy(vapp.programVKey(), vapp.verifier());
        bytes32 role = adapter.SUBMITTER_ROLE();
        vm.prank(admin);
        adapter.grantRole(role, keeper);
    }

    function _deploy(bytes32 vkey, address verifier) internal returns (DeriveCelestiaAttestedBalanceAdapter) {
        address[] memory ids = new address[](3);
        address[] memory toks = new address[](3);
        (ids[0], ids[1], ids[2]) = (DERIVE_A, DERIVE_SIX, DERIVE_HYPE);
        (toks[0], toks[1], toks[2]) = (address(tokenA), address(tokenSix), address(hype));
        return
            new DeriveCelestiaAttestedBalanceAdapter(address(vapp), address(balances), admin, vkey, verifier, ids, toks);
    }

    // ─────────────────────────────────────────────────────────────── helpers

    function _rec(uint256 id, address owner, address asset, int256 bal)
        internal
        pure
        returns (DeriveBlobBuilder.Rec memory r)
    {
        r.id = id;
        r.owner = owner;
        r.coll = new DeriveBlobBuilder.Coll[](1);
        r.coll[0] = DeriveBlobBuilder.Coll(asset, bal);
    }

    /// @dev Three records: `first` and `second` as given, then 900 owned by someone else to frame `second`.
    function _blob(DeriveBlobBuilder.Rec memory first, DeriveBlobBuilder.Rec memory second)
        internal
        returns (DeriveBlobBuilder.Blob memory b)
    {
        DeriveBlobBuilder.Rec[] memory recs = new DeriveBlobBuilder.Rec[](3);
        recs[0] = first;
        recs[1] = second;
        recs[2] = _rec(900, address(0xFEED), DERIVE_A, 1e12);
        b = DeriveBlobBuilder.build(recs);
        vapp.setCommitment(b.commitment);
    }

    function _submit(address account, bytes memory data) internal {
        vm.prank(keeper);
        adapter.submit(account, data);
    }

    function _expectSubmitRevert(address account, bytes memory data, bytes memory err) internal {
        vm.expectRevert(err);
        vm.prank(keeper);
        adapter.submit(account, data);
    }

    // ─────────────────────────────────────────────────────────────── happy paths

    function test_submit_cachesCollateralAsOneLeg() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 7e12), _rec(101, bob, DERIVE_A, 1e12));
        _submit(alice, b.payload(b.proof(0, 100, false)));

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(tokenA));
        assertEq(amount, 7 ether);
        assertFalse(isDebt);

        INAVCalculator.PositionBalance[] memory legs = adapter.getAdapterPositions(alice, address(0));
        assertEq(legs.length, 1);
        assertEq(legs[0].amount, 7 ether);
        assertEq(uint8(legs[0].positionKind), uint8(PositionKind.Collateral));
        assertEq(legs[0].protocolBrand, ProtocolIds.DERIVE);
        assertEq(legs[0].protocolId, ProtocolIds.DERIVE_V3);
        assertEq(legs[0].protocolSubId, ProtocolIds.DERIVE_V3_SUBACCOUNTS);
        assertEq(legs[0].positionId, abi.encode(address(vapp)));
        assertEq(legs[0].balanceAdapter, address(adapter));
    }

    function test_submit_sumsSubaccountsOfOneOwner() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 1e12), _rec(101, alice, DERIVE_A, 2e12));
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps =
            new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](2);
        ps[0] = b.proof(0, 100, false);
        ps[1] = b.proof(1, 101, false);
        DeriveCelestiaAttestedBalanceAdapter.ShareProof memory first = b.shareProof(0);
        vm.prank(keeper);
        adapter.submitSubaccounts(alice, first, ps);

        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(tokenA));
        assertEq(amount, 3 ether);
    }

    function test_submit_scalesToTokenDecimalsRoundingDown() public {
        // 1.5 units plus 1e-12: the sub-microunit part cannot be represented at 6 decimals and is dropped.
        DeriveBlobBuilder.Blob memory b =
            _blob(_rec(100, alice, DERIVE_SIX, 1.5e12 + 1), _rec(101, bob, DERIVE_A, 1e12));
        _submit(alice, b.payload(b.proof(0, 100, false)));
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(tokenSix));
        assertEq(amount, 1_500_000);
    }

    function test_lastRecordInSection_needsPreviousRecordFraming() public {
        DeriveBlobBuilder.Rec[] memory recs = new DeriveBlobBuilder.Rec[](2);
        recs[0] = _rec(100, bob, DERIVE_A, 1e12);
        recs[1] = _rec(101, alice, DERIVE_A, 4e12);
        DeriveBlobBuilder.Blob memory b = DeriveBlobBuilder.build(recs);
        vapp.setCommitment(b.commitment);

        // After the last record comes the next section, not a record head.
        _expectSubmitRevert(
            alice,
            b.payload(b.proof(1, 101, false)),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.BadBoundary.selector, 101)
        );

        _submit(alice, b.payload(b.proof(1, 101, true)));
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(tokenA));
        assertEq(amount, 4 ether);
    }

    function test_preview_matchesCache() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 9e12), _rec(101, bob, DERIVE_A, 1e12));
        bytes memory data = b.payload(b.proof(0, 100, false));
        INAVCalculator.PositionBalance[] memory preview = adapter.previewPositions(alice, data);
        _submit(alice, data);
        INAVCalculator.PositionBalance[] memory cached = adapter.getAdapterPositions(alice, address(0));
        assertEq(preview.length, 1);
        assertEq(cached.length, 1);
        assertEq(preview[0].amount, cached[0].amount);
        assertEq(preview[0].balanceAsset.asset, cached[0].balanceAsset.asset);
    }

    // ─────────────────────────────────────────────────────────────── staleness

    function test_nextBatch_readsZero() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 7e12), _rec(101, bob, DERIVE_A, 1e12));
        _submit(alice, b.payload(b.proof(0, 100, false)));
        vapp.setCommitment(keccak256("next batch"));
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(tokenA));
        assertEq(amount, 0);
        assertFalse(adapter.isAttestationLive(alice, address(tokenA)));
    }

    /// @dev Derive stops posting batches but its sequencer keeps trading: the commitment, and so the epoch, stays
    ///      put while the collateral may be spent. The entry must still expire.
    function test_stalledBatches_readZeroAfterMaxAge() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 7e12), _rec(101, bob, DERIVE_A, 1e12));
        _submit(alice, b.payload(b.proof(0, 100, false)));

        skip(adapter.MAX_ATTESTATION_AGE());
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(tokenA));
        assertEq(amount, 7 ether, "still live at exactly the max age");

        skip(1);
        (amount,) = adapter.getAdapterBalanceForAsset(alice, address(tokenA));
        assertEq(amount, 0, "same batch, but older than the max age");
        assertFalse(adapter.isAttestationLive(alice, address(tokenA)));
    }

    function test_programRotation_readsZeroAndRefusesSubmits() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 7e12), _rec(101, bob, DERIVE_A, 1e12));
        bytes memory data = b.payload(b.proof(0, 100, false));
        _submit(alice, data);

        vapp.setProgram(keccak256("new program"), address(0xB0B));
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(tokenA));
        assertEq(amount, 0, "same commitment, but the program changed");
        _expectSubmitRevert(
            alice,
            data,
            abi.encodeWithSelector(
                DeriveCelestiaAttestedBalanceAdapter.ProgramChanged.selector, keccak256("new program"), address(0xB0B)
            )
        );
    }

    // ─────────────────────────────────────────────────────────────── rejections

    function test_revert_wrongOwner() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, bob, DERIVE_A, 7e12), _rec(101, bob, DERIVE_A, 1e12));
        _expectSubmitRevert(
            alice,
            b.payload(b.proof(0, 100, false)),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.WrongOwner.selector, 100, bob)
        );
    }

    function test_revert_wrongSubaccountId() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 7e12), _rec(101, bob, DERIVE_A, 1e12));
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof memory p = b.proof(0, 100, false);
        p.subaccountId = 99;
        _expectSubmitRevert(
            alice,
            b.payload(p),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.WrongSubaccount.selector, 99, 100)
        );
    }

    function test_revert_negativeBalance() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, -5e12), _rec(101, bob, DERIVE_A, 1e12));
        _expectSubmitRevert(
            alice,
            b.payload(b.proof(0, 100, false)),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.NegativeBalance.selector, 100, DERIVE_A)
        );
    }

    function test_revert_unmappedAsset() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, address(0xD9), 5e12), _rec(101, bob, DERIVE_A, 1e12));
        _expectSubmitRevert(
            alice,
            b.payload(b.proof(0, 100, false)),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.UnmappedAsset.selector, 100, address(0xD9))
        );
    }

    function test_revert_openOptions() public {
        DeriveBlobBuilder.Rec memory r = _rec(100, alice, DERIVE_A, 5e12);
        r.options = 1;
        DeriveBlobBuilder.Blob memory b = _blob(r, _rec(101, bob, DERIVE_A, 1e12));
        _expectSubmitRevert(
            alice,
            b.payload(b.proof(0, 100, false)),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.PositionsNotAllowed.selector, 100, 0, 1)
        );
    }

    function test_revert_openPerps() public {
        DeriveBlobBuilder.Rec memory r = _rec(100, alice, DERIVE_A, 5e12);
        r.perps = 2;
        DeriveBlobBuilder.Blob memory b = _blob(r, _rec(101, bob, DERIVE_A, 1e12));
        _expectSubmitRevert(
            alice,
            b.payload(b.proof(0, 100, false)),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.PositionsNotAllowed.selector, 100, 2, 0)
        );
    }

    function test_revert_subaccountsNotAscending() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 1e12), _rec(101, alice, DERIVE_A, 2e12));
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps =
            new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](2);
        ps[0] = b.proof(1, 101, false);
        ps[1] = b.proof(0, 100, false);
        _expectSubmitRevert(
            alice,
            b.payload(ps),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.SubaccountsNotAscending.selector, 100)
        );
    }

    function test_revert_sameSubaccountTwice() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 1e12), _rec(101, bob, DERIVE_A, 2e12));
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps =
            new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](2);
        ps[0] = b.proof(0, 100, false);
        ps[1] = b.proof(0, 100, false);
        _expectSubmitRevert(
            alice,
            b.payload(ps),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.SubaccountsNotAscending.selector, 100)
        );
    }

    function test_revert_proofAgainstOlderBatch() public {
        DeriveBlobBuilder.Blob memory b = _blob(_rec(100, alice, DERIVE_A, 7e12), _rec(101, bob, DERIVE_A, 1e12));
        bytes memory data = b.payload(b.proof(0, 100, false));
        vapp.setCommitment(keccak256("next batch"));
        _expectSubmitRevert(
            alice, data, abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.InvalidShareProof.selector)
        );
    }

    // ─────────────────────────────────────────────────────────────── share positions

    /// @dev A blob of at least three shares, and the index of a record that starts in share 0 and ends in share 1.
    function _threeShareBlob() internal returns (DeriveBlobBuilder.Blob memory b, uint256 k) {
        DeriveBlobBuilder.Rec[] memory recs = new DeriveBlobBuilder.Rec[](20);
        for (uint256 i; i < recs.length; ++i) {
            recs[i] = _rec(100 + i, bob, DERIVE_A, 1e12);
        }
        b = DeriveBlobBuilder.build(recs);
        assertGe(b.shares.length, 3, "fixture: at least three shares");
        while (b.ends[k] <= DeriveBlobBuilder.FIRST_DATA) ++k;
        assertLt(b.starts[k], DeriveBlobBuilder.FIRST_DATA, "fixture: record straddles shares 0 and 1");
        vapp.setCommitment(b.commitment);
    }

    /// @dev Each share is real, but share 2 is presented as share 1, so the joined bytes are not what Derive
    ///      posted. The share must be checked at the index it claims.
    function test_revert_spliceRealShareFromElsewhere() public {
        (DeriveBlobBuilder.Blob memory b, uint256 k) = _threeShareBlob();
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof memory p = b.proof(k, 100 + k, false);
        assertEq(p.shares[1].index, 1);
        DeriveCelestiaAttestedBalanceAdapter.ShareProof memory other = b.shareProof(2);
        other.index = 1;
        p.shares[1] = other;
        _expectSubmitRevert(
            bob, b.payload(p), abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.InvalidShareProof.selector)
        );
    }

    function test_revert_repeatedShare() public {
        (DeriveBlobBuilder.Blob memory b, uint256 k) = _threeShareBlob();
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof memory p = b.proof(k, 100 + k, false);
        DeriveCelestiaAttestedBalanceAdapter.ShareProof memory again = b.shareProof(0);
        again.index = 1;
        p.shares[1] = again;
        _expectSubmitRevert(
            bob, b.payload(p), abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.InvalidShareProof.selector)
        );
    }

    /// @dev The share count, and so the tree shape every index is checked against, comes from share 0. A later
    ///      share cannot stand in for it.
    function test_revert_firstShareMustBeShareZero() public {
        (DeriveBlobBuilder.Blob memory b, uint256 k) = _threeShareBlob();
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps =
            new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](1);
        ps[0] = b.proof(k, 100 + k, false);

        DeriveCelestiaAttestedBalanceAdapter.ShareProof memory first = b.shareProof(1);
        first.index = 0;
        vm.expectRevert(CelestiaShareProof.NotFirstShare.selector);
        vm.prank(keeper);
        adapter.submitSubaccounts(bob, first, ps);

        first = b.shareProof(1);
        vm.expectRevert(CelestiaShareProof.NotFirstShare.selector);
        vm.prank(keeper);
        adapter.submitSubaccounts(bob, first, ps);
    }

    // ─────────────────────────────────────────────────────────────── constructor

    function test_constructor_refusesUnreviewedProgram() public {
        bytes32 vkey = vapp.programVKey();
        address verifier = vapp.verifier();
        vm.expectRevert(
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.ProgramChanged.selector, vkey, verifier)
        );
        _deploy(keccak256("some other program"), verifier);
    }

    function test_constructor_refusesDuplicateAssetId() public {
        address[] memory ids = new address[](2);
        address[] memory toks = new address[](2);
        (ids[0], ids[1]) = (DERIVE_A, DERIVE_A);
        (toks[0], toks[1]) = (address(tokenA), address(tokenSix));
        bytes32 vkey = vapp.programVKey();
        address verifier = vapp.verifier();
        vm.expectRevert(InvalidArguments.selector);
        new DeriveCelestiaAttestedBalanceAdapter(address(vapp), address(balances), admin, vkey, verifier, ids, toks);
    }

    function test_constructor_refusesLengthMismatch() public {
        address[] memory ids = new address[](1);
        address[] memory toks = new address[](0);
        ids[0] = DERIVE_A;
        bytes32 vkey = vapp.programVKey();
        address verifier = vapp.verifier();
        vm.expectRevert(InvalidArguments.selector);
        new DeriveCelestiaAttestedBalanceAdapter(address(vapp), address(balances), admin, vkey, verifier, ids, toks);
    }

    // ─────────────────────────────────────────────────────────────── real Derive batches

    /// @dev hype-split's subaccount 122119, from the blob of the Ethereum batch at block 26,450,225 (Celestia
    ///      16,041,645). The blob's subtree width is 16, so this exercises real NMT paths.
    function test_realBatch_hypeSplitSubaccount() public {
        (bytes memory data,, bytes32 commitment) = _loadReal("hype_split_122119.json");
        vapp.setCommitment(commitment);
        _submit(HYPE_SPLIT_SAFE, data);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(HYPE_SPLIT_SAFE, address(hype));
        assertEq(amount, 0.12 ether);
    }

    /// @dev Subaccount 108093 holds 2 perps and 234 options in the batch at block 26,450,577 (Celestia 16,043,118):
    ///      a real record spanning 23 shares, refused because its positions are not valued.
    function test_realBatch_positionsRefused() public {
        (bytes memory data,, bytes32 commitment) = _loadReal("sub_108093.json");
        vapp.setCommitment(commitment);
        address owner = 0x6845630cB654E050312e0Cb4169b19e83De5Eb08;
        _expectSubmitRevert(
            owner,
            data,
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.PositionsNotAllowed.selector, 108093, 2, 234)
        );
    }

    function test_realBatch_alteredShareRefused() public {
        (, DeriveCelestiaAttestedBalanceAdapter.ShareProof memory first, bytes32 commitment) =
            _loadReal("hype_split_122119.json");
        string memory json = _readFixture("hype_split_122119.json");
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps =
            new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](1);
        ps[0] = _proofFrom(json);
        vapp.setCommitment(commitment);
        bytes memory s = ps[0].shares[0].share;
        s[300] = bytes1(uint8(s[300]) ^ 0x01);
        _expectSubmitRevert(
            HYPE_SPLIT_SAFE,
            abi.encode(first, ps),
            abi.encodeWithSelector(DeriveCelestiaAttestedBalanceAdapter.InvalidShareProof.selector)
        );
    }

    function _readFixture(string memory name) internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/test/integration/derive-celestia/", name));
    }

    /// @return data       The submit payload: the blob's share 0 and the one subaccount proof.
    /// @return first      The share 0 proof alone.
    /// @return commitment The commitment the Ethereum batch recorded for that blob.
    function _loadReal(string memory name)
        internal
        view
        returns (bytes memory data, DeriveCelestiaAttestedBalanceAdapter.ShareProof memory first, bytes32 commitment)
    {
        string memory json = _readFixture(name);
        commitment = vm.parseJsonBytes32(json, ".commitment");
        first = _shareFrom(json, ".firstShare");
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps =
            new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](1);
        ps[0] = _proofFrom(json);
        data = abi.encode(first, ps);
    }

    function _proofFrom(string memory json)
        internal
        view
        returns (DeriveCelestiaAttestedBalanceAdapter.SubaccountProof memory p)
    {
        p.subaccountId = vm.parseJsonUint(json, ".subaccount");
        p.recordOffset = vm.parseJsonUint(json, ".recordOffset");
        p.usePrevious = vm.parseJsonBool(json, ".boundary.usePrevious");
        p.prevOffset = vm.parseJsonUint(json, ".boundary.prevOffset");
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".shares[", vm.toString(n), "]"))) ++n;
        p.shares = new DeriveCelestiaAttestedBalanceAdapter.ShareProof[](n);
        for (uint256 i; i < n; ++i) {
            p.shares[i] = _shareFrom(json, string.concat(".shares[", vm.toString(i), "]"));
        }
    }

    function _shareFrom(string memory json, string memory k)
        internal
        pure
        returns (DeriveCelestiaAttestedBalanceAdapter.ShareProof memory s)
    {
        s.index = vm.parseJsonUint(json, string.concat(k, ".index"));
        s.share = vm.parseJsonBytes(json, string.concat(k, ".share"));
        s.nmtSiblings = vm.parseJsonBytesArray(json, string.concat(k, ".nmtSiblings"));
        s.rfcSiblings = vm.parseJsonBytes32Array(json, string.concat(k, ".rfcSiblings"));
    }
}
