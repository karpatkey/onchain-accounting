// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {UniswapV2BalanceOracle} from "src/balances/protocols/UniswapV2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @notice Local copy of the minimal pair interface — keeps this test independent of the adapter file's internal layout.
interface IUniswapV2PairFork {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function kLast() external view returns (uint256);
}

interface IUniswapV2FactoryFork {
    function feeTo() external view returns (address);
}

/// @title UniswapV2BalanceOracle fork tests — USDC/WETH V2 pair on mainnet
/// @notice Verifies the adapter against live mainnet pair state (real reserves, totalSupply,
///         kLast, factory.feeTo()). Uses `deal()` to assign synthetic LP balances so the math
///         can be asserted exactly without depending on a particular holder at a pinned block.
contract UniswapV2BalanceOracleForkTest_USDC_WETH is BalanceAdapterTestBase {
    // Canonical Uniswap V2 USDC/WETH pair
    address public constant PAIR = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;
    address public constant V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;

    // Pool tokens (token0 = USDC, token1 = WETH for this pair)
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Pinned block — same recent block used by Curve fork test (matches established cadence)
    uint256 public constant FORK_BLOCK = 24_444_658;

    UniswapV2BalanceOracle public oracle;
    address internal alice;
    address internal unknownAccount;

    function setUp() public override {
        super.setUp();
        _setupFork();
        alice = makeAddr("alice");
        unknownAccount = makeAddr("unknownAccount");
        _setupOracle();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupOracle() internal {
        address[] memory assets = new address[](2);
        assets[0] = USDC;
        assets[1] = WETH;
        balances = _deployBalancesForOracle(assets);
        oracle = new UniswapV2BalanceOracle(
            PAIR,
            "Uniswap V2",
            "{\"protocol\":\"Uniswap V2\",\"pool\":\"USDC/WETH LP\"",
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
        assertEq(oracle.TOKEN0(), USDC, "token0 should be USDC for this pair");
        assertEq(oracle.TOKEN1(), WETH, "token1 should be WETH for this pair");
        assertEq(oracle.FACTORY(), V2_FACTORY);
    }

    // ============================================
    // underlyingAssetsSupported
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 2);
        assertEq(assets[0], USDC);
        assertEq(assets[1], WETH);
    }

    // ============================================
    // Math against live pair state — deal a synthetic LP balance and assert exact pro-rata
    // ============================================

    /// @dev With `feeTo` historically unset on the canonical V2 factory, the dilution branch
    ///      should evaluate to 0, and the reported amount equals naive `balance × reserve / totalSupply`.
    function test_synthetic_balance_matches_pro_rata_live() public {
        uint256 lp = 1e15; // synthetic LP balance — small so we don't risk overflow on uint112×uint256.
        deal(PAIR, alice, lp);

        uint256 totalSupply = IUniswapV2PairFork(PAIR).totalSupply();
        (uint112 r0, uint112 r1,) = IUniswapV2PairFork(PAIR).getReserves();

        // Compute the dilution-adjusted denominator the adapter would use, mirroring `_pendingProtocolMint`.
        uint256 effectiveSupply = totalSupply + _pendingProtocolMintLive(uint256(r0), uint256(r1), totalSupply);

        uint256 expectedUsdc = (lp * uint256(r0)) / effectiveSupply;
        uint256 expectedWeth = (lp * uint256(r1)) / effectiveSupply;

        (uint256 amountUsdc,) = oracle.getOracleBalanceForAsset(alice, USDC);
        (uint256 amountWeth,) = oracle.getOracleBalanceForAsset(alice, WETH);
        assertEq(amountUsdc, expectedUsdc, "USDC pro-rata must match formula on live state");
        assertEq(amountWeth, expectedWeth, "WETH pro-rata must match formula on live state");
        assertGt(amountUsdc, 0);
        assertGt(amountWeth, 0);
    }

    function test_unknownAccount_returnsZero() public view {
        (uint256 amountUsdc,) = oracle.getOracleBalanceForAsset(unknownAccount, USDC);
        (uint256 amountWeth,) = oracle.getOracleBalanceForAsset(unknownAccount, WETH);
        assertEq(amountUsdc, 0);
        assertEq(amountWeth, 0);
    }

    function test_unsupportedAsset_returnsZero() public {
        deal(PAIR, alice, 1e15);
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(0xdead));
        assertEq(amount, 0);
    }

    // ============================================
    // Position aggregation
    // ============================================

    function test_getOracleBalances_synthetic() public {
        deal(PAIR, alice, 1e15);
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(alice);
        assertEq(assets.length, 2, "expect both tokens");
        assertEq(assets[0], USDC);
        assertEq(assets[1], WETH);
        assertGt(amounts[0], 0);
        assertGt(amounts[1], 0);
        assertFalse(isDebt[0]);
        assertFalse(isDebt[1]);
    }

    function test_getOraclePositions_synthetic_bothRegistered() public {
        deal(PAIR, alice, 1e15);
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));
        assertEq(positions.length, 2);
        bool sawUsdc;
        bool sawWeth;
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].balanceOracle, address(oracle));
            assertEq(positions[i].protocol, "Uniswap V2");
            assertEq(
                positions[i].positionDetail,
                "{\"protocol\":\"Uniswap V2\",\"pool\":\"USDC/WETH LP\",\"type\":\"Supply\"}"
            );
            assertFalse(positions[i].isDebt);
            assertGt(positions[i].amount, 0);
            if (positions[i].underlyingAsset.asset == USDC) sawUsdc = true;
            if (positions[i].underlyingAsset.asset == WETH) sawWeth = true;
        }
        assertTrue(sawUsdc, "USDC position present");
        assertTrue(sawWeth, "WETH position present");
    }

    function test_getOraclePositions_assetFilter_usdc() public {
        deal(PAIR, alice, 1e15);
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, USDC);
        assertEq(positions.length, 1);
        assertEq(positions[0].underlyingAsset.asset, USDC);
        assertGt(positions[0].amount, 0);
    }

    function test_getOraclePositions_assetFilter_unsupported() public {
        deal(PAIR, alice, 1e15);
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0xdead));
        assertEq(positions.length, 0);
    }

    // ============================================
    // Dilution branch — mock factory.feeTo() to non-zero, mock kLast < current k
    // ============================================

    function test_dilution_branch_reduces_amount_relative_to_naive() public {
        deal(PAIR, alice, 1e15);

        uint256 totalSupply = IUniswapV2PairFork(PAIR).totalSupply();
        (uint112 r0, uint112 r1,) = IUniswapV2PairFork(PAIR).getReserves();

        // Mock factory.feeTo() → non-zero recipient so the dilution branch activates.
        vm.mockCall(V2_FACTORY, abi.encodeCall(IUniswapV2FactoryFork.feeTo, ()), abi.encode(address(0xFEE0)));

        // Mock pair.kLast() → a value strictly below current k so √k > √kLast and pendingMint > 0.
        uint256 currentK = uint256(r0) * uint256(r1);
        require(currentK > 4, "live k too small for this test");
        vm.mockCall(PAIR, abi.encodeCall(IUniswapV2PairFork.kLast, ()), abi.encode(currentK / 4));

        // Hand-compute expected amount with adapter's exact formula.
        uint256 rootK = Math.sqrt(currentK);
        uint256 rootKLast = Math.sqrt(currentK / 4);
        uint256 pendingMint = (totalSupply * (rootK - rootKLast)) / (rootK * 5 + rootKLast);
        assertGt(pendingMint, 0, "dilution branch should produce non-zero pending mint");

        uint256 expectedUsdc = (1e15 * uint256(r0)) / (totalSupply + pendingMint);
        (uint256 amountUsdc,) = oracle.getOracleBalanceForAsset(alice, USDC);
        assertEq(amountUsdc, expectedUsdc, "dilution-adjusted amount must match _mintFee math");

        // And it must be strictly less than naive pro-rata.
        uint256 naive = (1e15 * uint256(r0)) / totalSupply;
        assertLt(amountUsdc, naive);
    }

    // ============================================
    // helper — same math as `_pendingProtocolMint` in the adapter
    // ============================================

    function _pendingProtocolMintLive(uint256 reserve0, uint256 reserve1, uint256 totalSupply)
        internal
        view
        returns (uint256)
    {
        address feeTo = IUniswapV2FactoryFork(V2_FACTORY).feeTo();
        if (feeTo == address(0)) return 0;
        uint256 kLast = IUniswapV2PairFork(PAIR).kLast();
        if (kLast == 0) return 0;
        uint256 rootK = Math.sqrt(reserve0 * reserve1);
        uint256 rootKLast = Math.sqrt(kLast);
        if (rootK <= rootKLast) return 0;
        return (totalSupply * (rootK - rootKLast)) / (rootK * 5 + rootKLast);
    }
}

