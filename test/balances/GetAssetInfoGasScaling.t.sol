// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {INAVCalculator} from "../../src/nav/INAVCalculator.sol";
import {RegisteredAssetLib} from "../../src/balances/RegisteredAssetLib.sol";

/// @title GetAssetInfoGasScaling
/// @notice CALIBRATION ONLY — measures what `MetaBalanceAdapter._getAssetInfo` costs and how it scales with the
///         registered-asset count. Not an invariant guard; no assertions on absolute gas, so it cannot rot into a
///         brittle threshold test. Numbers are printed for the investigation report.
/// @dev Cold-vs-warm discipline: every mock is deployed in `setUp()`, never in a test body. Forge resets the EIP-2929
///      access list between `setUp()` and each test, so the FIRST touch inside a test body is a genuine cold access
///      (2600 for the account + 2100 per cold storage slot) and later touches in the same body are warm (100).
///      Measuring the second call and calling it "the cost" understates it; measuring 50 cold calls and multiplying
///      overstates it. Both numbers are reported separately for exactly that reason.
contract MockRegistry {
    INAVCalculator.Asset[] private _assets;
    /// @dev 1-based index, mirroring `NAVCalculator._assetIndex` (0 = not registered).
    mapping(address asset => uint256) private _assetIndex;

    /// @notice Seeds `n` registered assets with 5-character symbols (representative of USDC/WETH/wstETH).
    function seed(uint256 n) external {
        for (uint256 i; i < n; ++i) {
            address a = address(uint160(0x1000 + i));
            _assets.push(INAVCalculator.Asset({asset: a, symbol: "ASSET", decimals: 18}));
            _assetIndex[a] = _assets.length;
        }
    }

    function assetAt(uint256 i) external view returns (address) {
        return _assets[i].asset;
    }

    /// @notice The O(N) surface the adapters use today.
    function getRegisteredAssets() external view returns (INAVCalculator.Asset[] memory) {
        return _assets;
    }

    /// @notice The O(1) surface that `NAVCalculator._getRegisteredAsset` (NAVCalculator.sol:785) already implements
    ///         internally but does not expose. Non-reverting `(asset, found)` shape, which is what the adapters need
    ///         — the existing internal helper reverts `AssetNotFound()`.
    function getRegisteredAsset(address asset) external view returns (INAVCalculator.Asset memory info, bool found) {
        uint256 idx = _assetIndex[asset];
        if (idx == 0) return (info, false);
        return (_assets[idx - 1], true);
    }
}

/// @notice Holds the two lookup shapes behind an external boundary so the measurement includes the same call overhead
///         a real adapter pays.
contract Probe {
    MockRegistry public immutable REG;

    constructor(MockRegistry reg) {
        REG = reg;
    }

    /// @dev Verbatim the body of `MetaBalanceAdapter._getAssetInfo` (MetaBalanceAdapter.sol:422).
    function lookupArray(address asset) external view returns (bool found) {
        (, found) = RegisteredAssetLib.find(REG.getRegisteredAssets(), asset);
    }

    /// @dev The O(1) alternative.
    function lookupIndexed(address asset) external view returns (bool found) {
        (, found) = REG.getRegisteredAsset(asset);
    }

    /// @notice `n` sequential O(N) lookups in ONE call — the real per-instance shape (1 cold touch, n-1 warm).
    function lookupArrayLoop(address[] calldata assets) external view returns (uint256 hits) {
        for (uint256 i; i < assets.length; ++i) {
            (, bool f) = RegisteredAssetLib.find(REG.getRegisteredAssets(), assets[i]);
            if (f) ++hits;
        }
    }

    function lookupIndexedLoop(address[] calldata assets) external view returns (uint256 hits) {
        for (uint256 i; i < assets.length; ++i) {
            (, bool f) = REG.getRegisteredAsset(assets[i]);
            if (f) ++hits;
        }
    }

    /// @notice Call-overhead baseline, so the reported figures can be stated net of the external hop.
    function noop() external view returns (uint256) {
        return block.number;
    }
}

