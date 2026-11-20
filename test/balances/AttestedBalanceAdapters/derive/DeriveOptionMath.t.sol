// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";

import {DeriveOptionMath} from "src/balances/AttestedBalanceAdapters/derive/DeriveOptionMath.sol";

/// @dev External wrappers so the library's internal functions can be called (and reverts observed) from tests.
contract DeriveOptionMathHarness {
    function normCdf(int256 x) external pure returns (uint256) {
        return DeriveOptionMath.normCdf(x);
    }

    function lnWad(uint256 x) external pure returns (int256) {
        return DeriveOptionMath.lnWad(x);
    }

    function expWad(int256 x) external pure returns (uint256) {
        return DeriveOptionMath.expWad(x);
    }

    function black76(uint256 fwd, uint256 strike, uint256 vol, uint256 tau, int256 rate, bool isCall)
        external
        pure
        returns (uint256)
    {
        return DeriveOptionMath.black76(fwd, strike, vol, tau, rate, isCall);
    }
}

/// @notice `DeriveOptionMath` against 50-digit references (Python mpmath, `option_math_vectors.json`): the normal CDF
///         across both tails and the erf-series / continued-fraction switch at |x| = 3·sqrt(2), ln and exp across
///         their ranges, and Black-76 on at-, out- and in-the-money options, a 3-hour option, a negative rate (floored
///         at 0) and the total-vol cap.
contract DeriveOptionMathTest is Test {
    DeriveOptionMathHarness internal h;
    string internal json;

    function setUp() public {
        h = new DeriveOptionMathHarness();
        json =
            vm.readFile(string.concat(vm.projectRoot(), "/test/integration/derive-celestia/option_math_vectors.json"));
    }

    /// @dev N(x) to 1e-12 absolute.
    function test_normCdf_matchesReference() public view {
        uint256 n = _len(".cdf");
        for (uint256 i; i < n; ++i) {
            string memory k = string.concat(".cdf[", vm.toString(i), "]");
            int256 x = vm.parseInt(vm.parseJsonString(json, string.concat(k, "[0]")));
            uint256 want = vm.parseUint(vm.parseJsonString(json, string.concat(k, "[1]")));
            assertApproxEqAbs(h.normCdf(x), want, 1e6, string.concat("N(x) at ", vm.toString(x)));
        }
    }

    function test_lnWad_matchesReference() public view {
        uint256 n = _len(".ln");
        for (uint256 i; i < n; ++i) {
            string memory k = string.concat(".ln[", vm.toString(i), "]");
            uint256 x = vm.parseUint(vm.parseJsonString(json, string.concat(k, "[0]")));
            int256 want = vm.parseInt(vm.parseJsonString(json, string.concat(k, "[1]")));
            assertApproxEqAbs(h.lnWad(x), want, 100, string.concat("ln at ", vm.toString(x)));
        }
    }

    /// @dev Relative 1e-15, or 2 wei where the result itself is a few wei.
    function test_expWad_matchesReference() public view {
        uint256 n = _len(".exp");
        for (uint256 i; i < n; ++i) {
            string memory k = string.concat(".exp[", vm.toString(i), "]");
            int256 x = vm.parseInt(vm.parseJsonString(json, string.concat(k, "[0]")));
            uint256 want = vm.parseUint(vm.parseJsonString(json, string.concat(k, "[1]")));
            uint256 got = h.expWad(x);
            if (want < 1e6) assertApproxEqAbs(got, want, 2, string.concat("exp at ", vm.toString(x)));
            else assertApproxEqRel(got, want, 1e3, string.concat("exp at ", vm.toString(x)));
        }
    }

    /// @dev Relative 1e-12, or 1e-15 USD absolute for prices near zero.
    function test_black76_matchesReference() public view {
        uint256 n = _len(".b76");
        for (uint256 i; i < n; ++i) {
            string memory k = string.concat(".b76[", vm.toString(i), "]");
            uint256 got = h.black76(
                _u(k, 0), _u(k, 1), _u(k, 2), _u(k, 3), _i(k, 4), vm.parseJsonBool(json, string.concat(k, "[5]"))
            );
            uint256 want = _u(k, 6);
            uint256 tol = want / 1e12 > 1e3 ? want / 1e12 : 1e3;
            assertApproxEqAbs(got, want, tol, string.concat("black76 vector ", vm.toString(i)));
        }
    }

    function test_expWad_belowRangeIsZero_aboveRangeReverts() public {
        assertEq(h.expWad(-42e18), 0);
        vm.expectRevert(DeriveOptionMath.ExpOutOfRange.selector);
        h.expWad(41e18);
    }

    function test_lnWad_zeroReverts() public {
        vm.expectRevert(DeriveOptionMath.NonPositiveInput.selector);
        h.lnWad(0);
    }

    function _len(string memory key) internal view returns (uint256 n) {
        while (vm.keyExistsJson(json, string.concat(key, "[", vm.toString(n), "]"))) ++n;
    }

    function _u(string memory k, uint256 j) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, string.concat(k, "[", vm.toString(j), "]")));
    }

    function _i(string memory k, uint256 j) internal view returns (int256) {
        return vm.parseInt(vm.parseJsonString(json, string.concat(k, "[", vm.toString(j), "]")));
    }
}
