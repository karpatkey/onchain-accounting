// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ConvexBalanceOracle} from "src/balances/protocols/Convex.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal Curve LP token mock for Convex tests
contract MockCurveLPToken {
    address private _token0;
    address private _token1;
    uint256 public totalSupply;
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
}

/// @notice Minimal extra rewarder mock (direct ERC20 reward)
contract MockExtraRewarder {
    address private _rewardToken;
    mapping(address => uint256) private _earned;

    constructor(address rewardToken_) {
        _rewardToken = rewardToken_;
    }

    function rewardToken() external view returns (address) {
        return _rewardToken;
    }

    function earned(address account) external view returns (uint256) {
        return _earned[account];
    }

    function setEarned(address account, uint256 amount) external {
        _earned[account] = amount;
    }
}

/// @notice Minimal Convex main rewarder mock
contract MockConvexRewarder {
    address private _rewardToken;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) private _earned;
    address[] private _extraRewarders;

    constructor(address rewardToken_) {
        _rewardToken = rewardToken_;
    }

    function rewardToken() external view returns (address) {
        return _rewardToken;
    }

    function earned(address account) external view returns (uint256) {
        return _earned[account];
    }

    function extraRewardsLength() external view returns (uint256) {
        return _extraRewarders.length;
    }

    function extraRewards(uint256 index) external view returns (address) {
        return _extraRewarders[index];
    }

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function setEarned(address account, uint256 amount) external {
        _earned[account] = amount;
    }

    function addExtraRewarder(address rewarder) external {
        _extraRewarders.push(rewarder);
    }
}

/// @notice Minimal ERC20 mock (for CRV, CVX mock token)
contract MockToken {
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;

    constructor(string memory symbol_, uint256 totalSupply_) {
        symbol = symbol_;
        totalSupply = totalSupply_;
    }
}

/// @title ConvexBalanceOracle unit tests (no fork)
contract ConvexBalanceOracleTest is Test {
    MockBalances mockBalances;
    MockToken usdt;
    MockToken crvUsd;
    MockToken crv;
    MockToken cvx;
    MockCurveLPToken mockLpToken;
    MockConvexRewarder mockRewarder;
    ConvexBalanceOracle oracle;

    address alice = makeAddr("alice");

    function setUp() public {
        mockBalances = new MockBalances();
        usdt = new MockToken("USDT", 0);
        crvUsd = new MockToken("crvUSD", 0);
        crv = new MockToken("CRV", 0);
        // CVX total supply: below first cliff so mint is non-zero
        cvx = new MockToken("CVX", 1_000_000e18);
        mockLpToken = new MockCurveLPToken(address(usdt), address(crvUsd));
        mockRewarder = new MockConvexRewarder(address(crv));
        oracle = new ConvexBalanceOracle(
            address(mockRewarder), address(mockLpToken), "Convex", "crvUSD/USDT Pool", address(mockBalances)
        );
    }

    // ============================================
    // Constructor Tests
    // ============================================

    function test_constructor_invalidArgs_zeroRewarder() public {
        vm.expectRevert(InvalidArguments.selector);
        new ConvexBalanceOracle(address(0), address(mockLpToken), "Convex", "crvUSD/USDT Pool", address(mockBalances));
    }

    function test_constructor_invalidArgs_zeroLpToken() public {
        vm.expectRevert(InvalidArguments.selector);
        new ConvexBalanceOracle(address(mockRewarder), address(0), "Convex", "crvUSD/USDT Pool", address(mockBalances));
    }

    function test_constructor_invalidArgs_nonContractRewarder() public {
        vm.expectRevert("Rewarder must be a contract");
        new ConvexBalanceOracle(
            address(0xdead), address(mockLpToken), "Convex", "crvUSD/USDT Pool", address(mockBalances)
        );
    }

    function test_constructor_invalidArgs_nonContractNavCalculator() public {
        vm.expectRevert("NAVCalculator must be a contract");
        new ConvexBalanceOracle(address(mockRewarder), address(mockLpToken), "Convex", "crvUSD/USDT Pool", address(0xdead));
    }

    function test_constructor_stores_immutables() public view {
        assertEq(oracle.REWARDER(), address(mockRewarder));
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

    function test_underlyingAssetsSupported_noExtraRewards() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        // pool tokens: USDT, crvUSD + main reward: CRV = 3
        assertEq(assets.length, 3);
        assertEq(assets[0], address(usdt));
        assertEq(assets[1], address(crvUsd));
        assertEq(assets[2], address(crv));
    }

    function test_underlyingAssetsSupported_withExtraReward() public {
        MockExtraRewarder extra = new MockExtraRewarder(address(cvx));
        mockRewarder.addExtraRewarder(address(extra));

        address[] memory assets = oracle.underlyingAssetsSupported();
        // USDT, crvUSD, CRV, CVX = 4
        assertEq(assets.length, 4);
        assertEq(assets[3], address(cvx));
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
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(usdt));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_stakedLP_poolToken() public {
        // Alice has 100/1000 LP staked → 10% × 500 USDT = 50 USDT
        mockRewarder.setBalance(alice, 100e18);
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(usdt));
        assertEq(amount, 50e18);
    }

    function test_getOracleBalanceForAsset_mainReward() public {
        // Alice has 100 CRV earned
        mockRewarder.setEarned(alice, 100e18);
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(crv));
        assertEq(amount, 100e18);
    }

    function test_getOracleBalanceForAsset_extraReward() public {
        MockExtraRewarder extra = new MockExtraRewarder(address(cvx));
        extra.setEarned(alice, 50e18);
        mockRewarder.addExtraRewarder(address(extra));

        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(cvx));
        assertEq(amount, 50e18);
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

    function test_getOracleBalances_withStakedPosition() public {
        // 100 staked LP → 10% of pool: 50 USDT + 50 crvUSD
        mockRewarder.setBalance(alice, 100e18);
        (address[] memory assets, uint256[] memory amounts,) = oracle.getOracleBalances(alice);
        assertEq(assets.length, 2);
        assertEq(assets[0], address(usdt));
        assertEq(amounts[0], 50e18);
        assertEq(assets[1], address(crvUsd));
        assertEq(amounts[1], 50e18);
    }

    // ============================================
    // getOraclePositions Tests
    // ============================================

    function test_getOraclePositions_unknownAccount_returnsEmpty() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));
        assertEq(positions.length, 0);
    }
}
