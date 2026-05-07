// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UniswapV2BalanceOracle} from "src/balances/protocols/UniswapV2.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal Uniswap V2 factory mock — settable `feeTo()`.
contract MockUniswapV2Factory {
    address public feeTo;

    function setFeeTo(address feeTo_) external {
        feeTo = feeTo_;
    }
}

/// @notice Minimal Uniswap V2 pair mock — settable reserves/supply/balances/kLast.
contract MockUniswapV2Pair {
    address public token0;
    address public token1;
    address public factory;
    uint112 private _reserve0;
    uint112 private _reserve1;
    uint32 private _blockTimestampLast;
    uint256 public totalSupply;
    uint256 public kLast;
    mapping(address => uint256) public balanceOf;

    constructor(address token0_, address token1_, address factory_) {
        token0 = token0_;
        token1 = token1_;
        factory = factory_;
    }

    function setReserves(uint112 r0, uint112 r1) external {
        _reserve0 = r0;
        _reserve1 = r1;
        _blockTimestampLast = uint32(block.timestamp);
    }

    function setTotalSupply(uint256 ts) external {
        totalSupply = ts;
    }

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function setKLast(uint256 k) external {
        kLast = k;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (_reserve0, _reserve1, _blockTimestampLast);
    }
}

/// @notice ERC20-ish stub providing only what the adapter looks at via the registry path.
contract MockToken {
    string public symbol;
    uint8 public decimals = 18;

    constructor(string memory symbol_) {
        symbol = symbol_;
    }
}

