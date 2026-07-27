// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @notice Minimal concrete {MetaBalanceAdapter} exposing the positionId decoders under test.
/// @dev Deliberately the smallest thing that compiles: this suite is about the shared decode contract, not about
///      any protocol's reads. `positionLabels` routes through `_addressLabels` so the helper is exercised the same
///      way the five adapters that use it do (Morpho vaults, Euler vaults, Fluid fTokens, Gearbox markets,
///      Compound comets), and the two raw decoders are exposed directly for the twelve adapters that call them.
contract PidHarness is MetaBalanceAdapter {
    constructor(address nav) MetaBalanceAdapter(nav) {}

    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        return _addressLabels(pid, "Vault", true);
    }

    function pidAddress(bytes calldata pid) external pure returns (address addr, bool ok) {
        return _pidAddress(pid);
    }

    function pidWord(bytes calldata pid) external pure returns (bytes32 word, bool ok) {
        return _pidWord(pid);
    }

    function _instancePositions(address, bytes32, address)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return new INAVCalculator.PositionBalance[](0);
    }

    function _instanceAssets(bytes32) internal view override returns (address[] memory) {
        return new address[](0);
    }

    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.MORPHO;
    }

    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.MORPHO;
    }

    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.MORPHO_VAULTS;
    }
}