contract GetAssetInfoGasScalingTest is Test {
    uint256[4] internal SIZES = [uint256(43), 65, 80, 100];

    MockRegistry internal r43;
    MockRegistry internal r65;
    MockRegistry internal r80;
    MockRegistry internal r100;
    Probe internal p43;
    Probe internal p65;
    Probe internal p80;
    Probe internal p100;

    function setUp() public {
        r43 = new MockRegistry();
        r43.seed(43);
        r65 = new MockRegistry();
        r65.seed(65);
        r80 = new MockRegistry();
        r80.seed(80);
        r100 = new MockRegistry();
        r100.seed(100);
        p43 = new Probe(r43);
        p65 = new Probe(r65);
        p80 = new Probe(r80);
        p100 = new Probe(r100);
    }

    function _probe(uint256 n) internal view returns (Probe) {
        if (n == 43) return p43;
        if (n == 65) return p65;
        if (n == 80) return p80;
        return p100;
    }

    function _reg(uint256 n) internal view returns (MockRegistry) {
        if (n == 43) return r43;
        if (n == 65) return r65;
        if (n == 80) return r80;
        return r100;
    }

    /// @notice Q1 — one `_getAssetInfo`, cold then warm, at each registry size. Worst position (last element) is used
    ///         because the scan is linear and a miss/last-hit is the realistic worst case.
    function test_q1_singleLookupColdAndWarm() public view {
        console2.log("=== Q1: one _getAssetInfo (O(N) array fetch + linear scan) ===");
        console2.log("N | coldFirst | warmMarginal | notFound(warm) | O(1) cold | O(1) warm");
        for (uint256 s; s < SIZES.length; ++s) {
            uint256 n = SIZES[s];
            Probe p = _probe(n);
            address last = _reg(n).assetAt(n - 1);

            uint256 g = gasleft();
            p.lookupArray(last);
            uint256 cold = g - gasleft();

            g = gasleft();
            p.lookupArray(last);
            uint256 warm = g - gasleft();

            g = gasleft();
            p.lookupArray(address(0xdead));
            uint256 miss = g - gasleft();

            Probe p2 = _probe(n);
            g = gasleft();
            p2.lookupIndexed(last);
            uint256 idxWarmish = g - gasleft();

            g = gasleft();
            p2.lookupIndexed(last);
            uint256 idxWarm = g - gasleft();

            console2.log(n, cold, warm);
            console2.log("   miss/idx:", miss, idxWarmish);
            console2.log("   idxWarm:", idxWarm);
        }
    }

    /// @notice Baseline: the bare external hop, so the figures above can be quoted net of call overhead.
    function test_q1b_callOverheadBaseline() public view {
        Probe p = p43;
        uint256 g = gasleft();
        p.noop();
        uint256 cold = g - gasleft();
        g = gasleft();
        p.noop();
        uint256 warm = g - gasleft();
        console2.log("=== Q1b: bare external call overhead (cold, warm) ===");
        console2.log(cold, warm);
    }

    /// @notice Q3 — the worst realistic multiplication: a 50-token pool (Balancer V2 ManagedPool cap) inside ONE
    ///         adapter read. One cold touch, 49 warm — measured, not multiplied.
    function test_q3_fiftyTokenPool() public view {
        console2.log("=== Q3: 50 lookups in one call (Balancer V2 ManagedPool token cap) ===");
        console2.log("N | O(N) total | O(1) total | saving");
        for (uint256 s; s < SIZES.length; ++s) {
            uint256 n = SIZES[s];
            Probe p = _probe(n);
            MockRegistry reg = _reg(n);
            address[] memory tokens = new address[](50);
            for (uint256 i; i < 50; ++i) {
                tokens[i] = reg.assetAt(i % n);
            }

            uint256 g = gasleft();
            p.lookupArrayLoop(tokens);
            uint256 arr = g - gasleft();

            Probe p2 = _probe(n);
            g = gasleft();
            p2.lookupIndexedLoop(tokens);
            uint256 idx = g - gasleft();

            console2.log(n, arr, idx);
            console2.log("   saving:", arr - idx);
        }
    }

    /// @notice Q3 scaling — how the per-adapter cost grows with token count at mainnet's 43 assets.
    /// @dev WARM basis by construction: the probes are created inside the body, and a freshly created account is
    ///      already in the access list. That is deliberate here — the slope is what this measures, and within a single
    ///      adapter read every lookup after the first IS warm. Do not quote these as cold figures; Q1 has those.
    function test_q3b_tokenCountScaling() public {
        console2.log("=== Q3b: token-count scaling at N=43, WARM basis (tokens | O(N) | O(1)) ===");
        uint8[6] memory counts = [2, 4, 8, 16, 32, 50];
        for (uint256 c; c < counts.length; ++c) {
            uint256 k = counts[c];
            address[] memory tokens = new address[](k);
            for (uint256 i; i < k; ++i) {
                tokens[i] = r43.assetAt(i % 43);
            }
            Probe a = new Probe(r43);
            Probe b = new Probe(r43);
            uint256 g = gasleft();
            a.lookupArrayLoop(tokens);
            uint256 arr = g - gasleft();
            g = gasleft();
            b.lookupIndexedLoop(tokens);
            uint256 idx = g - gasleft();
            console2.log(k, arr, idx);
        }
    }
}
