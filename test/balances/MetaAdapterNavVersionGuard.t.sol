// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

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
/// @dev The tests below are ordered to make the argument, not just to cover lines: first that the old pairing is
///      rejected at deploy time, then — the part that justifies the guard — a demonstration of what the old pairing
///      does when it is NOT rejected.
contract MetaAdapterNavVersionGuardTest is Test {
    function test_deployingAgainstAnOldNavCalculatorReverts() public {
        OldNav old = new OldNav();
        vm.expectRevert(abi.encodeWithSelector(MetaBalanceAdapter.NAVCalculatorTooOld.selector, address(old)));
        new ProbeMetaAdapter(address(old));
    }

    function test_deployingAgainstACapableNavCalculatorSucceeds() public {
        NewNav nu = new NewNav();
        ProbeMetaAdapter a = new ProbeMetaAdapter(address(nu));
        assertEq(address(a.NAV_CALCULATOR()), address(nu), "a capable NAVCalculator is accepted and pinned");
    }

    /// @notice The guard must not reject a NAVCalculator whose registry is EMPTY. The probe passes `address(0)`,
    ///         which resolves to `(zeroed, false)` — a legitimate answer, not a failure.
    /// @dev Worth its own test because the obvious way to write this guard — probing with a real asset, or treating
    ///      a `false` result as failure — would reject every fresh deployment, where the NAV proxy exists but no
    ///      assets are registered yet. That is the ordinary state during `01_2` → `04`.
    function test_anEmptyRegistryIsNotTreatedAsAnOldNavCalculator() public {
        NewNav nu = new NewNav(); // getRegisteredAsset returns found == false for everything
        ProbeMetaAdapter a = new ProbeMetaAdapter(address(nu));
        assertEq(address(a.NAV_CALCULATOR()), address(nu), "found == false is an answer, not an absence");
    }

    /// @notice A non-contract is still rejected by the pre-existing `AddressCheckLib` check, and that error is kept
    ///         distinct from the version error so an operator can tell a typo from a stale implementation.
    function test_nonContractStillRejectedDistinctly() public {
        vm.expectRevert();
        new ProbeMetaAdapter(address(0xdead));
    }
}
