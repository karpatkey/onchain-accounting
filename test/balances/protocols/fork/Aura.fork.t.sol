// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {TestSetupHelpers, BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {Aura} from "src/balances/protocols/Aura.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";

contract AuraTest is TestEnvConfigurator, TestSetupHelpers {
    Aura public oracle;
    // Tokens in the pool
    address public constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant BAL = 0xba100000625a3754423978a60c9317c58a424e3D;
    address public constant AURA = 0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF;
    // GHO/USDT/USDC Balancer V3 pool
    address public constant BOOSTER = 0xA57b8d98dAE62B26Ec3bcC4a365338157060B234;
    address public constant POOL = 0x85B2b559bC2D21104C4DEFdd6EFcA8A20343361D;
    address public constant USER = 0x849D52316331967b6fF1198e5E32A0eB168D039d;
    address public constant ROUTER = 0xb21A277466e7dB6934556a1Ce12eb3F032815c8A;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant GAUGE = 0x9fdD52eFEb601E4Bc78b89C6490505B8aC637E9f;
    uint256 public constant AURA_PID = 246;
    MockBalances mockBalances;
    BalancesHarnessForFork public balances;

    // Global user addresses with positions in Aura
    address public mainnetUser;
    address public mainnetUser2;
    address public testUser;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(22_131_922);
        mockBalances = new MockBalances();
        balances = _deployBalancesForOracle();
        oracle = new Aura(POOL, GAUGE, BOOSTER, AURA_PID, "Aura", "{\"protocol\":\"Aura\",\"pool\":\"Some Aura Pool\"", "0x0000000000000000000000000000000000000001", address(balances));
        assertTrue(oracle.IS_MAINNET(), "Mainnet fork should be detected as Mainnet");
        assertEq(oracle.AURA_TOKEN(), AURA, "AURA_TOKEN should match Booster.minter()");

        // Register all supported assets in MockBalances (for non-fork tests)
        _registerOracleAssets();

        // Set global user addresses - use addresses that have positions at the fork block
        mainnetUser = 0x12ba33C6B8Ac904b6FD9cb6DFf3FdB86BC19B75A;
        mainnetUser2 = 0xB5e6B574b35D732Cc0cE412D28Fe0584f43096Cf;
        testUser = address(0xbeef); // For tests that create positions
    }

    function _deployBalancesForOracle() internal returns (BalancesHarnessForFork) {
        // Register pool address and all pool tokens/reward tokens
        address[] memory allAssets = new address[](6);
        allAssets[0] = POOL; // Pool itself is the underlying asset
        allAssets[1] = USDT;
        allAssets[2] = USDC;
        allAssets[3] = GHO;
        allAssets[4] = AURA;
        allAssets[5] = BAL;

        return deployBalancesInFork(allAssets);
    }

    function _registerOracleAssets() internal {
        address[] memory assets = oracle.underlyingAssetsSupported();
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            try IERC20Metadata(asset).decimals() returns (uint8 decimals) {
                mockBalances.setAssetDecimals(asset, decimals);
            } catch {
                // If decimals() fails, use default 18 (common for many tokens)
                mockBalances.setAssetDecimals(asset, 18);
            }

            // If the asset is an ERC4626 vault, also register its underlying token
            try IERC4626(asset).asset() returns (address underlyingToken) {
                try IERC20Metadata(underlyingToken).decimals() returns (uint8 decimals) {
                    mockBalances.setAssetDecimals(underlyingToken, decimals);
                } catch {
                    mockBalances.setAssetDecimals(underlyingToken, 18);
                }
            } catch {
                // Not an ERC4626 vault, skip
            }
        }
        // Also register reward tokens and pool tokens that might not be in underlyingAssetsSupported
        address[] memory tokensToRegister = new address[](5);
        tokensToRegister[0] = USDT;
        tokensToRegister[1] = USDC;
        tokensToRegister[2] = GHO;
        tokensToRegister[3] = AURA;
        tokensToRegister[4] = BAL;

        for (uint256 i = 0; i < tokensToRegister.length; i++) {
            try IERC20Metadata(tokensToRegister[i]).decimals() returns (uint8 decimals) {
                mockBalances.setAssetDecimals(tokensToRegister[i], decimals);
            } catch {
                mockBalances.setAssetDecimals(tokensToRegister[i], 18);
            }
        }
    }

    function test_balanceOf_single_user() public {
        depositAura(testUser);

        assertOracleBalancesMatchRedemption(testUser);
    }

    function test_balanceOf_mainnet_user() public {
        assertOracleBalancesMatchRedemption(mainnetUser);
    }

    function test_balanceOf_mainnet_user2() public {
        assertOracleBalancesMatchRedemption(mainnetUser2);
    }

    function provideLiquidity(address sender) public returns (uint256, uint256) {
        vm.startPrank(address(sender));

        uint256[] memory amountsIn = new uint256[](3);
        amountsIn[0] = 0; // USDT
        amountsIn[1] = 1000e6; // GHO
        amountsIn[2] = 1000e6; // USDC

        bool[] memory wrapUnderlying = new bool[](3);
        wrapUnderlying[0] = false;
        wrapUnderlying[1] = true;
        wrapUnderlying[2] = true;

        // Deal tokens
        deal(USDT, address(sender), amountsIn[0]);
        deal(GHO, address(sender), 1000e18);
        deal(USDC, address(sender), 1000e18);

        // Approve tokens to Permit2
        IUSDT(USDT).approve(PERMIT2, 0); // Reset USDT allowance first
        IUSDT(USDT).approve(PERMIT2, type(uint256).max);
        IERC20(GHO).approve(PERMIT2, type(uint256).max);
        IERC20(USDC).approve(PERMIT2, type(uint256).max);

        // Approve Router on Permit2 for each token
        IPermit2(PERMIT2).approve(USDT, ROUTER, 0, type(uint48).max);
        IPermit2(PERMIT2).approve(USDT, ROUTER, type(uint160).max, type(uint48).max);
        IPermit2(PERMIT2).approve(GHO, ROUTER, type(uint160).max, type(uint48).max);
        IPermit2(PERMIT2).approve(USDC, ROUTER, type(uint160).max, type(uint48).max);

        uint256 bptBefore = IERC20(POOL).balanceOf(address(sender));

        // Add liquidity through router
        uint256 amountOut = IRouter(ROUTER)
            .addLiquidityUnbalancedToERC4626Pool(
                POOL,
                wrapUnderlying,
                amountsIn,
                800, // exactBptAmountOut - we want at least 1 wei of BPT
                false, // wethIsEth
                "" // no custom userData needed
            );

        uint256 bptAfter = IERC20(POOL).balanceOf(address(sender));
        uint256 bptReceived = bptAfter - bptBefore;

        vm.stopPrank();

        return (amountOut, bptReceived);
    }

    function redeemLiquidity(address sender) public {
        vm.startPrank(address(sender));

        // Approve router to spend BPT
        IERC20(POOL).approve(ROUTER, type(uint256).max);

        // Setup minimum amounts out (accepting any amount)
        uint256[] memory minAmountsOut = new uint256[](3);
        minAmountsOut[0] = 0; // USDT min
        minAmountsOut[1] = 0; // GHO min
        minAmountsOut[2] = 0; // USDC min

        // Setup unwrap flags
        bool[] memory unwrapWrapped = new bool[](3);
        unwrapWrapped[0] = true;
        unwrapWrapped[1] = true;
        unwrapWrapped[2] = true;

        // Get current BPT balance
        uint256 bptBalance = IERC20(POOL).balanceOf(address(sender));

        // Remove all BPT tokens
        IRouter(ROUTER)
            .removeLiquidityProportionalFromERC4626Pool(
                POOL,
                unwrapWrapped,
                bptBalance,
                minAmountsOut,
                false, // wethIsEth
                "" // userData
            );

        vm.stopPrank();
    }

    function depositAura(address sender) public {
        provideLiquidity(sender);
        vm.startPrank(sender);
        // Approve the gauge to spend the BPT
        IERC20(POOL).approve(BOOSTER, 0);
        IERC20(POOL).approve(BOOSTER, type(uint256).max);

        uint256 amount = IERC20(POOL).balanceOf(address(sender));

        // Deposit into the AURA gauge
        Booster(BOOSTER).deposit(AURA_PID, amount, true);

        amount = IERC20(POOL).balanceOf(address(sender));

        vm.stopPrank();
    }

    function redeemAllTokens(address sender) public {
        vm.startPrank(sender);
        BaseRewardPool4626(address(oracle.AURA_REWARDS())).withdrawAllAndUnwrap(true);

        redeemLiquidity(sender);

        vm.stopPrank();
    }

    function assertOracleBalancesMatchRedemption(address user) internal {
        // Declare token addresses and names
        address[5] memory tokens;
        tokens[0] = USDT;
        tokens[1] = USDC;
        tokens[2] = GHO;
        tokens[3] = AURA;
        tokens[4] = BAL;

        // Declare arrays to store oracle balances and before balances
        uint256[5] memory amounts;
        bool[5] memory isDebt;
        uint256[5] memory beforeBalances;

        // Get oracle balances and token balances before redemption
        for (uint256 i = 0; i < tokens.length; i++) {
            (uint256 amount, bool isDebt_) = oracle.getOracleBalanceForAsset(user, tokens[i]);
            amounts[i] = amount;
            isDebt[i] = isDebt_;
            beforeBalances[i] = IERC20(tokens[i]).balanceOf(user);
        }

        // Check that user has at least one non-zero position
        bool hasPosition = false;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (amounts[i] != 0) {
                hasPosition = true;
                break;
            }
        }
        assertTrue(hasPosition, "User should have at least one non-zero position");

        // Redeem tokens (will handle both gauge and regular redemption)
        redeemAllTokens(user);

        // Verify that redemption resulted in receiving tokens (for positions that were non-zero)
        for (uint256 i = 0; i < tokens.length; i++) {
            if (amounts[i] != 0) {
                uint256 received = IERC20(tokens[i]).balanceOf(user) - beforeBalances[i];
                // For positive oracle balances (credit positions), user should receive tokens
                if (!isDebt[i] && amounts[i] > 0) {
                    assertGt(received, 0, "User should receive tokens for positive oracle balance");
                }
            }
        }
    }
}