/// @title MetaBalanceAdapter positionId decode guards
/// @author KPK
/// @notice Pins the shared accept window for an address- or word-keyed `positionId`, which every `positionLabels`
///         in the meta family now routes through.
/// @dev `positionLabels` is display-only and reachable from a configuration view that probes with whatever word it
///      has, so the decode has two obligations that the obvious `if (pid.length < 32) …; abi.decode(pid, (address))`
///      spelling meets neither of:
///
///        1. **Never revert.** Solidity's decoder validates an `address`, so a word with dirty upper 96 bits — a
///           `bytes32` marketId/poolId copied from a sibling adapter is the ordinary source — reverted.
///        2. **Never over-claim.** `abi.decode` ignores trailing bytes, so `< 32` let a foreign MULTI-word
///           coordinate through and labelled it from its first word.
///
///      Both are pinned here rather than 19 times across the per-adapter suites, because both now live in exactly
///      one place. The twelve adapters that call {_pidAddress}/{_pidWord} inline keep their own assertions in their
///      own suites; this file is what makes a regression in the helper itself impossible to land quietly.
contract MetaBalanceAdapterPidGuardsTest is Test {
    PidHarness internal harness;
    Mock_NAVCalculator internal nav;
    Mock_ERC20 internal token;

    function setUp() public {
        nav = new Mock_NAVCalculator();
        token = new Mock_ERC20("USDC", 6);
        harness = new PidHarness(address(nav));
    }

    //
    // _pidAddress
    //

    /// @dev The accept window is exactly one clean word. Anything else is `(address(0), false)` — never a revert.
    function test_pidAddress_acceptsOnlyExactlyOneCleanWord() public view {
        (address addr, bool ok) = harness.pidAddress(abi.encode(address(token)));
        assertTrue(ok, "a clean single word is the one accepted shape");
        assertEq(addr, address(token));

        // address(0) is a legitimate clean word: the helper reports it faithfully rather than conflating it with
        // "malformed". Callers that treat address(0) as absent decide that themselves.
        (address zero, bool zeroOk) = harness.pidAddress(abi.encode(address(0)));
        assertTrue(zeroOk);
        assertEq(zero, address(0));

        // Largest clean value, smallest dirty value — the boundary of the `raw >> 160` check.
        (, bool maxClean) = harness.pidAddress(abi.encode((uint256(1) << 160) - 1));
        assertTrue(maxClean, "2^160 - 1 is the largest valid address");
        (address dirtyAddr, bool minDirty) = harness.pidAddress(abi.encode(uint256(1) << 160));
        assertFalse(minDirty, "2^160 is the smallest dirty word");
        assertEq(dirtyAddr, address(0), "a rejected word yields no address");
    }

    /// @dev A dirty word must be REJECTED, not masked. Sweeping every dirty bit position with a real token in the
    ///      low 160 bits is what distinguishes rejection from masking: a masking implementation returns
    ///      `(token, true)` for all 96 of these and this test fails 96 times over.
    function test_pidAddress_rejectsEveryDirtyBitRatherThanMasking() public view {
        for (uint256 bit = 160; bit < 256; ++bit) {
            uint256 raw = uint256(uint160(address(token))) | (uint256(1) << bit);
            (address addr, bool ok) = harness.pidAddress(abi.encode(raw));
            assertFalse(ok, "dirty upper bits must be rejected");
            assertEq(addr, address(0), "a dirty word must not be masked down to a real address");
        }
    }

    /// @dev The length half of the guard, at every boundary. 33 and 64 are the cases a `>= 32` guard would accept
    ///      and label from the first word.
    function test_pidAddress_rejectsEveryLengthOtherThan32() public view {
        bytes memory clean = abi.encode(address(token));

        (, bool empty) = harness.pidAddress("");
        assertFalse(empty, "0 bytes");
        (, bool one) = harness.pidAddress(hex"01");
        assertFalse(one, "1 byte");
        (, bool short31) = harness.pidAddress(_truncate(clean, 31));
        assertFalse(short31, "31 bytes");

        (, bool exact) = harness.pidAddress(clean);
        assertTrue(exact, "32 bytes is the accepted length");

        (, bool over33) = harness.pidAddress(abi.encodePacked(clean, hex"01"));
        assertFalse(over33, "33 bytes");
        (, bool over64) = harness.pidAddress(abi.encode(address(token), uint256(7)));
        assertFalse(over64, "64 bytes");
        (, bool over96) = harness.pidAddress(abi.encode(address(token), uint256(7), uint256(9)));
        assertFalse(over96, "96 bytes");
    }

    //
    // _pidWord
    //

    /// @dev The `bytes32` sibling has no range check to make — every 256-bit value is a valid `bytes32`, including
    ///      one whose upper bits are set, which is exactly why Morpho marketIds and Balancer V2 poolIds use it
    ///      instead of {_pidAddress}. Only the length window applies.
    function test_pidWord_acceptsAnyFullWordButOnlyOne() public view {
        (bytes32 w, bool ok) = harness.pidWord(abi.encode(bytes32(type(uint256).max)));
        assertTrue(ok, "a full word with every bit set is a valid bytes32 coordinate");
        assertEq(w, bytes32(type(uint256).max));

        (, bool zero) = harness.pidWord(abi.encode(bytes32(0)));
        assertTrue(zero, "bytes32(0) is a valid word");

        (bytes32 none, bool short_) = harness.pidWord(hex"0102");
        assertFalse(short_, "2 bytes");
        assertEq(none, bytes32(0));
        (, bool over) = harness.pidWord(abi.encode(bytes32(uint256(1)), uint256(2)));
        assertFalse(over, "64 bytes");
    }

    //
    // _addressLabels — the five adapters that share the label shape
    //

    /// @dev End-to-end through the helper the vault/market/lending adapters call: a malformed positionId is `[]`,
    ///      never a revert and never a label. The clean-word tail is what keeps this from passing on a helper that
    ///      returns `[]` unconditionally.
    function test_addressLabels_malformedPositionIdReturnsEmpty() public view {
        assertEq(harness.positionLabels("").length, 0, "empty");
        assertEq(harness.positionLabels(hex"0102030405060708090a0b0c").length, 0, "truncated");

        uint256 dirty = uint256(uint160(address(token))) | (uint256(1) << 255);
        assertEq(harness.positionLabels(abi.encode(dirty)).length, 0, "dirty word");

        assertEq(harness.positionLabels(abi.encode(address(token), uint256(1))).length, 0, "over-long");

        string[] memory clean = harness.positionLabels(abi.encode(address(token)));
        assertEq(clean.length, 2, "a clean word still resolves");
        assertEq(clean[0], "Vault");
        assertEq(clean[1], "USDC");
    }

    /// @dev Helper: first `n` bytes of `b`, so a 31-byte case can be built from a real encoding.
    function _truncate(bytes memory b, uint256 n) private pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = b[i];
        }
    }
}
