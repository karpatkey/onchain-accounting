// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {NotAContract} from "src/errors.sol";

/// @notice A NAVCalculator that predates `getRegisteredAsset` — it serves the array getter and nothing else.
/// @dev Stands in for a proxy running an implementation from before that getter existed. No fallback, so the
///      missing selector reverts, which is exactly what a real UUPS proxy does when its implementation has no
///      matching function.
contract OldNav {
    function getRegisteredAssets() external pure returns (INAVCalculator.Asset[] memory) {
        return new INAVCalculator.Asset[](0);
    }
}

/// @notice A NAVCalculator that can serve the getter.
contract NewNav {
    function getRegisteredAssets() external pure returns (INAVCalculator.Asset[] memory) {
        return new INAVCalculator.Asset[](0);
    }

    function getRegisteredAsset(address) external pure returns (INAVCalculator.Asset memory a, bool found) {
        return (a, false);
    }
}

/// @notice Success, zero returndata for ANY selector — the shape that defeated the first version of the guard.
/// @dev Not a strawman: a Safe with no fallback handler, a permissive router, and several proxy patterns all
///      answer an unknown selector this way. `staticcall` reports success, so a guard that checks only the
///      success flag accepts it and pins it forever.
contract SilentFallbackNav {
    fallback() external {}
}

/// @notice Returns SUCCESS with 96 bytes — too short to be an answer, but comfortably above a 64-byte floor.
/// @dev Exists to make the specific value 192 load-bearing. A mutation run showed the suite still passed with
///      the floor weakened to 64, because the only other short-return mock returns ZERO bytes and so is caught
///      by any floor at all. Without this mock the constant was pinned by a comment, not by a test.
contract ShortReturnNav {
    fallback() external {
        assembly {
            return(0, 96)
        }
    }
}

/// @notice A NAVCalculator with a real registry, so "empty" and "populated but missing" are distinguishable.
/// @dev The success mock returns a hard-coded `(a, false)` regardless of argument, which cannot tell those two
///      apart — the distinction the empty-registry test exists to make.
contract RegistryNav {
    mapping(address => bool) internal _registered;

    function register(address asset) external {
        _registered[asset] = true;
    }

    function getRegisteredAsset(address asset) external view returns (INAVCalculator.Asset memory a, bool found) {
        found = _registered[asset];
        if (found) a.asset = asset;
    }
}

/// @notice Minimal concrete meta-adapter; the guard lives in the base constructor so the body is irrelevant.
contract ProbeMetaAdapter is MetaBalanceAdapter {
    constructor(address nav_) MetaBalanceAdapter(nav_) {}

    function _instancePositions(address, bytes32, address)
        internal
        pure
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return new INAVCalculator.PositionBalance[](0);
    }

    function _instanceAssets(bytes32) internal pure override returns (address[] memory) {
        return new address[](0);
    }

    function _protocolBrand() internal pure override returns (bytes32) {
        return bytes32("probe");
    }

    function _protocolId() internal pure override returns (bytes32) {
        return bytes32("probe");
    }

    function _protocolSubId() internal pure override returns (bytes32) {
        return bytes32("probe");
    }

    function positionLabels(bytes calldata) external pure override returns (string[] memory) {
        return new string[](0);
    }
}