/// @title UniswapV2BalanceOracle fork tests — multi-pool real holder (factory.feeTo recipient)
/// @notice Zero-drift verification against a real mainnet holder at a fresh block.
/// @dev    Picked via Dune query 7553459 (multi-pool Uni V2 LP holders, ordered by pair count).
///         The holder is the current value of `UniswapV2Factory.feeTo()` — the protocol-fee
///         recipient wallet — and holds non-zero LP in all 6 canonical V2 pairs simultaneously.
///         Because feeTo != address(0) at this block, the adapter's dilution branch is exercised
///         live (not via mocks). Expected amounts are derived from the same `_pendingProtocolMint`
///         formula implemented in src/balances/protocols/UniswapV2.sol; evidence pack lives at
///         script/development/test/uniswapV2/case-multi-pool-mainnet.json.
contract UniswapV2BalanceOracleForkTest_MultiPool_FeeReceiver is BalanceAdapterTestBase {
    address public constant HOLDER = 0xf38521f130fcCF29dB1961597bc5d2B60F995f85;
    address public constant V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    uint256 public constant FORK_BLOCK = 25_144_444;

    struct PoolCase {
        string label;
        address pair;
        address token0;
        address token1;
        uint256 expected0;
        uint256 expected1;
        UniswapV2BalanceOracle adapter;
    }

    PoolCase[6] public cases;

    function setUp() public override {
        super.setUp();
        _setupFork();
        _seedCases();
        _deployAdapters();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    /// @dev Expected amounts are dilution-adjusted per `_pendingProtocolMint` at FORK_BLOCK.
    ///      Computed off-chain via the Python helper `script/development/test/uniswapV2/`
    ///      using arbitrary-precision integers; mirrored here as constants so the test stays
    ///      self-contained. Any change in on-chain state at FORK_BLOCK invalidates these.
    function _seedCases() internal {
        cases[0] = PoolCase({
            label: "USDC_WETH",
            pair: 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc,
            token0: MAINNET_USDC,
            token1: MAINNET_WETH,
            expected0: 74_259_143,
            expected1: 35_066_111_262_254_964,
            adapter: UniswapV2BalanceOracle(address(0))
        });
        cases[1] = PoolCase({
            label: "USDT_WETH",
            pair: 0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852,
            token0: MAINNET_WETH,
            token1: MAINNET_USDT,
            expected0: 34_371_817_334_190_102,
            expected1: 72_841_301,
            adapter: UniswapV2BalanceOracle(address(0))
        });
        cases[2] = PoolCase({
            label: "DAI_WETH",
            pair: 0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11,
            token0: MAINNET_DAI,
            token1: MAINNET_WETH,
            expected0: 36_218_518_466_527_858_189,
            expected1: 17_105_149_103_443_307,
            adapter: UniswapV2BalanceOracle(address(0))
        });
        cases[3] = PoolCase({
            label: "WBTC_WETH",
            pair: 0xBb2b8038a1640196FbE3e38816F3e67Cba72D940,
            token0: MAINNET_WBTC,
            token1: MAINNET_WETH,
            expected0: 59_860,
            expected1: 21_711_539_995_652_021,
            adapter: UniswapV2BalanceOracle(address(0))
        });
        cases[4] = PoolCase({
            label: "USDC_USDT",
            pair: 0x3041CbD36888bECc7bbCBc0045E3B1f144466f5f,
            token0: MAINNET_USDC,
            token1: MAINNET_USDT,
            expected0: 72_501,
            expected1: 72_670,
            adapter: UniswapV2BalanceOracle(address(0))
        });
        cases[5] = PoolCase({
            label: "DAI_USDC",
            pair: 0xAE461cA67B15dc8dc81CE7615e0320dA1A9aB8D5,
            token0: MAINNET_DAI,
            token1: MAINNET_USDC,
            expected0: 12_470_607_855_679_992_115,
            expected1: 12_499_207,
            adapter: UniswapV2BalanceOracle(address(0))
        });
    }

    function _deployAdapters() internal {
        // Single Balances harness registered with every unique underlying token across the 6 pools.
        address[] memory assets = new address[](5);
        assets[0] = MAINNET_USDC;
        assets[1] = MAINNET_WETH;
        assets[2] = MAINNET_DAI;
        assets[3] = MAINNET_USDT;
        assets[4] = MAINNET_WBTC;
        balances = _deployBalancesForOracle(assets);

        for (uint256 i = 0; i < cases.length; i++) {
            cases[i].adapter = new UniswapV2BalanceOracle(
                cases[i].pair, "Uniswap V2", "{\"protocol\":\"Uniswap V2\",\"pool\":\"LP\"", "0x0", address(balances)
            );
        }
    }

    // ============================================
    // Setup invariants
    // ============================================

    /// @notice Pre-flight check: the chosen holder IS the factory's current fee recipient.
    /// @dev If this assertion fails, the dilution branch may no longer be active live and the
    ///      whole case needs re-derivation against a new block / new holder.
    function test_holder_is_factory_feeTo() public view {
        assertEq(IUniswapV2FactoryFork(V2_FACTORY).feeTo(), HOLDER, "holder must be factory.feeTo");
    }

    /// @notice Confirms the dilution branch is exercised in this case.
    /// @dev Each pool's pendingProtocolMint computed off-chain is non-zero — if any drift to zero,
    ///      the test is no longer testing what it claims to. Re-derive the case.
    function test_dilution_branch_active_each_pool() public view {
        for (uint256 i = 0; i < cases.length; i++) {
            uint256 ts = IUniswapV2PairFork(cases[i].pair).totalSupply();
            (uint112 r0, uint112 r1,) = IUniswapV2PairFork(cases[i].pair).getReserves();
            uint256 kLast = IUniswapV2PairFork(cases[i].pair).kLast();
            uint256 rootK = Math.sqrt(uint256(r0) * uint256(r1));
            uint256 rootKLast = Math.sqrt(kLast);
            assertGt(rootK, rootKLast, _msg(cases[i].label, "sqrt(k_now) must exceed sqrt(kLast)"));
            uint256 pending = (ts * (rootK - rootKLast)) / (rootK * 5 + rootKLast);
            assertGt(pending, 0, _msg(cases[i].label, "pendingProtocolMint must be non-zero"));
        }
    }

    // ============================================
    // Strict-equality assertions (the audit-grade core)
    // ============================================

    /// @notice The adapter's `getOracleBalanceForAsset` must return EXACTLY the dilution-adjusted
    ///         amount per pool, per token, with no drift. This is the same number Uniswap V2's
    ///         own `pair.burn(HOLDER)` would transfer at this block.
    function test_strict_equality_per_pool_token0() public view {
        for (uint256 i = 0; i < cases.length; i++) {
            (uint256 amt0, bool isDebt) = cases[i].adapter.getOracleBalanceForAsset(HOLDER, cases[i].token0);
            assertEq(amt0, cases[i].expected0, _msg(cases[i].label, "token0 amount mismatch"));
            assertFalse(isDebt, _msg(cases[i].label, "token0 must not be debt"));
        }
    }

    function test_strict_equality_per_pool_token1() public view {
        for (uint256 i = 0; i < cases.length; i++) {
            (uint256 amt1, bool isDebt) = cases[i].adapter.getOracleBalanceForAsset(HOLDER, cases[i].token1);
            assertEq(amt1, cases[i].expected1, _msg(cases[i].label, "token1 amount mismatch"));
            assertFalse(isDebt, _msg(cases[i].label, "token1 must not be debt"));
        }
    }

    /// @notice `getOracleBalances` must aggregate token0+token1 per adapter and surface both with
    ///         the exact dilution-adjusted amounts, in the order [token0, token1].
    function test_strict_equality_via_getOracleBalances() public view {
        for (uint256 i = 0; i < cases.length; i++) {
            (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) =
                cases[i].adapter.getOracleBalances(HOLDER);
            assertEq(assets.length, 2, _msg(cases[i].label, "must emit both tokens"));
            assertEq(assets[0], cases[i].token0, _msg(cases[i].label, "assets[0] should be token0"));
            assertEq(assets[1], cases[i].token1, _msg(cases[i].label, "assets[1] should be token1"));
            assertEq(amounts[0], cases[i].expected0, _msg(cases[i].label, "amounts[0] mismatch"));
            assertEq(amounts[1], cases[i].expected1, _msg(cases[i].label, "amounts[1] mismatch"));
            assertFalse(isDebt[0], _msg(cases[i].label, "isDebt[0] must be false"));
            assertFalse(isDebt[1], _msg(cases[i].label, "isDebt[1] must be false"));
        }
    }

    /// @notice `getOraclePositions` (multi-leg surface) must mirror `getOracleBalances` here —
    ///         Uniswap V2 has no `type` discriminator (single Supply leg per pair), so the
    ///         position count equals the number of underlying tokens with a non-zero amount.
    function test_strict_equality_via_getOraclePositions() public view {
        for (uint256 i = 0; i < cases.length; i++) {
            INAVCalculator.PositionBalance[] memory positions = cases[i].adapter.getOraclePositions(HOLDER, address(0));
            assertEq(positions.length, 2, _msg(cases[i].label, "expect 2 positions per pair"));
            bool saw0;
            bool saw1;
            for (uint256 j = 0; j < positions.length; j++) {
                assertEq(positions[j].balanceOracle, address(cases[i].adapter), _msg(cases[i].label, "balanceOracle"));
                assertFalse(positions[j].isDebt, _msg(cases[i].label, "isDebt"));
                if (positions[j].underlyingAsset.asset == cases[i].token0) {
                    assertEq(positions[j].amount, cases[i].expected0, _msg(cases[i].label, "token0 via positions"));
                    saw0 = true;
                }
                if (positions[j].underlyingAsset.asset == cases[i].token1) {
                    assertEq(positions[j].amount, cases[i].expected1, _msg(cases[i].label, "token1 via positions"));
                    saw1 = true;
                }
            }
            assertTrue(saw0, _msg(cases[i].label, "token0 position missing"));
            assertTrue(saw1, _msg(cases[i].label, "token1 position missing"));
        }
    }

    function _msg(string memory label, string memory tail) internal pure returns (string memory) {
        return string(abi.encodePacked("[", label, "] ", tail));
    }
}