/// @title USDT Token Interface
/// @notice Interface for USDT token specific functionality
interface IUSDT {
    /// @notice Approves the spender to use a specified amount of tokens
    /// @param spender The address allowed to spend the tokens
    /// @param value The amount of tokens to approve
    function approve(address spender, uint256 value) external;
}

/// @title Permit2 Interface
/// @notice Interface for the Permit2 contract that handles token approvals
interface IPermit2 {
    /// @notice Approves the spender to use up to amount of the specified token up until the expiration
    /// @param token The token to approve
    /// @param spender The spender address to approve
    /// @param amount The approved amount of the token
    /// @param expiration The timestamp at which the approval is no longer valid
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @title Balancer Router Interface
/// @notice Interface for Balancer V3 router operations
interface IRouter {
    /// @notice Adds liquidity to an ERC4626 pool with unbalanced token amounts
    /// @param pool The address of the pool
    /// @param wrapUnderlying Whether to wrap underlying tokens
    /// @param exactAmountsIn The exact amounts of tokens to add
    /// @param minBptAmountOut The minimum amount of BPT tokens to receive
    /// @param wethIsEth Whether to treat WETH as ETH
    /// @param userData Additional data for the operation
    /// @return bptAmountOut The amount of BPT tokens received
    function addLiquidityUnbalancedToERC4626Pool(
        address pool,
        bool[] memory wrapUnderlying,
        uint256[] memory exactAmountsIn,
        uint256 minBptAmountOut,
        bool wethIsEth,
        bytes memory userData
    ) external payable returns (uint256 bptAmountOut);