/// @title UniswapV2BalanceOracle unit tests (no fork).
contract UniswapV2BalanceOracleTest is Test {
    MockBalances mockBalances;
    MockUniswapV2Factory mockFactory;
    MockUniswapV2Pair mockPair;
    MockToken token0;
    MockToken token1;
    UniswapV2BalanceOracle oracle;

    address alice = makeAddr("alice");
    address feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        mockBalances = new MockBalances();
        mockFactory = new MockUniswapV2Factory();
        token0 = new MockToken("TKN0");
        token1 = new MockToken("TKN1");
        mockPair = new MockUniswapV2Pair(address(token0), address(token1), address(mockFactory));
        oracle = new UniswapV2BalanceOracle(
            address(mockPair),
            "Uniswap V2",
            "{\"protocol\":\"Uniswap V2\",\"pool\":\"T0/T1\"",
            "0x0000000000000000000000000000000000000001",
            address(mockBalances)
        );
    }

    // ============================================
    // Constructor Tests
    // ============================================

    function test_constructor_invalidArgs_zeroPair() public {
        vm.expectRevert(InvalidArguments.selector);
        new UniswapV2BalanceOracle(
            address(0),
            "Uniswap V2",
            "{\"protocol\":\"Uniswap V2\",\"pool\":\"T0/T1\"",
            "0x0000000000000000000000000000000000000001",
            address(mockBalances)
        );
    }

    function test_constructor_invalidArgs_nonContractPair() public {
        vm.expectRevert("Pair must be a contract");
        new UniswapV2BalanceOracle(
            address(0xdead),
            "Uniswap V2",
            "{\"protocol\":\"Uniswap V2\",\"pool\":\"T0/T1\"",
            "0x0000000000000000000000000000000000000001",
            address(mockBalances)
        );
    }

    function test_constructor_invalidArgs_nonContractNavCalculator() public {
        vm.expectRevert("NAVCalculator must be a contract");
        new UniswapV2BalanceOracle(
            address(mockPair),
            "Uniswap V2",
            "{\"protocol\":\"Uniswap V2\",\"pool\":\"T0/T1\"",
            "0x0000000000000000000000000000000000000001",
            address(0xdead)
        );
    }

    function test_constructor_zeroToken_reverts() public {
        // Pair where token0 == address(0): constructor must reject.
        MockUniswapV2Pair badPair = new MockUniswapV2Pair(address(0), address(token1), address(mockFactory));
        vm.expectRevert("Pair tokens must be non-zero");
        new UniswapV2BalanceOracle(
            address(badPair),
            "Uniswap V2",
            "{\"protocol\":\"Uniswap V2\",\"pool\":\"T0/T1\"",
            "0x0000000000000000000000000000000000000001",
            address(mockBalances)
        );
    }

    function test_constructor_identicalTokens_reverts() public {
        MockUniswapV2Pair badPair = new MockUniswapV2Pair(address(token0), address(token0), address(mockFactory));
        vm.expectRevert("Pair tokens must differ");
        new UniswapV2BalanceOracle(
            address(badPair),
            "Uniswap V2",
            "{\"protocol\":\"Uniswap V2\",\"pool\":\"T0/T1\"",
            "0x0000000000000000000000000000000000000001",
            address(mockBalances)
        );
    }

    function test_constructor_stores_immutables() public view {
        assertEq(oracle.PAIR(), address(mockPair));
        assertEq(oracle.TOKEN0(), address(token0));
        assertEq(oracle.TOKEN1(), address(token1));
        assertEq(oracle.FACTORY(), address(mockFactory));
        assertEq(address(oracle.NAV_CALCULATOR()), address(mockBalances));
    }

    // ============================================
    // Interface Compliance
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(bytes4(0xdeadbeef)));
    }

    // ============================================
    // underlyingAssetsSupported
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 2);
        assertEq(assets[0], address(token0));
        assertEq(assets[1], address(token1));
    }

    // ============================================
    // getOracleBalanceForAsset — guards
    // ============================================

    function test_getOracleBalanceForAsset_zeroAsset() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_zeroAccount() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(address(0), address(token0));
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(0xdead));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_unknownAccount() public {
        // Pool is set up but Alice has 0 LP balance.
        mockPair.setReserves(1000e18, 2000e6);
        mockPair.setTotalSupply(1_000e18);
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(token0));
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_zeroTotalSupply() public {
        // totalSupply == 0 → no LP → 0
        mockPair.setBalance(alice, 100e18);
        mockPair.setReserves(1000e18, 2000e6);
        mockPair.setTotalSupply(0);
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(token0));
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_zeroReserve() public {
        // Reserve for the queried side is 0 → 0
        mockPair.setBalance(alice, 100e18);
        mockPair.setReserves(0, 2000e6);
        mockPair.setTotalSupply(1_000e18);
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(token0));
        assertEq(amount, 0);
    }

    // ============================================
    // getOracleBalanceForAsset — math (feeTo unset → naive pro-rata)
    // ============================================

    function test_getOracleBalanceForAsset_naive_token0() public {
        // Alice owns 100/1000 LP (10%) → 10% × 1000 token0 = 100 token0
        mockPair.setBalance(alice, 100e18);
        mockPair.setReserves(1000e18, 2000e6);
        mockPair.setTotalSupply(1_000e18);
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(token0));
        assertEq(amount, 100e18);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_naive_token1() public {
        // Alice owns 100/1000 LP → 10% × 2000e6 token1 = 200e6 token1
        mockPair.setBalance(alice, 100e18);
        mockPair.setReserves(1000e18, 2000e6);
        mockPair.setTotalSupply(1_000e18);
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(token1));
        assertEq(amount, 200e6);
    }

    function test_getOracleBalanceForAsset_naive_feeToUnset_kLastNonzero() public {
        // feeTo == 0 → pendingMint = 0 even if kLast is non-zero.
        mockPair.setBalance(alice, 100e18);
        mockPair.setReserves(2000e18, 2000e6);
        mockPair.setTotalSupply(1_000e18);
        mockPair.setKLast(1_000e18 * 1_000e6); // a stale snapshot < current k
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(token0));
        // No dilution → 10% × 2000 = 200
        assertEq(amount, 200e18);
    }

    // ============================================
    // getOracleBalanceForAsset — math (feeTo set, dilution)
    // ============================================

    function test_getOracleBalanceForAsset_feeToSet_kLastZero_noDilution() public {
        // Per Uniswap V2 _mintFee: kLast == 0 → no protocol mint, even if feeTo is set.
        mockFactory.setFeeTo(feeRecipient);
        mockPair.setBalance(alice, 100e18);
        mockPair.setReserves(1000e18, 2000e6);
        mockPair.setTotalSupply(1_000e18);
        mockPair.setKLast(0);
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(token0));
        assertEq(amount, 100e18);
    }

    function test_getOracleBalanceForAsset_feeToSet_kEqKLast_noDilution() public {
        // √k <= √kLast → no protocol mint.
        mockFactory.setFeeTo(feeRecipient);
        mockPair.setBalance(alice, 100e18);
        mockPair.setReserves(1000e18, 2000e6);
        mockPair.setTotalSupply(1_000e18);
        mockPair.setKLast(1000e18 * 2000e6);
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(token0));
        assertEq(amount, 100e18);
    }

    function test_getOracleBalanceForAsset_feeToSet_kGtKLast_dilutes() public {
        // Dilution branch: kLast was 1000 × 1000, current is 2000 × 2000 (k doubled, √k went 1000→2000).
        // ts = 1_000e18, rootK − rootKLast scales (within fixed precision after sqrt).
        // We assert the result is strictly less than the naive pro-rata.
        mockFactory.setFeeTo(feeRecipient);
        uint256 lpBalance = 100e18;
        mockPair.setBalance(alice, lpBalance);
        uint112 r0 = 2_000e18;
        uint112 r1 = 2_000e18;
        uint256 ts = 1_000e18;
        uint256 kLast = 1_000e18 * 1_000e18;
        mockPair.setReserves(r0, r1);
        mockPair.setTotalSupply(ts);
        mockPair.setKLast(kLast);

        // Hand-compute expected dilution-adjusted amount.
        uint256 rootK = Math.sqrt(uint256(r0) * uint256(r1));
        uint256 rootKLast = Math.sqrt(kLast);
        uint256 pendingMint = (ts * (rootK - rootKLast)) / (rootK * 5 + rootKLast);
        uint256 expected = (lpBalance * uint256(r0)) / (ts + pendingMint);

        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(token0));
        assertEq(amount, expected, "dilution-adjusted amount must match _mintFee math");

        // Sanity: the dilution-adjusted amount is strictly less than naive pro-rata.
        uint256 naive = (lpBalance * uint256(r0)) / ts;
        assertLt(amount, naive, "must be strictly less than naive pro-rata when feeTo set + k grew");
    }

    function test_getOracleBalanceForAsset_factoryWithoutFeeTo_treatsAsUnset() public {
        // V2 forks that omit (or revert on) the `feeTo()` getter must be treated as fee-disabled.
        // Simulate by making the factory revert on `feeTo()`.
        vm.mockCallRevert(address(mockFactory), abi.encodeWithSignature("feeTo()"), "");

        mockPair.setBalance(alice, 100e18);
        mockPair.setReserves(2000e18, 2000e18);
        mockPair.setTotalSupply(1_000e18);
        mockPair.setKLast(1_000e18 * 1_000e18); // would dilute if feeTo were set
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(token0));
        // No dilution (feeTo() reverts → treated as 0) → naive 10% × 2000 = 200
        assertEq(amount, 200e18);
    }

    function test_getOracleBalanceForAsset_pairWithoutKLast_treatsAsFeeDisabled() public {
        // V2 forks that omit (or revert on) the `kLast()` getter must be treated as fee-disabled
        // (no dilution adjustment), even when `factory.feeTo()` is non-zero.
        mockFactory.setFeeTo(feeRecipient);
        vm.mockCallRevert(address(mockPair), abi.encodeWithSignature("kLast()"), "");

        mockPair.setBalance(alice, 100e18);
        mockPair.setReserves(2000e18, 2000e18);
        mockPair.setTotalSupply(1_000e18);
        // (No `setKLast` — it would be ignored anyway since the call is mocked to revert.)

        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(token0));
        // No dilution (kLast() reverts → pendingMint = 0) → naive 10% × 2000 = 200
        assertEq(amount, 200e18);
    }

    // ============================================
    // getOracleBalances
    // ============================================

    function test_getOracleBalances_zeroAccount() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(address(0));
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_getOracleBalances_unknownAccount() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(alice);
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_getOracleBalances_withPosition() public {
        mockPair.setBalance(alice, 100e18);
        mockPair.setReserves(1000e18, 2000e6);
        mockPair.setTotalSupply(1_000e18);
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(alice);
        assertEq(assets.length, 2);
        assertEq(assets[0], address(token0));
        assertEq(amounts[0], 100e18);
        assertFalse(isDebt[0]);
        assertEq(assets[1], address(token1));
        assertEq(amounts[1], 200e6);
        assertFalse(isDebt[1]);
    }

    // ============================================
    // getOraclePositions — registry-empty path (only path exercisable via MockBalances)
    // ============================================

    function test_getOraclePositions_emptyRegistry_returnsEmpty() public view {
        // MockBalances.getRegisteredAssets() returns [] → intersection is empty → length 0.
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));
        assertEq(positions.length, 0);
    }

    function test_getOraclePositions_zeroAccount_returnsEmpty() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(address(0), address(0));
        assertEq(positions.length, 0);
    }

    function test_getOraclePositions_assetFilterUnsupported_returnsEmpty() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0xdead));
        assertEq(positions.length, 0);
    }
}
