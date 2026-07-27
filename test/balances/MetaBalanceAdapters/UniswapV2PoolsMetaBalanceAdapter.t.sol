// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {
    UniswapV2PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV2PoolsMetaBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {MockUniswapV2Factory, MockUniswapV2Pair, MockToken} from "test/balances/MetaBalanceAdapters/UniswapV2Mocks.sol";

/// @title UniswapV2PoolsMetaBalanceAdapter unit tests (no fork)
/// @notice Meta-framework behaviour and decomposition logic for UniswapV2PoolsMeta.
contract UniswapV2PoolsMetaBalanceAdapterTest is Test {
    using Strings for address;

    Mock_NAVCalculator nav;
    MockUniswapV2Factory factory;
    UniswapV2PoolsMetaBalanceAdapter meta;

    MockToken dai;
    MockToken weth;
    MockToken usdc;
    MockUniswapV2Pair pairA; // DAI/WETH
    MockUniswapV2Pair pairB; // USDC/WETH

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        factory = new MockUniswapV2Factory();
        dai = new MockToken("DAI");
        weth = new MockToken("WETH");
        usdc = new MockToken("USDC");
        nav.registerAsset(address(dai), 18, "DAI");
        nav.registerAsset(address(weth), 18, "WETH");
        nav.registerAsset(address(usdc), 18, "USDC");

        pairA = new MockUniswapV2Pair(address(dai), address(weth), address(factory));
        pairA.setReserves(1000e18, 10e18);
        pairA.setTotalSupply(100e18);
        pairA.setBalance(alice, 10e18); // 10% share -> 100 DAI, 1 WETH

        pairB = new MockUniswapV2Pair(address(usdc), address(weth), address(factory));
        pairB.setReserves(2000e18, 20e18);
        pairB.setTotalSupply(200e18);
        pairB.setBalance(alice, 10e18); // 5% share -> 100 USDC, 1 WETH

        meta = new UniswapV2PoolsMetaBalanceAdapter(address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(pairA))));
        ins[1] = bytes32(uint256(uint160(address(pairB))));
    }

    function test_supportsInterface() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
    }

    function test_noArgMethods_returnEmpty() public view {
        assertEq(meta.getAdapterPositions(alice, address(0)).length, 0);
        assertEq(meta.underlyingAssetsSupported().length, 0);
    }

    function test_values() public view {
        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, one, address(0));
        assertEq(p.length, 2, "DAI + WETH supply legs");
        assertEq(p[0].balanceAsset.asset, address(dai));
        assertEq(p[0].amount, 100e18);
        assertEq(p[1].amount, 1e18);

        assertEq(p[0].positionId, abi.encode(address(pairA)));
    }

    function test_fanOut_acrossPairs() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(p.length, 4, "2 legs per pair");
        assertEq(p[2].balanceAsset.asset, address(usdc));
        assertEq(p[2].amount, 100e18);
    }

    function test_assetFilter() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instances(), address(weth));
        assertEq(p.length, 2, "WETH leg from each pair");
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].balanceAsset.asset, address(weth));
        }
    }

    function test_unregisteredToken_skipped() public {
        nav.unregisterAssetHelper(address(weth));
        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, one, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].balanceAsset.asset, address(dai));
    }

    function test_zeroBalance_empty() public {
        pairA.setBalance(alice, 0);
        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        assertEq(meta.getAdapterPositionsForInstances(alice, one, address(0)).length, 0);
    }

    /// @notice The protocol-fee dilution is applied when the factory answers coherently — the control for the
    ///         two malformed-factory tests below.
    function test_protocolFeeDilution_reducesReportedShare() public {
        factory.setFeeTo(address(0xFEE));
        pairA.setKLast(2.5e39); // rootK = 1e20, rootKLast = 5e19 → pendingMint = 100e18·5e19/5.5e20

        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, one, address(0));

        assertEq(p.length, 2, "DAI + WETH legs");
        assertLt(p[0].amount, 100e18, "dilution must reduce the reported share");
        assertApproxEqRel(p[0].amount, 91.666e18, 1e15, "burn-equivalent share after protocol-fee dilution");
    }

    /// @notice A factory whose `feeTo()` word is not a valid address must make the pair report NOTHING — never
    ///         the undiluted (larger) share.
    /// @dev The regression this guards is subtle and was introduced by the move to masking. `StaticCallLib`
    ///      deliberately masks a dirty word to 160 bits instead of reverting, which is right everywhere else in
    ///      the sweep. But a word of `type(uint96).max << 160` masks to `address(0)`, and at THIS call site
    ///      `feeTo == address(0)` means "no protocol fee" — so the dilution term silently vanishes and the
    ///      reported share grows. Before masking, that word hit `abi.decode`'s validator, reverted, and the
    ///      per-instance `try`/`catch` dropped the pair — the safe direction.
    ///
    ///      Delete the `feeToWord >> 160 != 0` check in `_pendingProtocolMint` and this fails with the full
    ///      undiluted 100e18, i.e. an over-report of ~909 bps against the control above.
    function test_malformedFeeTo_reportsNothingRatherThanUndilutedShare() public {
        factory.setFeeTo(address(0xFEE));
        pairA.setKLast(2.5e39);

        // Upper 96 bits set, low 160 bits zero: masks to address(0), which this call site would read as
        // "no protocol fee".
        vm.mockCall(
            address(factory), abi.encodeWithSignature("feeTo()"), abi.encodePacked(uint256(type(uint96).max) << 160)
        );

        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, one, address(0));

        assertEq(p.length, 0, "an unreadable factory must drop the pair, not inflate it");
    }

    /// @notice A factory returning a dirty word whose low 160 bits are a REAL address is equally unreadable.
    /// @dev Complements the zero-low-bits case: here masking would yield a non-zero `feeTo` and apply dilution,
    ///      which happens to under-report — but the word still is not an address, so the honest answer is that
    ///      the dilution is unknowable. Pinning both directions stops a future "only reject when it masks to
    ///      zero" narrowing.
    function test_malformedFeeTo_withRealLowBits_alsoDropsThePair() public {
        factory.setFeeTo(address(0xFEE));
        pairA.setKLast(2.5e39);

        vm.mockCall(
            address(factory),
            abi.encodeWithSignature("feeTo()"),
            abi.encodePacked(uint256(uint160(address(0xFEE))) | (uint256(1) << 200))
        );

        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, one, address(0));

        assertEq(p.length, 0, "a dirty feeTo word is unreadable regardless of its low bits");
    }

    /// @notice A factory that answers `feeTo()` SUCCESSFULLY but with fewer than 32 bytes is "absent", not
    ///         "broken" — the pair must still report, undiluted.
    /// @dev The input class that no test covered, and the one that separates "cannot read an address" from
    ///      "answered with something that is not an address". A raw staticcall to a CODE-LESS factory succeeds
    ///      with zero returndata, so this is not exotic: it is what a fork with a mis-set `factory()`, or a proxy
    ///      whose implementation slot is unset, looks like. Treating it as malformed would drop the operator's
    ///      entire LP position — both legs to zero — over a missing optional getter, which is a far bigger error
    ///      than the dilution term the malformed path exists to protect.
    ///
    ///      Widen `malformed` in {StaticCallLib.safeAddrStrict} to any non-address (i.e. `hasWord` dropped from
    ///      its definition) and this test fails with 0 legs.
    function test_emptyFeeToReply_reportsUndilutedRatherThanDropping() public {
        factory.setFeeTo(address(0xFEE));
        pairA.setKLast(2.5e39);

        // Successful call, zero-length reply — exactly what a code-less factory returns to a raw staticcall.
        vm.mockCall(address(factory), abi.encodeWithSignature("feeTo()"), "");

        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, one, address(0));

        assertEq(p.length, 2, "an absent feeTo() must not drop the pair");
        assertEq(p[0].amount, 100e18, "absent feeTo() means no protocol fee, so no dilution");
    }

    /// @notice Same for a truncated word: still absent, not broken.
    function test_shortFeeToReply_reportsUndilutedRatherThanDropping() public {
        factory.setFeeTo(address(0xFEE));
        pairA.setKLast(2.5e39);
        vm.mockCall(address(factory), abi.encodeWithSignature("feeTo()"), hex"00112233");

        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, one, address(0));

        assertEq(p.length, 2, "a short feeTo() reply must not drop the pair");
        assertEq(p[0].amount, 100e18, "no readable feeTo() means no dilution");
    }

    /// @notice A fork that genuinely omits `feeTo()` still reports, undiluted — the fail-open this branch exists
    ///         for must survive the malformed-word guard.
    function test_missingFeeToSelector_stillReportsUndiluted() public {
        pairA.setKLast(2.5e39);
        vm.mockCallRevert(address(factory), abi.encodeWithSignature("feeTo()"), "");

        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, one, address(0));

        assertEq(p.length, 2, "a fee-less fork still reports");
        assertEq(p[0].amount, 100e18, "no protocol fee means no dilution");
    }

    function test_badInstance_isolated() public view {
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead))));
        ins[1] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(p.length, 2, "bad pair isolated, pairA legs returned");
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory a = meta.underlyingAssetsSupportedForInstances(_instances());
        assertEq(a.length, 4);
        assertEq(a[0], address(dai));
        assertEq(a[1], address(weth));
        assertEq(a[2], address(usdc));
        assertEq(a[3], address(weth));
    }
}
