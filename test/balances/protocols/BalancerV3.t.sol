// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {TestSetupHelpers, BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {BalancerV3PoolBalanceOracle} from "src/balances/protocols/BalancerV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {InvalidArguments, NotAuthorized} from "src/errors.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";

contract Balancerv3Test is TestEnvConfigurator, TestSetupHelpers {
    BalancerV3PoolBalanceOracle public oracle;
    // Tokens in the pool
    address public constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant BAL = 0xba100000625a3754423978a60c9317c58a424e3D;
    // GHO/USDT/USDC Balancer V3 pool
    address public constant POOL = 0x85B2b559bC2D21104C4DEFdd6EFcA8A20343361D;
    address public constant USER = 0x849D52316331967b6fF1198e5E32A0eB168D039d;
    address public constant ROUTER = 0xb21A277466e7dB6934556a1Ce12eb3F032815c8A;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant GAUGE = 0x9fdD52eFEb601E4Bc78b89C6490505B8aC637E9f;
    address public constant BALANCER_RELAYER = 0x35Cea9e57A393ac66Aaa7E25C391D52C74B5648f;
    address public constant BALANCER_MINTER = 0x239e55F427D44C3cc793f49bFB507ebe76638a2b;
    uint256 fork;
    MockBalances mockBalances;
    BalancesHarnessForFork public balances;

    // Global user addresses with positions in Balancer V3
    address public mainnetStakedUser;
    address public mainnetUnstakedUser;
    address public mainnetWhaleUser;
    address public testUser;

    function setUp() public {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(22_087_430);
        mockBalances = new MockBalances();
        balances = _deployBalancesForOracle();
        oracle = new BalancerV3PoolBalanceOracle(POOL, GAUGE, BALANCER_MINTER, "Balancer v3", address(balances));

        // Register all supported assets in MockBalances (for non-fork tests)
        _registerOracleAssets();

        // Set global user addresses - use addresses that have positions at the fork block
        mainnetStakedUser = 0xd0ca2a7Ed8aeE7972750B085B27350f1Cd387F9b;
        mainnetUnstakedUser = 0x9fdD52eFEb601E4Bc78b89C6490505B8aC637E9f;
        mainnetWhaleUser = 0xaF52695E1bB01A16D33D7194C28C42b10e0Dbec2;
        testUser = address(0xbeef); // For tests that create positions
    }

    function _deployBalancesForOracle() internal returns (BalancesHarnessForFork) {
        // Register pool address and all pool tokens/reward tokens
        address[] memory allAssets = new address[](5);
        allAssets[0] = POOL; // Pool itself is the underlying asset
        allAssets[1] = USDT;
        allAssets[2] = USDC;
        allAssets[3] = GHO;
        allAssets[4] = BAL;
        
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
        // Also register pool tokens and reward tokens that might not be in underlyingAssetsSupported
        address[] memory tokensToRegister = new address[](4);
        tokensToRegister[0] = USDT;
        tokensToRegister[1] = USDC;
        tokensToRegister[2] = GHO;
        tokensToRegister[3] = BAL;

        for (uint256 i = 0; i < tokensToRegister.length; i++) {
            try IERC20Metadata(tokensToRegister[i]).decimals() returns (uint8 decimals) {
                mockBalances.setAssetDecimals(tokensToRegister[i], decimals);
            } catch {
                mockBalances.setAssetDecimals(tokensToRegister[i], 18);
            }
        }
    }

    function testConstructor() public view {
        assertEq(address(oracle.POOL()), POOL);
        assertEq(address(oracle.GAUGE()), GAUGE);
    }

    function testConstructorRevertZeroPool() public {
        vm.expectRevert(InvalidArguments.selector);
        new BalancerV3PoolBalanceOracle(address(0), GAUGE, BALANCER_MINTER, "Balancer v3", address(mockBalances));
    }

    function testConstructorRevertZeroGauge() public {
        vm.expectRevert(InvalidArguments.selector);
        new BalancerV3PoolBalanceOracle(POOL, address(0), BALANCER_MINTER, "Balancer v3", address(mockBalances));
    }

    function test_balanceOf_unstaked_bpt() public {
        address user = address(0xbeef);
        provideLiquidity(user);
        assertOracleBalancesMatchRedemption(user);
    }

    function test_balanceOf_oracle_mainnet_staked_gauge() public {
        vm.selectFork(fork);
        vm.rollFork(22_131_971);

        balances = _deployBalancesForOracle();
        oracle = new BalancerV3PoolBalanceOracle(POOL, GAUGE, BALANCER_MINTER, "Balancer v3", address(balances));

        address user = 0xd0ca2a7Ed8aeE7972750B085B27350f1Cd387F9b;
        assertOracleBalancesMatchRedemption(user);
    }

    function test_balanceOf_oracle_mainnet_unstaked_bpt() public {
        address user = 0x9fdD52eFEb601E4Bc78b89C6490505B8aC637E9f;
        assertOracleBalancesMatchRedemption(user);
    }

    function test_balanceOf_oracle_mainnet_staked_gauge_AfterRedeem() public {
        vm.selectFork(fork);
        vm.rollFork(22_131_954);
        balances = _deployBalancesForOracle();
        oracle = new BalancerV3PoolBalanceOracle(POOL, GAUGE, BALANCER_MINTER, "Balancer v3", address(balances));
        address user = 0xd0ca2a7Ed8aeE7972750B085B27350f1Cd387F9b;

        //console2.log("oracle balance before", oracle.balanceOf(USDC, user));

        //uint256 bptBefore = IERC20(POOL).balanceOf(user);

        //vm.startPrank(user);
        //uint256 gaugeBalance = IERC20(GAUGE).balanceOf(user);
        //IBalancerGauge(GAUGE).withdraw(gaugeBalance, true);
        //vm.stopPrank();

        //uint256 bptAfter = IERC20(POOL).balanceOf(user);

        //console2.log("oracle balance after", oracle.balanceOf(USDC, user));
        //console2.log("BPT : ", bptAfter - bptBefore);
        //console2.log("gaugeBalance : ", gaugeBalance);

        assertOracleBalancesMatchRedemption(user);
    }

    function test_balanceOf_oracle_mainnet_staked_gauge_whale() public {
        address user = 0xaF52695E1bB01A16D33D7194C28C42b10e0Dbec2;
        assertOracleBalancesMatchRedemption(user);
    }

    function testBalanceOfZeroForNonPoolToken() public {
        address randomToken = address(0x1234);

        provideLiquidity(testUser);

        int256 balance = oracle.getOracleBalanceForAsset(testUser, randomToken);
        assertEq(balance, 0);
    }

    function testBalanceOfZeroWhenNoBpt() public view {
        address deadAddress = address(0xdead);

        int256 ghoBalance = oracle.getOracleBalanceForAsset(deadAddress, GHO);
        assertEq(ghoBalance, 0);

        int256 usdtBalance = oracle.getOracleBalanceForAsset(deadAddress, USDT);
        assertEq(usdtBalance, 0);

        int256 usdcBalance = oracle.getOracleBalanceForAsset(deadAddress, USDC);
        assertEq(usdcBalance, 0);
    }

    // Helper functions
    function redeemGaugeAndRewards(address sender) public {
        bytes[] memory data = new bytes[](1);
        data[0] = gaugeMintPayload(GAUGE);

        vm.startPrank(sender);
        uint256 gaugeBalance = IERC20(GAUGE).balanceOf(sender);
        IBalancerMinter(BALANCER_MINTER).setMinterApproval(BALANCER_RELAYER, true);
        IBalancerRelayer(BALANCER_RELAYER).multicall(data);
        IBalancerGauge(GAUGE).claim_rewards(sender, sender);
        IBalancerGauge(GAUGE).withdraw(gaugeBalance, true);
        vm.stopPrank();
    }

    function gaugeMintPayload(address gaugeAddress) internal pure returns (bytes memory) {
        address[] memory gauges = new address[](1);
        gauges[0] = gaugeAddress;

        return abi.encodeWithSignature(
            "gaugeMint(address[],uint256)",
            gauges,
            0 // uint256 arg2
        );
    }

    function provideLiquidity(address sender) public returns (uint256, uint256) {
        vm.startPrank(address(sender));

        uint256[] memory amountsIn = new uint256[](3);
        amountsIn[0] = 0;
        amountsIn[1] = 1000e6; // 1000 GHO
        amountsIn[2] = 1000e6; // 1000 USDC

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
                1, // exactBptAmountOut - we want at least 1 wei of BPT
                false, // wethIsEth
                "" // no custom userData needed
            );

        uint256 bptAfter = IERC20(POOL).balanceOf(address(sender));
        uint256 bptReceived = bptAfter - bptBefore;

        vm.stopPrank();

        return (amountOut, bptReceived);
    }

    function redeemLiquidity(address sender) public returns (address[] memory, uint256[] memory) {
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
        //uint256 bptBalance = 83_323_088_530_129_652_620;

        //27_080_772_132_532_413_155; //

        // Remove all BPT tokens
        (address[] memory tokensOut, uint256[] memory amountsOut) = IRouter(ROUTER)
            .removeLiquidityProportionalFromERC4626Pool(
                POOL,
                unwrapWrapped,
                bptBalance,
                minAmountsOut,
                false, // wethIsEth
                "" // userData
            );

        vm.stopPrank();

        return (tokensOut, amountsOut);
    }

    function assertOracleBalancesMatchRedemption(address user) internal {
        // Get oracle balances before redemption
        int256 oracleBalanceUsdt = oracle.getOracleBalanceForAsset(user, USDT);
        int256 oracleBalanceUsdc = oracle.getOracleBalanceForAsset(user, USDC);
        int256 oracleBalanceGho = oracle.getOracleBalanceForAsset(user, GHO);
        int256 oracleBalanceBal = oracle.getOracleBalanceForAsset(user, BAL);

        // Check that user has at least one non-zero position
        bool hasPosition =
            oracleBalanceUsdt != 0 || oracleBalanceUsdc != 0 || oracleBalanceGho != 0 || oracleBalanceBal != 0;
        assertTrue(hasPosition, "User should have at least one non-zero position");

        // Get token balances before redemption
        uint256 beforeUsdt = IERC20(USDT).balanceOf(user);
        uint256 beforeUsdc = IERC20(USDC).balanceOf(user);
        uint256 beforeGho = IERC20(GHO).balanceOf(user);
        uint256 beforeBal = IERC20(BAL).balanceOf(user);

        // Redeem tokens
        redeemGaugeAndRewards(user);

        redeemLiquidity(user);

        // Calculate actual received amounts (after - before)
        uint256 receivedUsdt = IERC20(USDT).balanceOf(user) - beforeUsdt;
        uint256 receivedUsdc = IERC20(USDC).balanceOf(user) - beforeUsdc;
        uint256 receivedGho = IERC20(GHO).balanceOf(user) - beforeGho;
        uint256 receivedBal = IERC20(BAL).balanceOf(user) - beforeBal;

        // Verify that redemption resulted in receiving tokens for positions that were non-zero
        if (oracleBalanceUsdt > 0) {
            assertGt(receivedUsdt, 0, "User should receive USDT for positive oracle balance");
        }
        if (oracleBalanceUsdc > 0) {
            assertGt(receivedUsdc, 0, "User should receive USDC for positive oracle balance");
        }
        if (oracleBalanceGho > 0) {
            assertGt(receivedGho, 0, "User should receive GHO for positive oracle balance");
        }
        if (oracleBalanceBal > 0) {
            assertGt(receivedBal, 0, "User should receive BAL for positive oracle balance");
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
    function claim_rewards(address user, address receiver) external;
}

interface IBalancerMinter {
    function mintManyFor(address[] calldata gauges, address user) external returns (uint256);
    function setMinterApproval(address minter, bool status) external;
}

interface IBalancerLib {
    function gaugeMint(address[] calldata gauges, uint256 outputReference) external payable;
}

interface IBalancerRelayer {
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
    function functionDelegateCall(address target, bytes memory data) external returns (bytes memory);
}
