// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AttestedAdapterConformance} from "test/balances/AttestedBalanceAdapters/AttestedAdapterConformance.sol";
import {DeriveBlobBuilder} from "test/balances/AttestedBalanceAdapters/derive/DeriveBlobBuilder.sol";
import {AttestedValueCache} from "src/balances/AttestedBalanceAdapters/AttestedValueCache.sol";
import {
    DeriveCelestiaAttestedBalanceAdapter,
    IDeriveVerifiableApp
} from "src/balances/AttestedBalanceAdapters/DeriveCelestiaAttestedBalanceAdapter.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

/// @notice Stand-in for Derive's `VerifiableApp`: a settable commitment, program pair and batch time.
/// @dev `lastOpTimestamp` defaults to "the batch just landed" (the current block time) until a test pins it, so tests
///      that warp to a fixture's time do not need to re-stamp the batch; staleness tests set it explicitly.
contract MockDeriveVapp is IDeriveVerifiableApp {
    bytes32 public celestiaLastCommitment;
    bytes32 public programVKey = keccak256("derive-vkey");
    address public verifier = address(0xA11CE);
    uint64 internal _lastOp;

    function setCommitment(bytes32 c) external {
        celestiaLastCommitment = c;
    }

    function setProgram(bytes32 vkey, address verifier_) external {
        programVKey = vkey;
        verifier = verifier_;
    }

    function setLastOpTimestamp(uint64 t) external {
        _lastOp = t;
    }

    function lastOpTimestamp() external view returns (uint64) {
        return _lastOp == 0 ? uint64(block.timestamp) : _lastOp;
    }
}

/// @notice Runs the attested family's conformance kit against the Derive member.
/// @dev The fixtures are synthetic blobs with real Celestia share proofs (`DeriveBlobBuilder`):
///      - `_validPayload` / `_secondValidPayload` prove two different records of ONE blob, so both are valid under
///        the same commitment and the non-suppression test cannot confuse suppression with staleness;
///      - `_tamperedPayload` keeps the valid commitment and flips one byte of the record, so it fails because the
///        share no longer hashes to the commitment;
///      - `_rotateValidity` moves the commitment, which is how entries go stale when Derive posts the next batch.
contract DeriveConformanceTest is AttestedAdapterConformance {
    using DeriveBlobBuilder for DeriveBlobBuilder.Blob;

    address internal constant DERIVE_A = address(0xD1);
    address internal constant DERIVE_B = address(0xD2);

    MockDeriveVapp internal vapp;
    Mock_ERC20 internal tokenA;
    Mock_ERC20 internal tokenB;

    function _deployMember(address admin_) internal override returns (AttestedValueCache) {
        vapp = new MockDeriveVapp();
        tokenA = new Mock_ERC20("A", 18);
        tokenB = new Mock_ERC20("B", 18);
        balances.addSupportedAssetForTest(address(tokenA));
        balances.addSupportedAssetForTest(address(tokenB));
        address[] memory ids = new address[](2);
        address[] memory toks = new address[](2);
        ids[0] = DERIVE_A;
        ids[1] = DERIVE_B;
        toks[0] = address(tokenA);
        toks[1] = address(tokenB);
        return new DeriveCelestiaAttestedBalanceAdapter(
            address(vapp),
            address(balances),
            admin_,
            vapp.programVKey(),
            vapp.verifier(),
            ids,
            toks,
            address(0),
            address(0)
        );
    }

    /// @dev Records 100 (A, 100) and 101 (B, 55) owned by `account`, then 102 owned by someone else, so 101 is
    ///      framed by a following head.
    function _blob(address account) internal returns (DeriveBlobBuilder.Blob memory b) {
        DeriveBlobBuilder.Rec[] memory recs = new DeriveBlobBuilder.Rec[](3);
        recs[0] = _rec(100, account, DERIVE_A, 100e12);
        recs[1] = _rec(101, account, DERIVE_B, 55e12);
        recs[2] = _rec(102, address(0xFEED), DERIVE_A, 1e12);
        b = DeriveBlobBuilder.build(recs);
        vapp.setCommitment(b.commitment);
    }

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

    function _validPayload(address account)
        internal
        override
        returns (bytes memory data, address[] memory assets, uint256[] memory values)
    {
        DeriveBlobBuilder.Blob memory b = _blob(account);
        data = b.payload(b.proof(0, 100, false));
        assets = new address[](1);
        values = new uint256[](1);
        assets[0] = address(tokenA);
        values[0] = 100 ether;
    }

    function _secondValidPayload(address account)
        internal
        override
        returns (bytes memory data, address[] memory assets, uint256[] memory values)
    {
        DeriveBlobBuilder.Blob memory b = _blob(account);
        data = b.payload(b.proof(1, 101, false));
        assets = new address[](1);
        values = new uint256[](1);
        assets[0] = address(tokenB);
        values[0] = 55 ether;
    }

    function _tamperedPayload(address account) internal override returns (bytes memory data) {
        DeriveBlobBuilder.Blob memory b = _blob(account);
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof memory p = b.proof(0, 100, false);
        // Flip one byte inside the record's balance; the share no longer hashes to the live commitment.
        bytes memory s = p.shares[0].share;
        uint256 at = 30 + p.recordOffset + 40; // header + record start + a byte inside the record body
        s[at] = bytes1(uint8(s[at]) ^ 0x01);
        data = b.payload(p);
    }

    function _tamperedRevertSelector() internal pure override returns (bytes4) {
        return DeriveCelestiaAttestedBalanceAdapter.InvalidShareProof.selector;
    }

    function _rotateValidity() internal override {
        vapp.setCommitment(keccak256("next-batch"));
    }

    function _submitViaTypedEntrypoint(address account, bytes memory data) internal override {
        (
            DeriveCelestiaAttestedBalanceAdapter.ShareProof memory first,
            DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps,
            bytes memory feeds
        ) = abi.decode(
            data,
            (
                DeriveCelestiaAttestedBalanceAdapter.ShareProof,
                DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[],
                bytes
            )
        );
        DeriveCelestiaAttestedBalanceAdapter(address(member)).submitSubaccounts(account, first, ps, feeds);
    }
}
