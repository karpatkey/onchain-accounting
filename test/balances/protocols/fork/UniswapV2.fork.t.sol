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
        oracle = new UniswapV2BalanceOracle(PAIR, address(balances));
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
            assertFalse(positions[i].isDebt);
            assertGt(positions[i].amount, 0);
            if (positions[i].balanceAsset.asset == USDC) sawUsdc = true;
            if (positions[i].balanceAsset.asset == WETH) sawWeth = true;
        }
        assertTrue(sawUsdc, "USDC position present");
        assertTrue(sawWeth, "WETH position present");
    }

    function test_getOraclePositions_assetFilter_usdc() public {
        deal(PAIR, alice, 1e15);
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, USDC);
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, USDC);
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
