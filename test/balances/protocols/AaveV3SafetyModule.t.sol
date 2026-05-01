// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {AaveV3SafetyModuleBalanceOracle} from "src/balances/protocols/AaveV3SafetyModule.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Mock stake token. Returns the staked / reward token addresses queried at registration,
///         and supports the balance / rewards reads used by the adapter under test.
contract MockStakeToken {
    address public immutable REWARD_TOKEN;
    address public immutable STAKED_TOKEN;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public rewards;
    uint256 public exchangeRateBps = 10_000; // 1:1 by default

    constructor(address rewardToken_, address stakedToken_) {
        REWARD_TOKEN = rewardToken_;
        STAKED_TOKEN = stakedToken_;
    }

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function setRewards(address account, uint256 amount) external {
        rewards[account] = amount;
    }

    function setExchangeRateBps(uint256 bps) external {
        exchangeRateBps = bps;
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return shares * exchangeRateBps / 10_000;
    }

    function getTotalRewardsBalance(address staker) external view returns (uint256) {
        return rewards[staker];
    }
}

/// @title AaveV3SafetyModuleBalanceOracleTest
/// @notice Unit tests for the multi-token AaveV3SafetyModuleBalanceOracle adapter (mocks only, no fork).
contract AaveV3SafetyModuleBalanceOracleTest is BalanceAdapterTestBase {
    AaveV3SafetyModuleBalanceOracle public oracle;
    MockStakeToken public stkUsdc; // staked = usdc, reward = dai
    MockStakeToken public stkDai; // staked = dai,  reward = dai (same-token case)

    address public adminAddr = makeAddr("smAdmin");

    function setUp() public override {
        super.setUp();

        stkUsdc = new MockStakeToken(address(dai), address(usdc)); // staked usdc, reward dai
        stkDai = new MockStakeToken(address(dai), address(dai)); // staked dai,  reward dai (same)

        AaveV3SafetyModuleBalanceOracle.StakeTokenInit[] memory init =
            new AaveV3SafetyModuleBalanceOracle.StakeTokenInit[](2);
        init[0] =
            AaveV3SafetyModuleBalanceOracle.StakeTokenInit({stakeToken: address(stkUsdc), positionDetail: "stkUSDC"});
        init[1] =
            AaveV3SafetyModuleBalanceOracle.StakeTokenInit({stakeToken: address(stkDai), positionDetail: "stkDAI"});

        oracle = new AaveV3SafetyModuleBalanceOracle(init, adminAddr, address(balances), "Aave V3 Safety Module");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    function test_constructor_pinsImmutables() public view {
        assertEq(address(oracle.NAV_CALCULATOR()), address(balances));
        assertEq(oracle.PROTOCOL(), "Aave V3 Safety Module");
        assertEq(oracle.owner(), adminAddr);
        assertEq(oracle.stakeTokenCount(), 2);
    }

    function test_constructor_acceptsEmptyInitial() public {
        AaveV3SafetyModuleBalanceOracle.StakeTokenInit[] memory empty =
            new AaveV3SafetyModuleBalanceOracle.StakeTokenInit[](0);
        AaveV3SafetyModuleBalanceOracle o =
            new AaveV3SafetyModuleBalanceOracle(empty, adminAddr, address(balances), "Aave V3 Safety Module");
        assertEq(o.stakeTokenCount(), 0);
    }

    function test_constructor_revertsOnZeroAdmin() public {
        AaveV3SafetyModuleBalanceOracle.StakeTokenInit[] memory empty =
            new AaveV3SafetyModuleBalanceOracle.StakeTokenInit[](0);
        // OZ Ownable rejects zero owner with its own error before our InvalidArguments fires.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new AaveV3SafetyModuleBalanceOracle(empty, address(0), address(balances), "x");
    }

    function test_constructor_revertsOnZeroNavCalculator() public {
        AaveV3SafetyModuleBalanceOracle.StakeTokenInit[] memory empty =
            new AaveV3SafetyModuleBalanceOracle.StakeTokenInit[](0);
        vm.expectRevert(InvalidArguments.selector);
        new AaveV3SafetyModuleBalanceOracle(empty, adminAddr, address(0), "x");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // addStakeToken / removeStakeToken
    // ─────────────────────────────────────────────────────────────────────────

    function test_addStakeToken_onlyOwner() public {
        MockStakeToken stk = new MockStakeToken(address(dai), address(weth));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        oracle.addStakeToken(address(stk), "stkWETH");
    }

    function test_addStakeToken_pinsStakedAndRewardFromContract() public {
        MockStakeToken stk = new MockStakeToken(address(dai), address(weth));
        vm.prank(adminAddr);
        oracle.addStakeToken(address(stk), "stkWETH");

        (address stakedToken, address rewardToken, string memory positionDetail) = oracle.stakeTokenInfo(address(stk));
        assertEq(stakedToken, address(weth));
        assertEq(rewardToken, address(dai));
        assertEq(positionDetail, "stkWETH");
        assertTrue(oracle.isStakeTokenRegistered(address(stk)));
        assertEq(oracle.stakeTokenCount(), 3);
    }

    function test_addStakeToken_rejectsDuplicate() public {
        vm.prank(adminAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV3SafetyModuleBalanceOracle.StakeTokenAlreadyRegistered.selector, address(stkUsdc)
            )
        );
        oracle.addStakeToken(address(stkUsdc), "again");
    }

    function test_addStakeToken_rejectsZeroAddress() public {
        vm.prank(adminAddr);
        vm.expectRevert(InvalidArguments.selector);
        oracle.addStakeToken(address(0), "zero");
    }

    function test_addStakeToken_rejectsNonContract() public {
        vm.prank(adminAddr);
        vm.expectRevert(); // require message; selector check unnecessary
        oracle.addStakeToken(makeAddr("eoa"), "eoa");
    }

    function test_addStakeToken_rejectsZeroStakedOrRewardToken() public {
        MockStakeToken bad = new MockStakeToken(address(0), address(weth));
        vm.prank(adminAddr);
        vm.expectRevert(InvalidArguments.selector);
        oracle.addStakeToken(address(bad), "bad");
    }

    function test_removeStakeToken_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        oracle.removeStakeToken(address(stkUsdc));
    }

    function test_removeStakeToken_swapAndPopKeepsListConsistent() public {
        // Initial list: [stkUsdc, stkDai]. Remove stkUsdc → expect list [stkDai].
        vm.prank(adminAddr);
        oracle.removeStakeToken(address(stkUsdc));
        assertFalse(oracle.isStakeTokenRegistered(address(stkUsdc)));
        assertTrue(oracle.isStakeTokenRegistered(address(stkDai)));
        assertEq(oracle.stakeTokenCount(), 1);

        address[] memory list = oracle.getStakeTokens();
        assertEq(list.length, 1);
        assertEq(list[0], address(stkDai));
    }

    function test_removeStakeToken_canReAddAfterRemoval() public {
        vm.prank(adminAddr);
        oracle.removeStakeToken(address(stkUsdc));
        vm.prank(adminAddr);
        oracle.addStakeToken(address(stkUsdc), "stkUSDC-v2");
        (,, string memory positionDetail) = oracle.stakeTokenInfo(address(stkUsdc));
        assertEq(positionDetail, "stkUSDC-v2");
    }

    function test_removeStakeToken_rejectsUnregistered() public {
        address ghost = makeAddr("ghost");
        vm.prank(adminAddr);
        vm.expectRevert(abi.encodeWithSelector(AaveV3SafetyModuleBalanceOracle.StakeTokenNotRegistered.selector, ghost));
        oracle.removeStakeToken(ghost);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // underlyingAssetsSupported
    // ─────────────────────────────────────────────────────────────────────────

    function test_underlyingAssetsSupported_dedupesAcrossStakeTokens() public view {
        // stkUsdc → staked=usdc, reward=dai
        // stkDai  → staked=dai,  reward=dai (same)
        // Expect deduplicated union: [usdc, dai] (any order).
        address[] memory list = oracle.underlyingAssetsSupported();
        assertEq(list.length, 2);
        // Both must be present.
        bool sawUsdc;
        bool sawDai;
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == address(usdc)) sawUsdc = true;
            if (list[i] == address(dai)) sawDai = true;
        }
        assertTrue(sawUsdc);
        assertTrue(sawDai);
    }

    function test_underlyingAssetsSupported_emptyWhenNoStakeTokens() public {
        AaveV3SafetyModuleBalanceOracle.StakeTokenInit[] memory empty =
            new AaveV3SafetyModuleBalanceOracle.StakeTokenInit[](0);
        AaveV3SafetyModuleBalanceOracle o =
            new AaveV3SafetyModuleBalanceOracle(empty, adminAddr, address(balances), "x");
        assertEq(o.underlyingAssetsSupported().length, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // getOracleBalanceForAsset (sums across stake tokens)
    // ─────────────────────────────────────────────────────────────────────────

    function test_getOracleBalanceForAsset_returnsZeroForZeroAccount() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(address(0), address(usdc));
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_returnsZeroForZeroAsset() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_returnsZeroForUnsupportedAsset() public {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, makeAddr("notAnAsset"));
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_singleStake_stakedLeg() public {
        stkUsdc.setBalance(alice, 1000); // 1000 usdc staked, 1:1 redemption
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(usdc));
        assertEq(amount, 1000);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_sumsRewardsAcrossStakeTokens() public {
        // Both stkUsdc and stkDai pay rewards in DAI; they should sum.
        stkUsdc.setRewards(alice, 50);
        stkDai.setBalance(alice, 200); // dai staked
        stkDai.setRewards(alice, 30); // dai rewards
        // For DAI: stkUsdc rewards (50) + stkDai staked (200) + stkDai rewards (30) = 280
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(dai));
        assertEq(amount, 280);
    }

    function test_getOracleBalanceForAsset_appliesExchangeRate() public {
        // 10% bonus on redemption.
        stkUsdc.setExchangeRateBps(11_000);
        stkUsdc.setBalance(alice, 1000);
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(usdc));
        assertEq(amount, 1100);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // getOracleBalances
    // ─────────────────────────────────────────────────────────────────────────

    function test_getOracleBalances_zeroAccountReturnsEmptyArrays() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(address(0));
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_getOracleBalances_skipsZeroBalances() public {
        // Only set DAI rewards (via stkUsdc); USDC stays zero.
        stkUsdc.setRewards(alice, 42);
        (address[] memory assets, uint256[] memory amounts,) = oracle.getOracleBalances(alice);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(dai));
        assertEq(amounts[0], 42);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // getOraclePositions
    // ─────────────────────────────────────────────────────────────────────────

    function test_getOraclePositions_zeroAccountReturnsEmpty() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(address(0), address(0));
        assertEq(positions.length, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ERC165
    // ─────────────────────────────────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(bytes4(0xdeadbeef)));
    }
}