/// @title Meta-adapters refuse to deploy against a NAVCalculator that cannot serve them
/// @notice Meta-adapters are IMMUTABLE with the NAV proxy pinned at construction; NAVCalculator is UUPS-UPGRADEABLE.
///         Without this guard, an adapter paired with a pre-`getRegisteredAsset` implementation fails **silently and
///         upward**: every `_eligible` call hits a missing selector, the proxy reverts cheaply, the per-instance
///         `catch` sees a small `consumed` so `GasStipendLib.exhausted` is false and it is not re-raised as
///         `InstanceGasExhausted`, the instance is recorded as zero legs, and `getAdapterPositions` RETURNS
///         SUCCESSFULLY. Dropped debt legs raise reported NAV.
/// @dev The tests below are ordered to make the argument, not just to cover lines: the old pairing is rejected,
///      the capable one is not, and the two shapes that defeated earlier versions of the guard — success with no
///      answer, and a non-contract — are each pinned to their own error. An earlier revision of this comment
///      promised "a demonstration of what the old pairing does when it is NOT rejected"; no such test existed,
///      and a doc claiming coverage that is absent is worse than no doc, because it stops the next reader
///      looking. What replaced it is `test_successWithEmptyReturndataIsRejected`, which pins the case that
///      actually reached the silent zero-leg over-report in review.
contract MetaAdapterNavVersionGuardTest is Test {
    function test_deployingAgainstAnOldNavCalculatorReverts() public {
        OldNav nav = new OldNav();
        vm.expectRevert(abi.encodeWithSelector(MetaBalanceAdapter.NAVCalculatorTooOld.selector, address(nav)));
        new ProbeMetaAdapter(address(nav));
    }

    function test_deployingAgainstACapableNavCalculatorSucceeds() public {
        NewNav nav = new NewNav();
        ProbeMetaAdapter meta = new ProbeMetaAdapter(address(nav));
        assertEq(address(meta.NAV_CALCULATOR()), address(nav));
    }

    /// @notice Success with EMPTY returndata must be rejected. This is the case the first version of the guard
    ///         let through, and letting it through reinstated the exact over-report the guard exists to prevent.
    /// @dev Fails if the `ret.length < 64` clause is removed — that mutation was run to confirm it, since a
    ///      `staticcall` to this mock returns `ok == true` and the success flag alone therefore proves nothing.
    function test_successWithEmptyReturndataIsRejected() public {
        SilentFallbackNav nav = new SilentFallbackNav();
        vm.expectRevert(abi.encodeWithSelector(MetaBalanceAdapter.NAVCalculatorTooOld.selector, address(nav)));
        new ProbeMetaAdapter(address(nav));
    }

    /// @notice The guard must not reject a NAVCalculator whose registry is EMPTY. The probe passes `address(0)`,
    ///         which is never a registered asset, so "not found" is the healthy answer and must not read as
    ///         "cannot serve".
    /// @dev Uses a registry-backed mock, deliberately: the plain success mock returns a hard-coded `(a, false)`
    ///      whatever it is asked, so it cannot distinguish an empty registry from a populated one that lacks the
    ///      probe key — and an earlier version of this test, built on that mock, was a byte-identical duplicate
    ///      of the success case above. Both states are asserted here so the case is not vacuous.
    function test_anEmptyRegistryIsNotTreatedAsAnOldNavCalculator() public {
        RegistryNav empty = new RegistryNav();
        ProbeMetaAdapter a = new ProbeMetaAdapter(address(empty));
        assertEq(address(a.NAV_CALCULATOR()), address(empty), "empty registry rejected");

        RegistryNav populated = new RegistryNav();
        populated.register(address(0xBEEF));
        ProbeMetaAdapter b = new ProbeMetaAdapter(address(populated));
        assertEq(address(b.NAV_CALCULATOR()), address(populated), "populated registry rejected");

        (, bool found) = populated.getRegisteredAsset(address(0));
        assertFalse(found, "probe key must be absent, or the test proves nothing");
    }

    /// @notice A short-but-non-empty answer is rejected. This is what makes the value 192 load-bearing.
    /// @dev Fails if the floor is weakened to anything <= 96 — verified by mutation, which is how the gap this
    ///      test fills was found: with only the zero-byte mock, dropping the floor from 192 to 64 changed no
    ///      test outcome, so the constant was documented rather than pinned.
    function test_shortButNonEmptyReturndataIsRejected() public {
        ShortReturnNav nav = new ShortReturnNav();
        vm.expectRevert(abi.encodeWithSelector(MetaBalanceAdapter.NAVCalculatorTooOld.selector, address(nav)));
        new ProbeMetaAdapter(address(nav));
    }

    /// @notice The 192-byte floor in the guard is justified by measurement, not by arithmetic in a comment.
    /// @dev `returns (Asset memory, bool)` with `Asset = (address, string, uint8)` encodes to six words when the
    ///      symbol is empty, which is what the `address(0)` probe elicits. If `Asset` ever gains a field this
    ///      test fails, forcing the floor to be revisited rather than silently becoming loose. A first pass put
    ///      the floor at 64, which would have admitted 64..191 bytes.
    function test_capableNavReturndataIsAtLeastTheFloor() public {
        NewNav nav = new NewNav();
        (bool ok, bytes memory ret) =
            address(nav).staticcall(abi.encodeWithSelector(INAVCalculator.getRegisteredAsset.selector, address(0)));
        assertTrue(ok, "capable NAV must answer");
        assertEq(ret.length, 192, "floor in MetaBalanceAdapter must match the real minimum encoding");
    }

    /// @notice A non-contract is rejected by `AddressCheckLib`, NOT by the probe, and the two errors are kept
    ///         distinct so an operator can tell a typo from a stale implementation.
    /// @dev Asserts the SPECIFIC error. A bare `vm.expectRevert()` — which is what this test used to do — passes
    ///      on any revert including `NAVCalculatorTooOld`, so it asserted the opposite of the distinctness it
    ///      claimed. That distinction is load-bearing here: a `staticcall` to a codeless account returns
    ///      SUCCESS, so the probe alone cannot reject an EOA and `requireContract` is what does the work.
    function test_nonContractStillRejectedDistinctly() public {
        address notAContract = address(0xdead);
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "NAVCalculator"));
        new ProbeMetaAdapter(notAContract);
    }
}
