// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {PancakeSwapV2BalanceOracle} from "src/balances/protocols/pancakeswap/PancakeSwapV2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @notice Local copy of the minimal pair interface — keeps this test independent of the
///         adapter file's internal layout.
interface IPancakeV2PairFork {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function kLast() external view returns (uint256);
}

interface IPancakeV2FactoryFork {
    function feeTo() external view returns (address);
}

/// @title PancakeSwapV2BalanceOracle fork tests — ETH/COW pair on BSC
/// @notice Tests the adapter against a live PancakeSwap V2 pair on BSC. The pair is
///         `0x74d4ee4ca29ca2fb69b31e9cbd4523b707e64662` (Cake-LP for Binance-Peg ETH × CoW Protocol),
///         and the test account `0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669` is effectively
///         the genesis depositor — at the pinned block they hold all but 1000 wei (the
///         `MIN_LIQUIDITY` lock-up) of `totalSupply`.
///
///         Requires either `BSC_URL` env var (preferred — KNode/Alchemy/QuickNode/etc.) or the
///         `ALCHEMY_API_KEY` fallback (which builds an Alchemy `bnb-mainnet` URL). Without
///         either, `vm.envOr` returns empty and `getAlchemyUrl` reverts with `RpcUrlNotSet`.
contract PancakeSwapV2BalanceOracleForkTest_BSC_ETH_COW is BalanceAdapterTestBase {
    // PancakeSwap V2 BSC contracts.
    address public constant PAIR = 0x74D4Ee4CA29Ca2FB69B31E9cbd4523b707e64662;
    address public constant V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;

    // Pool tokens (token0 = Binance-Peg ETH, token1 = COW).
    address public constant BSC_ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    address public constant BSC_COW = 0x5BfdAa3f7C28B9994B56135403bF1aCEA02595b0;

    // Test account that is the (effective sole) LP of this pair at the pinned block.
    address public constant TEST_HOLDER = 0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669;

    // Pinned block — picked recent enough that the position is still held but not the very tip
    // of the chain (RPC-stability margin).
    uint256 public constant FORK_BLOCK = 96_200_000;

    PancakeSwapV2BalanceOracle public oracle;
    address internal alice;
    address internal unknownAccount;

    function setUp() public override {
        // Skip the entire suite if no BSC RPC is configured. BSC isn't in the default CI env
        // (CI sets MAINNET_URL/ARBITRUM_URL/BASE_URL/OP_URL/GNOSIS_URL/ALCHEMY_API_KEY but not
        // BSC_URL), so without an explicit BSC_URL or ALCHEMY_API_KEY-with-BSC-coverage we
        // can't reach BSC. `vm.skip(true)` aborts the test cleanly instead of hard-failing.
        if (!_bscRpcConfigured()) {
            vm.skip(true);
            return;
        }
        super.setUp();
        _setupFork();
        alice = makeAddr("alice");
        unknownAccount = makeAddr("unknownAccount");
        _setupOracle();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("bnb-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    /// @dev True iff at least one of `BSC_URL` or `ALCHEMY_API_KEY` is set in the environment.
    ///      `getAlchemyUrl("bnb-mainnet")` consumes the former first; falls back to the latter.
    function _bscRpcConfigured() internal view returns (bool) {
        return bytes(vm.envOr("BSC_URL", string(""))).length != 0
            || bytes(vm.envOr("ALCHEMY_API_KEY", string(""))).length != 0;
    }

    function _setupOracle() internal {
        address[] memory assets = new address[](2);
        assets[0] = BSC_ETH;
        assets[1] = BSC_COW;
        balances = _deployBalancesForOracle(assets);
        oracle = new PancakeSwapV2BalanceOracle(
            PAIR,
            "PancakeSwap V2",
            "{\"protocol\":\"PancakeSwap V2\",\"pool\":\"ETH/COW LP\"",
            "0x0000000000000000000000000000000000000001",
            address(balances)
        );
    }

    // ============================================
    // Interface compliance + immutables
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    function test_immutables_derived_from_pair() public view {
        assertEq(oracle.PAIR(), PAIR);
        assertEq(oracle.TOKEN0(), BSC_ETH, "token0 should be Binance-Peg ETH");
        assertEq(oracle.TOKEN1(), BSC_COW, "token1 should be COW");
        assertEq(oracle.FACTORY(), V2_FACTORY);
    }

    // ============================================
    // underlyingAssetsSupported
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 2);
        assertEq(assets[0], BSC_ETH);
        assertEq(assets[1], BSC_COW);
    }

    // ============================================
    // Real holder — assert non-zero balances + match the live formula exactly
    // ============================================

    /// @notice The test account is the genesis LP (essentially `totalSupply - MIN_LIQUIDITY`).
    ///         We assert the adapter's reported amounts equal the dilution-adjusted formula
    ///         `balance × reserve / (totalSupply + pendingProtocolMint)` against live pair state.
    function test_realHolder_matchesLiveFormula() public view {
        uint256 lp = IPancakeV2PairFork(PAIR).balanceOf(TEST_HOLDER);
        assertGt(lp, 0, "test holder must own the LP at the pinned block");

        uint256 totalSupply = IPancakeV2PairFork(PAIR).totalSupply();
        (uint112 r0, uint112 r1,) = IPancakeV2PairFork(PAIR).getReserves();
        assertGt(uint256(r0), 0);
        assertGt(uint256(r1), 0);

        uint256 effectiveSupply = totalSupply + _pendingProtocolMintLive(uint256(r0), uint256(r1), totalSupply);
        uint256 expectedEth = (lp * uint256(r0)) / effectiveSupply;
        uint256 expectedCow = (lp * uint256(r1)) / effectiveSupply;

        (uint256 amountEth,) = oracle.getOracleBalanceForAsset(TEST_HOLDER, BSC_ETH);
        (uint256 amountCow,) = oracle.getOracleBalanceForAsset(TEST_HOLDER, BSC_COW);
        assertEq(amountEth, expectedEth, "BSC-ETH pro-rata must match formula on live state");
        assertEq(amountCow, expectedCow, "COW pro-rata must match formula on live state");
        assertGt(amountEth, 0);
        assertGt(amountCow, 0);
    }

    function test_realHolder_isGenesisLp() public view {
        // Cross-check: the test account holds essentially the whole LP supply (totalSupply - 1000
        // wei MIN_LIQUIDITY) — confirms the holder selection is correct.
        uint256 lp = IPancakeV2PairFork(PAIR).balanceOf(TEST_HOLDER);
        uint256 totalSupply = IPancakeV2PairFork(PAIR).totalSupply();
        assertEq(totalSupply - lp, 1000, "test holder must be the genesis LP (locked MIN_LIQUIDITY = 1000 wei)");
    }

    function test_unknownAccount_returnsZero() public view {
        (uint256 amountEth,) = oracle.getOracleBalanceForAsset(unknownAccount, BSC_ETH);
        (uint256 amountCow,) = oracle.getOracleBalanceForAsset(unknownAccount, BSC_COW);
        assertEq(amountEth, 0);
        assertEq(amountCow, 0);
    }

    function test_unsupportedAsset_returnsZero() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(TEST_HOLDER, address(0xdead));
        assertEq(amount, 0);
    }

    // ============================================
    // getOracleBalances + getOraclePositions on real holder
    // ============================================

    function test_getOracleBalances_realHolder_bothNonZero() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) =
            oracle.getOracleBalances(TEST_HOLDER);
        assertEq(assets.length, 2, "expect both tokens");
        assertEq(assets[0], BSC_ETH);
        assertEq(assets[1], BSC_COW);
        assertGt(amounts[0], 0);
        assertGt(amounts[1], 0);
        assertFalse(isDebt[0]);
        assertFalse(isDebt[1]);
    }

    function test_getOraclePositions_realHolder_bothRegistered() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(TEST_HOLDER, address(0));
        assertEq(positions.length, 2);
        bool sawEth;
        bool sawCow;
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].balanceOracle, address(oracle));
            assertEq(positions[i].protocol, "PancakeSwap V2");
            assertEq(positions[i].positionDetail, "{\"protocol\":\"PancakeSwap V2\",\"pool\":\"ETH/COW LP\"}");
            assertFalse(positions[i].isDebt);
            assertGt(positions[i].amount, 0);
            if (positions[i].underlyingAsset.asset == BSC_ETH) sawEth = true;
            if (positions[i].underlyingAsset.asset == BSC_COW) sawCow = true;
        }
        assertTrue(sawEth, "BSC-ETH position present");
        assertTrue(sawCow, "COW position present");
    }

    function test_getOraclePositions_assetFilter_eth() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(TEST_HOLDER, BSC_ETH);
        assertEq(positions.length, 1);
        assertEq(positions[0].underlyingAsset.asset, BSC_ETH);
        assertGt(positions[0].amount, 0);
    }

    function test_getOraclePositions_assetFilter_unsupported() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(TEST_HOLDER, address(0xdead));
        assertEq(positions.length, 0);
    }

    // ============================================
    // Shipped-config behaviour: only ETH registered (mirrors `assets.json` + `RegisterAssets._symbolsForChain(56)`)
    // ============================================

    /// @notice The shipped BSC config registers BNB/WBNB/USDC/USDT/ETH/CAKE in NAV but
    ///         intentionally leaves COW unregistered (no Chainlink feed available). The PancakeSwap
    ///         V2 ETH/COW adapter is therefore disabled by default in `chains/56.json`. This test
    ///         exercises what would happen if it were enabled anyway: only the ETH leg of the LP
    ///         is reported by `getOraclePositions` and the COW leg drops out, producing a NAV that
    ///         is only the ETH side of the pair (~half the actual position value). The test
    ///         documents this behaviour so a future operator who flips the adapter on without
    ///         pricing COW has a regression bar to compare against.
    function test_getOraclePositions_productionConfig_dropsCowLeg() public {
        // Build a separate Balances registry that mirrors the shipped BSC config: only ETH is registered.
        address[] memory shippedAssets = new address[](1);
        shippedAssets[0] = BSC_ETH;
        BalancesHarnessForFork shippedBalances = _deployBalancesForOracle(shippedAssets);
        PancakeSwapV2BalanceOracle shippedOracle = new PancakeSwapV2BalanceOracle(
            PAIR,
            "PancakeSwap V2",
            "{\"protocol\":\"PancakeSwap V2\",\"pool\":\"ETH/COW LP\"",
            "0x0000000000000000000000000000000000000001",
            address(shippedBalances)
        );

        INAVCalculator.PositionBalance[] memory positions = shippedOracle.getOraclePositions(TEST_HOLDER, address(0));
        assertEq(positions.length, 1, "only ETH leg should survive the registry filter");
        assertEq(positions[0].underlyingAsset.asset, BSC_ETH, "the surviving leg is ETH");
        assertGt(positions[0].amount, 0, "ETH leg is the holder's pro-rata share of the ETH reserve");

        // And the per-asset query for COW returns 0 because COW isn't in the registry — the
        // adapter still reports a non-zero `getOracleBalanceForAsset` for COW (it's protocol-level,
        // pre-registry), but `getOraclePositions` is the path NAVCalculator actually consumes,
        // and that's the path we just confirmed drops COW.
        (uint256 cowAmount, bool cowIsDebt) = shippedOracle.getOracleBalanceForAsset(TEST_HOLDER, BSC_COW);
        assertGt(cowAmount, 0, "raw per-asset query bypasses registry filter -- COW is still reported");
        assertFalse(cowIsDebt);
    }

    // ============================================
    // Dilution branch — mock factory.feeTo() to non-zero, mock kLast < current k
    // ============================================

    function test_dilution_branch_reduces_amount_relative_to_naive() public {
        // PancakeSwap on BSC has historically run with `feeTo` enabled, but to exercise the
        // dilution math deterministically we mock `feeTo` and `kLast` ourselves.
        uint256 lp = IPancakeV2PairFork(PAIR).balanceOf(TEST_HOLDER);
        uint256 totalSupply = IPancakeV2PairFork(PAIR).totalSupply();
        (uint112 r0, uint112 r1,) = IPancakeV2PairFork(PAIR).getReserves();

        // Mock factory.feeTo() → non-zero recipient so the dilution branch activates.
        vm.mockCall(V2_FACTORY, abi.encodeCall(IPancakeV2FactoryFork.feeTo, ()), abi.encode(address(0xFEE0)));

        // Mock pair.kLast() → a value strictly below current k so √k > √kLast and pendingMint > 0.
        uint256 currentK = uint256(r0) * uint256(r1);
        require(currentK > 4, "live k too small for this test");
        vm.mockCall(PAIR, abi.encodeCall(IPancakeV2PairFork.kLast, ()), abi.encode(currentK / 4));

        // Hand-compute expected amount with adapter's exact formula.
        uint256 rootK = Math.sqrt(currentK);
        uint256 rootKLast = Math.sqrt(currentK / 4);
        uint256 pendingMint = (totalSupply * (rootK - rootKLast)) / (rootK * 5 + rootKLast);
        assertGt(pendingMint, 0, "dilution branch should produce non-zero pending mint");

        uint256 expectedEth = (lp * uint256(r0)) / (totalSupply + pendingMint);
        (uint256 amountEth,) = oracle.getOracleBalanceForAsset(TEST_HOLDER, BSC_ETH);
        assertEq(amountEth, expectedEth, "dilution-adjusted amount must match _mintFee math");

        // And it must be strictly less than naive pro-rata.
        uint256 naive = (lp * uint256(r0)) / totalSupply;
        assertLt(amountEth, naive);
    }

    // ============================================
    // helper — same math as `_pendingProtocolMint` in the adapter
    // ============================================

    function _pendingProtocolMintLive(uint256 reserve0, uint256 reserve1, uint256 totalSupply)
        internal
        view
        returns (uint256)
    {
        address feeTo = IPancakeV2FactoryFork(V2_FACTORY).feeTo();
        if (feeTo == address(0)) return 0;
        uint256 kLast = IPancakeV2PairFork(PAIR).kLast();
        if (kLast == 0) return 0;
        uint256 rootK = Math.sqrt(reserve0 * reserve1);
        uint256 rootKLast = Math.sqrt(kLast);
        if (rootK <= rootKLast) return 0;
        return (totalSupply * (rootK - rootKLast)) / (rootK * 5 + rootKLast);
    }
}
