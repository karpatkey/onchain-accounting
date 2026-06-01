// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {CurveBalanceOracle} from "src/balances/protocols/Curve.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal Curve gauge mock (returns lp_token and staked balances)
contract MockCurveGauge {
    address private _lpToken;
    mapping(address => uint256) public balanceOf;
    uint256 public rewardCount;
    mapping(uint256 => address) public rewardTokens;

    constructor(address lpToken_) {
        _lpToken = lpToken_;
    }

    // solhint-disable-next-line func-name-mixedcase
    function lp_token() external view returns (address) {
        return _lpToken;
    }

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function setRewardToken(uint256 index, address token) external {
        rewardTokens[index] = token;
        if (index >= rewardCount) rewardCount = index + 1;
    }

    // reward_count and reward_tokens use snake_case per Curve convention
    // solhint-disable-next-line func-name-mixedcase
    function reward_count() external view returns (uint256) {
        return rewardCount;
    }

    // solhint-disable-next-line func-name-mixedcase
    function reward_tokens(uint256 index) external view returns (address) {
        return rewardTokens[index];
    }

    // solhint-disable-next-line func-name-mixedcase
    function claimable_reward(address, address) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Minimal Curve LP token mock (2-token pool)
contract MockCurveLPToken {
    address private _token0;
    address private _token1;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => uint256) private _poolBalance;

    constructor(address token0_, address token1_) {
        _token0 = token0_;
        _token1 = token1_;
        totalSupply = 1_000e18;
        _poolBalance[0] = 500e18;
        _poolBalance[1] = 500e18;
    }

    function coins(uint256 index) external view returns (address) {
        if (index == 0) return _token0;
        if (index == 1) return _token1;
        revert("out of range");
    }

    function balances(uint256 index) external view returns (uint256) {
        return _poolBalance[index];
    }

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function setPoolBalance(uint256 index, uint256 amount) external {
        _poolBalance[index] = amount;
    }
}

/// @notice Minimal token mock
contract MockToken {
    string public symbol;
    uint8 public decimals = 18;

    constructor(string memory symbol_) {
        symbol = symbol_;
    }
}

/// @title CurveBalanceOracle unit tests (no fork)
contract CurveBalanceOracleTest is Test {
    MockBalances mockBalances;
    MockToken weth;
    MockToken weEth;
    MockCurveLPToken mockLpToken;
    MockCurveGauge mockGauge;
    CurveBalanceOracle oracle;

    address alice = makeAddr("alice");

    function setUp() public {
        mockBalances = new MockBalances();
        weth = new MockToken("WETH");
        weEth = new MockToken("weETH");
        mockLpToken = new MockCurveLPToken(address(weth), address(weEth));
        mockGauge = new MockCurveGauge(address(mockLpToken));
        oracle = new CurveBalanceOracle(address(mockGauge), address(mockBalances));
    }

    // ============================================
    // Constructor Tests
    // ============================================

    function test_constructor_invalidArgs_zeroGauge() public {
        vm.expectRevert(InvalidArguments.selector);
        new CurveBalanceOracle(address(0), address(mockBalances));
    }

    function test_constructor_invalidArgs_nonContractGauge() public {
        vm.expectRevert("Gauge must be a contract");
        new CurveBalanceOracle(address(0xdead), address(mockBalances));
    }

    function test_constructor_invalidArgs_nonContractNavCalculator() public {
        vm.expectRevert("NAVCalculator must be a contract");
        new CurveBalanceOracle(address(mockGauge), address(0xdead));
    }

    function test_constructor_stores_immutables() public view {
        assertEq(oracle.GAUGE(), address(mockGauge));
        assertEq(oracle.LP_TOKEN(), address(mockLpToken));
        assertEq(address(oracle.NAV_CALCULATOR()), address(mockBalances));
    }

    // ============================================
    // Interface Compliance Tests
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(bytes4(0xdeadbeef)));
    }

    // ============================================
    // underlyingAssetsSupported Tests
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        // pool tokens: WETH, weETH + CRV (always included) = 3
        assertEq(assets.length, 3);
        assertEq(assets[0], address(weth));
        assertEq(assets[1], address(weEth));
        // CRV at index 2 (canonical mainnet address)
        assertEq(assets[2], 0xD533a949740bb3306d119CC777fa900bA034cd52);
    }

    // ============================================
    // getOracleBalanceForAsset Tests
    // ============================================

    function test_getOracleBalanceForAsset_zeroAsset() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(0xdead));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_unknownAccount() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(weth));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_unstakedLP() public {
        // Alice holds 100/1000 LP (10%) → 10% × 500 WETH = 50 WETH
        mockLpToken.setBalance(alice, 100e18);
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(weth));
        assertEq(amount, 50e18);
    }

    function test_getOracleBalanceForAsset_stakedLP() public {
        // Alice has 200/1000 LP staked in gauge → 20% × 500 weETH = 100 weETH
        mockGauge.setBalance(alice, 200e18);
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(weEth));
        assertEq(amount, 100e18);
    }

    function test_getOracleBalanceForAsset_unstakedAndStaked() public {
        // Alice has 100 unstaked + 100 staked = 200/1000 (20%) → 100 WETH
        mockLpToken.setBalance(alice, 100e18);
        mockGauge.setBalance(alice, 100e18);
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(weth));
        assertEq(amount, 100e18);
    }

    // ============================================
    // getOracleBalances Tests
    // ============================================

    function test_getOracleBalances_unknownAccount() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(alice);
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_getOracleBalances_withPosition() public {
        // 100 unstaked LP → 10% of pool
        mockLpToken.setBalance(alice, 100e18);
        (address[] memory assets, uint256[] memory amounts,) = oracle.getOracleBalances(alice);
        // Should return WETH and weETH (50 each), CRV = 0 (no checkpoint) → skipped
        assertEq(assets.length, 2);
        assertEq(assets[0], address(weth));
        assertEq(amounts[0], 50e18);
        assertEq(assets[1], address(weEth));
        assertEq(amounts[1], 50e18);
    }

    // ============================================
    // getOraclePositions Tests
    // ============================================

    function test_getOraclePositions_unknownAccount_returnsEmpty() public view {
        // MockBalances.getRegisteredAssets() returns [] — intersection is empty
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));
        assertEq(positions.length, 0);
    }
}
