// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title DeriveOptionMath
/// @notice Black-76 pricing of Derive's cash-settled European options on Derive's SVI volatility slice.
/// @dev All values are 1e18 fixed point. Written from the published formulas (Black 1976; Gatheral's SVI
///      parameterisation), not from Derive's or any third-party implementation. The exponential and
///      logarithm are range-reduced by powers of two with a Taylor / atanh series; the normal CDF uses the
///      Maclaurin series of erf for |x|/sqrt(2) <= 3 and a Laplace continued fraction for the far tail.
///      Absolute error is below 1e-12 for N(x) over |x| < 40 and the discounted price error is far below
///      one 12-decimal USD unit for any option that the adapter can price.
library DeriveOptionMath {
    uint256 internal constant WAD = 1e18;
    /// @dev ln(2) in 1e18 fixed point.
    int256 internal constant LN2 = 693147180559945309;
    /// @dev 1/sqrt(2) in 1e18 fixed point.
    uint256 internal constant INV_SQRT2 = 707106781186547524;
    /// @dev 2/sqrt(pi) in 1e18 fixed point.
    uint256 internal constant TWO_OVER_SQRT_PI = 1128379167095512574;
    /// @dev sqrt(pi) in 1e18 fixed point.
    uint256 internal constant SQRT_PI = 1772453850905516027;
    /// @dev Total variance cap of the SVI slice (w <= 144).
    uint256 internal constant SVI_W_CAP = 144e18;
    /// @dev Total volatility above which a call is treated as deep in the money (standard call = 1).
    uint256 internal constant TOTAL_VOL_CAP = 24e18;
    /// @dev Seconds in the year used to convert expiries into year fractions (Derive convention).
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    /// @dev Number of terms of the continued fraction for erfc.
    uint256 private constant _CF_TERMS = 120;
    /// @dev Above this |x| / sqrt(2) the Taylor series is replaced by the continued fraction.
    uint256 private constant _ERF_SERIES_LIMIT = 3e18;

    error NonPositiveInput();
    error ExpOutOfRange();
    error NegativeVariance();
    error ZeroVolatility();
    error NonPositiveForward();
    error NonPositiveStrike();
    error NonPositiveTau();

    /// @dev SVI slice parameters, as published by Derive (`a`, `b`, `rho`, `m`, `sigma`, `sviFwd`, `refTau`).
    struct Svi {
        int256 a;
        uint256 b;
        int256 rho;
        int256 m;
        uint256 sigma;
        uint256 sviFwd;
        uint256 refTau;
    }

    /// @notice Year fraction from `nowTs` to `expiry` in 1e18 fixed point. Requires expiry > nowTs.
    function yearsTo(uint256 expiry, uint256 nowTs) internal pure returns (uint256) {
        return (expiry - nowTs) * WAD / SECONDS_PER_YEAR;
    }

    /// @notice Natural logarithm of `x` (x > 0), 1e18 fixed point in and out.
    /// @dev x = m * 2^k with m in [1, 2). ln(m) = 2 * atanh(z), z = (m - 1) / (m + 1) < 1/3.
    function lnWad(uint256 x) internal pure returns (int256) {
        if (x == 0) revert NonPositiveInput();
        int256 k;
        uint256 m = x;
        while (m >= 2 * WAD) {
            m >>= 1;
            ++k;
        }
        while (m < WAD) {
            m <<= 1;
            --k;
        }
        int256 z = int256((m - WAD) * WAD / (m + WAD));
        int256 z2 = z * z / int256(WAD);
        int256 term = z;
        int256 sum = z;
        for (uint256 n = 3; term != 0; n += 2) {
            term = term * z2 / int256(WAD);
            sum += term / int256(n);
        }
        return k * LN2 + 2 * sum;
    }

    /// @notice e^x for x in 1e18 fixed point; returns 0 for x <= -42 (the result is below 1e-18).
    /// @dev x = k * ln(2) + r with |r| < ln(2); e^r by Taylor series, then scaled by 2^k.
    function expWad(int256 x) internal pure returns (uint256) {
        if (x <= -42 * int256(WAD)) return 0;
        if (x > 40 * int256(WAD)) revert ExpOutOfRange();
        int256 k = x / LN2;
        int256 r = x - k * LN2;
        int256 sum = int256(WAD);
        int256 term = int256(WAD);
        for (int256 n = 1; term != 0; ++n) {
            term = term * r / (n * int256(WAD));
            sum += term;
        }
        if (k >= 0) return uint256(sum) << uint256(k);
        return uint256(sum) >> uint256(-k);
    }

    /// @notice sqrt(x) for x in 1e18 fixed point.
    function sqrtWad(uint256 x) internal pure returns (uint256) {
        return Math.sqrt(x * WAD);
    }

    /// @notice Standard normal CDF N(x), x and result in 1e18 fixed point.
    function normCdf(int256 x) internal pure returns (uint256) {
        uint256 t = x < 0 ? uint256(-x) : uint256(x);
        if (t >= 40 * WAD) return x < 0 ? 0 : WAD;
        uint256 z = t * INV_SQRT2 / WAD;
        uint256 lower; // N(-t)
        if (z <= _ERF_SERIES_LIMIT) {
            lower = (WAD - _erf(z)) / 2;
        } else {
            lower = _erfc(z) / 2;
        }
        return x < 0 ? lower : WAD - lower;
    }

    /// @notice Black-76 price of a European option on a forward, discounted to today, 1e18 fixed point.
    /// @param fwd Forward price F (> 0).
    /// @param strike Strike K (> 0).
    /// @param vol Annualised volatility.
    /// @param tau Year fraction to expiry (> 0).
    /// @param rate Continuously compounded rate; negative rates are floored at zero.
    function black76(uint256 fwd, uint256 strike, uint256 vol, uint256 tau, int256 rate, bool isCall)
        internal
        pure
        returns (uint256 price)
    {
        if (fwd == 0) revert NonPositiveForward();
        if (strike == 0) revert NonPositiveStrike();
        uint256 r = rate > 0 ? uint256(rate) : 0;
        uint256 disc = expWad(-int256(r * tau / WAD));
        uint256 totalVol = vol * sqrtWad(tau) / WAD;
        uint256 m = strike * WAD / fwd;

        uint256 stdCall = WAD;
        if (totalVol < TOTAL_VOL_CAP) {
            if (totalVol == 0) revert ZeroVolatility();
            int256 d1 = (int256(totalVol * totalVol / WAD / 2) - lnWad(m)) * int256(WAD) / int256(totalVol);
            int256 d2 = d1 - int256(totalVol);
            int256 c = int256(normCdf(d1)) - int256(m * normCdf(d2) / WAD);
            stdCall = c > 0 ? uint256(c) : 0;
        }

        uint256 fDisc = fwd * disc / WAD;
        if (isCall) {
            price = stdCall * fDisc / WAD;
            if (price > fDisc) price = fDisc;
        } else {
            uint256 sum = stdCall + m;
            uint256 stdPut = sum > WAD ? sum - WAD : 0;
            price = stdPut * fDisc / WAD;
            uint256 kDisc = strike * disc / WAD;
            if (price > kDisc) price = kDisc;
        }
    }

    /// @notice Implied volatility of the SVI slice at `strike`.
    /// @dev k = ln(K / sviFwd) clamped to +/- 4 sqrt(a + b sigma); w = a + b (rho (k - m) + sqrt((k - m)^2 + sigma^2)),
    ///      capped at 144; vol = sqrt(w / refTau).
    function sviVol(Svi memory s, uint256 strike) internal pure returns (uint256) {
        if (s.sviFwd == 0) revert NonPositiveForward();
        if (s.refTau == 0) revert NonPositiveTau();
        int256 volFactorSq = s.a + int256(s.b * s.sigma / WAD);
        if (volFactorSq < 0) revert NegativeVariance();
        int256 kBound = int256(4 * sqrtWad(uint256(volFactorSq)));

        int256 k;
        uint256 ratio = strike * WAD / s.sviFwd;
        if (ratio == 0) {
            k = -kBound;
        } else {
            k = lnWad(ratio);
            if (k > kBound) k = kBound;
            if (k < -kBound) k = -kBound;
        }

        int256 d = k - s.m;
        uint256 root = sqrtWad(uint256(d * d / int256(WAD)) + s.sigma * s.sigma / WAD);
        int256 inner = s.rho * d / int256(WAD) + int256(root);
        int256 w = s.a + int256(s.b) * inner / int256(WAD);
        if (w < 0) revert NegativeVariance();
        uint256 wCapped = uint256(w) > SVI_W_CAP ? SVI_W_CAP : uint256(w);
        return sqrtWad(wCapped * WAD / s.refTau);
    }

    /// @notice Price of a Derive option: SVI vol at `strike`, forward F = spot + fwdDiff, Black-76 discounted at `rate`.
    function optionPrice(
        Svi memory s,
        uint256 strike,
        uint256 spot,
        int256 fwdDiff,
        int256 rate,
        uint256 tau,
        bool isCall
    ) internal pure returns (uint256) {
        uint256 vol = sviVol(s, strike);
        int256 fwd = int256(spot) + fwdDiff;
        if (fwd <= 0) revert NonPositiveForward();
        return black76(uint256(fwd), strike, vol, tau, rate, isCall);
    }

    /// @dev erf(z) for 0 <= z <= 3 by the Maclaurin series (2/sqrt(pi)) * sum (-1)^n z^(2n+1) / (n! (2n+1)).
    function _erf(uint256 z) private pure returns (uint256) {
        uint256 z2 = z * z / WAD;
        uint256 p = z; // z^(2n+1) / n!
        int256 sum;
        for (uint256 n; p != 0; ++n) {
            int256 t = int256(p / (2 * n + 1));
            sum = n % 2 == 0 ? sum + t : sum - t;
            p = p * z2 / WAD / (n + 1);
        }
        return uint256(sum) * TWO_OVER_SQRT_PI / WAD;
    }

    /// @dev erfc(z) for z > 0 by the Laplace continued fraction
    ///      erfc(z) = exp(-z^2) / sqrt(pi) / (z + (1/2)/(z + 1/(z + (3/2)/(z + ...)))).
    function _erfc(uint256 z) private pure returns (uint256) {
        uint256 d = z;
        for (uint256 k = _CF_TERMS; k > 0; --k) {
            d = z + (k * WAD / 2) * WAD / d;
        }
        uint256 e = expWad(-int256(z * z / WAD));
        return e * WAD / SQRT_PI * WAD / d;
    }
}
