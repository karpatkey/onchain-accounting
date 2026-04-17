// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {CurveBalanceOracle} from "src/balances/protocols/Curve.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title CurveBalanceOracle fork tests — weETH/WETH Pool (factory-stable-ng-157)
/// @notice Tests using the real Curve weETH/WETH pool on Ethereum mainnet
contract CurveBalanceOracleForkTest_weETH_WETH is BalanceAdapterTestBase {
    // weETH/WETH Curve pool (factory-stable-ng-157)
    address public constant GAUGE = 0x053df3e4D0CeD9a3Bf0494F97E83CE1f13BdC0E2;
    address public constant LP_TOKEN = 0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5;

    // Pool tokens
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;

    // Canonical CRV token
    address public constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    // Fork block matching source oracle tests
    uint256 public constant FORK_BLOCK = 24_444_658;

    // Account with fully staked LP tokens in the gauge
    address public constant USER_FULLY_STAKED = 0x8b3f91Dc0042DCe3828b6b97aF153ED92843f356;
    uint256 public constant USER_STAKED_WETH = 11_009_378_597_265_390;
    uint256 public constant USER_STAKED_WEETH = 28_630_344_888_716_619;

    // Account with only unstaked LP tokens (not in gauge)
    address public constant USER_UNSTAKED = 0x19ab096040F13cFa6a18ab2E0cA786bdFE8EAcD0;
    uint256 public constant USER_UNSTAKED_WETH = 110_258_088_747_932_900;
    uint256 public constant USER_UNSTAKED_WEETH = 286_730_725_057_283_488;

    CurveBalanceOracle public oracle;
    address internal unknownAccount;

    function setUp() public override {
        super.setUp();
        _setupFork();
        unknownAccount = makeAddr("unknownAccount");
        _setupOracle();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupOracle() internal {
        // Register both pool tokens (WETH + weETH) for getOraclePositions tests
        address[] memory assets = new address[](2);
        assets[0] = WETH;
        assets[1] = WEETH;
        balances = _deployBalancesForOracle(assets);
        oracle = new CurveBalanceOracle(GAUGE, "Curve", "weETH/WETH Pool", address(balances));
    }

    // ============================================
    // Interface Compliance Tests
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    function test_derivedLpToken() public view {
        assertEq(oracle.LP_TOKEN(), LP_TOKEN, "LP_TOKEN should be derived from gauge.lp_token()");
    }

    // ============================================
    // underlyingAssetsSupported Tests
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        // weETH/WETH pool has 2 tokens + CRV (minimum) = at least 3
        assertTrue(assets.length >= 3);

        bool hasWeth = false;
        bool hasWeEth = false;
        bool hasCrv = false;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == WETH) hasWeth = true;
            if (assets[i] == WEETH) hasWeEth = true;
            if (assets[i] == CRV) hasCrv = true;
        }
        assertTrue(hasWeth, "Should include WETH");
        assertTrue(hasWeEth, "Should include weETH");
        assertTrue(hasCrv, "Should include CRV");
    }

    // ============================================
    // Real Position Tests — Unstaked LP
    // ============================================

    function test_getOracleBalanceForAsset_unstaked_weth() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(USER_UNSTAKED, WETH);
        assertApproxEqAbs(amount, USER_UNSTAKED_WETH, 1e12, "Unstaked WETH balance within tolerance");
        assertGt(amount, 0);
    }

    function test_getOracleBalanceForAsset_unstaked_weEth() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(USER_UNSTAKED, WEETH);
        assertApproxEqAbs(amount, USER_UNSTAKED_WEETH, 1e12, "Unstaked weETH balance within tolerance");
        assertGt(amount, 0);
    }

    // ============================================
    // Real Position Tests — Staked LP
    // ============================================

    function test_getOracleBalanceForAsset_staked_weth() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(USER_FULLY_STAKED, WETH);
        assertApproxEqAbs(amount, USER_STAKED_WETH, 1e12, "Staked WETH balance within tolerance");
        assertGt(amount, 0);
    }

    function test_getOracleBalanceForAsset_staked_weEth() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(USER_FULLY_STAKED, WEETH);
        assertApproxEqAbs(amount, USER_STAKED_WEETH, 1e12, "Staked weETH balance within tolerance");
        assertGt(amount, 0);
    }

    function test_getOracleBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(USER_FULLY_STAKED, address(0xdead));
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_unknownAccount() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(unknownAccount, WETH);
        assertEq(amount, 0);
    }

    // ============================================
    // CRV Reward Tests
    // ============================================

    function test_crvClaimableAccurate_fullyStaked() public {
        // crvClaimableAccurate performs checkpointing and returns accurate CRV
        uint256 crvAccurate = oracle.crvClaimableAccurate(USER_FULLY_STAKED);
        // Source test: USER_FULLY_STAKED_CRV_REWARDS = 4_635_543_705_665_215_120 at fork block
        assertApproxEqAbs(
            crvAccurate, 4_635_543_705_665_215_120, 1e15, "Accurate CRV should match source oracle test value"
        );
    }

    function test_getCrvRewardsLowerBound_nonNegative() public view {
        // Lower bound may be less than accurate (stale integrate_fraction between checkpoints)
        uint256 lb = oracle.getCrvRewardsLowerBound(USER_FULLY_STAKED);
        // Lower bound ≤ accurate, but always non-negative
        assertTrue(lb <= 4_635_543_705_665_215_120 * 2, "Lower bound should be reasonable");
    }

    // ============================================
    // Position Aggregation Tests
    // ============================================

    function test_getOracleBalances_stakedUser() public view {
        (address[] memory assets, uint256[] memory amounts,) = oracle.getOracleBalances(USER_FULLY_STAKED);
        // Should include WETH and weETH (non-zero); CRV may be included if lower bound > 0
        assertTrue(assets.length >= 2, "Should have at least pool tokens");

        bool hasWeth = false;
        bool hasWeEth = false;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == WETH) {
                hasWeth = true;
                assertGt(amounts[i], 0);
            }
            if (assets[i] == WEETH) {
                hasWeEth = true;
                assertGt(amounts[i], 0);
            }
        }
        assertTrue(hasWeth, "Should include WETH");
        assertTrue(hasWeEth, "Should include weETH");
    }

    function test_getOracleBalances_unknownAccount() public view {
        (address[] memory assets,,) = oracle.getOracleBalances(unknownAccount);
        assertEq(assets.length, 0);
    }

    function test_getOraclePositions_stakedUser() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(USER_FULLY_STAKED, address(0));
        // WETH and weETH registered — should get 2 positions (pool tokens only; CRV not registered)
        assertEq(positions.length, 2, "Should have WETH and weETH positions");

        bool hasWeth = false;
        bool hasWeEth = false;
        for (uint256 i = 0; i < positions.length; i++) {
            assertGt(positions[i].amount, 0);
            assertFalse(positions[i].isDebt);
            assertEq(positions[i].protocol, "Curve");
            assertEq(positions[i].positionDetail, "weETH/WETH Pool");
            if (positions[i].underlyingAsset.asset == WETH) hasWeth = true;
            if (positions[i].underlyingAsset.asset == WEETH) hasWeEth = true;
        }
        assertTrue(hasWeth, "Should have WETH position");
        assertTrue(hasWeEth, "Should have weETH position");
    }

    function test_getOraclePositions_withAssetFilter() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(USER_FULLY_STAKED, WETH);
        assertEq(positions.length, 1);
        assertEq(positions[0].underlyingAsset.asset, WETH);
        assertGt(positions[0].amount, 0);

        INAVCalculator.PositionBalance[] memory empty = oracle.getOraclePositions(USER_FULLY_STAKED, address(0xdead));
        assertEq(empty.length, 0);
    }
}