    /// @notice Removes liquidity from an ERC4626 pool proportionally
    /// @param pool The address of the pool
    /// @param unwrapWrapped Whether to unwrap wrapped tokens
    /// @param exactBptAmountIn The exact amount of BPT tokens to burn
    /// @param minAmountsOut The minimum amounts of tokens to receive
    /// @param wethIsEth Whether to treat WETH as ETH
    /// @param userData Additional data for the operation
    /// @return tokensOut The addresses of tokens received
    /// @return amountsOut The amounts of tokens received
    function removeLiquidityProportionalFromERC4626Pool(
        address pool,
        bool[] memory unwrapWrapped,
        uint256 exactBptAmountIn,
        uint256[] memory minAmountsOut,
        bool wethIsEth,
        bytes memory userData
    ) external returns (address[] memory tokensOut, uint256[] memory amountsOut);
}

/// @title Balancer Gauge Interface
/// @notice Interface for Balancer V3 gauge operations
interface IBalancerGauge {
    /// @notice Withdraws staked tokens from the gauge
    /// @param value The amount of tokens to withdraw
    /// @param claimRewards Whether to claim pending rewards
    function withdraw(uint256 value, bool claimRewards) external;
}

interface Booster {
    function FEE_DENOMINATOR() external view returns (uint256);
    function maxFees() external view returns (uint256);
    function REWARD_MULTIPLIER_DENOMINATOR() external view returns (uint256);
    function addPool(address _lptoken, address _gauge, uint256 _stashVersion) external returns (bool);
    function bridgeDelegate() external view returns (address);
    function claimRewards(uint256 _pid, address _gauge) external returns (bool);
    function crv() external view returns (address);
    function deposit(uint256 _pid, uint256 _amount, bool _stake) external returns (bool);
    function depositAll(uint256 _pid, bool _stake) external returns (bool);
    function distributeL2Fees(uint256 _amount) external;
    function earmarkFees(address _feeToken) external returns (bool);
    function earmarkIncentive() external view returns (uint256);
    function earmarkRewards(uint256 _pid) external returns (bool);
    function feeManager() external view returns (address);
    function feeTokens(address) external view returns (address distro, address rewards, bool active);
    function gaugeMap(address) external view returns (bool);
    function getRewardMultipliers(address) external view returns (uint256);
    function isShutdown() external view returns (bool);
    function l2FeesHistory(uint256) external view returns (uint256);
    function lockIncentive() external view returns (uint256);
    function lockRewards() external view returns (address);
    function minter() external view returns (address);
    function owner() external view returns (address);
    function platformFee() external view returns (uint256);
    function poolInfo(uint256)
        external
        view
        returns (address lptoken, address token, address gauge, address crvRewards, address stash, bool shutdown);
    function poolLength() external view returns (uint256);
    function poolManager() external view returns (address);
    function rewardArbitrator() external view returns (address);
    function rewardClaimed(uint256 _pid, address _address, uint256 _amount) external returns (bool);
    function rewardFactory() external view returns (address);
    function setArbitrator(address _arb) external;
    function setBridgeDelegate(address _bridgeDelegate) external;
    function setDelegate(address _delegateContract, address _delegate, bytes32 _space) external;
    function setFactories(address _rfactory, address _sfactory, address _tfactory) external;
    function setFeeInfo(address _feeToken, address _feeDistro) external;
    function setFeeManager(address _feeM) external;
    function setFees(uint256 _lockFees, uint256 _stakerFees, uint256 _callerFees, uint256 _platform) external;
    function setGaugeRedirect(uint256 _pid) external returns (bool);
    function setOwner(address _owner) external;
    function setPoolManager(address _poolM) external;
    function setRewardContracts(address _rewards, address _stakerRewards) external;
    function setRewardMultiplier(address rewardContract, uint256 multiplier) external;
    function setTreasury(address _treasury) external;
    function setVote(bytes32 _hash) external returns (bool);
    function setVoteDelegate(address _voteDelegate) external;
    function shutdownPool(uint256 _pid) external returns (bool);
    function shutdownSystem() external;
    function staker() external view returns (address);
    function stakerIncentive() external view returns (uint256);
    function stakerRewards() external view returns (address);
    function stashFactory() external view returns (address);
    function tokenFactory() external view returns (address);
    function treasury() external view returns (address);
    function updateFeeInfo(address _feeToken, bool _active) external;
    function vote(uint256 _voteId, address _votingAddress, bool _support) external returns (bool);
    function voteDelegate() external view returns (address);
    function voteGaugeWeight(address[] memory _gauge, uint256[] memory _weight) external returns (bool);
    function voteOwnership() external view returns (address);
    function voteParameter() external view returns (address);
    function withdraw(uint256 _pid, uint256 _amount) external returns (bool);
    function withdrawAll(uint256 _pid) external returns (bool);
    function withdrawTo(uint256 _pid, uint256 _amount, address _to) external returns (bool);
}

interface BaseRewardPool4626 {
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event RewardAdded(uint256 reward);
    event RewardPaid(address indexed user, uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event Withdrawn(address indexed user, uint256 amount);

    function addExtraReward(address _reward) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function asset() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function clearExtraRewards() external;
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function currentRewards() external view returns (uint256);
    function decimals() external view returns (uint8);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function duration() external view returns (uint256);
    function earned(address account) external view returns (uint256);
    function extraRewards(uint256) external view returns (address);
    function extraRewardsLength() external view returns (uint256);
    function getReward() external returns (bool);
    function getReward(address _account, bool _claimExtras) external returns (bool);
    function historicalRewards() external view returns (uint256);
    function lastTimeRewardApplicable() external view returns (uint256);
    function lastUpdateTime() external view returns (uint256);
    function maxDeposit(address) external view returns (uint256);
    function maxMint(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function mint(uint256 shares, address receiver) external returns (uint256);
    function name() external view returns (string memory);
    function newRewardRatio() external view returns (uint256);
    function operator() external view returns (address);
    function periodFinish() external view returns (uint256);
    function pid() external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function processIdleRewards() external;
    function queueNewRewards(uint256 _rewards) external returns (bool);
    function queuedRewards() external view returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function rewardManager() external view returns (address);
    function rewardPerToken() external view returns (uint256);
    function rewardPerTokenStored() external view returns (uint256);
    function rewardRate() external view returns (uint256);
    function rewardToken() external view returns (address);
    function rewards(address) external view returns (uint256);
    function stake(uint256 _amount) external returns (bool);
    function stakeAll() external returns (bool);
    function stakeFor(address _for, uint256 _amount) external returns (bool);
    function stakingToken() external view returns (address);
    function symbol() external view returns (string memory);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function userRewardPerTokenPaid(address) external view returns (uint256);
    function withdraw(uint256 amount, bool claim) external returns (bool);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function withdrawAll(bool claim) external;
    function withdrawAllAndUnwrap(bool claim) external;
    function withdrawAndUnwrap(uint256 amount, bool claim) external returns (bool);
}
